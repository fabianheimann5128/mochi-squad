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
import fcntl
import json
import os
import sqlite3
import sys
from pathlib import Path

import common

TAIL = 256 * 1024
CLAUDE_FILE = "limits-claude.json"


LATEST_RESET = 4102444800  # 2100-01-01: anything later is no real reset time
SCAN_DAYS = 14
SCAN_FILES = 8
# Without a stored value the search goes on further back, file by file, until a report turns up.
SCAN_MORE = 200


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
    """History files, most recently written first: those of the last day folders and those Codex's own index lists
    as recently updated. A conversation continued today still lies in the folder of the day it began, possibly
    weeks ago, so neither the folder date nor the folders alone tell which file is current."""
    base = Path(home) / "sessions"
    folders = []
    try:
        for year in sorted((p for p in base.iterdir() if p.is_dir()), reverse=True)[:2]:
            for month in sorted((p for p in year.iterdir() if p.is_dir()), reverse=True)[:2]:
                folders += sorted((p for p in month.iterdir() if p.is_dir()), reverse=True)
    except OSError:
        folders = []
    candidates = set(indexed_rollouts(home))
    for day in sorted(folders, reverse=True)[:days]:
        candidates.update(day.glob("rollout-*.jsonl"))
    files = []
    for file in candidates:
        try:
            files.append((file.stat().st_mtime, file))
        except OSError:
            continue
    return [file for _, file in sorted(files, key=lambda pair: pair[0], reverse=True)]


def indexed_rollouts(home, limit=40):
    """History files of the conversations Codex updated last, from its own database."""
    found = []
    for db in sorted(Path(home).glob("state_*.sqlite"), key=lambda p: p.stat().st_mtime, reverse=True)[:1]:
        try:
            with sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=0.5) as connection:
                rows = connection.execute("SELECT rollout_path FROM threads ORDER BY updated_at DESC LIMIT ?", (limit,)).fetchall()
        except (sqlite3.Error, OSError):
            continue
        found += [Path(row[0]) for row in rows if isinstance(row[0], str) and row[0].endswith(".jsonl")]
    return found


def stamp_time(stamp):
    """Seconds since 1970 of a report's time stamp, or None."""
    if not isinstance(stamp, str):
        return None
    try:
        return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


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
            minutes = interval.get("window_minutes")
            # Only a plain number says which window this is; anything else is skipped, not trusted.
            if isinstance(minutes, bool) or not isinstance(minutes, (int, float)):
                continue
            field = {300: "five", 10080: "week"}.get(minutes)
            if field:
                result[field] = window(interval.get("used_percent"), interval.get("resets_at"))
        if result["five"] or result["week"]:
            return result
    return None


def stored(cache, ident):
    record = common.read_json(cache, None)
    if not isinstance(record, dict) or record.get("id") != ident:
        return None
    five, week = checked(record.get("five")), checked(record.get("week"))
    if not five and not week:
        return None
    return {"id": ident, "five": five, "week": week, "stamp": record.get("stamp") if isinstance(record.get("stamp"), str) else None}


def codex(home, ident, data=None):
    """The newest report of a Codex folder, by the time of the report itself. The last one found is kept, so new
    conversations that have not reported yet do not make the plan disappear, and an older report found later
    never replaces a newer one, also when two helpers run at the same time."""
    cache = Path(data or common.DATA) / ("limits-" + ident.replace(":", "-") + ".json")
    files = recent_rollouts(home)
    best = None
    for index, file in enumerate(files):
        if index >= SCAN_FILES and (best or cache.is_file()) or index >= SCAN_MORE:
            break
        found = codex_limits(file)
        if found and (best is None or (stamp_time(found["stamp"]) or 0) > (stamp_time(best["stamp"]) or 0)):
            best = found
    try:
        with open(cache.with_name(cache.name + ".lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            known = stored(cache, ident)
            known_time = stamp_time(known["stamp"]) if known else None
            if best and (known_time is None or (stamp_time(best["stamp"]) or 0) > known_time):
                entry = dict(best, id=ident)
                write(cache, entry)
                return entry
            return known or (dict(best, id=ident) if best else None)
    except OSError:
        return dict(best, id=ident) if best else stored(cache, ident)


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
