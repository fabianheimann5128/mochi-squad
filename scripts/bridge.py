"""Local MCP server for the coordinators. The app owns projects, agents and sessions; this process only
translates between MCP over HTTP (127.0.0.1, random port, bearer token) and the app (stdin/stdout).

Every coordinator session gets its own token, so the app knows which session is calling and judges a request by
that session's rights, not by anyone else's.

Protocol with the app:
  argv:   an optional port to listen on again after a restart (any free port otherwise)
  stdout: {"ready": true, "port": <port>}
  app → stdin: {"grant": "<token>", "caller": "<session id>"}   a session may call from now on
  app → stdin: {"revoke": "<token>"}                            the session ended
  stdout: {"id": "...", "tool": "...", "args": {...}, "caller": "<session id>"}   tool call
  app → stdin: {"id": "...", "result": {...}}                   answer
"""
import hmac
import json
import queue
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 128_000
MAX_ARG = 24_000
MIN_TOKEN = 32
ANSWER_TIMEOUT = 90


def tool(name, description, *fields):
    return name, {"name": name, "description": description, "inputSchema": {
        "type": "object", "additionalProperties": False, "required": [f[0] for f in fields],
        "properties": {key: {"type": "string", "description": text} for key, text in fields}}}


PROJECT = ("project", "Exact project path returned by list_projects.")
TOOLS = dict([
    tool("list_projects", "List the project folders registered in Mochi Squad."),
    tool("overview", "Read-only status of every project: agents, what they work on, open sessions and routines."),
    tool("list_agents", "List the named agents of one project.", PROJECT),
    tool("start_named_agent", "Give a named agent an assignment. It continues its open session or starts a new one.",
         PROJECT, ("agent", "Agent id from list_agents."), ("task", "The assignment, written for the agent.")),
    tool("list_jobs", "List live agent sessions with their state."),
    tool("list_chats", "List saved chats of a project.", PROJECT),
    tool("read_chat", "Read the recent messages of a saved chat.", PROJECT, ("chat", "Chat id from list_chats.")),
])


def valid_arguments(name, args):
    """Only known tools with exactly the required, non-empty text arguments."""
    schema = TOOLS.get(name, {}).get("inputSchema") if isinstance(name, str) else None
    return bool(schema) and isinstance(args, dict) and set(args) == set(schema["required"]) and all(
        isinstance(v, str) and v.strip() and len(v) <= MAX_ARG and "\x00" not in v for v in args.values())


class Relay:
    """Passes tool calls on to the app and waits for the matching answer. Also keeps the tokens the app granted."""

    def __init__(self, out):
        self.out = out
        self.lock = threading.Lock()
        self.waiting = {}
        self.grants = {}

    def caller(self, header):
        """Session id behind an Authorization header, or None. Every token is compared in constant time."""
        given, found = header.encode(), None
        with self.lock:
            grants = list(self.grants.items())
        for token, caller in grants:
            if hmac.compare_digest(given, b"Bearer " + token.encode()):
                found = caller
        return found

    def call(self, name, args, caller="", timeout=ANSWER_TIMEOUT):
        ident = uuid.uuid4().hex
        box = queue.Queue(maxsize=1)
        with self.lock:
            self.waiting[ident] = box
            self.out.write(json.dumps({"id": ident, "tool": name, "args": args, "caller": caller}) + "\n")
            self.out.flush()
        try:
            return box.get(timeout=timeout)
        except queue.Empty:
            return {"error": "Mochi Squad did not answer in time. Check list_jobs before retrying."}
        finally:
            with self.lock:
                self.waiting.pop(ident, None)

    def answer(self, line):
        """Handle one line from the app: a grant, a revocation or an answer. Faulty lines are ignored."""
        try:
            message = json.loads(line)
            if isinstance(message, dict) and "grant" in message:
                token, caller = message["grant"], message.get("caller")
                if not (isinstance(token, str) and len(token) >= MIN_TOKEN and isinstance(caller, str) and caller):
                    return False
                with self.lock:
                    self.grants[token] = caller
                return True
            if isinstance(message, dict) and "revoke" in message:
                with self.lock:
                    return self.grants.pop(message["revoke"], None) is not None
            ident, result = message["id"], message["result"]
        except (ValueError, KeyError, TypeError):
            return False
        with self.lock:
            box = self.waiting.get(ident)
        if box is None:
            return False
        try:
            box.put_nowait(result if isinstance(result, dict) else {"error": "Invalid answer"})
        except queue.Full:
            return False
        return True


def handle_rpc(call, relay, caller=""):
    """JSON-RPC message → (HTTP status, answer or None)."""
    if not isinstance(call, dict) or call.get("jsonrpc") != "2.0":
        return 400, None
    method, reply = call.get("method"), {"jsonrpc": "2.0", "id": call.get("id")}
    if isinstance(method, str) and method.startswith("notifications/") and "id" not in call:
        return 202, None
    if method == "initialize":
        reply["result"] = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                           "serverInfo": {"name": "mochi", "version": "1.0"}}
    elif method == "ping":
        reply["result"] = {}
    elif method == "tools/list":
        reply["result"] = {"tools": list(TOOLS.values())}
    elif method == "tools/call":
        params = call.get("params") if isinstance(call.get("params"), dict) else {}
        name, args = params.get("name"), params.get("arguments", {})
        answer = relay.call(name, args, caller) if valid_arguments(name, args) else {"error": "Invalid tool arguments"}
        reply["result"] = {"content": [{"type": "text", "text": json.dumps(answer, ensure_ascii=False)}],
                           "isError": "error" in answer}
    else:
        reply["error"] = {"code": -32601, "message": "Method not found"}
    return 200, reply


class Handler(BaseHTTPRequestHandler):
    timeout = 15

    def log_message(self, *args):
        pass

    def send(self, status, payload=None):
        data = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send(405)

    def do_POST(self):
        port = self.server.server_address[1]
        # No browser (Origin) and no foreign host name (DNS rebinding); tokens are compared in constant time.
        if self.path != "/mcp":
            return self.send(404)
        if self.headers.get("Host") not in {f"127.0.0.1:{port}", f"localhost:{port}"} or self.headers.get("Origin"):
            return self.send(403)
        caller = self.server.relay.caller(self.headers.get("Authorization", ""))
        if caller is None:
            return self.send(401)
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.send(411)
        if not 0 < length <= MAX_BODY:
            return self.send(413)
        try:
            call = json.loads(self.rfile.read(length))
        except ValueError:
            return self.send(400)
        status, reply = handle_rpc(call, self.server.relay, caller)
        self.send(status, reply)


def listen(port=0):
    """Binds to the wanted port, or to any free one if it is taken (or none is wanted)."""
    if port:
        try:
            return ThreadingHTTPServer(("127.0.0.1", port), Handler)
        except OSError:
            pass
    return ThreadingHTTPServer(("127.0.0.1", 0), Handler)


def serve(inp=sys.stdin, out=sys.stdout, port=0):
    server = listen(port)
    server.daemon_threads = True
    server.relay = Relay(out)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    out.write(json.dumps({"ready": True, "port": server.server_address[1]}) + "\n")
    out.flush()
    try:
        for line in inp:
            server.relay.answer(line)
    finally:
        server.shutdown()
        server.server_close()


def main():
    # After a restart the app asks for the port of the first start, which running sessions still use.
    wanted = sys.argv[1] if len(sys.argv) > 1 else ""
    serve(port=int(wanted) if wanted.isdigit() and 1024 < int(wanted) < 65536 else 0)


if __name__ == "__main__":
    main()
