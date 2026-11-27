#!/usr/bin/python3
"""Plan limits of the user's subscriptions, for the usage display in the app.

  limits.py    prints a JSON list, one entry per subscription:
               {"id": "claude" | "codex" | "codex:<account>", "five": window|null, "week": window|null, "stamp": iso|null}
               window = {"percent": 0..100, "resets": unix time|null}

Claude Code reports its limits to the status line of a running session; context.py keeps the latest report in
limits-claude.json. Codex writes them into its own history files, so they are read from the newest ones. Nothing
here asks a server: the values are as fresh as the last answer of that subscription.
"""
import datetime
import json
import os
import sys
from pathlib import Path

import common

TAIL = 256 * 1024
CLAUDE_FILE = "limits-claude.json"


LATEST_RESET = 4102444800  # 2100-01-01: anything later is no real reset time
SCAN_DAYS = 14
SCAN_FILES = 8


def window(percent, resets=None):
    """A usage window, or None if the numbers are unusable. Percent is clamped to 0–100."""
    if isinstance(percent, bool) or not isinstance(percent, (int, float)) or percent != percent or percent in (float("inf"), float("-inf")):
        return None
    valid_reset = (not isinstance(resets, bool) and isinstance(resets, (int, float)) and resets == resets
                   and 0 < resets < LATEST_RESET)
    return {"percent": max(0.0, min(100.0, float(percent))), "resets": resets if valid_reset else None}


def checked(stored):
    """A stored window read back: checked again, never trusted as it is."""
    return window(stored.get("percent"), stored.get("resets")) if isinstance(stored, dict) else None


def claude(data=None):
    record = common.read_json(Path(data or common.DATA) / CLAUDE_FILE, None)
    if not isinstance(record, dict):
        return None
    five, week = checked(record.get("five")), checked(record.get("week"))
    if not five and not week:
        return None
    return {"id": "claude", "five": five, "week": week, "stamp": record.get("stamp") if isinstance(record.get("stamp"), str) else None}


def remember_claude(rates, data=None, now=None):
    """Called by the status line of a Claude session: stores the plan limits it just reported."""
    rates = rates if isinstance(rates, dict) else {}
    five, week = rates.get("five_hour"), rates.get("seven_day")
    five, week = five if isinstance(five, dict) else {}, week if isinstance(week, dict) else {}
    entry = {"five": window(five.get("used_percentage"), five.get("resets_at")),
             "week": window(week.get("used_percentage"), week.get("resets_at")),
             "stamp": now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if entry["five"] is None and entry["week"] is None:
        return
    write(Path(data or common.DATA) / CLAUDE_FILE, entry)


def write(target, entry):
    temp = target.with_name("." + target.name + "." + str(os.getpid()))
    temp.write_text(json.dumps(entry), encoding="utf-8")
    os.replace(temp, target)


def recent_rollouts(home, days=SCAN_DAYS):
    """History files of the last days, most recently written first. A conversation continued today still lies in
    the folder of the day it began, so the date of the folder alone does not tell which file is current."""
    base = Path(home) / "sessions"
    folders = []
    try:
        for year in sorted((p for p in base.iterdir() if p.is_dir()), reverse=True)[:2]:
            for month in sorted((p for p in year.iterdir() if p.is_dir()), reverse=True)[:2]:
                folders += sorted((p for p in month.iterdir() if p.is_dir()), reverse=True)
    except OSError:
        return []
    files = []
    for day in sorted(folders, reverse=True)[:days]:
        for file in day.glob("rollout-*.jsonl"):
            try:
                files.append((file.stat().st_mtime, file))
            except OSError:
                continue
    return [file for _, file in sorted(files, key=lambda pair: pair[0], reverse=True)]


def codex_limits(file):
    """(five, week, stamp) from the last limit report in a Codex history file, or None."""
    try:
        with open(file, "rb") as handle:
            size = os.fstat(handle.fileno()).st_size
            handle.seek(max(0, size - TAIL))
            lines = handle.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        if '"rate_limits"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        payload = record.get("payload") if isinstance(record, dict) else None
        rates = payload.get("rate_limits") if isinstance(payload, dict) else None
        if not isinstance(rates, dict):
            continue
        result = {"five": None, "week": None, "stamp": record.get("timestamp") if isinstance(record.get("timestamp"), str) else None}
        for key in ("primary", "secondary"):
            interval = rates.get(key)
            if not isinstance(interval, dict):
                continue
            field = {300: "five", 10080: "week"}.get(interval.get("window_minutes"))
            if field:
                result[field] = window(interval.get("used_percent"), interval.get("resets_at"))
        if result["five"] or result["week"]:
            return result
    return None


def codex(home, ident, data=None):
    """The newest report of a Codex folder. The last one found is kept, so new conversations that have not reported
    yet do not make the plan disappear from the display."""
    cache = Path(data or common.DATA) / ("limits-" + ident.replace(":", "-") + ".json")
    for file in recent_rollouts(home)[:SCAN_FILES]:
        found = codex_limits(file)
        if found:
            entry = dict(found, id=ident)
            try:
                write(cache, entry)
            except OSError:
                pass
            return entry
    stored = common.read_json(cache, None)
    if isinstance(stored, dict) and stored.get("id") == ident:
        five, week = checked(stored.get("five")), checked(stored.get("week"))
        if five or week:
            return {"id": ident, "five": five, "week": week, "stamp": stored.get("stamp") if isinstance(stored.get("stamp"), str) else None}
    return None


def collect(data=None):
    """Every subscription on its own: one broken report never hides the others."""
    jobs = [lambda: claude(data), lambda: codex(common.codex_home(), "codex", data)]
    extra = Path(data or common.DATA) / "accounts" / "codex"
    if extra.is_dir():
        for home in sorted(p for p in extra.iterdir() if p.is_dir() and common.ACCOUNT_ID.fullmatch(p.name)):
            jobs.append(lambda home=home: codex(home, "codex:" + home.name, data))
    entries = []
    for job in jobs:
        try:
            entry = job()
        except Exception:  # noqa: BLE001 – a single unreadable source must not cost the whole display
            entry = None
        if entry:
            entries.append(entry)
    return entries


if __name__ == "__main__":
    json.dump(collect(), sys.stdout)
