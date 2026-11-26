import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import common  # noqa: E402
import launcher  # noqa: E402


def make_spec(project, **agent):
    base = {"name": "Mira", "job": "Researcherin", "instructions": "Recherchiere Quellen.", "persona": "",
            "model": "", "effort": "", "canEdit": False, "isCoordinator": False}
    base.update(agent)
    return launcher.validate_spec({"provider": "claude", "project": project, "task": "Prüfe die Quellen.",
                                   "sessionId": str(uuid.uuid4()).upper(), "owner": "Alex", "agent": base})


class SpecTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.project = self.dir.name

    def tearDown(self):
        self.dir.cleanup()

    def test_valid_spec_is_normalised(self):
        spec = make_spec(self.project, canEdit="yes")
        self.assertEqual(spec["sessionId"], spec["sessionId"].lower())
        self.assertFalse(spec["agent"]["canEdit"], "Nur echtes true erlaubt Schreibrechte")
        self.assertEqual(spec["project"], str(Path(self.project).resolve()))

    def test_rejects_bad_input(self):
        good = {"provider": "claude", "project": self.project, "task": "x", "sessionId": str(uuid.uuid4()),
                "agent": {"name": "A"}}
        for change in ({"provider": "gpt"}, {"project": "relative/path"}, {"project": "/does/not/exist"},
                       {"task": "  "}, {"sessionId": "nope"}, {"agent": {"name": ""}}, {"agent": "x"}):
            with self.subTest(change=change), self.assertRaises(launcher.SpecError):
                launcher.validate_spec(dict(good, **change))

    def test_load_spec_reports_unreadable_file(self):
        path = Path(self.project) / "spec.json"
        path.write_text("{kaputt")
        with self.assertRaises(launcher.SpecError):
            launcher.load_spec(path)


class PromptTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def test_task_follows_marker_and_briefing_names_agent(self):
        prompt = launcher.build_prompt(make_spec(self.dir.name))
        briefing, task = prompt.split(common.TASK_MARK)
        self.assertTrue(briefing.startswith(common.BRIEFING_MARK))
        self.assertIn("Du bist Mira, Researcherin im Agenten-Team von Alex", briefing)
        self.assertIn("Recherchiere Quellen.", briefing)
        self.assertEqual(task, "Prüfe die Quellen.")

    def test_coordinator_and_routine_notes(self):
        spec = make_spec(self.dir.name, isCoordinator=True, job="")
        spec["unattended"] = True
        prompt = launcher.build_prompt(spec)
        self.assertIn("Koordinator", prompt)
        self.assertIn("geplante Routine", prompt)

    def test_post_instructions_only_with_post_tool(self):
        spec = make_spec(self.dir.name)
        self.assertNotIn(" liste`", launcher.build_prompt(spec))
        spec.update(post="/tmp/x/post", team=["Karo (Autorin)"])
        prompt = launcher.build_prompt(spec)
        self.assertIn("/tmp/x/post liste", prompt)
        self.assertIn("Karo (Autorin)", prompt)


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.project = str(Path(self.dir.name).resolve())

    def tearDown(self):
        self.dir.cleanup()

    def settings(self, **agent):
        return launcher.build_claude_settings(make_spec(self.project, **agent), home="/Users/test")

    def test_every_agent_is_sandboxed_without_escape(self):
        for can_edit in (False, True):
            sandbox = self.settings(canEdit=can_edit)["sandbox"]
            self.assertTrue(sandbox["enabled"])
            self.assertFalse(sandbox["allowUnsandboxedCommands"])
            for secret in (".ssh", ".codex", ".claude", "Library/Application Support"):
                self.assertIn("/Users/test/" + secret, sandbox["filesystem"]["denyRead"])

    def test_read_only_agent_cannot_write_the_project(self):
        settings = self.settings()
        self.assertEqual(settings["sandbox"]["filesystem"]["denyWrite"], [self.project])
        self.assertNotIn("allowWrite", settings["sandbox"]["filesystem"])
        self.assertFalse(any(rule.startswith(("Edit", "Bash")) for rule in settings["permissions"]["allow"]))

    def test_editing_agent_writes_project_but_not_client_settings(self):
        settings = self.settings(canEdit=True)
        self.assertIn(f"Edit(/{self.project}/**)", settings["permissions"]["allow"])
        self.assertIn(f"Edit(/{self.project}/.claude/**)", settings["permissions"]["deny"])
        self.assertEqual(settings["sandbox"]["filesystem"]["denyWrite"][0], self.project + "/.claude")

    def test_post_rule_needs_tool_and_outbox_and_only_opens_the_outbox(self):
        spec = make_spec(self.project)
        spec["post"] = "/x/bin/post"
        self.assertFalse(any("post" in r for r in launcher.build_claude_settings(spec)["permissions"]["allow"]))
        spec["outbox"] = "/x/outbox/abc"
        settings = launcher.build_claude_settings(spec)
        self.assertIn("Bash(/x/bin/post:*)", settings["permissions"]["allow"])
        self.assertEqual(settings["sandbox"]["filesystem"]["allowWrite"], ["/x/outbox/abc"])

    def test_coordinator_and_web_rights_are_explicit(self):
        spec = make_spec(self.project, isCoordinator=True)
        spec["allowWeb"] = True
        allow = launcher.build_claude_settings(spec)["permissions"]["allow"]
        self.assertIn("mcp__mochi", allow)
        self.assertIn("WebFetch", allow)
        self.assertNotIn("WebFetch", self.settings()["permissions"]["allow"])
        self.assertNotIn("mcp__mochi", self.settings()["permissions"]["allow"])


class RuntimeTests(unittest.TestCase):
    """Pfade einer Sitzung kommen nie aus der Datei, sondern aus dem Sitzungsordner der App."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = Path(self.dir.name).resolve()
        self.project = root / "projekt"
        self.session = root / "sessions" / "abc"
        self.shared = root / "shared"
        for folder in (self.project, self.session, self.shared / "bin", self.shared / "outbox" / "abc"):
            folder.mkdir(parents=True)
        (self.shared / "bin" / "post").write_text("#!/bin/sh")

    def tearDown(self):
        self.dir.cleanup()

    def spec(self, provider="claude", **agent):
        spec = make_spec(str(self.project), **agent)
        spec.update(provider=provider, postEnabled=True)
        return spec

    def test_paths_from_the_file_are_ignored(self):
        spec = launcher.validate_spec({"provider": "claude", "project": str(self.project), "task": "x", "sessionId": str(uuid.uuid4()),
                                       "agent": {"name": "A"}, "post": "/bin/sh", "outbox": "/tmp", "mcpConfig": "/tmp/evil.json",
                                       "contextFile": "/tmp/c.json", "parentChat": "../../x"})
        for key in ("post", "outbox", "mcpConfig", "contextFile"):
            self.assertNotIn(key, spec)
        self.assertIsNone(spec["parentChat"])

    def test_runtime_paths_derive_from_session_folder(self):
        spec = launcher.attach_runtime(self.spec(), self.session, shared=self.shared)
        self.assertEqual(spec["post"], str(self.shared / "bin" / "post"))
        self.assertEqual(spec["outbox"], str(self.shared / "outbox" / "abc"))
        self.assertEqual(spec["contextFile"], str(self.session / "context.json"))

    def test_read_only_codex_agent_can_post(self):
        self.assertIn("post", launcher.attach_runtime(self.spec(provider="codex"), self.session, shared=self.shared))

    def test_coordinator_needs_its_tool_config(self):
        with self.assertRaises(launcher.SpecError):
            launcher.attach_runtime(self.spec(isCoordinator=True), self.session, shared=self.shared)
        (self.session / "mcp.json").write_text("{}")
        spec = launcher.attach_runtime(self.spec(isCoordinator=True), self.session, shared=self.shared)
        args = launcher.claude_args(spec)
        self.assertIn("--strict-mcp-config", args)
        self.assertEqual(args[args.index("--mcp-config") + 1], str(self.session / "mcp.json"))

    def test_run_rejects_specs_outside_the_session_area(self):
        outside = self.project / "spec.json"
        outside.write_text("{}")
        with self.assertRaises(SystemExit) as failure:
            launcher.run(str(outside))
        self.assertIn("Sitzungsbereich", str(failure.exception))


class ArgumentTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def test_claude_arguments(self):
        spec = make_spec(self.dir.name, model="opus", effort="high")
        spec.update(parentChat="abcdef12-3456")
        args = launcher.claude_args(spec)
        self.assertEqual(args[:2], ["--session-id", spec["sessionId"]])
        json.loads(args[args.index("--settings") + 1])
        for flag in ("--resume", "--fork-session"):
            self.assertIn(flag, args)
        self.assertNotIn("--mcp-config", args)
        self.assertEqual(args[args.index("--model") + 1], "opus")
        self.assertEqual(launcher.claude_args(spec, interactive=False)[0], "-p")

    def test_unknown_effort_is_dropped(self):
        self.assertNotIn("--effort", launcher.claude_args(make_spec(self.dir.name, effort="ultra; rm")))

    def test_codex_profile_follows_edit_right(self):
        home = Path("/Users/test")
        reader = launcher.build_codex_permissions(make_spec(self.dir.name), home=home)
        self.assertEqual(reader["filesystem"][":project_roots"], {".": "read"})
        self.assertNotIn(":tmpdir", reader["filesystem"])
        self.assertFalse(reader["network"]["enabled"])
        spec = make_spec(self.dir.name, canEdit=True)
        spec.update(outbox="/x/outbox/abc", allowWeb=True)
        editor = launcher.build_codex_permissions(spec, home=home)
        self.assertEqual(editor["filesystem"][":project_roots"]["."], "write")
        self.assertEqual(editor["filesystem"]["/x/outbox/abc"], "write")
        self.assertTrue(editor["network"]["enabled"])
        for secret in (".ssh", ".codex", ".claude", "Library/Application Support"):
            self.assertEqual(editor["filesystem"][str(home / secret)], "none")

    def test_codex_args_use_profile_instead_of_sandbox_flag(self):
        spec = make_spec(self.dir.name, canEdit=True, effort="minimal")
        args = launcher.codex_args(spec)
        self.assertNotIn("--sandbox", args)
        self.assertIn('default_permissions="mochi"', args)
        profile = next(a for a in args if a.startswith("permissions.mochi="))
        self.assertIn('":root" = "read"', profile)
        self.assertIn('web_search="disabled"', args)
        self.assertIn('model_reasoning_effort="minimal"', args)

    def test_codex_profile_check_fails_closed(self):
        spec = make_spec(self.dir.name)
        script = Path(self.dir.name) / "fake-codex"
        # Ein Client, der das Profil übergeht: jeder Befehl gelingt.
        script.write_text("#!/bin/sh\nexit 0\n")
        script.chmod(0o755)
        self.assertFalse(launcher.codex_profile_enforced(str(script), spec))
        # Ein Client ohne Unterbefehl „sandbox“: nichts gelingt.
        script.write_text("#!/bin/sh\nexit 2\n")
        self.assertFalse(launcher.codex_profile_enforced(str(script), spec))
        self.assertFalse(launcher.codex_profile_enforced(str(script) + "-fehlt", spec))
        # Ein Client, der die Sperre durchsetzt: der Lesetest scheitert, der Leerlauf gelingt.
        script.write_text('#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in /usr/bin/true) exit 0;; *) exit 1;; esac\n')
        self.assertTrue(launcher.codex_profile_enforced(str(script), spec))

    def test_editors_cannot_touch_client_folders(self):
        spec = make_spec(self.dir.name, canEdit=True)
        codex = launcher.build_codex_permissions(spec, home=Path("/Users/test"))
        claude = launcher.build_claude_settings(spec, home=Path("/Users/test"))
        for folder in (".claude", ".codex", ".git/hooks"):
            self.assertEqual(codex["filesystem"][":project_roots"][folder], "read")
            self.assertIn(str(Path(spec["project"]) / folder), claude["sandbox"]["filesystem"]["denyWrite"])
            self.assertIn(f"Edit(/{spec['project']}/{folder}/**)", claude["permissions"]["deny"])

    def test_codex_sees_only_its_own_outbox(self):
        spec = make_spec(self.dir.name)
        own = str(common.OUTBOXES / "abc")
        spec["outbox"] = own
        files = launcher.build_codex_permissions(spec)["filesystem"]
        self.assertEqual(files[str(common.OUTBOXES)], "none")
        self.assertEqual(files[own], "write")

    def test_project_must_not_expose_home(self):
        home = Path(self.dir.name).resolve()
        (home / "Library" / "Caches").mkdir(parents=True)
        (home / "Projekt").mkdir()
        for bad in (home, home.parent, Path("/"), home / "Library", home / "Library" / "Caches"):
            self.assertFalse(common.project_allowed(bad, home=home), bad)
        self.assertTrue(common.project_allowed(home / "Projekt", home=home))
        with self.assertRaises(launcher.SpecError):
            launcher.validate_spec(make_spec(str(common.HOME)))

    def test_toml_keeps_unicode(self):
        self.assertEqual(launcher._toml({"/Users/zoë 😀": "none"}), '{"/Users/zoë 😀" = "none"}')

    def test_codex_switches_off_personal_tool_servers(self):
        script = Path(self.dir.name) / "fake-codex"
        script.write_text('#!/bin/sh\necho \'[{"name":"postiz","enabled":true,"transport":{"url":"https://x"}},{"name":"aus","enabled":false},{"name":"node_repl","transport":{"command":"node"}}]\'\n')
        script.chmod(0o755)
        servers = launcher.codex_servers(str(script))
        self.assertEqual(servers, [("postiz", False), ("node_repl", True)])
        args = launcher.codex_args(make_spec(self.dir.name), servers=servers)
        self.assertIn("mcp_servers.postiz.enabled=false", args)
        self.assertIn("mcp_servers.node_repl.enabled=false", args)
        self.assertIn('mcp_servers.node_repl.command="/usr/bin/false"', args)
        self.assertNotIn('mcp_servers.postiz.command="/usr/bin/false"', args)
        # Nicht lesbar oder nicht abschaltbar heißt: nicht starten.
        script.write_text('#!/bin/sh\necho \'[{"name":"a.b=true"}]\'\n')
        self.assertIsNone(launcher.codex_servers(str(script)))
        script.write_text("#!/bin/sh\necho kaputt\n")
        self.assertIsNone(launcher.codex_servers(str(script)))
        self.assertIsNone(launcher.codex_servers(str(script) + "-fehlt"))

    def test_toml_escapes_keys(self):
        self.assertEqual(launcher._toml({'a "b"': {"c": True}}), '{"a \\"b\\"" = {"c" = true}}')


if __name__ == "__main__":
    unittest.main()
