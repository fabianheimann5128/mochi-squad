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


def window(percent, resets=None):
    if not isinstance(percent, (int, float)):
        return None
    return {"percent": max(0.0, min(100.0, float(percent))), "resets": resets if isinstance(resets, (int, float)) else None}


def claude(data=None):
    record = common.read_json(Path(data or common.DATA) / CLAUDE_FILE, None)
    if not isinstance(record, dict):
        return None
    return {"id": "claude", "five": record.get("five"), "week": record.get("week"), "stamp": record.get("stamp")}


def remember_claude(rates, data=None, now=None):
    """Called by the status line of a Claude session: stores the plan limits it just reported."""
    rates = rates if isinstance(rates, dict) else {}
    five, week = rates.get("five_hour") or {}, rates.get("seven_day") or {}
    entry = {"five": window(five.get("used_percentage"), five.get("resets_at")),
             "week": window(week.get("used_percentage"), week.get("resets_at")),
             "stamp": now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if entry["five"] is None and entry["week"] is None:
        return
    target = Path(data or common.DATA) / CLAUDE_FILE
    temp = target.with_name("." + CLAUDE_FILE + "." + str(os.getpid()))
    temp.write_text(json.dumps(entry), encoding="utf-8")
    os.replace(temp, target)


def newest_rollouts(home, count=3):
    """The most recently written history files of a Codex folder (sessions/YYYY/MM/DD/rollout-*.jsonl)."""
    found = []
    # Look at the last few days, in case today's folder is still empty.
    base = Path(home) / "sessions"
    if not base.is_dir():
        return []
    for year in sorted((p for p in base.iterdir() if p.is_dir()), reverse=True)[:1]:
        for month in sorted((p for p in year.iterdir() if p.is_dir()), reverse=True)[:2]:
            for day in sorted((p for p in month.iterdir() if p.is_dir()), reverse=True)[:3]:
                found += [p for p in day.glob("rollout-*.jsonl") if p.is_file()]
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)[:count]


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
        rates = ((record.get("payload") or {}).get("rate_limits")) or {}
        result = {"five": None, "week": None, "stamp": record.get("timestamp")}
        for key in ("primary", "secondary"):
            interval = rates.get(key) or {}
            field = {300: "five", 10080: "week"}.get(interval.get("window_minutes"))
            if field:
                result[field] = window(interval.get("used_percent"), interval.get("resets_at"))
        if result["five"] or result["week"]:
            return result
    return None


def codex(home, ident):
    for file in newest_rollouts(home):
        found = codex_limits(file)
        if found:
            return dict(found, id=ident)
    return None


def collect(data=None):
    entries = [claude(data)]
    entries.append(codex(common.codex_home(), "codex"))
    extra = Path(data or common.DATA) / "accounts" / "codex"
    if extra.is_dir():
        for home in sorted(p for p in extra.iterdir() if p.is_dir() and common.ACCOUNT_ID.fullmatch(p.name)):
            entries.append(codex(home, "codex:" + home.name))
    return [entry for entry in entries if entry]


if __name__ == "__main__":
    json.dump(collect(), sys.stdout)
