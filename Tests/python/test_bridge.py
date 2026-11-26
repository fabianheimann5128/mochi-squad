import http.client
import io
import json
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import bridge  # noqa: E402

TOKEN = "t" * 40
CALLER = "11111111-2222-3333-4444-555555555555"


class FakeApp:
    """Plays the app: reads the server's tool calls and answers them."""

    def __init__(self):
        self.to_server_r, self.to_server_w = io.StringIO(), None
        self.lines = []
        self.answers = []
        self.cond = threading.Condition()

    def write(self, text):
        with self.cond:
            self.lines.extend(x for x in text.splitlines() if x)
            self.cond.notify_all()

    def flush(self):
        pass

    def wait_line(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for line in self.lines:
                    data = json.loads(line)
                    if predicate(data):
                        return data
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError("no matching line")
                self.cond.wait(remaining)


class BlockingInput:
    def __init__(self):
        self.queue = []
        self.cond = threading.Condition()
        self.closed = False

    def push(self, line):
        with self.cond:
            self.queue.append(line)
            self.cond.notify_all()

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify_all()

    def __iter__(self):
        while True:
            with self.cond:
                while not self.queue and not self.closed:
                    self.cond.wait()
                if not self.queue:
                    return
                line = self.queue.pop(0)
            yield line


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.app = FakeApp()
        self.inp = BlockingInput()
        self.thread = threading.Thread(target=bridge.serve, args=(self.inp, self.app), daemon=True)
        self.thread.start()
        self.port = self.app.wait_line(lambda d: d.get("ready"))["port"]
        self.inp.push(json.dumps({"grant": TOKEN, "caller": CALLER}) + "\n")
        self.wait_until(lambda: self.post({"jsonrpc": "2.0", "id": 0, "method": "ping"})[0] == 200)

    def tearDown(self):
        self.inp.close()
        self.thread.join(5)

    def wait_until(self, check, timeout=5):
        deadline = time.monotonic() + timeout
        while not check():
            if time.monotonic() > deadline:
                raise AssertionError("condition not met in time")
            time.sleep(0.02)

    def post(self, body, headers=None, raw=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = raw if raw is not None else json.dumps(body).encode()
        base = {"Host": f"127.0.0.1:{self.port}", "Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}
        base.update(headers or {})
        conn.request("POST", "/mcp", body=data, headers=base)
        response = conn.getresponse()
        payload = response.read()
        conn.close()
        return response.status, json.loads(payload) if payload else None

    def test_random_port_and_tool_list(self):
        self.assertGreater(self.port, 1024)
        status, reply = self.post({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        self.assertEqual(status, 200)
        names = {t["name"] for t in reply["result"]["tools"]}
        self.assertIn("start_named_agent", names)
        self.assertNotIn("start_agent", names)

    def test_rejects_wrong_token_origin_and_host(self):
        call = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
        self.assertEqual(self.post(call, {"Authorization": "Bearer " + "x" * 40})[0], 401)
        self.assertEqual(self.post(call, {"Origin": "https://evil.example"})[0], 403)
        self.assertEqual(self.post(call, {"Host": "evil.example"})[0], 403)

    def test_rejects_oversized_and_invalid_bodies(self):
        self.assertEqual(self.post(None, raw=b"x" * (bridge.MAX_BODY + 1))[0], 413)
        self.assertEqual(self.post(None, raw=b"{broken")[0], 400)
        self.assertEqual(self.post({"id": 1, "method": "ping"})[0], 400)

    def test_tool_call_round_trip_through_app(self):
        def answer():
            call = self.app.wait_line(lambda d: d.get("tool") == "list_projects")
            self.assertEqual(call["caller"], CALLER)
            self.inp.push("not a json line\n")
            self.inp.push(json.dumps({"id": call["id"], "result": {"projects": []}}) + "\n")
        threading.Thread(target=answer, daemon=True).start()
        status, reply = self.post({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                   "params": {"name": "list_projects", "arguments": {}}})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(reply["result"]["content"][0]["text"]), {"projects": []})
        self.assertFalse(reply["result"]["isError"])

    def test_invalid_arguments_never_reach_app(self):
        status, reply = self.post({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                   "params": {"name": "list_agents", "arguments": {"project": "", "x": "y"}}})
        self.assertTrue(reply["result"]["isError"])
        self.assertFalse(any("list_agents" in line for line in self.app.lines))


    def test_every_session_has_its_own_token(self):
        """A second session is told apart by its token, short tokens are refused, and a revoked token stops working."""
        other, second = "o" * 40, "99999999-2222-3333-4444-555555555555"
        self.inp.push(json.dumps({"grant": other, "caller": second}) + "\n")
        self.inp.push(json.dumps({"grant": "short", "caller": second}) + "\n")
        ping = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
        self.wait_until(lambda: self.post(ping, {"Authorization": "Bearer " + other})[0] == 200)
        self.assertEqual(self.post(ping, {"Authorization": "Bearer short"})[0], 401)

        def answer():
            call = self.app.wait_line(lambda d: d.get("tool") == "list_jobs")
            self.inp.push(json.dumps({"id": call["id"], "result": {"caller": call["caller"]}}) + "\n")
        threading.Thread(target=answer, daemon=True).start()
        _, reply = self.post({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "list_jobs", "arguments": {}}},
                             {"Authorization": "Bearer " + other})
        self.assertEqual(json.loads(reply["result"]["content"][0]["text"]), {"caller": second})
        self.inp.push(json.dumps({"revoke": other}) + "\n")
        self.wait_until(lambda: self.post(ping, {"Authorization": "Bearer " + other})[0] == 401)
        self.assertEqual(self.post(ping)[0], 200)


class ValidationTests(unittest.TestCase):
    def test_valid_arguments(self):
        self.assertTrue(bridge.valid_arguments("list_agents", {"project": "/p"}))
        self.assertFalse(bridge.valid_arguments("list_agents", {}))
        self.assertFalse(bridge.valid_arguments("nope", {}))
        self.assertFalse(bridge.valid_arguments("list_agents", {"project": "a\x00b"}))
        self.assertFalse(bridge.valid_arguments("list_agents", {"project": 3}))
        self.assertFalse(bridge.valid_arguments(["list_agents"], {"project": "/p"}))


if __name__ == "__main__":
    unittest.main()
