#!/usr/bin/python3
"""Führt eine geplante Routine aus. launchd startet dieses Skript auch, wenn die App geschlossen ist.

  routine.py <routine-id> [--now]    --now: Testlauf, auch wenn die Routine pausiert ist

Liest die Routine aus routines.json, startet den Client ohne Rückfragen im Projektordner (mit denselben Regeln
wie eine normale Sitzung) und hängt das Ergebnis immer an routine-runs.jsonl an, auch bei Fehlern.
"""
import datetime
import fcntl
import json
import subprocess
import sys
import uuid
from pathlib import Path

import common
import launcher

TIMEOUT = 3 * 3600


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def find_routine(routine_id, path=None):
    routines = common.read_json(path or common.DATA / "routines.json", [])
    if not isinstance(routines, list):
        return None
    return next((r for r in routines if isinstance(r, dict) and r.get("id") == routine_id), None)


def build_spec(routine, owner, session_id):
    # Die Werkzeuge des Koordinators gibt es nur, solange die App läuft. In Routinen arbeitet er wie jeder andere Agent.
    agent = routine.get("agent") or {}
    if isinstance(agent, dict) and agent.get("isCoordinator"):
        agent = dict(agent, isCoordinator=False, job=agent.get("job") or "Koordinator")
    return launcher.validate_spec({
        "provider": routine.get("provider"), "project": routine.get("project"), "task": routine.get("task"),
        "sessionId": session_id, "owner": owner, "unattended": True, "allowWeb": routine.get("allowWeb") is True,
        "agent": agent, "account": agent.get("account") or "" if isinstance(agent, dict) else "",
    })


def execute(spec, binary):
    """(Exit-Code, Ausgabe, Verlaufsdatei oder None)."""
    env = common.client_path_env(common.clean_child_env())
    prompt = launcher.build_prompt(spec)
    if spec["provider"] == "codex":
        # Auch die Prüfaufrufe unten sollen im Ordner des gewählten Abos laufen.
        common.use_account(spec["account"])
        common.use_account(spec["account"], env)
        if not launcher.codex_profile_enforced(binary, spec):
            return 1, launcher.OUTDATED_CODEX, None
        servers = launcher.codex_servers(binary)
        if servers is None:
            return 1, launcher.UNKNOWN_SERVERS, None
        args = [binary, "exec", *launcher.codex_args(spec, interactive=False, servers=servers), "--skip-git-repo-check", prompt]
        journal = None
    else:
        args = [binary, *launcher.claude_args(spec, interactive=False), prompt]
        journal = str(common.claude_journal(spec["project"], spec["sessionId"]))
    result = subprocess.run(args, cwd=spec["project"], env=env, capture_output=True, text=True, timeout=TIMEOUT)
    return result.returncode, (result.stdout or result.stderr)[-6000:], journal


def append_record(record, path=None):
    path = Path(path or common.DATA / "routine-runs.jsonl")
    with open(path, "a", encoding="utf-8") as log:
        fcntl.flock(log, fcntl.LOCK_EX)
        log.write(json.dumps(record, ensure_ascii=False) + "\n")


def main(argv):
    routine_id = argv[0] if argv else ""
    manual = "--now" in argv[1:]
    routine = find_routine(routine_id)
    if not routine or (routine.get("active") is not True and not manual):
        return
    settings = common.read_json(common.DATA / "settings.json", {}) or {}
    record = {"routine": routine_id, "project": routine.get("project"), "agent": (routine.get("agent") or {}).get("id"),
              "name": (routine.get("agent") or {}).get("name"), "start": now(), "journal": None}
    try:
        spec = build_spec(routine, str(settings.get("ownerName") or ""), str(uuid.uuid4()))
        binary = common.find_client(spec["provider"])
        if not binary:
            record.update(code=127, output="Der Client ist auf diesem Mac nicht installiert.")
        else:
            code, output, journal = execute(spec, binary)
            record.update(code=code, output=output, journal=journal)
    except launcher.SpecError as error:
        record.update(code=2, output=str(error))
    except subprocess.TimeoutExpired:
        record.update(code=124, output="Die Routine wurde nach drei Stunden abgebrochen.")
    except OSError as error:
        record.update(code=1, output=f"Start fehlgeschlagen: {error}")
    except Exception as error:  # noqa: BLE001 – jeder Lauf soll im Protokoll enden, auch ein unerwartet gescheiterter
        record.update(code=1, output=f"Unerwarteter Fehler: {error}")
    record["end"] = now()
    append_record(record)


if __name__ == "__main__":
    main(sys.argv[1:])
