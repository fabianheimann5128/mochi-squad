"""Starts an agent (Claude Code or Codex) from a session description written by the app.

  launcher.py run <spec.json>    interactive session in the app's terminal (replaces itself with the client)
  launcher.py status             JSON: installed clients and their sign-in state
  launcher.py login <provider>   opens the client's sign-in (confirm the subscription in the browser)

The app writes the session description (readable by the user only). Every rule that decides an agent's rights or
task lives in pure functions and is covered in Tests/.
"""
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import uuid
from pathlib import Path

import common
import memory
from common import t

# Read lock for commands in the sandbox: credentials, histories of other projects, data of other apps.
SECRET_PATHS = (".ssh", ".aws", ".gnupg", ".config/gh", ".config/gcloud", ".config/op", ".docker", ".kube", ".netrc", ".npmrc", ".pypirc", ".git-credentials",
                ".codex", ".claude", ".claude.json", "Library/Keychains", "Library/Application Support", "Library/Cookies",
                "Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers", "Library/Group Containers")
# Never writable inside the project: an agent could grant itself rights here or leave code for later sessions.
CLIENT_FOLDERS = (".claude", ".codex", ".git/hooks")
# Single files with the same effect: .git/config can redirect hooks and helper programs.
CLIENT_FILES = (".git/config",)
# MCP servers through which Codex operates the computer.
COMPUTER_SERVERS = ("cua_repl",)
# Where OpenAI ships that server, and the team that signs it.
COMPUTER_APP = "/Applications/ChatGPT.app"
COMPUTER_TEAM = "2DC432GLL2"
# Claude Code's built-in server for desktop control.
COMPUTER_TOOLS = "computer-use"
# Name of the coordinator's own tool server in both clients.
TOOL_SERVER = "mochi"
TOKEN_VARIABLE = "MOCHI_TOKEN"
EFFORT = re.compile(r"[a-z]{2,12}")
SERVER_NAME = re.compile(r"[A-Za-z0-9_-]{1,64}")
CHAT_ID = re.compile(r"[A-Za-z0-9-]{8,64}")
SKILL_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
LOCAL_URL = re.compile(r"http://127\.0\.0\.1:\d{2,5}/mcp")

CHAT_STYLE = ("Your answers appear in Mochi Squad as chat messages. Write the way a good colleague writes in a messenger: "
              "lead with the result or the answer, then what happens next or one concrete question. Keep paragraphs to one to "
              "three sentences and separate them with a blank line. Use a list only for real enumerations of three or more "
              "items, with one short line per item, and never nest lists. No headings and no tables in the chat. Put file "
              "names, paths and commands in backticks and write file names in full, never cut off; give a file's name, not "
              "its whole path, unless the path matters. Long content belongs in a file: mention only the file name in the chat.")


class SpecError(ValueError):
    pass


def load_spec(path):
    """Reads and checks a session description. Raises SpecError with a message the user can act on."""
    spec = common.read_json(path)
    if not isinstance(spec, dict):
        raise SpecError(t("The session description is unreadable.", "Die Sitzungsbeschreibung ist unlesbar."))
    return validate_spec(spec)


def validate_spec(spec):
    if spec.get("provider") not in common.PROVIDERS:
        raise SpecError(t("Unknown provider.", "Unbekannter Anbieter."))
    project = Path(str(spec.get("project", ""))).expanduser()
    if not project.is_absolute() or not project.is_dir():
        raise SpecError(t("The project folder cannot be reached.", "Der Projektordner ist nicht erreichbar."))
    if not common.project_allowed(project):
        raise SpecError(t("This folder is not allowed as a project. Choose a folder inside your home folder.",
                          "Dieser Ordner ist als Projekt nicht erlaubt. Wähle einen Ordner unterhalb deines Benutzerordners."))
    if not str(spec.get("task", "")).strip():
        raise SpecError(t("The task is empty.", "Der Auftrag ist leer."))
    try:
        uuid.UUID(str(spec.get("sessionId", "")))
    except ValueError as error:
        raise SpecError(t("Invalid session id.", "Ungültige Sitzungs-ID.")) from error
    agent = spec.get("agent")
    if not isinstance(agent, dict) or not str(agent.get("name", "")).strip():
        raise SpecError(t("The agent has no name.", "Der Agent hat keinen Namen."))
    spec = dict(spec, project=str(project.resolve()), sessionId=str(spec["sessionId"]).lower())
    spec["agent"] = {
        "name": str(agent.get("name", "")).strip(),
        "job": str(agent.get("job", "")).strip(),
        "instructions": str(agent.get("instructions", "")).strip(),
        "persona": str(agent.get("persona", "")).strip(),
        "model": str(agent.get("model", "")).strip(),
        "effort": str(agent.get("effort", "")).strip(),
        "canEdit": agent.get("canEdit") is True,
        "fullAccess": agent.get("fullAccess") is True,
        "computerUse": agent.get("computerUse") is True,
        "isCoordinator": agent.get("isCoordinator") is True,
    }
    spec["team"] = [str(x) for x in spec.get("team") or [] if str(x).strip()]
    spec["owner"] = str(spec.get("owner") or "").strip() or "the user"
    spec["language"] = "de" if spec.get("language") == "de" else "en"
    spec["unattended"] = spec.get("unattended") is True
    spec["allowWeb"] = spec.get("allowWeb") is True
    # Full access exists only while the user is present: routines always run in the sandbox.
    if spec["unattended"]:
        spec["agent"]["fullAccess"] = False
        spec["agent"]["computerUse"] = False
    spec["postEnabled"] = spec.get("postEnabled") is True
    account = str(spec.get("account") or "")
    if account and (spec["provider"] != "codex" or not common.ACCOUNT_ID.fullmatch(account)):
        raise SpecError(t("The chosen subscription is invalid.", "Das gewählte Abo ist ungültig."))
    spec["account"] = account
    parent = spec.get("parentChat")
    spec["parentChat"] = parent if isinstance(parent, str) and CHAT_ID.fullmatch(parent) else None
    # Runtime paths are set by attach_runtime only; they are never taken from the file.
    for key in ("post", "outbox", "contextFile", "mcpConfig", "toolUrl", "skills"):
        spec.pop(key, None)
    try:
        spec["agentId"] = str(uuid.UUID(str(spec.get("agentId", "")))).upper()
    except ValueError:
        spec["agentId"] = ""
    return spec


def attach_skills(spec, data=None, shared=None):
    """Adds the skills this agent has: name, description and the file to read.

    The list and its assignment come from the app's skills.json; the files lie in the shared area, which agents may
    read but sandboxed agents cannot change. A skill whose file is missing is left out.
    """
    index = common.read_json(Path(data or common.DATA) / "skills.json", [])
    root = Path(shared or common.SHARED) / "skills"
    skills = []
    for entry in index if isinstance(index, list) else []:
        if not isinstance(entry, dict) or not SKILL_ID.fullmatch(str(entry.get("id", ""))):
            continue
        agents = entry.get("agents")
        if isinstance(agents, list) and spec.get("agentId", "") not in [str(a).upper() for a in agents]:
            continue
        file = root / entry["id"] / "SKILL.md"
        if file.is_file():
            skills.append({"name": _line(entry.get("name"), 80), "description": _line(entry.get("description"), 300), "file": str(file)})
    return dict(spec, skills=skills[:40], skillsFolder=str(root))


def attach_memory(spec, settings=None, home=None):
    """Adds what Mochi Memory knows about the user and this project. The launcher reads the notes itself, so agents
    in the sandbox need no access to the memory folder."""
    try:
        root, profile, project = memory.for_project(spec["project"], settings, home)
    except Exception:  # noqa: BLE001 – a broken note must never keep an agent from starting
        return spec
    return dict(spec, memoryFolder=str(root), memoryProfile=[_line(x, 300) for x in profile],
                memoryProject=[_line(x, 300) for x in project])


def _line(value, limit):
    """One line of plain text for the briefing."""
    return " ".join(str(value or "").split())[:limit]


def attach_runtime(spec, session_dir, shared=None):
    """Adds the paths of an app session. They depend only on the session folder the app created."""
    session_dir = Path(session_dir)
    spec = dict(spec, contextFile=str(session_dir / "context.json"))
    outbox = Path(shared or common.SHARED) / "outbox" / session_dir.name
    tool = Path(shared or common.SHARED) / "bin" / "post"
    if spec["postEnabled"] and outbox.is_dir() and tool.is_file():
        spec.update(post=str(tool), outbox=str(outbox))
    if spec["agent"]["isCoordinator"]:
        config = session_dir / "mcp.json"
        if not config.is_file():
            raise SpecError(t("The coordinator's tools are not ready yet. Start the session again in a moment.",
                              "Die Werkzeuge des Koordinators sind noch nicht bereit. Starte die Sitzung gleich noch einmal."))
        spec["mcpConfig"] = str(config)
        # Codex takes the address as an option. Only the app's own loopback address is accepted.
        servers = (common.read_json(config, {}) or {}).get("mcpServers") or {}
        address = str((servers.get(TOOL_SERVER) or {}).get("url") or "")
        if LOCAL_URL.fullmatch(address):
            spec["toolUrl"] = address
    return spec


def coordinator_brief(owner, can_edit=False):
    return (f"You are the coordinator of {owner}'s team of agents. You produce nothing yourself; you keep the overview and "
            f"hand out work. With the tools of the server \"{TOOL_SERVER}\" you see all projects and agents (overview, "
            "list_agents), running sessions (list_jobs) and histories (list_chats, read_chat) and you give agents tasks "
            "(start_named_agent). Answer questions about the state of things from these tools. If no fitting agent exists "
            f"for a task yet, suggest that {owner} creates one." + ("" if can_edit else " You only read files."))


def build_prompt(spec):
    """Briefing and task. In the chat the history reader shows only the part after TASK_MARK."""
    agent, owner = spec["agent"], spec["owner"]
    project = Path(spec["project"])
    job = agent["job"] or ("coordinator" if agent["isCoordinator"] else "agent")
    fallback = "German" if spec.get("language") == "de" else "English"
    parts = [common.BRIEFING_MARK,
             f"You are {agent['name']}, {job} in {owner}'s team of agents. You work in the project folder {project.name}.",
             f"Always answer in the language of the message you are answering. If that is unclear, use {fallback}."]
    if agent["isCoordinator"]:
        parts.append(coordinator_brief(owner, agent["canEdit"]))
    if agent["instructions"]:
        parts.append("Your tasks: " + agent["instructions"])
    if agent["persona"]:
        parts.append("Your character: " + agent["persona"] + ".")
    if agent["computerUse"]:
        parts.append("You may operate the computer: " + ("the whole desktop (screenshots, mouse and keyboard in any app) through the "
                     "computer-use tools, and the Chrome browser through Claude in Chrome." if spec["provider"] == "claude"
                     else "apps and the browser through Codex's computer control.") +
                     f" Use it only when {owner} asks for it, and never send, buy or delete anything through it without explicit approval.")
    if agent["fullAccess"]:
        parts.append("You have full access to this Mac, without a sandbox and without confirmations. Handle it with care: work "
                     "in the project folder unless the task requires otherwise, and do not delete or overwrite anything "
                     f"outside of it without asking {owner} in the chat first.")
    elif agent["canEdit"]:
        parts.append("You may create and change files in the project folder. Commands run in a sandbox that may only write "
                     "to the project and the temp folder.")
    parts.append(f"Do not publish or upload anything and do not trigger anything that costs money without {owner}'s explicit "
                 "approval in the chat.")
    if spec.get("post"):
        team = ", ".join(spec["team"])
        parts.append((f"Your team in this project: {team}. " if team else "")
                     + f"You reach other agents with `{spec['post']} list` and `{spec['post']} send <name> \"<message>\"`. "
                     "Call the command on its own, without additions such as `; echo $?` or `&&`, otherwise it needs approval. "
                     "Answers appear as \"Message from <name>\" in your chat. You answer the coordinator simply here in the "
                     "chat; it reads your history and cannot be reached by post. When a message starts with "
                     "\"Team chat · <name>:\", you answer for everyone in the team chat; @name brings a colleague in there.")
    if spec.get("memoryProfile") or spec.get("memoryProject") or spec.get("post"):
        known = []
        if spec.get("memoryProfile"):
            known.append(f"About {owner}:\n" + "\n".join("- " + x for x in spec["memoryProfile"]))
        if spec.get("memoryProject"):
            known.append("About this project:\n" + "\n".join("- " + x for x in spec["memoryProject"]))
        text = (f"Mochi Memory, what the team remembers ({owner} can read and edit it):\n" + "\n".join(known)) if known else ""
        if spec.get("post"):
            text += ("\n" if text else "") + (
                f"When you learn something lasting, such as a preference of {owner}, a decision or an important fact about "
                f"the project, save it in one short sentence with `{spec['post']} remember \"<fact>\"`, or with "
                f"`{spec['post']} remember --about-me \"<fact>\"` if it is about {owner} personally. Save only what will "
                "still matter in a week, never passwords, keys, tokens or private details of other people. If an entry "
                "above is wrong or outdated, say so in the chat and save the correct one.")
        parts.append(text)
    if spec.get("skills"):
        parts.append(f"You have skills: instructions for particular kinds of work that {owner} gave you. Before you start a "
                     "task that fits one of them, read its file completely and follow it; files it mentions lie next to it.\n"
                     + "\n".join(f"- {s['name']}: {s['description']} (`{s['file']}`)" for s in spec["skills"]))
    if spec["unattended"]:
        parts.append(f"This is a scheduled routine; {owner} is not at the computer. Do not ask questions, work on your own "
                     "and save results as a file in the project.")
    parts.append(CHAT_STYLE)
    return "\n".join(parts) + common.TASK_MARK + str(spec["task"]).strip()


def relocated_homes(home):
    """Client folders the user moved elsewhere (CLAUDE_CONFIG_DIR, CODEX_HOME). They hold credentials and
    histories just like the standard folders and get the same read lock."""
    home = Path(home)
    standard = {home / ".claude", home / ".codex"}
    return [str(p) for p in (common.claude_home(), common.codex_home()) if p not in standard]


def locked_paths(home):
    """Everything a restricted agent must not read, as absolute paths."""
    return [str(Path(home) / p) for p in SECRET_PATHS] + relocated_homes(home)


def _status_line(spec):
    hook = Path(__file__).with_name("context.py")
    return {"type": "command", "command": " ".join(shlex.quote(str(x)) for x in [sys.executable, hook, "claude", spec["contextFile"]])}


def build_claude_settings(spec, home=None):
    """Rights of a Claude Code session.

    Every restricted agent runs in the sandbox and cannot leave it; if the sandbox cannot start, the client quits
    instead of working without it. Reading: the project plus whatever the user confirms, never the locked paths
    (file tools and commands alike). Writing: with canEdit the project without the client folders, otherwise
    nothing but its own outbox.
    """
    home = Path(home or common.HOME)
    agent, project = spec["agent"], spec["project"]
    if agent["fullAccess"]:
        # Switched on explicitly by the user: no sandbox, no locks. Only the status line stays.
        settings = {"permissions": {"allow": ["mcp__" + TOOL_SERVER] if agent["isCoordinator"] else []}}
        if spec.get("contextFile"):
            settings["statusLine"] = _status_line(spec)
        return settings
    locked = locked_paths(home)
    # A leading double slash marks an absolute path in permission rules.
    allow = [f"Read(/{project}/**)"]
    if spec.get("skills"):
        allow.append(f"Read(/{spec['skillsFolder']}/**)")
    # Edit rules apply to every tool that changes files; Read rules also to search tools.
    deny = ([f"Edit(/{project}/{p}/**)" for p in CLIENT_FOLDERS] + [f"Edit(/{project}/{p})" for p in CLIENT_FILES]
            + [rule for path in locked for rule in (f"Read(/{path})", f"Read(/{path}/**)")])
    filesystem = {"denyRead": locked,
                  "denyWrite": [str(Path(project) / p) for p in CLIENT_FOLDERS + CLIENT_FILES] if agent["canEdit"] else [project]}
    if agent["canEdit"]:
        allow.append(f"Edit(/{project}/**)")
    if spec.get("post") and spec.get("outbox"):
        allow.append(f"Bash({spec['post']}:*)")
        filesystem["allowWrite"] = [spec["outbox"]]
    if agent["isCoordinator"]:
        allow.append("mcp__" + TOOL_SERVER)
    if spec.get("allowWeb"):
        allow += ["WebSearch", "WebFetch"]
    elif spec["unattended"]:
        # Nobody is there to confirm a request, and some domains are approved in advance: "off" means off.
        deny += ["WebSearch", "WebFetch"]
    if agent["computerUse"]:
        allow += ["mcp__claude-in-chrome", "mcp__" + COMPUTER_TOOLS]
    settings = {
        "permissions": {"allow": allow, "deny": deny},
        # Local ports stay closed (the default): an agent shall not reach unprotected services on this Mac.
        "sandbox": {"enabled": True, "failIfUnavailable": True, "autoAllowBashIfSandboxed": True,
                    "allowUnsandboxedCommands": False, "filesystem": filesystem},
    }
    if spec.get("contextFile"):
        settings["statusLine"] = _status_line(spec)
    return settings


def claude_args(spec, interactive=True):
    agent = spec["agent"]
    # Computer use means for Claude Code: its desktop control (switched on per project, see computer.py) and Chrome.
    args = ["--session-id", spec["sessionId"], "--settings", json.dumps(build_claude_settings(spec)),
            "--chrome" if agent["computerUse"] else "--no-chrome"]
    if not interactive:
        # Without a user there is no trust question: a routine loads neither the project's settings (hooks) nor its
        # tool servers, only what the user set up for themselves.
        args = ["-p"] + args + ["--output-format", "text", "--setting-sources", "user", "--strict-mcp-config"]
    args += ["--permission-mode", "bypassPermissions" if agent["fullAccess"] else "default"]
    # Only its own tools: a foreign server with the same name must not inherit the approval.
    if agent["isCoordinator"]:
        args += ([] if "--strict-mcp-config" in args else ["--strict-mcp-config"]) + (["--mcp-config", spec["mcpConfig"]] if spec.get("mcpConfig") else [])
    if spec.get("parentChat"):
        args += ["--resume", spec["parentChat"], "--fork-session"]
    if agent["model"]:
        args += ["--model", agent["model"]]
    if agent["effort"] in {"low", "medium", "high", "xhigh", "max"}:
        args += ["--effort", agent["effort"]]
    return args


def _toml(value):
    """Writes booleans, strings and tables as a TOML value for `codex -c`."""
    if isinstance(value, dict):
        return "{" + ", ".join(f"{json.dumps(str(k), ensure_ascii=False)} = {_toml(v)}" for k, v in value.items()) + "}"
    return json.dumps(value, ensure_ascii=False)


def build_codex_permissions(spec, home=None):
    """Permission profile of a Codex session, the counterpart of build_claude_settings.

    Reading: everything except the locked paths. Writing: with canEdit the project and the temp folder, otherwise
    nothing but its own outbox. Network for commands only with allowWeb.
    """
    home = Path(home or common.HOME)
    edit = spec["agent"]["canEdit"]
    roots = {".": "write" if edit else "read"}
    if edit:
        roots.update({p: "read" for p in CLIENT_FOLDERS + CLIENT_FILES})
    # Other sessions' outboxes are locked; the own one is opened again below.
    files = {":root": "read", ":project_roots": roots, str(common.OUTBOXES): "none"}
    if edit:
        files[":tmpdir"] = "write"
    files.update({path: "none" for path in locked_paths(home)})
    if spec.get("outbox"):
        files[spec["outbox"]] = "write"
    return {"filesystem": files, "network": {"enabled": bool(spec.get("allowWeb"))}}


def codex_profile_args(spec):
    """An own profile instead of --sandbox: only profiles know read locks.

    The profile name is random per launch. Codex merges entries from a `.codex/config.toml` in the project into
    profiles of the same name; with an unpredictable name a project cannot widen the profile.
    """
    name = spec.setdefault("profileName", "mochi_" + secrets.token_hex(8))
    return ["-c", f'default_permissions="{name}"', "-c", f"permissions.{name}=" + _toml(build_codex_permissions(spec))]


def codex_profile_enforced(binary, spec, home=None, timeout=20):
    """Checks on the real client that the profile takes effect. Older Codex versions silently ignore it."""
    locked = str(Path(home or common.HOME) / "Library/Application Support")

    def probe(*command):
        try:
            return subprocess.run([binary, "sandbox", *codex_profile_args(spec), "--", *command], cwd=spec["project"],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=timeout).returncode
        except (OSError, subprocess.TimeoutExpired):
            return None
    # A no-op succeeds, reading and writing at a locked place fail. The probe file would lie in the app data.
    marker = str(Path(locked) / common.APP_NAME / ".profile-probe")
    ok = probe("/usr/bin/true") == 0 and probe("/bin/ls", locked) not in (0, None) and probe("/usr/bin/touch", marker) not in (0, None)
    Path(marker).unlink(missing_ok=True)
    return ok


def codex_servers(binary, cwd, timeout=20):
    """The user's enabled MCP servers as (name, runs as a command, command, arguments), or None if they cannot be read.

    Asked in the project folder: Codex may know other servers there than elsewhere, and the list must match
    the session that is about to start.
    """
    try:
        result = subprocess.run([binary, "mcp", "list", "--json"], cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=timeout)
        rows = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    if result.returncode != 0 or not isinstance(rows, list):
        return None
    servers = []
    for row in rows:
        if not isinstance(row, dict) or row.get("enabled") is False:
            continue
        transport = row.get("transport") or {}
        arguments = transport.get("args") if isinstance(transport.get("args"), list) else []
        servers.append((str(row.get("name", "")), "url" not in transport, str(transport.get("command") or ""), [str(a) for a in arguments]))
    # A name that cannot be written as a key could not be switched off.
    return servers if all(SERVER_NAME.fullmatch(server[0]) for server in servers) else None


def signed_by_openai(app=COMPUTER_APP, timeout=20):
    """Is the ChatGPT app intact and signed by OpenAI? Checked with macOS's own tool."""
    try:
        if subprocess.run(["/usr/bin/codesign", "--verify", "--strict", app], capture_output=True, timeout=timeout).returncode != 0:
            return False
        info = subprocess.run(["/usr/bin/codesign", "-dv", app], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return f"TeamIdentifier={COMPUTER_TEAM}" in (info.stdout + info.stderr).split()


def trusted_computer_server(name, command, arguments, project, verify=None):
    """Codex's computer control stays on only if it really is OpenAI's.

    A name proves nothing: a project could bring a server of the same name with its own command in its
    `.codex/config.toml`. So the program must lie inside the signed ChatGPT app (links resolved), and its arguments
    may only be switches, never a script or path of the caller's choosing.
    """
    if name not in COMPUTER_SERVERS or not command:
        return False
    own = Path(project) / ".codex" / "config.toml"
    try:
        if own.is_file() and any(server in own.read_text(errors="replace") for server in COMPUTER_SERVERS):
            return False
        real = os.path.realpath(command)
    except OSError:
        return False
    inside = real.startswith(os.path.realpath(COMPUTER_APP) + "/Contents/")
    switches = all(re.fullmatch(r"--[a-z][a-z-]{1,40}", arg) for arg in arguments)
    return inside and switches and (verify or signed_by_openai)()


def outdated_codex():
    return t("This Codex version does not know permission profiles, so the read locks would not apply. Update Codex and start the session again.",
             "Diese Codex-Version kennt keine Rechteprofile, die Lesesperren würden nicht greifen. Aktualisiere Codex und starte die Sitzung erneut.")


def unknown_servers():
    return t("The tool servers of your Codex configuration could not be read and therefore not switched off. Check `codex mcp list` and start the session again.",
             "Die Werkzeugserver deiner Codex-Konfiguration ließen sich nicht lesen und damit nicht abschalten. Prüfe `codex mcp list` und starte die Sitzung erneut.")


def codex_args(spec, interactive=True, servers=()):
    """`servers` are the user's MCP servers. Their tools would run outside the sandbox, so they stay off."""
    agent = spec["agent"]
    if agent["fullAccess"]:
        # Switched on explicitly by the user: Codex without sandbox and confirmations, with its own tools.
        # Only the computer control keeps following its own switch.
        args = ["--sandbox", "danger-full-access", "-c", 'web_search="live"']
        servers = () if agent["computerUse"] else [(name, True, "", []) for name in COMPUTER_SERVERS]
    else:
        args = codex_profile_args(spec) + ["-c", "web_search=" + json.dumps("live" if spec.get("allowWeb") else "disabled")]
    for name, is_command, *rest in servers:
        command, arguments = (rest + ["", []])[0], (rest + ["", []])[1]
        # With computer use, Codex's own computer control stays on, provided it is genuine.
        if agent["computerUse"] and trusted_computer_server(name, command, arguments, spec["project"]):
            continue
        # Servers from plugins have no entry in the configuration; only with a command is the entry valid.
        if is_command:
            args += ["-c", f'mcp_servers.{name}.command="/usr/bin/false"']
        args += ["-c", f"mcp_servers.{name}.enabled=false"]
    if agent["isCoordinator"] and spec.get("toolUrl"):
        # The coordinator's own tools, set after the loop so that a user server of the same name cannot stand in.
        # The token never appears here: Codex reads it from the session's environment.
        args += ["-c", f"mcp_servers.{TOOL_SERVER}.url=" + json.dumps(spec["toolUrl"]),
                 "-c", f"mcp_servers.{TOOL_SERVER}.bearer_token_env_var=" + json.dumps(TOKEN_VARIABLE),
                 "-c", f"mcp_servers.{TOOL_SERVER}.enabled=true"]
    if interactive:
        args += ["--ask-for-approval", "never" if agent["fullAccess"] else "on-request"]
    if agent["model"]:
        args += ["--model", agent["model"]]
    if EFFORT.fullmatch(agent["effort"]):
        args += ["-c", "model_reasoning_effort=" + json.dumps(agent["effort"])]
    if not interactive:
        # No notification program runs in routines, not even one from a project configuration.
        args += ["-c", "notify=[]"]
    if spec.get("contextFile") and interactive:
        hook = Path(__file__).with_name("context.py")
        args += ["-c", "notify=" + json.dumps([sys.executable, str(hook), "bind", spec["contextFile"]])]
    return args


def codex_prompt(spec, prompt):
    """The Codex watcher and the routine log find the session by this first line."""
    return f"{common.SESSION_LINE}{spec['sessionId']}\n" + prompt


def login_state(provider, binary, timeout=20, env=None):
    """(signed in, note). Every kind of sign-in counts; subscription, API key or cloud access is the user's choice."""
    args = ["login", "status"] if provider == "codex" else ["auth", "status", "--json"]
    try:
        result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return False, t("The client does not answer.", "Der Client antwortet nicht.")
    if provider == "codex":
        text = (result.stdout + result.stderr).strip()
        return result.returncode == 0 and "not logged in" not in text.lower(), text.splitlines()[0] if text else ""
    try:
        info = json.loads(result.stdout)
    except ValueError:
        return False, ""
    return bool(info.get("loggedIn")), str(info.get("authMethod") or "")


def status():
    report = {}
    for provider in common.PROVIDERS:
        binary = common.find_client(provider)
        logged_in, detail = login_state(provider, binary) if binary else (False, "")
        report[provider] = {"installed": bool(binary), "path": binary or "", "loggedIn": logged_in, "detail": detail}
    # Extra ChatGPT subscriptions: one sign-in state per folder.
    codex, accounts = common.find_client("codex"), {}
    for home in common.codex_homes()[1:]:
        if codex and common.ACCOUNT_ID.fullmatch(home.name):
            accounts[home.name] = login_state("codex", codex, env=dict(os.environ, CODEX_HOME=str(home)))[0]
    report["accounts"] = accounts
    return report


# Printed while the launcher waits for a sign-in; the app recognises the line and shows a card in the chat.
LOGIN_NOTICE = "MOCHI-SIGN-IN"


def run(spec_path):
    try:
        session_dir = Path(spec_path).resolve().parent
        # The launcher accepts launch data only from the app's session area, which agents cannot write to.
        if session_dir.parent != common.SESSIONS.resolve():
            raise SpecError(t("The session description is not in Mochi Squad's session area.",
                              "Die Sitzungsbeschreibung liegt nicht im Sitzungsbereich von Mochi Squad."))
        spec = attach_memory(attach_skills(attach_runtime(load_spec(spec_path), session_dir)))
    except SpecError as error:
        raise SystemExit(str(error))
    provider = spec["provider"]
    binary = common.find_client(provider)
    label = "Claude Code" if provider == "claude" else "Codex"
    if not binary:
        raise SystemExit(t(f"{label} is not installed on this Mac. Install it and start the session again.",
                           f"{label} ist auf diesem Mac nicht installiert. Installiere es und starte die Sitzung erneut."))
    common.use_account(spec["account"])
    if not login_state(provider, binary)[0]:
        print(LOGIN_NOTICE + " " + t(f"For this agent you need to sign in to {label} once.",
                                     f"Für diesen Agenten musst du dich einmal bei {label} anmelden."), flush=True)
        subprocess.run([binary, *(["login"] if provider == "codex" else ["auth", "login"])])
        if not login_state(provider, binary)[0]:
            raise SystemExit(t("Sign-in not confirmed. You can close the session and try again.",
                               "Anmeldung nicht bestätigt. Du kannst die Sitzung schließen und es erneut versuchen."))
    prompt = build_prompt(spec)
    os.chdir(spec["project"])
    os.environ.update(common.client_path_env(common.clean_child_env()))
    if spec.get("outbox"):
        os.environ["MOCHI_OUTBOX"] = spec["outbox"]
    if provider == "codex":
        servers = ()
        if not spec["agent"]["fullAccess"]:
            if not codex_profile_enforced(binary, spec):
                raise SystemExit(outdated_codex())
            servers = codex_servers(binary, spec["project"])
            if servers is None:
                raise SystemExit(unknown_servers())
        prompt = codex_prompt(spec, prompt)
        if spec.get("parentChat"):
            os.execv(binary, [binary, "fork", *codex_args(spec, servers=servers), spec["parentChat"], prompt])
        os.execv(binary, [binary, *codex_args(spec, servers=servers), prompt])
    if spec["agent"]["computerUse"]:
        prepare_desktop_control(binary, spec["project"])
        open_chrome()
    journal = common.claude_journal(spec["project"], spec["sessionId"])
    common.write_private(spec["contextFile"], json.dumps({"historyPath": str(journal)}))
    os.execv(binary, [binary, *claude_args(spec), prompt])


def prepare_desktop_control(binary, project):
    """Claude Code keeps its desktop control off until it is enabled once per project. Do that before the first
    session that may use it; whatever goes wrong here must not keep the session from starting."""
    try:
        import computer
        if project in (common.read_json(computer.marker(), []) or []):
            return
        print(t("Switching on desktop control for this project (once, a few seconds) …",
                "Schalte die Bildschirmsteuerung für dieses Projekt ein (einmalig, wenige Sekunden) …"), flush=True)
        computer.ensure(binary, project)
    except Exception:  # noqa: BLE001 – a convenience step; the client reports itself if the tools are missing
        pass


CHROME = "/Applications/Google Chrome.app"


def open_chrome(run=subprocess.run):
    """The Claude extension can only connect while Chrome is running. Start it in the background if it is
    installed and closed, so that an agent that may use the browser finds it on the first try."""
    try:
        if not Path(CHROME).is_dir() or run(["/usr/bin/pgrep", "-x", "Google Chrome"], capture_output=True).returncode == 0:
            return False
        run(["/usr/bin/open", "-g", "-a", CHROME], capture_output=True)
        return True
    except OSError:
        return False


def login(provider, account=""):
    binary = common.find_client(provider)
    if not binary:
        raise SystemExit(t("The program is not installed on this Mac.", "Das Programm ist auf diesem Mac nicht installiert."))
    env = common.client_path_env(common.clean_child_env())
    if provider == "codex":
        try:
            common.use_account(account, env)
        except ValueError as error:
            raise SystemExit(str(error))
    os.environ.clear()
    os.environ.update(env)
    os.execv(binary, [binary, *(["login"] if provider == "codex" else ["auth", "login"])])


def main(argv):
    if argv[:1] == ["status"]:
        print(json.dumps(status()))
    elif len(argv) in (2, 3) and argv[0] == "login" and argv[1] in common.PROVIDERS:
        login(*argv[1:])
    elif len(argv) == 2 and argv[0] == "run":
        run(argv[1])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
