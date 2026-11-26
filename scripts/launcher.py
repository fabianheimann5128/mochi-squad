"""Startet einen Agenten (Claude Code oder Codex) nach einer Sitzungsbeschreibung der App.

  launcher.py run <spec.json>    interaktive Sitzung im Terminal der App (ersetzt sich durch den Client)
  launcher.py status             JSON: installierte Clients und ihr Anmeldestatus
  launcher.py login <anbieter>   öffnet die Anmeldung des Clients (Abo im Browser bestätigen)

Die Sitzungsbeschreibung schreibt die App (nur für den Nutzer lesbar). Alle Regeln, die Rechte oder den
Auftrag eines Agenten bestimmen, stehen in reinen Funktionen und sind in tests/ abgedeckt.
"""
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

import common

# Lesesperre für Befehle in der Sandbox: Zugangsdaten, Verläufe anderer Projekte, Daten anderer Programme.
SECRET_PATHS = (".ssh", ".aws", ".gnupg", ".config/gh", ".config/gcloud", ".config/op", ".docker", ".kube", ".netrc", ".npmrc", ".pypirc", ".git-credentials",
                ".codex", ".claude", ".claude.json", "Library/Keychains", "Library/Application Support", "Library/Cookies",
                "Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers", "Library/Group Containers")
CHAT_ID = __import__("re").compile(r"[A-Za-z0-9-]{8,64}")

CHAT_STYLE = ("Deine Antworten erscheinen in Mochi Squad als Chat. Schreib kurz und verständlich in der Du-Form: "
              "was rausgekommen ist, was als Nächstes passiert oder eine konkrete Frage. Ausführliches gehört in Dateien, "
              "im Chat nennst du nur den Dateinamen.")


class SpecError(ValueError):
    pass


def load_spec(path):
    """Liest und prüft eine Sitzungsbeschreibung. Wirft SpecError mit verständlicher Meldung."""
    spec = common.read_json(path)
    if not isinstance(spec, dict):
        raise SpecError("Die Sitzungsbeschreibung ist unlesbar.")
    return validate_spec(spec)


def validate_spec(spec):
    if spec.get("provider") not in common.PROVIDERS:
        raise SpecError("Unbekannter Anbieter.")
    project = Path(str(spec.get("project", ""))).expanduser()
    if not project.is_absolute() or not project.is_dir():
        raise SpecError("Der Projektordner ist nicht erreichbar.")
    if not str(spec.get("task", "")).strip():
        raise SpecError("Der Auftrag ist leer.")
    try:
        uuid.UUID(str(spec.get("sessionId", "")))
    except ValueError as error:
        raise SpecError("Ungültige Sitzungs-ID.") from error
    agent = spec.get("agent")
    if not isinstance(agent, dict) or not str(agent.get("name", "")).strip():
        raise SpecError("Der Agent hat keinen Namen.")
    spec = dict(spec, project=str(project.resolve()), sessionId=str(spec["sessionId"]).lower())
    spec["agent"] = {
        "name": str(agent.get("name", "")).strip(),
        "job": str(agent.get("job", "")).strip(),
        "instructions": str(agent.get("instructions", "")).strip(),
        "persona": str(agent.get("persona", "")).strip(),
        "model": str(agent.get("model", "")).strip(),
        "effort": str(agent.get("effort", "")).strip(),
        "canEdit": agent.get("canEdit") is True,
        "isCoordinator": agent.get("isCoordinator") is True,
    }
    spec["team"] = [str(x) for x in spec.get("team") or [] if str(x).strip()]
    spec["owner"] = str(spec.get("owner") or "").strip() or "der Nutzer"
    spec["unattended"] = spec.get("unattended") is True
    spec["allowWeb"] = spec.get("allowWeb") is True
    spec["postEnabled"] = spec.get("postEnabled") is True
    parent = spec.get("parentChat")
    spec["parentChat"] = parent if isinstance(parent, str) and CHAT_ID.fullmatch(parent) else None
    # Laufzeitpfade bestimmt nur attach_runtime; aus der Datei werden sie nie übernommen.
    for key in ("post", "outbox", "contextFile", "mcpConfig"):
        spec.pop(key, None)
    return spec


def attach_runtime(spec, session_dir, shared=None):
    """Ergänzt die Pfade einer App-Sitzung. Sie hängen nur vom Sitzungsordner ab, den die App angelegt hat."""
    session_dir = Path(session_dir)
    spec = dict(spec, contextFile=str(session_dir / "context.json"))
    outbox = Path(shared or common.SHARED) / "outbox" / session_dir.name
    tool = Path(shared or common.SHARED) / "bin" / "post"
    # Codex-Agenten ohne Schreibrecht laufen in einer reinen Lese-Sandbox und können keinen Postausgang beschreiben.
    can_post = spec["provider"] == "claude" or spec["agent"]["canEdit"]
    if spec["postEnabled"] and can_post and outbox.is_dir() and tool.is_file():
        spec.update(post=str(tool), outbox=str(outbox))
    if spec["agent"]["isCoordinator"]:
        config = session_dir / "mcp.json"
        if not config.is_file():
            raise SpecError("Die Werkzeuge des Koordinators sind noch nicht bereit. Starte die Sitzung gleich noch einmal.")
        spec["mcpConfig"] = str(config)
    return spec


def coordinator_brief(owner):
    return (f"Du bist der Koordinator von {owner}s Agenten-Team. Du produzierst selbst nichts, sondern behältst den Überblick "
            "und verteilst Arbeit. Mit den Werkzeugen des Servers „mochi“ siehst du alle Projekte und Agenten (overview, "
            "list_agents), laufende Sitzungen (list_jobs) und Verläufe (list_chats, read_chat) und gibst Agenten Aufträge "
            "(start_named_agent). Beantworte Fragen zum Stand aus diesen Werkzeugen. Gibt es für eine Aufgabe noch keinen "
            f"passenden Agenten, schlage {owner} vor, einen anzulegen. Dateien liest du nur.")


def build_prompt(spec):
    """Briefing und Auftrag. Der Verlaufsleser zeigt im Chat nur den Teil nach TASK_MARK."""
    agent, owner = spec["agent"], spec["owner"]
    project = Path(spec["project"])
    job = agent["job"] or ("Koordinator" if agent["isCoordinator"] else "Agent")
    parts = [common.BRIEFING_MARK,
             f"Du bist {agent['name']}, {job} im Agenten-Team von {owner}. Du arbeitest im Projektordner {project.name}."]
    if agent["isCoordinator"]:
        parts.append(coordinator_brief(owner))
    if agent["instructions"]:
        parts.append("Deine Aufgaben: " + agent["instructions"])
    if agent["persona"]:
        parts.append("Dein Charakter: " + agent["persona"] + ".")
    if agent["canEdit"]:
        parts.append("Du darfst im Projektordner Dateien anlegen und ändern. Befehle laufen in einer Sandbox, die nur ins "
                     "Projekt und in den Temp-Ordner schreiben darf.")
    parts.append(f"Veröffentliche nichts, lade nichts hoch und lös nichts aus, das Geld kostet, ohne {owner}s ausdrückliche "
                 "Freigabe im Chat.")
    if spec.get("post"):
        team = ", ".join(spec["team"])
        parts.append((f"Dein Team in diesem Projekt: {team}. " if team else "")
                     + f"Andere Agenten erreichst du mit `{spec['post']} liste` und `{spec['post']} sende <Name> \"<Nachricht>\"`; "
                     "Rufe den Befehl einzeln auf, ohne Zusätze wie `; echo $?` oder `&&`, sonst braucht er eine Freigabe. "
                     "Antworten erscheinen als „Nachricht von <Name>“ in deinem Chat. Beginnt eine Nachricht mit "
                     "„Team-Chat · <Name>:“, antwortest du für alle im Team-Chat; @Name holt dort einen Kollegen dazu.")
    if spec["unattended"]:
        parts.append(f"Dies ist eine geplante Routine; {owner} ist nicht am Rechner. Frage nichts nach, arbeite selbstständig "
                     "und lege Ergebnisse als Datei im Projekt ab.")
    parts.append(CHAT_STYLE)
    return "\n".join(parts) + common.TASK_MARK + str(spec["task"]).strip()


def build_claude_settings(spec, home=None):
    """Rechte einer Claude-Code-Sitzung.

    Jeder Agent läuft in der Sandbox und kann sie nicht verlassen. Lesen: nur das Projekt (Werkzeuge) bzw. alles
    außer SECRET_PATHS (Befehle). Schreiben: mit canEdit das Projekt ohne .claude/, sonst nichts außer dem eigenen
    Postausgang.
    """
    home = Path(home or common.HOME)
    agent, project = spec["agent"], spec["project"]
    allow = [f"Read(/{project}/**)"]
    # Edit-Regeln gelten für alle Werkzeuge, die Dateien ändern.
    deny = [f"Edit(/{project}/.claude/**)", f"Read(/{home / 'Library/Application Support'}/**)"]
    filesystem = {"denyRead": [str(home / p) for p in SECRET_PATHS],
                  "denyWrite": [str(Path(project) / ".claude")] if agent["canEdit"] else [project]}
    if agent["canEdit"]:
        allow.append(f"Edit(/{project}/**)")
    if spec.get("post") and spec.get("outbox"):
        allow.append(f"Bash({spec['post']}:*)")
        filesystem["allowWrite"] = [spec["outbox"]]
    if agent["isCoordinator"]:
        allow.append("mcp__mochi")
    if spec.get("allowWeb"):
        allow += ["WebSearch", "WebFetch"]
    settings = {
        "permissions": {"allow": allow, "deny": deny},
        "sandbox": {"enabled": True, "autoAllowBashIfSandboxed": True, "allowUnsandboxedCommands": False,
                    "network": {"allowLocalBinding": True}, "filesystem": filesystem},
    }
    if spec.get("contextFile"):
        hook = Path(__file__).with_name("context.py")
        settings["statusLine"] = {"type": "command",
                                  "command": " ".join(map(_quote, [sys.executable, str(hook), "claude", spec["contextFile"]]))}
    return settings


def _quote(value):
    import shlex
    return shlex.quote(str(value))


def claude_args(spec, interactive=True):
    agent = spec["agent"]
    args = ["--session-id", spec["sessionId"], "--settings", json.dumps(build_claude_settings(spec)), "--no-chrome"]
    if not interactive:
        args = ["-p"] + args + ["--output-format", "text"]
    args += ["--permission-mode", "default"]
    # Immer nur die eigenen Werkzeuge: Ein fremder Server namens „mochi“ darf die Freigabe nicht erben.
    if agent["isCoordinator"]:
        args += ["--strict-mcp-config"] + (["--mcp-config", spec["mcpConfig"]] if spec.get("mcpConfig") else [])
    if spec.get("parentChat"):
        args += ["--resume", spec["parentChat"], "--fork-session"]
    if agent["model"]:
        args += ["--model", agent["model"]]
    if agent["effort"] in {"low", "medium", "high", "xhigh", "max"}:
        args += ["--effort", agent["effort"]]
    return args


def codex_args(spec, interactive=True):
    agent = spec["agent"]
    args = ["--sandbox", "workspace-write" if agent["canEdit"] else "read-only"]
    if agent["canEdit"] and spec.get("outbox"):
        args += ["-c", "sandbox_workspace_write.writable_roots=" + json.dumps([spec["outbox"]])]
    if interactive:
        args += ["--ask-for-approval", "on-request"]
    if agent["model"]:
        args += ["--model", agent["model"]]
    if agent["effort"] in {"minimal", "low", "medium", "high", "xhigh"}:
        args += ["-c", "model_reasoning_effort=" + json.dumps(agent["effort"])]
    if spec.get("contextFile") and interactive:
        hook = Path(__file__).with_name("context.py")
        args += ["-c", "notify=" + json.dumps([sys.executable, str(hook), "bind", spec["contextFile"]])]
    return args


def login_state(provider, binary, timeout=20):
    """(angemeldet, Hinweis). Jede Anmeldeart zählt; Abo, API-Schlüssel oder Cloud-Zugang entscheidet der Nutzer."""
    args = ["login", "status"] if provider == "codex" else ["auth", "status", "--json"]
    try:
        result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return False, "Der Client antwortet nicht."
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
    return report


def run(spec_path):
    try:
        session_dir = Path(spec_path).resolve().parent
        # Startdaten nimmt der Starter nur aus dem Sitzungsbereich der App an, den Agenten nicht beschreiben können.
        if session_dir.parent != common.SESSIONS.resolve():
            raise SpecError("Die Sitzungsbeschreibung liegt nicht im Sitzungsbereich von Mochi Squad.")
        spec = attach_runtime(load_spec(spec_path), session_dir)
    except SpecError as error:
        raise SystemExit(str(error))
    provider = spec["provider"]
    binary = common.find_client(provider)
    label = "Claude Code" if provider == "claude" else "Codex"
    if not binary:
        raise SystemExit(f"{label} ist auf diesem Mac nicht installiert. Installiere es und starte die Sitzung erneut.")
    if not login_state(provider, binary)[0]:
        print(f"Für diesen Agenten musst du dich einmal bei {label} anmelden.", flush=True)
        subprocess.run([binary, *(["login"] if provider == "codex" else ["auth", "login"])])
        if not login_state(provider, binary)[0]:
            raise SystemExit("Anmeldung nicht bestätigt. Du kannst die Sitzung schließen und es erneut versuchen.")
    prompt = build_prompt(spec)
    os.chdir(spec["project"])
    os.environ.update(common.client_path_env(common.clean_child_env()))
    if spec.get("outbox"):
        os.environ["MOCHI_OUTBOX"] = spec["outbox"]
    if provider == "codex":
        # Der Codex-Beobachter findet die Sitzung über diese Zeile in der ersten Nachricht.
        prompt = f"Sitzung {spec['sessionId']}\n" + prompt
        if spec.get("parentChat"):
            os.execv(binary, [binary, "fork", *codex_args(spec), spec["parentChat"], prompt])
        os.execv(binary, [binary, *codex_args(spec), prompt])
    journal = common.claude_journal(spec["project"], spec["sessionId"])
    common.write_private(spec["contextFile"], json.dumps({"historyPath": str(journal)}))
    os.execv(binary, [binary, *claude_args(spec), prompt])


def login(provider):
    binary = common.find_client(provider)
    if not binary:
        raise SystemExit("Das Programm ist auf diesem Mac nicht installiert.")
    os.execv(binary, [binary, *(["login"] if provider == "codex" else ["auth", "login"])])


def main(argv):
    if argv[:1] == ["status"]:
        print(json.dumps(status()))
    elif len(argv) == 2 and argv[0] == "login" and argv[1] in common.PROVIDERS:
        login(argv[1])
    elif len(argv) == 2 and argv[0] == "run":
        run(argv[1])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
