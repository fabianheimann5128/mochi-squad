"""Gemeinsame Pfade und Hilfen für die Python-Helfer von Mochi Squad (nur Standardbibliothek, Python 3.9+)."""
import json
import os
import re
import shutil
from pathlib import Path

APP_NAME = "Mochi Squad"
HOME = Path.home()
DATA = HOME / "Library" / "Application Support" / APP_NAME

# Bereich außerhalb der App-Daten: das Post-Werkzeug und je Sitzung ein Postausgang. Die Sandbox einer Sitzung darf
# nur ihren eigenen Postausgang beschreiben; der Pfad enthält keine Leerzeichen, damit Freigaberegeln eindeutig greifen.
SHARED = HOME / "Library" / "Caches" / "dev.mochisquad.app"
POST_TOOL = SHARED / "bin" / "post"
OUTBOXES = SHARED / "outbox"
SESSIONS = DATA / "sessions"

# Markierungen im Startprompt: Der Verlaufsleser zeigt im Chat nur den eigentlichen Auftrag.
BRIEFING_MARK = "[Mochi Squad · Briefing]"
TASK_MARK = "\n[Auftrag]\n"

PROVIDERS = {"claude": "claude", "codex": "codex"}


def claude_home():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or HOME / ".claude")


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or HOME / ".codex")


def project_allowed(project, home=None):
    """Ein Projekt liegt unterhalb des Benutzerordners oder außerhalb davon, aber nie darüber und nie in ~/Library.

    Sonst lägen Zugangsdaten, Startskripte oder die Daten der App selbst im beschreibbaren Bereich eines Agenten.
    """
    home = Path(home or HOME).resolve()
    project = Path(project).resolve()
    library = home / "Library"
    return project != home and project not in home.parents and project != library and library not in project.parents


def project_key(project):
    """So benennt Claude Code den Ordner eines Projekts unter ~/.claude/projects."""
    return re.sub(r"[^a-zA-Z0-9]", "-", str(project))


def claude_journal(project, session_id):
    return claude_home() / "projects" / project_key(project) / (session_id.lower() + ".jsonl")


def find_client(provider):
    """Pfad zum installierten Client oder None. Sucht auch dort, wo grafische Apps PATH nicht kennen."""
    command = PROVIDERS.get(provider)
    if not command:
        return None
    found = shutil.which(command)
    if found:
        return found
    candidates = [HOME / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin"), HOME / ".npm-global/bin",
                  HOME / ".volta/bin", HOME / ".bun/bin"]
    candidates += sorted((HOME / ".nvm/versions/node").glob("*/bin"), reverse=True)
    if command == "codex":
        candidates.append(Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"))
    for folder in candidates:
        path = folder / command
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def client_path_env(env=None):
    """PATH für Clients, die aus der App oder von launchd gestartet werden."""
    env = dict(os.environ if env is None else env)
    extra = [str(HOME / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/sbin", "/sbin"]
    env["PATH"] = ":".join([env.get("PATH") or "/usr/bin:/bin"] + extra)
    return env


def clean_child_env(env=None):
    """Entfernt Markierungen einer übergeordneten Claude-Sitzung, damit der Client die eigene Anmeldung nutzt."""
    env = dict(os.environ if env is None else env)
    for key in list(env):
        if key.startswith(("CLAUDE_CODE_", "CLAUDE_AGENT_SDK_", "CLAUDE_PREVIEW_")) or key in (
                "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_BASE_URL"):
            del env[key]
    return env


def write_private(path, text):
    """Schreibt eine Datei, die nur der Nutzer lesen kann (0600), atomar."""
    path = Path(path)
    temp = path.with_name(path.name + ".tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(temp, path)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default
