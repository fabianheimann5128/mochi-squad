import json
import sys
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import common  # noqa: E402
import connectors  # noqa: E402
import context  # noqa: E402
import history  # noqa: E402
import post  # noqa: E402
import routine  # noqa: E402


class PostTests(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(post.parse(["liste"]), {"to": "?", "text": ""})
        self.assertEqual(post.parse(["sende", "Karo", "Hallo", "du"]), {"to": "Karo", "text": "Hallo du"})
        for wrong in ([], ["sende", "Karo"], ["sende", "Karo", "  "], ["freigabe", "x.mp4"], ["liste", "x"]):
            self.assertIsNone(post.parse(wrong))

    def test_send_waits_for_receipt(self):
        with tempfile.TemporaryDirectory() as box:
            box = Path(box)

            def app():
                for _ in range(100):
                    letters = list(box.glob("out-*.json"))
                    if letters:
                        letter = letters[0]
                        (box / (letter.stem + ".result")).write_text("Zugestellt.")
                        letter.unlink()
                        return
                    time.sleep(0.02)
            threading.Thread(target=app, daemon=True).start()
            self.assertEqual(post.send(box, {"to": "Karo", "text": "Hi"}, wait=3), "Zugestellt.")
            self.assertEqual(list(box.iterdir()), [])

    def test_send_gives_up_cleanly(self):
        with tempfile.TemporaryDirectory() as box:
            self.assertIn("Nicht zugestellt", post.send(Path(box), {"to": "X", "text": "Hi"}, wait=0.3))
            self.assertEqual(list(Path(box).iterdir()), [])


class OutboxTests(unittest.TestCase):
    def test_outbox_must_be_a_session_outbox(self):
        import os
        from unittest import mock
        with tempfile.TemporaryDirectory() as home:
            real = Path(home).resolve() / "Library" / "Caches" / "dev.mochisquad.app" / "outbox" / "abc"
            real.mkdir(parents=True)
            with mock.patch.object(Path, "home", return_value=Path(home).resolve()):
                with mock.patch.dict(os.environ, {"MOCHI_OUTBOX": str(real)}):
                    self.assertEqual(post.outbox(), real)
                for wrong in (home, str(real.parent), str(real / ".." / ".." / "bin"), ""):
                    with mock.patch.dict(os.environ, {"MOCHI_OUTBOX": wrong}):
                        self.assertIsNone(post.outbox(), wrong)


class HistoryTests(unittest.TestCase):
    def test_user_text_shows_only_the_task(self):
        prompt = common.BRIEFING_MARK + "\nDu bist Mira …" + common.TASK_MARK + "Prüfe die Quellen."
        self.assertEqual(history.user_text(prompt), "Prüfe die Quellen.")
        codex = "Sitzung 1234\n" + prompt
        self.assertEqual(history.user_text(codex), "Prüfe die Quellen.")
        self.assertEqual(history.user_text("<system-reminder>x"), "")
        self.assertEqual(history.user_text("<pasted_content>Hallo</pasted_content>"), "Hallo")
        self.assertEqual(history.user_text(None), "")

    def test_codex_item(self):
        self.assertEqual(history.codex_item({"type": "AgentMessage", "content": [{"text": "a"}, "kaputt", {"text": "b"}]}),
                         ("assistant", "a\n\nb"))
        self.assertEqual(history.codex_item({"type": "Other"}), ("", ""))


class ContextTests(unittest.TestCase):
    def test_claude_statusline_tolerates_missing_numbers(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "context.json"
            context.claude(target, {"transcript_path": "/x.jsonl", "context_window": {
                "current_usage": {"input_tokens": None, "cache_read_input_tokens": 5}}})
            data = json.loads(target.read_text())
            self.assertEqual(data["used"], 5)
            self.assertEqual(data["historyPath"], "/x.jsonl")
            self.assertEqual([p.name for p in Path(folder).iterdir()], ["context.json"])

    def test_codex_record(self):
        data = {}
        context.codex_record(data, {"type": "event_msg", "payload": {"type": "token_count", "info": {
            "model_context_window": 200, "last_token_usage": {"total_tokens": 50, "input_tokens": 40,
                                                              "cached_input_tokens": 10}}}})
        self.assertEqual((data["used"], data["limit"], data["percent"], data["fresh"]), (50, 200, 25.0, 30))


class ConnectorTests(unittest.TestCase):
    def test_url_check(self):
        for good in ("https://mcp.example.com/sse", "http://localhost:3000/mcp", "http://127.0.0.1:9/x"):
            self.assertTrue(connectors.check_url(good), good)
        for bad in ("http://example.com", "https://user:pw@x.com", "https://x.com/?token=1", "ftp://x.com", "x"):
            self.assertFalse(connectors.check_url(bad), bad)

    def test_main_rejects_unknown_provider_and_missing_args(self):
        with self.assertRaises(ValueError):
            connectors.main("list", "gpt", "/tmp")
        with self.assertRaises(ValueError):
            connectors.main("login", "claude", "/tmp")


class RoutineTests(unittest.TestCase):
    def test_find_and_build(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / "routines.json"
            routine_data = {"id": "r1", "active": True, "provider": "claude", "project": folder, "task": "Lies die News.",
                            "allowWeb": True, "agent": {"id": "a", "name": "Mira", "canEdit": False}}
            file.write_text(json.dumps([routine_data, "kaputt"]))
            found = routine.find_routine("r1", file)
            self.assertEqual(found["task"], "Lies die News.")
            self.assertIsNone(routine.find_routine("nope", file))
            spec = routine.build_spec(found, "Alex", str(uuid.uuid4()))
            self.assertTrue(spec["unattended"] and spec["allowWeb"])

    def test_find_routine_survives_bad_file(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / "routines.json"
            file.write_text("{kaputt")
            self.assertIsNone(routine.find_routine("r1", file))

    def test_records_are_appended(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "runs.jsonl"
            routine.append_record({"routine": "a"}, log)
            routine.append_record({"routine": "b"}, log)
            self.assertEqual([json.loads(x)["routine"] for x in log.read_text().splitlines()], ["a", "b"])


class CommonTests(unittest.TestCase):
    def test_project_key_and_private_files(self):
        self.assertEqual(common.project_key("/Users/a b/Projekt.x"), "-Users-a-b-Projekt-x")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "secret.json"
            common.write_private(path, "{}")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(common.read_json(path), {})
            self.assertEqual(common.read_json(Path(folder) / "missing.json", 5), 5)

    def test_clean_child_env(self):
        env = common.clean_child_env({"CLAUDECODE": "1", "CLAUDE_CODE_X": "1", "PATH": "/bin"})
        self.assertEqual(env, {"PATH": "/bin"})


if __name__ == "__main__":
    unittest.main()
