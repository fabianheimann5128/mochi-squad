"""Manage the connectors (MCP servers) of the installed clients.

  connectors.py list    <claude|codex> <folder>
  connectors.py login   <claude|codex> <folder> <name>
  connectors.py add     <claude|codex> <folder> <name> <url>

Output is always exactly one JSON line, on errors {"error": "..."}.
"""
import json
import re
import subprocess
import sys
from urllib.parse import urlsplit

import common
from common import t

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")


def client(provider):
    binary = common.find_client(provider)
    if not binary:
        raise ValueError(t("The client is not installed on this Mac.", "Der Client ist auf diesem Mac nicht installiert."))
    return binary


def check_url(address):
    """Only HTTPS or local HTTP, without credentials, query or fragment."""
    url = urlsplit(address)
    local = url.hostname in ("localhost", "127.0.0.1", "::1")
    return bool(url.hostname) and not (url.username or url.password or url.fragment or url.query) and (
        url.scheme == "https" or (url.scheme == "http" and local))


def run(provider, args, folder, timeout=45):
    return subprocess.run([client(provider), "mcp", *args], capture_output=True, text=True, cwd=folder, timeout=timeout)


# Sign-in states Codex reports for a server that works: no sign-in needed, or signed in.
CODEX_READY = (None, "", "unsupported", "bearer_token", "o_auth", "oauth", "logged_in")


def codex_state(row):
    """ok, login (sign-in needed), off (disabled) or unknown (a state this version does not know)."""
    if row.get("enabled") is False:
        return "off"
    status = row.get("auth_status")
    if status == "not_logged_in":
        return "login"
    return "ok" if status in CODEX_READY else "unknown"


def claude_state(text):
    """ok, login, error or unknown. "Disconnected" and "Not connected" contain "connected" and are checked first."""
    text = text.lower()
    if re.search(r"not connected|disconnected|failed|error|unreachable", text):
        return "error"
    if "auth" in text:
        return "login"
    return "ok" if re.search(r"\bconnected\b", text) else "unknown"


def connectors(provider, folder):
    codex = provider == "codex"
    result = run(provider, ["list", "--json"] if codex else ["list"], folder)
    if result.returncode:
        raise ValueError(t("The client could not list its connectors.", "Der Client konnte seine Konnektoren nicht auflisten."))
    if codex:
        return [dict(name=str(x.get("name", "")), state=codex_state(x))
                for x in json.loads(result.stdout) if isinstance(x, dict) and x.get("name")]
    rows = []
    for line in result.stdout.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        match = re.match(r"^([^:]+): .+? - (.+)$", line.strip())
        if match:
            rows.append(dict(name=match[1], state=claude_state(match[2])))
    return rows


def main(action=None, provider=None, folder=None, *args):
    if provider not in common.PROVIDERS or not folder:
        raise ValueError(t("Unknown client.", "Unbekannter Client."))
    if action == "list":
        return dict(rows=connectors(provider, folder))
    if not args:
        raise ValueError(t("The name is missing.", "Name fehlt."))
    name = args[0]
    if action == "login":
        if not name or name.startswith("-"):
            raise ValueError(t("Invalid name.", "Ungültiger Name."))
        command = ["login", name]
    elif action == "add":
        if not NAME.fullmatch(name):
            raise ValueError(t("Use a short name made of letters, digits, hyphen or underscore.",
                               "Verwende einen kurzen Namen aus Buchstaben, Ziffern, Bindestrich oder Unterstrich."))
        if len(args) < 2 or not check_url(args[1]):
            raise ValueError(t("Enter an HTTPS address or a local HTTP address without credentials.",
                               "Gib eine HTTPS-Adresse oder eine lokale HTTP-Adresse ohne Zugangsdaten ein."))
        if any(x["name"] == name for x in connectors(provider, folder)):
            raise ValueError(t("A connector with this name already exists.", "Ein Konnektor mit diesem Namen existiert bereits."))
        command = ["add", name, "--url", args[1]] if provider == "codex" else [
            "add", "--scope", "user", "--transport", "http", name, args[1]]
    else:
        raise ValueError(t("Unknown action.", "Unbekannte Aktion."))
    result = run(provider, command, folder, timeout=180)
    if result.returncode:
        raise ValueError(t("The client did not confirm the action. Check the address and the sign-in method.",
                           "Der Client hat die Aktion nicht bestätigt. Prüfe Adresse und Anmeldemethode."))
    return dict(message=t("Saved.", "Gespeichert.") if action == "add" else t("Sign-in confirmed by the client.", "Anmeldung vom Client bestätigt."))


if __name__ == "__main__":
    try:
        result = main(*sys.argv[1:])
    except subprocess.TimeoutExpired:
        result = dict(error=t("The client did not answer in time.", "Der Client hat innerhalb der Wartezeit nicht geantwortet."))
    except (ValueError, OSError, TypeError) as error:
        result = dict(error=str(error))
    print(json.dumps(result))
