#!/usr/bin/python3
"""Runs a scheduled routine. launchd starts this script even when the app is closed.

  routine.py <routine-id> [--now]    --now: test run, even if the routine is paused

Reads the routine from routines.json, starts the client without confirmations in the project folder (with the same
rules as a regular session) and always appends the result to routine-runs.jsonl, also on errors.
"""
import datetime
import fcntl
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

import common
import context
import launcher
from common import t

TIMEOUT = 3 * 3600
CAFFEINATE = "/usr/bin/caffeinate"


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def find_routine(routine_id, path=None):
    routines = common.read_json(path or common.DATA / "routines.json", [])
    if not isinstance(routines, list):
        return None
    return next((r for r in routines if isinstance(r, dict) and r.get("id") == routine_id), None)


NOTHING_NEW = "NOTHING_NEW"


def previous_output(routine_id, path=None):
    """What the last finished run of this routine reported, so the next one can tell what is new."""
    path = Path(path or common.DATA / "routine-runs.jsonl")
    try:
        with open(path, "rb") as log:
            log.seek(max(0, os.fstat(log.fileno()).st_size - 512 * 1024))
            lines = log.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    for line in reversed(lines):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if (isinstance(record, dict) and record.get("routine") == routine_id and record.get("code") == 0
                and record.get("output") and not record.get("silent")):
            return str(record["output"]).strip()[-1500:]
    return ""


def routine_task(routine, owner, previous=""):
    """The task as the agent gets it: what started the run, what it found last time, and when to stay silent."""
    parts = []
    if routine.get("trigger") == "folder" and routine.get("folder"):
        parts.append(f"The folder `{routine['folder']}` just changed. Look at what is new there first.")
    parts.append(str(routine.get("task") or "").strip())
    if routine.get("quiet") is True:
        if previous:
            parts.append("Your previous run reported:\n<<<\n" + previous + "\n>>>")
        parts.append(f"If there is nothing new since then and nothing that needs {owner}'s attention, answer with exactly "
                     f"{NOTHING_NEW} and nothing else. Otherwise answer with a short summary of what is new.")
    return "\n\n".join(p for p in parts if p)


def silent(output):
    """True if a quiet routine found nothing worth reporting."""
    return NOTHING_NEW in str(output or "").strip()[-200:]


def build_spec(routine, owner, session_id, language="en", previous=""):
    # The coordinator's tools exist only while the app runs. In routines it works like any other agent.
    agent = routine.get("agent") or {}
    if isinstance(agent, dict) and agent.get("isCoordinator"):
        agent = dict(agent, isCoordinator=False, job=agent.get("job") or "coordinator")
    return launcher.attach_memory(launcher.attach_skills(launcher.validate_spec({
        "provider": routine.get("provider"), "project": routine.get("project"),
        "task": routine_task(routine, owner or "the user", previous),
        "sessionId": session_id, "owner": owner, "language": language, "unattended": True,
        "allowWeb": routine.get("allowWeb") is True,
        "agent": agent, "account": agent.get("account") or "" if isinstance(agent, dict) else "",
        "agentId": agent.get("id") or "" if isinstance(agent, dict) else "",
    })))


def execute(spec, binary):
    """(exit code, output, history file or None)."""
    env = common.client_path_env(common.clean_child_env())
    prompt = launcher.build_prompt(spec)
    if spec["provider"] == "codex":
        # The checks below shall run in the chosen subscription's folder too.
        common.use_account(spec["account"])
        common.use_account(spec["account"], env)
        if not launcher.codex_profile_enforced(binary, spec):
            return 1, launcher.outdated_codex(), None
        servers = launcher.codex_servers(binary, spec["project"])
        if servers is None:
            return 1, launcher.unknown_servers(), None
        args = [binary, "exec", *launcher.codex_args(spec, interactive=False, servers=servers), "--skip-git-repo-check",
                launcher.codex_prompt(spec, prompt)]
    else:
        args = [binary, *launcher.claude_args(spec, interactive=False), prompt]
    # caffeinate keeps the Mac from falling asleep in the middle of the run; it ends with the client.
    if Path(CAFFEINATE).is_file():
        args = [CAFFEINATE, "-i", *args]
    result = subprocess.run(args, cwd=spec["project"], env=env, capture_output=True, text=True, timeout=TIMEOUT)
    if spec["provider"] == "codex":
        # Codex names its history file itself; the session line in the prompt leads to it.
        found = context.locate_rollout(spec["project"], spec["sessionId"])
        journal = found[0] if found else None
    else:
        journal = str(common.claude_journal(spec["project"], spec["sessionId"]))
    return result.returncode, (result.stdout or result.stderr)[-6000:], journal


def append_record(record, path=None):
    path = Path(path or common.DATA / "routine-runs.jsonl")
    with open(path, "a", encoding="utf-8") as log:
        fcntl.flock(log, fcntl.LOCK_EX)
        log.write(json.dumps(record, ensure_ascii=False) + "\n")


def single_run(routine_id, folder=None):
    """Lock that keeps one routine from running twice at once. Returns the open file, or None if a run is active."""
    folder = Path(folder or common.DATA / "locks")
    folder.mkdir(parents=True, exist_ok=True)
    handle = open(folder / (routine_id + ".lock"), "w")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def main(argv):
    routine_id = argv[0] if argv else ""
    manual = "--now" in argv[1:]
    routine = find_routine(routine_id)
    if not routine or (routine.get("active") is not True and not manual):
        return
    settings = common.read_json(common.DATA / "settings.json", {}) or {}
    record = {"routine": routine_id, "project": routine.get("project"), "agent": (routine.get("agent") or {}).get("id"),
              "name": (routine.get("agent") or {}).get("name"), "start": now(), "journal": None}
    lock = single_run(routine_id) if common.ACCOUNT_ID.fullmatch(routine_id) else None
    try:
        if lock is None:
            record.update(code=75, output=t("Skipped: an earlier run of this routine is still working.",
                                            "Übersprungen: Ein früherer Lauf dieser Routine arbeitet noch."))
        else:
            if routine.get("trigger") == "folder" and not Path(str(routine.get("folder") or "")).is_dir():
                raise launcher.SpecError(t("The watched folder no longer exists.", "Der beobachtete Ordner existiert nicht mehr."))
            previous = previous_output(routine_id) if routine.get("quiet") is True else ""
            spec = build_spec(routine, str(settings.get("ownerName") or ""), str(uuid.uuid4()), common.language(), previous)
            binary = common.find_client(spec["provider"])
            if not binary:
                record.update(code=127, output=t("The client is not installed on this Mac.",
                                                 "Der Client ist auf diesem Mac nicht installiert."))
            else:
                code, output, journal = execute(spec, binary)
                record.update(code=code, output=output, journal=journal)
                if routine.get("quiet") is True and code == 0 and silent(output):
                    record["silent"] = True
    except launcher.SpecError as error:
        record.update(code=2, output=str(error))
    except subprocess.TimeoutExpired:
        record.update(code=124, output=t("The routine was stopped after three hours.",
                                         "Die Routine wurde nach drei Stunden abgebrochen."))
    except OSError as error:
        record.update(code=1, output=t("Start failed: ", "Start fehlgeschlagen: ") + str(error))
    except Exception as error:  # noqa: BLE001 – every run shall end in the log, even one that failed unexpectedly
        record.update(code=1, output=t("Unexpected error: ", "Unerwarteter Fehler: ") + str(error))
    finally:
        if lock is not None:
            lock.close()
    record["end"] = now()
    append_record(record)


if __name__ == "__main__":
    main(sys.argv[1:])
