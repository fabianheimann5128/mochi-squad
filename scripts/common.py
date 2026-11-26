"""Shared paths and helpers for the Python helpers of Mochi Squad (standard library only, Python 3.9+)."""
import json
import os
import re
import shutil
from pathlib import Path

APP_NAME = "Mochi Squad"
HOME = Path.home()
DATA = HOME / "Library" / "Application Support" / APP_NAME

# Area outside the app data: the post tool and one outbox per session. A session's sandbox may only write to its own
# outbox; the path has no spaces so that permission rules match unambiguously.
SHARED = HOME / "Library" / "Caches" / "dev.mochisquad.app"
POST_TOOL = SHARED / "bin" / "post"
OUTBOXES = SHARED / "outbox"
SESSIONS = DATA / "sessions"

# Markers in the first prompt: the history reader shows only the actual task in the chat.
BRIEFING_MARK = "[Mochi Squad · Briefing]"
TASK_MARK = "\n[Task]\n"
# Written by earlier versions; still recognised so that old chats read correctly.
LEGACY_TASK_MARKS = ("\n[Auftrag]\n",)
# First line of a Codex prompt, by which the watcher finds the session's history file.
SESSION_LINE = "Session "
LEGACY_SESSION_LINES = ("Sitzung ",)

PROVIDERS = {"claude": "claude", "codex": "codex"}


def language():
    """Interface language of the app: "en" unless the user chose German. The app passes it in MOCHI_LANG;
    helpers started by launchd read it from the settings."""
    chosen = os.environ.get("MOCHI_LANG") or (read_json(DATA / "settings.json", {}) or {}).get("language")
    return "de" if chosen == "de" else "en"


def t(en, de):
    """The message in the interface language."""
    return de if language() == "de" else en


def node_paths():
    """Folders where Node.js is commonly installed, newest nvm version first."""
    return ([HOME / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin"), HOME / ".volta/bin"]
            + sorted((HOME / ".nvm/versions/node").glob("*/bin"), reverse=True)
            + sorted((HOME / ".local/opt").glob("node-*/bin"), reverse=True))


def claude_home():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or HOME / ".claude")


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or HOME / ".codex")


ACCOUNT_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")


def account_home(account, root=None):
    """Own Codex folder of an extra ChatGPT subscription; None for the regular one.

    The folder lies in the app data and therefore behind the sandbox's read lock.
    """
    if not account:
        return None
    if not ACCOUNT_ID.fullmatch(account):
        raise ValueError(t("Invalid subscription.", "Ungültiges Abo."))
    return Path(root or DATA / "accounts") / "codex" / account


def use_account(account, env=None):
    """Points the environment at the chosen subscription and creates its folder."""
    env = os.environ if env is None else env
    home = account_home(account)
    if home is not None:
        home.mkdir(parents=True, exist_ok=True)
        os.chmod(home, 0o700)
        env["CODEX_HOME"] = str(home)
    return env


def codex_homes():
    """The standard Codex folder and the folders of all extra subscriptions."""
    extra = DATA / "accounts" / "codex"
    return [codex_home()] + (sorted(p for p in extra.iterdir() if p.is_dir()) if extra.is_dir() else [])


def project_allowed(project, home=None):
    """A project lies inside the home folder or outside of it, but never above it and never in ~/Library.

    Otherwise credentials, startup scripts or the app's own data would sit in an agent's writable area.
    """
    home = Path(home or HOME).resolve()
    project = Path(project).resolve()
    if project == home or project in home.parents:
        return False
    # Inside the home folder, ~/Library, ~/Applications and hidden folders such as ~/.ssh, ~/.claude or ~/.codex are off limits.
    if home in project.parents:
        first = project.relative_to(home).parts[0]
        return first not in ("Library", "Applications") and not first.startswith(".")
    return True


def project_key(project):
    """How Claude Code names a project's folder under ~/.claude/projects."""
    return re.sub(r"[^a-zA-Z0-9]", "-", str(project))


def claude_journal(project, session_id):
    return claude_home() / "projects" / project_key(project) / (session_id.lower() + ".jsonl")


def find_client(provider):
    """Path of the installed client or None. Also looks where graphical apps do not know PATH."""
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
    """PATH for clients started from the app or by launchd."""
    env = dict(os.environ if env is None else env)
    extra = [str(HOME / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/sbin", "/sbin"]
    env["PATH"] = ":".join([env.get("PATH") or "/usr/bin:/bin"] + extra)
    return env


def clean_child_env(env=None):
    """Removes markers of a parent Claude session so that the client uses its own sign-in."""
    env = dict(os.environ if env is None else env)
    for key in list(env):
        if key.startswith(("CLAUDE_CODE_", "CLAUDE_AGENT_SDK_", "CLAUDE_PREVIEW_")) or key in (
                "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "ANTHROPIC_BASE_URL"):
            del env[key]
    return env


def write_private(path, text):
    """Writes a file only the user can read (0600), atomically."""
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
