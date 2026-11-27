"""Usage data of an agent session (model, context, limits) for the app.

  context.py claude <context.json>                          status line of Claude Code (data on stdin)
  context.py codex  <context.json> <folder> <id> <app-pid>  watches the history of a Codex session
  context.py bind   <context.json> <event-json>             Codex notification: remember the thread id
"""
import json
import os
import sqlite3
import sys
import tempfile
import time
import uuid
from pathlib import Path


def publish(path, data):
    """Atomic and safe with concurrent calls: every write uses its own temp file."""
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".context-", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle)
    os.replace(temp, path)


def number(value):
    return value if isinstance(value, (int, float)) else 0


def table(value):
    """A JSON object, or an empty one for anything else: a malformed report must not end the status line."""
    return value if isinstance(value, dict) else {}


def percent(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= 100 else None


def claude(path, data):
    data = table(data)
    window = table(data.get("context_window"))
    usage = table(window.get("current_usage"))
    cache = number(usage.get("cache_read_input_tokens")) + number(usage.get("cache_creation_input_tokens"))
    used = number(usage.get("input_tokens")) + cache if usage else None
    rate = table(data.get("rate_limits"))
    try:
        # The plan limits concern the whole subscription, not this session: the usage display reads them from here.
        import limits
        limits.remember_claude(rate)
    except Exception:  # noqa: BLE001 – the status line must never fail because of the display
        pass
    # What the session started with (instructions, tools, skills, first exchange) stays as the base of the breakdown.
    previous = {}
    try:
        previous = table(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        pass
    base = previous.get("base") if isinstance(previous.get("base"), int) else used
    publish(path, dict(base=base, answerInside=False, historyPath=data.get("transcript_path"), model=table(data.get("model")).get("display_name"),
                       used=used, limit=window.get("context_window_size"), percent=window.get("used_percentage"),
                       cached=usage.get("cache_read_input_tokens"), cacheWrite=usage.get("cache_creation_input_tokens"),
                       fresh=usage.get("input_tokens"), output=usage.get("output_tokens"),
                       five=percent(table(rate.get("five_hour")).get("used_percentage")),
                       week=percent(table(rate.get("seven_day")).get("used_percentage"))))
    print("Mochi Squad")


def locate_rollout(project, marker, thread_id=None):
    """(history file, model) of the Codex session whose first message contains `marker`, or None."""
    home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    db_dir = Path(os.environ.get("CODEX_SQLITE_HOME", home))
    for file in sorted(db_dir.glob("state_*.sqlite"), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            with sqlite3.connect(file.as_uri() + "?mode=ro", uri=True, timeout=0.3) as db:
                row = db.execute("SELECT rollout_path, model FROM threads WHERE cwd=? AND (id=? OR instr(first_user_message,?)>0) LIMIT 1",
                                 (project, thread_id, marker)).fetchone()
            if row and Path(row[0]).is_file():
                return row
        except (sqlite3.Error, OSError):
            continue
    return None


def codex_record(data, record):
    value = record.get("payload") or {}
    if record.get("type") == "turn_context" and value.get("model"):
        data["model"] = value["model"]
    if record.get("type") != "event_msg" or value.get("type") != "token_count":
        return
    info = value.get("info") or {}
    usage = info.get("last_token_usage") or {}
    if usage and info.get("model_context_window"):
        used = usage.get("total_tokens")
        limit = info["model_context_window"]
        if usage.get("input_tokens") is not None and usage.get("cached_input_tokens") is not None:
            data["fresh"] = max(0, usage["input_tokens"] - usage["cached_input_tokens"])
        if used is not None and "base" not in data:
            data["base"] = used
        data["answerInside"] = True
        data.update(used=used, limit=limit, percent=100 * used / limit if used is not None else None,
                    cached=usage.get("cached_input_tokens"), output=usage.get("output_tokens"))
    rates = value.get("rate_limits") or {}
    for key in ("primary", "secondary"):
        interval = rates.get(key) or {}
        field = {300: "five", 10080: "week"}.get(interval.get("window_minutes"))
        if field:
            data[field] = interval.get("used_percent")


def watch_codex(path, project, marker, parent_pid):
    # Retain only the numeric telemetry and model from this exact run.
    position = 0
    row = None
    data = {}
    while path.parent.is_dir() and os.getppid() == parent_pid:
        if not row:
            binding = path.with_suffix(".thread")
            thread_id = binding.read_text() if binding.exists() else None
            row = locate_rollout(project, marker, thread_id)
        if row:
            before = data.copy()
            data["historyPath"] = row[0]
            if not data.get("model"):
                data["model"] = row[1]
            try:
                with open(row[0], "rb") as log:
                    log.seek(position)
                    for line in log:
                        if not line.endswith(b"\n"):
                            break
                        position += len(line)
                        if b'"token_count"' in line or b'"turn_context"' in line[:120]:
                            try:
                                codex_record(data, json.loads(line))
                            except (ValueError, TypeError):
                                continue
            except FileNotFoundError:
                row, position = None, 0
            if data != before:
                publish(path, data)
        time.sleep(2)


if __name__ == "__main__":
    dest = Path(sys.argv[2])
    if sys.argv[1] == "bind":
        event = json.loads(sys.argv[3])
        ident = event.get("thread-id") or event.get("thread_id")
        if ident and dest.parent.is_dir():
            dest.with_suffix(".thread").write_text(str(uuid.UUID(ident)))
    elif sys.argv[1] == "claude":
        claude(dest, json.load(sys.stdin))
    elif sys.argv[1] == "codex":
        watch_codex(dest, sys.argv[3], sys.argv[4], int(sys.argv[5]))
