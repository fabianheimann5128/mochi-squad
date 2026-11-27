import json
import os
import sys
import tempfile
import unittest
import uuid
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import common  # noqa: E402
import launcher  # noqa: E402


def make_spec(project, **agent):
    base = {"name": "Mira", "job": "researcher", "instructions": "Research sources.", "persona": "",
            "model": "", "effort": "", "canEdit": False, "isCoordinator": False}
    base.update(agent)
    return launcher.validate_spec({"provider": "claude", "project": project, "task": "Check the sources.",
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
        self.assertFalse(spec["agent"]["canEdit"], "only a real true grants write access")
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
        path.write_text("{broken")
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
        self.assertIn("You are Mira, researcher in Alex's team of agents", briefing)
        self.assertIn("Research sources.", briefing)
        self.assertEqual(task, "Check the sources.")

    def test_agents_answer_in_the_language_they_are_addressed_in(self):
        english = launcher.build_prompt(make_spec(self.dir.name))
        self.assertIn("Always answer in the language of the message you are answering", english)
        self.assertIn("use English", english)
        spec = make_spec(self.dir.name)
        spec["language"] = "de"
        self.assertIn("use German", launcher.build_prompt(spec))
        self.assertEqual(launcher.validate_spec(dict(spec, language="fr"))["language"], "en")

    def test_coordinator_and_routine_notes(self):
        spec = make_spec(self.dir.name, isCoordinator=True, job="")
        spec["unattended"] = True
        prompt = launcher.build_prompt(spec)
        self.assertIn("coordinator", prompt)
        self.assertIn("scheduled routine", prompt)

    def test_post_instructions_only_with_post_tool(self):
        spec = make_spec(self.dir.name)
        self.assertNotIn(" list`", launcher.build_prompt(spec))
        spec.update(post="/tmp/x/post", team=["Karo (writer)"])
        prompt = launcher.build_prompt(spec)
        self.assertIn("/tmp/x/post list", prompt)
        self.assertIn("Karo (writer)", prompt)


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
            # No sandbox, no session: the client must quit rather than work unprotected.
            self.assertTrue(sandbox["failIfUnavailable"])
            self.assertFalse(sandbox["allowUnsandboxedCommands"])
            # Local ports stay closed.
            self.assertNotIn("network", sandbox)
            for secret in (".ssh", ".codex", ".claude", "Library/Application Support"):
                self.assertIn("/Users/test/" + secret, sandbox["filesystem"]["denyRead"])

    def test_file_tools_are_locked_out_like_commands(self):
        """Every path that is locked for commands is locked for the client's own file tools too."""
        settings = self.settings()
        for path in settings["sandbox"]["filesystem"]["denyRead"]:
            self.assertIn(f"Read(/{path})", settings["permissions"]["deny"])
            self.assertIn(f"Read(/{path}/**)", settings["permissions"]["deny"])
        self.assertIn("Read(//Users/test/.ssh/**)", settings["permissions"]["deny"])

    def test_relocated_client_folders_are_locked_too(self):
        import os
        with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": "/Volumes/x/claude", "CODEX_HOME": "/Volumes/x/codex"}):
            spec = make_spec(self.project)
            claude = launcher.build_claude_settings(spec, home="/Users/test")
            codex = launcher.build_codex_permissions(spec, home="/Users/test")
        for moved in ("/Volumes/x/claude", "/Volumes/x/codex"):
            self.assertIn(moved, claude["sandbox"]["filesystem"]["denyRead"])
            self.assertEqual(codex["filesystem"][moved], "none")

    def test_routines_without_web_cannot_fetch(self):
        spec = make_spec(self.project)
        spec["unattended"] = True
        deny = launcher.build_claude_settings(spec, home="/Users/test")["permissions"]["deny"]
        self.assertIn("WebFetch", deny)
        self.assertIn("WebSearch", deny)
        spec["allowWeb"] = True
        allowed = launcher.build_claude_settings(spec, home="/Users/test")["permissions"]
        self.assertIn("WebFetch", allowed["allow"])
        self.assertNotIn("WebFetch", allowed["deny"])
        # In a chat the user is there to confirm a request, so nothing is denied outright.
        self.assertNotIn("WebFetch", self.settings()["permissions"]["deny"])

    def test_routines_load_no_project_settings_or_servers(self):
        """Without the user present there is no trust question, so a routine takes nothing from the project."""
        spec = make_spec(self.project)
        spec["unattended"] = True
        args = launcher.claude_args(spec, interactive=False)
        self.assertEqual(args[args.index("--setting-sources") + 1], "user")
        self.assertIn("--strict-mcp-config", args)
        self.assertNotIn("--mcp-config", args)
        self.assertNotIn("--setting-sources", launcher.claude_args(make_spec(self.project)))

    def test_read_only_agent_cannot_write_the_project(self):
        settings = self.settings()
        self.assertEqual(settings["sandbox"]["filesystem"]["denyWrite"][0], self.project)
        # M7: the locked paths (memory folder among them) can never be written, also inside a writable project.
        self.assertEqual(settings["sandbox"]["filesystem"]["denyWrite"][1:], settings["sandbox"]["filesystem"]["denyRead"])
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
    """A session's paths never come from the file but from the app's session folder."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = Path(self.dir.name).resolve()
        self.project = root / "project"
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
        for key in ("post", "outbox", "mcpConfig", "contextFile", "toolUrl"):
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
        self.assertEqual(args.count("--strict-mcp-config"), 1)

    def test_codex_coordinator_gets_the_app_tools_and_nothing_else(self):
        def config(url):
            (self.session / "mcp.json").write_text(json.dumps({"mcpServers": {"mochi": {"type": "http", "url": url}}}))
            return launcher.attach_runtime(self.spec(provider="codex", isCoordinator=True), self.session, shared=self.shared)
        spec = config("http://127.0.0.1:51234/mcp")
        args = launcher.codex_args(spec, servers=[("mochi", False, "", []), ("postiz", False, "", [])])
        self.assertIn('mcp_servers.mochi.url="http://127.0.0.1:51234/mcp"', args)
        self.assertIn('mcp_servers.mochi.bearer_token_env_var="MOCHI_TOKEN"', args)
        # The app's own entry comes last, so a user server of the same name cannot stay in its place.
        self.assertGreater(args.index("mcp_servers.mochi.enabled=true"), args.index("mcp_servers.mochi.enabled=false"))
        self.assertIn("mcp_servers.postiz.enabled=false", args)
        self.assertFalse(any("MOCHI_TOKEN=" in a or "Bearer" in a for a in args))
        # Only the app's own loopback address is accepted as a tool server.
        for foreign in ("https://evil.example/mcp", "http://127.0.0.1:51234/other", "http://10.0.0.5:51234/mcp"):
            self.assertNotIn("toolUrl", config(foreign))
        plain = launcher.attach_runtime(self.spec(provider="codex"), self.session, shared=self.shared)
        self.assertFalse(any(a.startswith("mcp_servers.mochi") for a in launcher.codex_args(plain)))

    def test_run_rejects_specs_outside_the_session_area(self):
        outside = self.project / "spec.json"
        outside.write_text("{}")
        with self.assertRaises(SystemExit) as failure:
            launcher.run(str(outside))
        self.assertIn("session area", str(failure.exception))


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
        name = spec["profileName"]
        self.assertRegex(name, r"^mochi_[0-9a-f]{16}$")
        self.assertIn(f'default_permissions="{name}"', args)
        profile = next(a for a in args if a.startswith(f"permissions.{name}="))
        # Every launch gets its own name, so a project cannot widen the profile in advance.
        other = make_spec(self.dir.name)
        launcher.codex_args(other)
        self.assertNotEqual(other["profileName"], name)
        self.assertIn('":root" = "read"', profile)
        self.assertIn('web_search="disabled"', args)
        self.assertIn('model_reasoning_effort="minimal"', args)

    def test_codex_profile_check_fails_closed(self):
        spec = make_spec(self.dir.name)
        script = Path(self.dir.name) / "fake-codex"
        # A client that ignores the profile: every command succeeds.
        script.write_text("#!/bin/sh\nexit 0\n")
        script.chmod(0o755)
        self.assertFalse(launcher.codex_profile_enforced(str(script), spec))
        # A client without the "sandbox" subcommand: nothing succeeds.
        script.write_text("#!/bin/sh\nexit 2\n")
        self.assertFalse(launcher.codex_profile_enforced(str(script), spec))
        self.assertFalse(launcher.codex_profile_enforced(str(script) + "-missing", spec))
        # A client that enforces the lock: the read probe fails, the no-op succeeds.
        script.write_text('#!/bin/sh\nfor a; do last="$a"; done\ncase "$last" in /usr/bin/true) exit 0;; *) exit 1;; esac\n')
        self.assertTrue(launcher.codex_profile_enforced(str(script), spec))

    def test_editors_cannot_touch_client_folders(self):
        spec = make_spec(self.dir.name, canEdit=True)
        codex = launcher.build_codex_permissions(spec, home=Path("/Users/test"))
        claude = launcher.build_claude_settings(spec, home=Path("/Users/test"))
        self.assertEqual(codex["filesystem"][":project_roots"][".git/config"], "read")
        self.assertIn(f"Edit(/{spec['project']}/.git/config)", claude["permissions"]["deny"])
        self.assertIn(str(Path(spec["project"]) / ".git/config"), claude["sandbox"]["filesystem"]["denyWrite"])
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
        (home / "Project").mkdir()
        for hidden in (".ssh", ".claude", "Applications"):
            (home / hidden / "x").mkdir(parents=True)
            self.assertFalse(common.project_allowed(home / hidden, home=home), hidden)
            self.assertFalse(common.project_allowed(home / hidden / "x", home=home), hidden)
        for bad in (home, home.parent, Path("/"), home / "Library", home / "Library" / "Caches"):
            self.assertFalse(common.project_allowed(bad, home=home), bad)
        self.assertTrue(common.project_allowed(home / "Project", home=home))
        with self.assertRaises(launcher.SpecError):
            launcher.validate_spec(make_spec(str(common.HOME)))

    def test_toml_keeps_unicode(self):
        self.assertEqual(launcher._toml({"/Users/zoë 😀": "none"}), '{"/Users/zoë 😀" = "none"}')

    def test_codex_switches_off_personal_tool_servers(self):
        script = Path(self.dir.name) / "fake-codex"
        script.write_text('#!/bin/sh\npwd > "$0.cwd"\necho \'[{"name":"postiz","enabled":true,"transport":{"url":"https://x"}},{"name":"off","enabled":false},{"name":"node_repl","transport":{"command":"node","args":["./s.mjs"]}}]\'\n')
        script.chmod(0o755)
        project = Path(self.dir.name).resolve() / "work"
        project.mkdir()
        servers = launcher.codex_servers(str(script), str(project))
        self.assertEqual(servers, [("postiz", False, "", []), ("node_repl", True, "node", ["./s.mjs"])])
        # The list is asked for inside the project: that is where the session will run.
        self.assertEqual(Path(str(script) + ".cwd").read_text().strip(), str(project))
        args = launcher.codex_args(make_spec(self.dir.name), servers=servers)
        self.assertIn("mcp_servers.postiz.enabled=false", args)
        self.assertIn("mcp_servers.node_repl.enabled=false", args)
        self.assertIn('mcp_servers.node_repl.command="/usr/bin/false"', args)
        self.assertNotIn('mcp_servers.postiz.command="/usr/bin/false"', args)
        # Unreadable or impossible to switch off means: do not start.
        script.write_text('#!/bin/sh\necho \'[{"name":"a.b=true"}]\'\n')
        self.assertIsNone(launcher.codex_servers(str(script), str(project)))
        script.write_text("#!/bin/sh\necho broken\n")
        self.assertIsNone(launcher.codex_servers(str(script), str(project)))
        self.assertIsNone(launcher.codex_servers(str(script) + "-missing", str(project)))

    def test_account_selects_its_own_codex_home(self):
        original = common.DATA
        common.DATA = Path(self.dir.name)
        try:
            env = common.use_account("work-1a2b", {})
            home = Path(self.dir.name) / "accounts" / "codex" / "work-1a2b"
            self.assertEqual(env, {"CODEX_HOME": str(home)})
            self.assertEqual(home.stat().st_mode & 0o777, 0o700)
            self.assertEqual(common.use_account("", {}), {})
            self.assertEqual(common.codex_homes()[1:], [home])
        finally:
            common.DATA = original
        for bad in ("../x", "A", "a/b", "-a", "a" * 41):
            with self.assertRaises(ValueError):
                common.account_home(bad)

    def test_spec_accepts_accounts_only_for_codex(self):
        def spec(provider, account):
            return launcher.validate_spec({"provider": provider, "project": self.dir.name, "task": "x", "account": account,
                                           "sessionId": str(uuid.uuid4()), "owner": "Alex", "agent": {"name": "Otto"}})
        self.assertEqual(spec("codex", "work-1a2b")["account"], "work-1a2b")
        self.assertEqual(spec("claude", "")["account"], "")
        for provider, account in (("claude", "work-1a2b"), ("codex", "../../etc"), ("codex", "Upper")):
            with self.assertRaises(launcher.SpecError):
                spec(provider, account)

    def test_full_access_drops_the_sandbox_only_when_asked(self):
        spec = make_spec(self.dir.name, canEdit=True, fullAccess=True)
        settings = launcher.build_claude_settings(spec, home="/Users/test")
        self.assertNotIn("sandbox", settings)
        self.assertEqual(settings["permissions"], {"allow": []})
        args = launcher.claude_args(spec)
        self.assertEqual(args[args.index("--permission-mode") + 1], "bypassPermissions")
        codex = launcher.codex_args(spec, servers=[("postiz", False, "", [])])
        self.assertEqual(codex[:2], ["--sandbox", "danger-full-access"])
        self.assertEqual(codex[codex.index("--ask-for-approval") + 1], "never")
        self.assertFalse(any(a.startswith("permissions.mochi") for a in codex))
        # Without computer use, Codex's computer control stays off even with full access; other servers run as usual.
        self.assertIn("mcp_servers.cua_repl.enabled=false", codex)
        self.assertNotIn("mcp_servers.postiz.enabled=false", codex)
        both = make_spec(self.dir.name, fullAccess=True, computerUse=True)
        self.assertFalse(any(a.startswith("mcp_servers") for a in launcher.codex_args(both)))
        self.assertIn("full access", launcher.build_prompt(spec))
        # Without the flag everything stays as it was.
        normal = make_spec(self.dir.name, canEdit=True)
        self.assertIn("sandbox", launcher.build_claude_settings(normal, home="/Users/test"))
        self.assertNotIn("danger-full-access", launcher.codex_args(normal))
        self.assertFalse(make_spec(self.dir.name, fullAccess="true")["agent"]["fullAccess"])

    def test_routines_never_get_full_access(self):
        spec = launcher.validate_spec({"provider": "claude", "project": self.dir.name, "task": "x", "unattended": True,
                                       "sessionId": str(uuid.uuid4()), "owner": "Alex", "agent": {"name": "Mira", "fullAccess": True}})
        self.assertFalse(spec["agent"]["fullAccess"])
        self.assertIn("sandbox", launcher.build_claude_settings(spec, home="/Users/test"))

    def test_computer_use_switches_on_what_each_client_offers(self):
        off = make_spec(self.dir.name)
        self.assertIn("--no-chrome", launcher.claude_args(off))
        on = make_spec(self.dir.name, computerUse=True)
        self.assertIn("--chrome", launcher.claude_args(on))
        allowed = launcher.build_claude_settings(on, home="/Users/test")["permissions"]["allow"]
        self.assertIn("mcp__claude-in-chrome", allowed)
        # Claude's desktop control is approved too, and the agent is told that it has the whole desktop.
        self.assertIn("mcp__computer-use", allowed)
        self.assertNotIn("mcp__computer-use", launcher.build_claude_settings(off, home="/Users/test")["permissions"]["allow"])
        self.assertIn("whole desktop", launcher.build_prompt(on))
        genuine = launcher.COMPUTER_APP + "/Contents/Resources/cua_node/bin/node_repl"
        servers = [("cua_repl", True, genuine, ["--require-browser-access"]), ("postiz", False, "", [])]
        off_flag = "mcp_servers.cua_repl.enabled=false"

        def fresh():
            return make_spec(self.dir.name, computerUse=True)
        with mock.patch.object(launcher, "signed_by_openai", return_value=True):
            kept = launcher.codex_args(on, servers=servers)
            self.assertNotIn(off_flag, kept)
            self.assertIn("mcp_servers.postiz.enabled=false", kept)
            self.assertIn(off_flag, launcher.codex_args(off, servers=servers))
            # A server of the same name stays off when its program lies elsewhere, sits in the user's folder,
            # or is the genuine program pointed at a script of someone's choosing.
            for command, arguments in (("/bin/sh", []), (str(Path.home() / ".codex/computer-use/node_repl"), []),
                                       (genuine, ["/tmp/evil.mjs"]), (genuine, ["--eval=x", "y"]), ("", [])):
                self.assertIn(off_flag, launcher.codex_args(fresh(), servers=[("cua_repl", True, command, arguments)]), command)
            # A link out of the app does not make a foreign program genuine.
            link = Path(self.dir.name) / "node_repl"
            link.symlink_to("/bin/sh")
            self.assertFalse(launcher.trusted_computer_server("cua_repl", str(link), [], self.dir.name))
            config = Path(self.dir.name) / ".codex"
            config.mkdir()
            (config / "config.toml").write_text('[mcp_servers.cua_repl]\ncommand = "/bin/sh"\n')
            self.assertIn(off_flag, launcher.codex_args(fresh(), servers=servers))
            (config / "config.toml").unlink()
        # The right place is not enough: the app must also carry OpenAI's signature.
        with mock.patch.object(launcher, "signed_by_openai", return_value=False):
            self.assertIn(off_flag, launcher.codex_args(fresh(), servers=servers))
        routine = launcher.validate_spec({"provider": "claude", "project": self.dir.name, "task": "x", "unattended": True,
                                          "sessionId": str(uuid.uuid4()), "owner": "Alex", "agent": {"name": "Mira", "computerUse": True}})
        self.assertFalse(routine["agent"]["computerUse"])

    def test_chrome_is_opened_only_when_it_is_closed(self):
        calls = []

        def fake(running):
            def run(command, **_):
                calls.append(command[0])
                return mock.Mock(returncode=0 if running else 1)
            return run
        with mock.patch.object(launcher, "CHROME", self.dir.name):
            self.assertFalse(launcher.open_chrome(fake(running=True)))
            self.assertEqual(calls, ["/usr/bin/pgrep"])
            self.assertTrue(launcher.open_chrome(fake(running=False)))
            self.assertEqual(calls[-1], "/usr/bin/open")
        with mock.patch.object(launcher, "CHROME", self.dir.name + "/missing.app"):
            self.assertFalse(launcher.open_chrome(fake(running=False)))

    def test_agents_get_their_skills_and_only_theirs(self):
        root = Path(self.dir.name).resolve()
        data, shared, mine = root / "data", root / "shared", str(uuid.uuid4())
        for skill in ("reviews-1a2b", "videos-3c4d", "gone-5e6f"):
            (shared / "skills" / skill).mkdir(parents=True)
        (shared / "skills" / "reviews-1a2b" / "SKILL.md").write_text("---\nname: reviews\n---\n")
        (shared / "skills" / "videos-3c4d" / "SKILL.md").write_text("---\nname: videos\n---\n")
        data.mkdir()
        (data / "skills.json").write_text(json.dumps([
            {"id": "reviews-1a2b", "name": "reviews", "description": "How reviews\nare written"},
            {"id": "videos-3c4d", "name": "videos", "description": "x", "agents": [str(uuid.uuid4()).upper()]},
            {"id": "gone-5e6f", "name": "gone", "description": "file missing"},
            {"id": "../../etc", "name": "evil", "description": "x"}, "broken"]))
        project = root / "work"
        project.mkdir()
        spec = make_spec(str(project))
        spec["agentId"] = mine.upper()
        with_skills = launcher.attach_skills(spec, data=data, shared=shared)
        self.assertEqual([s["name"] for s in with_skills["skills"]], ["reviews"])
        self.assertEqual(with_skills["skills"][0]["description"], "How reviews are written")
        prompt = launcher.build_prompt(with_skills)
        self.assertIn(str(shared / "skills" / "reviews-1a2b" / "SKILL.md"), prompt)
        self.assertNotIn("videos", prompt)
        self.assertIn(f"Read(/{shared / 'skills'}/**)", launcher.build_claude_settings(with_skills, home="/Users/test")["permissions"]["allow"])
        # A skill narrowed down to this agent is included, whatever the letter case of the id.
        index = json.loads((data / "skills.json").read_text())
        index[1]["agents"] = [mine.lower()]
        (data / "skills.json").write_text(json.dumps(index))
        self.assertEqual(len(launcher.attach_skills(spec, data=data, shared=shared)["skills"]), 2)
        # Skills never come from the session file, and no skills means no word about them.
        clean = launcher.validate_spec(dict(spec, skills=[{"name": "x", "description": "y", "file": "/etc/passwd"}], agentId="nonsense"))
        self.assertNotIn("skills", clean)
        self.assertEqual(clean["agentId"], "")
        self.assertNotIn("You have skills", launcher.build_prompt(launcher.attach_skills(clean, data=root / "none", shared=shared)))

    def test_many_skills_are_named_or_counted_never_dropped_silently(self):
        root = Path(self.dir.name).resolve()
        data, shared = root / "data", root / "shared"
        data.mkdir()
        index = []
        for n in range(1003):
            sid = f"s{n}-abcd"
            (shared / "skills" / sid).mkdir(parents=True)
            (shared / "skills" / sid / "SKILL.md").write_text(f"---\nname: s{n}\n---\n")
            index.append({"id": sid, "name": f"s{n}", "description": "d"})
        (data / "skills.json").write_text(json.dumps(index))
        project = root / "work"
        project.mkdir()
        spec = launcher.attach_skills(make_spec(str(project)), data=data, shared=shared)
        self.assertEqual((len(spec["skills"]), len(spec["skillNames"]), spec["skillsLeftOut"]), (150, 850, 3))
        prompt = launcher.build_prompt(spec)
        self.assertIn("s150 (`", prompt)
        self.assertIn("s999 (`", prompt)
        self.assertNotIn("s1000 (`", prompt)
        self.assertIn("3 further skills are not listed here.", prompt)

    def test_codex_effort_passes_any_plain_level(self):
        self.assertIn('model_reasoning_effort="max"', launcher.codex_args(make_spec(self.dir.name, effort="max")))
        self.assertFalse(any("reasoning_effort" in a for a in launcher.codex_args(make_spec(self.dir.name, effort="x; rm"))))

    def test_toml_escapes_keys(self):
        self.assertEqual(launcher._toml({'a "b"': {"c": True}}), '{"a \\"b\\"" = {"c" = true}}')


if __name__ == "__main__":
    unittest.main()


class MemoryLockTests(unittest.TestCase):
    def test_memory_folder_inside_a_writable_project_stays_locked(self):
        with tempfile.TemporaryDirectory() as home:
            spec = make_spec(home, canEdit=True)
            settings = launcher.build_claude_settings(spec, home=home)
            folder = os.path.realpath(home) + "/Mochi Memory"
            self.assertIn(folder, settings["sandbox"]["filesystem"]["denyWrite"])
            self.assertIn(f"Edit(/{folder}/**)", settings["permissions"]["deny"])
            self.assertIn(f"Edit(/{os.path.realpath(home)}/**)", settings["permissions"]["allow"])
