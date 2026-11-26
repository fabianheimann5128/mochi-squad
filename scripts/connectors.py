"""Konnektoren (MCP-Server) der installierten Clients verwalten.

  connectors.py list    <claude|codex> <ordner>
  connectors.py login   <claude|codex> <ordner> <name>
  connectors.py add     <claude|codex> <ordner> <name> <url>

Ausgabe ist immer genau eine JSON-Zeile, bei Fehlern {"error": "..."}.
"""
import json
import re
import subprocess
import sys
from urllib.parse import urlsplit

import common

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")


def client(provider):
    binary = common.find_client(provider)
    if not binary:
        raise ValueError("Der Client ist auf diesem Mac nicht installiert.")
    return binary


def check_url(address):
    """Nur HTTPS oder lokales HTTP, ohne Zugangsdaten, Query oder Fragment."""
    url = urlsplit(address)
    local = url.hostname in ("localhost", "127.0.0.1", "::1")
    return bool(url.hostname) and not (url.username or url.password or url.fragment or url.query) and (
        url.scheme == "https" or (url.scheme == "http" and local))


def run(provider, args, folder, timeout=45):
    return subprocess.run([client(provider), "mcp", *args], capture_output=True, text=True, cwd=folder, timeout=timeout)


def connectors(provider, folder):
    codex = provider == "codex"
    result = run(provider, ["list", "--json"] if codex else ["list"], folder)
    if result.returncode:
        raise ValueError("Der Client konnte seine Konnektoren nicht auflisten.")
    if codex:
        return [dict(name=str(x.get("name", "")), status=x.get("auth_status", "") if x.get("enabled", True) else "disabled")
                for x in json.loads(result.stdout) if isinstance(x, dict) and x.get("name")]
    rows = []
    for line in result.stdout.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        match = re.match(r"^([^:]+): .+? - (.+)$", line.strip())
        if match:
            rows.append(dict(name=match[1], status=match[2]))
    return rows


def main(action=None, provider=None, folder=None, *args):
    if provider not in common.PROVIDERS or not folder:
        raise ValueError("Unbekannter Client.")
    if action == "list":
        return dict(rows=connectors(provider, folder))
    if not args:
        raise ValueError("Name fehlt.")
    name = args[0]
    if action == "login":
        if not name or name.startswith("-"):
            raise ValueError("Ungültiger Name.")
        command = ["login", name]
    elif action == "add":
        if not NAME.fullmatch(name):
            raise ValueError("Verwende einen kurzen Namen aus Buchstaben, Ziffern, Bindestrich oder Unterstrich.")
        if len(args) < 2 or not check_url(args[1]):
            raise ValueError("Gib eine HTTPS-Adresse oder eine lokale HTTP-Adresse ohne Zugangsdaten ein.")
        if any(x["name"] == name for x in connectors(provider, folder)):
            raise ValueError("Ein Konnektor mit diesem Namen existiert bereits.")
        command = ["add", name, "--url", args[1]] if provider == "codex" else [
            "add", "--scope", "user", "--transport", "http", name, args[1]]
    else:
        raise ValueError("Unbekannte Aktion.")
    result = run(provider, command, folder, timeout=180)
    if result.returncode:
        raise ValueError("Der Client hat die Aktion nicht bestätigt. Prüfe Adresse und Anmeldemethode.")
    return dict(message="Gespeichert." if action == "add" else "Anmeldung vom Client bestätigt.")


if __name__ == "__main__":
    try:
        result = main(*sys.argv[1:])
    except subprocess.TimeoutExpired:
        result = dict(error="Der Client hat innerhalb der Wartezeit nicht geantwortet.")
    except (ValueError, OSError, TypeError) as error:
        result = dict(error=str(error))
    print(json.dumps(result))
