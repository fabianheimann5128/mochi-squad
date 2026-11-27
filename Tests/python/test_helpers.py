import json
import os
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
import compact  # noqa: E402
import launcher  # noqa: E402
import limits  # noqa: E402
import memory  # noqa: E402
import routine  # noqa: E402


class PostTests(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(post.parse(["list"]), {"to": "?", "text": ""})
        self.assertEqual(post.parse(["send", "Karo", "Hello", "you"]), {"to": "Karo", "text": "Hello you"})
        # The German verbs of earlier versions still work: running sessions were briefed with them.
        self.assertEqual(post.parse(["liste"]), {"to": "?", "text": ""})
        self.assertEqual(post.parse(["sende", "Karo", "Hallo"]), {"to": "Karo", "text": "Hallo"})
        for wrong in ([], ["send", "Karo"], ["send", "Karo", "  "], ["approve", "x.mp4"], ["list", "x"]):
            self.assertIsNone(post.parse(wrong))

    def test_send_waits_for_receipt(self):
        with tempfile.TemporaryDirectory() as box:
            box = Path(box)

            def app():
                for _ in range(100):
                    letters = list(box.glob("out-*.json"))
                    if letters:
                        letter = letters[0]
                        (box / (letter.stem + ".result")).write_text("Delivered.")
                        letter.unlink()
                        return
                    time.sleep(0.02)
            threading.Thread(target=app, daemon=True).start()
            self.assertEqual(post.send(box, {"to": "Karo", "text": "Hi"}, wait=3), "Delivered.")
            self.assertEqual(list(box.iterdir()), [])

    def test_send_gives_up_cleanly(self):
        with tempfile.TemporaryDirectory() as box:
            self.assertIn("Not delivered", post.send(Path(box), {"to": "X", "text": "Hi"}, wait=0.3))
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
        prompt = common.BRIEFING_MARK + "\nYou are Mira …" + common.TASK_MARK + "Check the sources."
        self.assertEqual(history.user_text(prompt), "Check the sources.")
        self.assertEqual(history.user_text(common.SESSION_LINE + "1234\n" + prompt), "Check the sources.")
        # Chats written by earlier versions used German markers and still read correctly.
        legacy = common.BRIEFING_MARK + "\nDu bist Mira …\n[Auftrag]\nPrüfe die Quellen."
        self.assertEqual(history.user_text(legacy), "Prüfe die Quellen.")
        self.assertEqual(history.user_text("Sitzung 1234\n" + legacy), "Prüfe die Quellen.")
        self.assertEqual(history.user_text("<system-reminder>x"), "")
        self.assertEqual(history.user_text("<pasted_content>Hello</pasted_content>"), "Hello")
        self.assertEqual(history.user_text(None), "")

    def test_codex_item(self):
        self.assertEqual(history.codex_item({"type": "AgentMessage", "content": [{"text": "a"}, "broken", {"text": "b"}]}),
                         ("assistant", "a\n\nb"))
        self.assertEqual(history.codex_item({"type": "Other"}), ("", ""))


    def test_long_history_is_read_from_its_end(self):
        """The first page of a long file comes from its tail; every message stays reachable by asking for more."""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "chat.jsonl"
            with path.open("w") as log:
                for index in range(9000):
                    log.write(json.dumps({"type": "user", "timestamp": "2026-01-01T00:00:00Z",
                                          "message": {"content": f"message {index} " + "x" * 600}}) + "\n")
            self.assertGreater(path.stat().st_size, history.TAIL_BYTES)
            page = history.read(str(path), "claude", 0, 40)
            self.assertEqual(len(page["messages"]), 40)
            self.assertTrue(page["messages"][-1]["text"].startswith("message 8999 "))
            self.assertTrue(page["older"])
            self.assertEqual(page["position"], path.stat().st_size)
            everything = history.read(str(path), "claude", 0, 20000)
            self.assertTrue(everything["messages"][0]["text"].startswith("message 0 "))
            self.assertFalse(everything["older"])


class LimitTests(unittest.TestCase):
    def test_claude_limits_are_kept_for_the_whole_subscription(self):
        with tempfile.TemporaryDirectory() as data:
            self.assertIsNone(limits.claude(data))
            limits.remember_claude({"five_hour": {"used_percentage": 41.5, "resets_at": 1796000000}, "seven_day": {"used_percentage": 12}}, data,
                                   now="2026-11-27T12:00:00Z")
            entry = limits.claude(data)
            self.assertEqual(entry["five"], {"percent": 41.5, "resets": 1796000000})
            self.assertEqual(entry["week"], {"percent": 12.0, "resets": None})
            # A report without limits keeps the last one.
            limits.remember_claude({}, data)
            self.assertEqual(limits.claude(data)["stamp"], "2026-11-27T12:00:00Z")

    def test_codex_limits_come_from_the_newest_history(self):
        with tempfile.TemporaryDirectory() as home:
            day = Path(home) / "sessions/2026/11/27"
            day.mkdir(parents=True)
            report = {"timestamp": "2026-11-27T13:48:02Z", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
                "primary": {"used_percent": 12.0, "window_minutes": 10080, "resets_at": 1796050916},
                "secondary": {"used_percent": 130, "window_minutes": 300, "resets_at": None}}}}
            (day / "rollout-a.jsonl").write_text('{"type": "session_meta"}\n' + json.dumps(report) + "\n" + '{"type": "event_msg", "payload": {}}\n')
            entry = limits.codex(home, "codex", data=home)
            self.assertEqual(entry["week"], {"percent": 12.0, "resets": 1796050916})
            self.assertEqual(entry["five"]["percent"], 100.0)
            self.assertEqual(entry["stamp"], "2026-11-27T13:48:02Z")
            with tempfile.TemporaryDirectory() as empty:
                self.assertIsNone(limits.codex(Path(home) / "missing", "codex", data=empty))

    def test_codex_prefers_the_most_recently_written_file_and_keeps_the_last_value(self):
        with tempfile.TemporaryDirectory() as home:
            def report(day, percent, mtime):
                folder = Path(home) / ("sessions/2026/11/%02d" % day)
                folder.mkdir(parents=True, exist_ok=True)
                file = folder / ("rollout-%d.jsonl" % day)
                file.write_text(json.dumps({"timestamp": "t", "payload": {"rate_limits": {
                    "primary": {"used_percent": percent, "window_minutes": 10080, "resets_at": 1796050916}}}}) + "\n")
                os.utime(file, (mtime, mtime))
            report(24, 97, 2000)
            for day in (25, 26, 27):
                report(day, 18, 1000)
            # 4.1: a conversation continued later lies in an older day folder.
            self.assertEqual(limits.codex(home, "codex", data=home)["week"]["percent"], 97.0)
            # 4.2: newer conversations without a report keep the last value.
            for day in (28, 29, 30):
                folder = Path(home) / ("sessions/2026/11/%02d" % day)
                folder.mkdir(parents=True)
                (folder / "rollout-x.jsonl").write_text('{"type": "session_meta"}\n')
            for file in Path(home).glob("sessions/2026/11/2[4-7]/*.jsonl"):
                file.unlink()
            self.assertEqual(limits.codex(home, "codex", data=home)["week"]["percent"], 97.0)

    def test_broken_reports_are_skipped_and_values_checked(self):
        with tempfile.TemporaryDirectory() as data:
            # 4.3: a broken stored window is dropped, values over 100 are clamped.
            (Path(data) / limits.CLAUDE_FILE).write_text(json.dumps({"five": {"percent": "x"}, "week": {"percent": 125, "resets": 1e100}, "stamp": "s"}))
            entry = limits.claude(data)
            self.assertIsNone(entry["five"])
            self.assertEqual(entry["week"], {"percent": 100.0, "resets": None})
            # 4.4: an odd report does not stop the search.
            day = Path(data) / "sessions/2026/11/27"
            day.mkdir(parents=True)
            good = {"timestamp": "t", "payload": {"rate_limits": {"primary": {"used_percent": 20, "window_minutes": 10080}}}}
            odd = {"timestamp": "t", "payload": {"rate_limits": {"primary": ["not", "a", "dict"]}}}
            (day / "rollout-a.jsonl").write_text(json.dumps(good) + "\n" + json.dumps(odd) + "\n")
            self.assertEqual(limits.codex(data, "codex", data=data)["week"]["percent"], 20.0)
            self.assertIsNone(limits.window(float("nan")))
            self.assertIsNone(limits.window(True))


class MemoryTests(unittest.TestCase):
    def test_notes_reach_the_briefing(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home) / "Mochi Memory"
            root.mkdir()
            (root / "About me.md").write_text("---\nmochi: profile\n---\n# About me\n\n- Likes short answers · Mira · 2026-11-27\n")
            (root / "Shop.md").write_text('---\nmochi: project\nproject: "/tmp/shop"\n---\n# Shop\n\n- [[About me]]\n- Runs on Shopify\n')
            (root / "Random.md").write_text("- not a memory note\n")
            folder, profile, project = memory.for_project("/tmp/shop", settings={}, home=home)
            self.assertEqual(folder, root)
            self.assertEqual(profile, ["Likes short answers"])
            self.assertEqual(project, ["Runs on Shopify"])
            chosen = memory.folder({"memoryFolder": "/elsewhere"}, home)
            self.assertEqual(chosen, Path("/elsewhere"))
            spec = launcher.attach_memory({"project": "/tmp/shop"}, settings={}, home=home)
            spec.update(post="/x/post", team=[], unattended=False)
            self.assertEqual(spec["memoryProject"], ["Runs on Shopify"])

    def test_remember_command(self):
        self.assertEqual(post.parse(["remember", "Uses", "Shopify"]), {"to": "@memory", "text": "Uses Shopify"})
        self.assertEqual(post.parse(["remember", "--about-me", "Likes tea"]), {"to": "@memory-me", "text": "Likes tea"})
        self.assertIsNone(post.parse(["remember"]))
        self.assertIsNone(post.parse(["remember", "--about-me"]))


class SyntheticTests(unittest.TestCase):
    def test_client_error_notes_stay_messages_without_model(self):
        with tempfile.TemporaryDirectory() as folder:
            journal = Path(folder) / "chat.jsonl"
            rows = [{"type": "user", "message": {"content": "hello"}},
                    {"type": "assistant", "message": {"model": "claude-opus-5-5", "content": [{"type": "text", "text": "hi"}],
                                                      "usage": {"input_tokens": 10, "cache_read_input_tokens": 0}}},
                    {"type": "assistant", "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "Not logged in"}],
                                                      "usage": {"input_tokens": 0}}}]
            journal.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            result = history.read(journal, "claude", 0, 40)
            self.assertEqual([m["role"] for m in result["messages"]], ["user", "assistant", "assistant"])
            self.assertEqual(result["usage"]["model"], "claude-opus-5-5")
            self.assertEqual(result["usage"]["used"], 10)


class CompactTests(unittest.TestCase):
    def test_commands_run_without_tools_or_saved_sessions(self):
        claude = compact.claude_command("/bin/claude", "P")
        self.assertIn("--no-session-persistence", claude)
        self.assertEqual(claude[claude.index("--tools") + 1], "")
        self.assertIn("--strict-mcp-config", claude)
        codex = compact.codex_command("/bin/codex", "P", "/tmp/x", "/tmp/x/o.txt", "gpt-x", [("srv", True, "node", [])])
        self.assertIn("--ephemeral", codex)
        self.assertEqual(codex[codex.index("--sandbox") + 1], "read-only")
        self.assertIn("mcp_servers.srv.enabled=false", codex)
        self.assertEqual(codex[-1], "P")

    def test_short_or_missing_conversations_are_refused(self):
        self.assertIn("error", compact.summarise("claude", "/does/not/exist"))
        self.assertIn("error", compact.summarise("other", "/x"))
        with tempfile.TemporaryDirectory() as folder:
            journal = Path(folder) / "chat.jsonl"
            journal.write_text(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
            self.assertIn("error", compact.summarise("claude", str(journal)))

    def test_conversation_keeps_the_newest_part(self):
        with tempfile.TemporaryDirectory() as folder:
            journal = Path(folder) / "chat.jsonl"
            rows = [{"type": "user" if i % 2 == 0 else "assistant", "message": {"content": "message %d " % i + "x" * 50}} for i in range(40)]
            journal.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            text = compact.conversation(journal, "claude", limit=500)
            self.assertLessEqual(len(text), 500)
            self.assertIn("message 39", text)


class DirectiveTests(unittest.TestCase):
    def test_codex_directives_are_hidden(self):
        self.assertEqual(history.agent_text('::browser-complete{title="Checked views"}'), "")
        self.assertEqual(history.agent_text('Done.\n\n::browser-complete{title="x"}\n'), "Done.")
        self.assertEqual(history.agent_text("Use `a::b{c}` here"), "Use `a::b{c}` here")
        self.assertEqual(history.codex_item({"type": "AgentMessage", "content": [{"text": '::git-stage{cwd="/x"}'}]}),
                         ("assistant", ""))


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

    def test_states_tell_connected_from_its_opposites(self):
        self.assertEqual(connectors.claude_state("✓ Connected"), "ok")
        for broken in ("✗ Disconnected", "Not connected", "✗ Failed to connect"):
            self.assertEqual(connectors.claude_state(broken), "error", broken)
        self.assertEqual(connectors.claude_state("! Needs authentication"), "login")
        self.assertEqual(connectors.claude_state("something new"), "unknown")
        self.assertEqual(connectors.codex_state({"enabled": False, "auth_status": "o_auth"}), "off")
        self.assertEqual(connectors.codex_state({"auth_status": "not_logged_in"}), "login")
        self.assertEqual(connectors.codex_state({"auth_status": "unsupported"}), "ok")
        self.assertEqual(connectors.codex_state({"auth_status": "brand_new_state"}), "unknown")

    def test_main_rejects_unknown_provider_and_missing_args(self):
        with self.assertRaises(ValueError):
            connectors.main("list", "gpt", "/tmp")
        with self.assertRaises(ValueError):
            connectors.main("login", "claude", "/tmp")


class QuietRoutineTests(unittest.TestCase):
    def test_task_carries_trigger_previous_result_and_quiet_rule(self):
        plain = routine.routine_task({"task": "Check the shop."}, "Alex")
        self.assertEqual(plain, "Check the shop.")
        quiet = routine.routine_task({"task": "Check the shop.", "quiet": True, "trigger": "folder", "folder": "/tmp/in"}, "Alex", "3 orders")
        self.assertIn("`/tmp/in` just changed", quiet)
        self.assertIn("3 orders", quiet)
        self.assertIn(routine.NOTHING_NEW, quiet)
        self.assertTrue(routine.silent("Looked at everything.\nNOTHING_NEW"))
        self.assertFalse(routine.silent("Two new orders came in."))

    def test_started_runs_carry_their_message(self):
        task = routine.routine_task({"task": "Report on the shop.", "trigger": "keyword"}, "Alex", given="only orders from today")
        self.assertTrue(task.startswith("Alex started this run with the message"))
        self.assertIn("only orders from today", task)
        self.assertIn("Report on the shop.", task)

    def test_previous_output_skips_failures_silence_and_other_routines(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "runs.jsonl"
            rows = [{"routine": "a1", "code": 0, "output": "first"}, {"routine": "b2", "code": 0, "output": "other"},
                    {"routine": "a1", "code": 1, "output": "broken"}, {"routine": "a1", "code": 0, "output": "NOTHING_NEW", "silent": True}]
            log.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            self.assertEqual(routine.previous_output("a1", log), "first")
            self.assertEqual(routine.previous_output("zz", log), "")
            self.assertEqual(routine.previous_output("a1", Path(folder) / "missing"), "")


class RoutineTests(unittest.TestCase):
    def test_find_and_build(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / "routines.json"
            routine_data = {"id": "r1", "active": True, "provider": "claude", "project": folder, "task": "Read the news.",
                            "allowWeb": True, "agent": {"id": "a", "name": "Mira", "canEdit": False}}
            file.write_text(json.dumps([routine_data, "broken"]))
            found = routine.find_routine("r1", file)
            self.assertEqual(found["task"], "Read the news.")
            self.assertIsNone(routine.find_routine("nope", file))
            spec = routine.build_spec(found, "Alex", str(uuid.uuid4()))
            self.assertTrue(spec["unattended"] and spec["allowWeb"])

    def test_coordinator_routine_runs_without_tool_claims(self):
        with tempfile.TemporaryDirectory() as folder:
            data = {"id": "r2", "provider": "claude", "project": folder, "task": "Summarise the state.",
                    "agent": {"id": "c", "name": "Mochi", "isCoordinator": True}}
            spec = routine.build_spec(data, "Alex", str(uuid.uuid4()))
            self.assertFalse(spec["agent"]["isCoordinator"])
            self.assertEqual(spec["agent"]["job"], "coordinator")
            self.assertNotIn("start_named_agent", launcher.build_prompt(spec))
            self.assertNotIn("--mcp-config", launcher.claude_args(spec, interactive=False))

    def test_only_one_run_of_a_routine_at_a_time(self):
        with tempfile.TemporaryDirectory() as folder:
            first = routine.single_run("r1", folder)
            self.assertIsNotNone(first)
            self.assertIsNone(routine.single_run("r1", folder))
            other = routine.single_run("r2", folder)
            self.assertIsNotNone(other)
            first.close()
            again = routine.single_run("r1", folder)
            self.assertIsNotNone(again)
            again.close()
            other.close()

    def test_find_routine_survives_bad_file(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / "routines.json"
            file.write_text("{broken")
            self.assertIsNone(routine.find_routine("r1", file))

    def test_records_are_appended(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "runs.jsonl"
            routine.append_record({"routine": "a"}, log)
            routine.append_record({"routine": "b"}, log)
            self.assertEqual([json.loads(x)["routine"] for x in log.read_text().splitlines()], ["a", "b"])


class TelegramTests(unittest.TestCase):
    def update(self, text="hi", user=7, chat=None, kind="private", **extra):
        message = {"from": {"id": user, "first_name": "Alex", "username": "alex"}, "chat": {"id": user if chat is None else chat, "type": kind}}
        if text is not None:
            message["text"] = text
        message.update(extra)
        return {"update_id": 1, "message": message}

    def test_only_the_paired_account_in_a_private_chat_is_heard(self):
        import telegram
        self.assertEqual(telegram.classify(self.update("hello"), 7), ("message", {"user": 7, "text": "hello"}))
        self.assertIsNone(telegram.classify(self.update("hello"), 8))
        self.assertIsNone(telegram.classify(self.update("hello"), None))
        self.assertIsNone(telegram.classify(self.update("hello", kind="group", chat=-5), 7))
        self.assertIsNone(telegram.classify(self.update("hello", chat=99), 7))
        self.assertIsNone(telegram.classify({"update_id": 2}, 7))
        self.assertEqual(telegram.classify(self.update(None, photo=[{}]), 7), ("unsupported", {"user": 7}))
        self.assertIsNone(telegram.classify(self.update(None, photo=[{}]), 8))

    def test_pairing_needs_a_proper_code(self):
        import telegram
        code = "A" * 32
        kind, event = telegram.classify(self.update("/start " + code, user=9), None)
        self.assertEqual((kind, event["code"], event["user"], event["name"], event["username"]), ("start", code, 9, "Alex", "alex"))
        # A plain /start or a short code pairs nobody and is no message either.
        self.assertIsNone(telegram.classify(self.update("/start"), 7))
        self.assertIsNone(telegram.classify(self.update("/start short"), 7))

    def test_long_answers_are_split(self):
        import telegram
        parts = telegram.chunks("a" * 3000 + "\n" + "b" * 3000)
        self.assertEqual(parts, ["a" * 3000, "b" * 3000])
        self.assertTrue(all(len(p) <= telegram.CHUNK for p in telegram.chunks("x" * 9001)))
        self.assertEqual("".join(telegram.chunks("x" * 9001)), "x" * 9001)

    def test_answers_go_to_the_paired_account_only(self):
        import io
        import telegram
        from unittest import mock
        link = telegram.Link("123456:" + "t" * 35, out=io.StringIO())
        with mock.patch.object(telegram, "call") as call:
            link.command(json.dumps({"send": "hi", "to": 7}))
            call.assert_not_called()
            link.command(json.dumps({"allow": 7}))
            link.command(json.dumps({"send": "hi", "to": 8}))
            call.assert_not_called()
            link.command(json.dumps({"send": "hi", "to": 7}))
            self.assertEqual(call.call_args[0][2]["chat_id"], 7)


class DesktopControlTests(unittest.TestCase):
    """Reading the client's `/mcp` dialog, as it arrives from the terminal."""

    def test_terminal_output_is_reduced_to_plain_lines(self):
        import computer
        raw = "\x1b[2K\x1b[1m  ❯\x1b[3Ccomputer-use\x1b[0m\r\n\r\n   Other MCPs\r\n".encode()
        self.assertEqual(computer.plain(raw), ["❯computer-use", "OtherMCPs"])

    def test_selection_mark_and_detail_view(self):
        import computer
        self.assertTrue(computer.marked(["claude.aiGmail", "❯computer-use"]))
        self.assertFalse(computer.marked(["❯claude.aiGmail", "computer-use"]))
        self.assertFalse(computer.marked(["computer-use"]))
        self.assertEqual(computer.view_state(["computer-use", "MCPserver", "Status:◯disabled", "❯Enable", "Back"]), "enable")
        self.assertEqual(computer.view_state(["Status:✔connected", "Capabilities:24tools", "❯Viewtools", "Disableinthisproject"]), "enabled")
        self.assertIsNone(computer.view_state(["somethingelse"]))

    def test_a_project_is_only_set_up_once(self):
        import computer
        from unittest import mock
        with tempfile.TemporaryDirectory() as folder:
            with mock.patch.object(common, "DATA", Path(folder)), mock.patch.object(computer, "enable", return_value="enabled") as enable:
                self.assertEqual(computer.ensure("/bin/claude", "/p/one"), "enabled")
                self.assertEqual(computer.ensure("/bin/claude", "/p/one"), "already")
                self.assertEqual(enable.call_count, 1)
            # A failed attempt is not remembered: the next session tries again.
            with mock.patch.object(common, "DATA", Path(folder)), mock.patch.object(computer, "enable", return_value="failed") as enable:
                computer.ensure("/bin/claude", "/p/two")
                computer.ensure("/bin/claude", "/p/two")
                self.assertEqual(enable.call_count, 2)


class CommonTests(unittest.TestCase):
    def test_project_key_and_private_files(self):
        self.assertEqual(common.project_key("/Users/a b/Project.x"), "-Users-a-b-Project-x")
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "secret.json"
            common.write_private(path, "{}")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(common.read_json(path), {})
            self.assertEqual(common.read_json(Path(folder) / "missing.json", 5), 5)

    def test_language_follows_the_app(self):
        import os
        from unittest import mock
        with mock.patch.dict(os.environ, {"MOCHI_LANG": "de"}):
            self.assertEqual(common.t("yes", "ja"), "ja")
        with mock.patch.dict(os.environ, {"MOCHI_LANG": "en"}):
            self.assertEqual(common.t("yes", "ja"), "yes")
        with mock.patch.dict(os.environ, {"MOCHI_LANG": "xx"}):
            self.assertEqual(common.language(), "en")

    def test_clean_child_env(self):
        env = common.clean_child_env({"CLAUDECODE": "1", "CLAUDE_CODE_X": "1", "PATH": "/bin"})
        self.assertEqual(env, {"PATH": "/bin"})


if __name__ == "__main__":
    unittest.main()
