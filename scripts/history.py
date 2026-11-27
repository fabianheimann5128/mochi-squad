"""Reads the histories of Claude Code and Codex for a project straight from their files, without copying them.

Output is JSON on stdout; the app calls the subcommands list, read, thread and activity.
"""
import json
import os
import re
import sqlite3
import sys
from collections import deque
from pathlib import Path

import common
from context import codex_record


SESSION_LINES = (common.SESSION_LINE,) + common.LEGACY_SESSION_LINES


def user_text(text):
    if not isinstance(text, str):
        return ""
    # Claude Code wraps multi-line pastes in <pasted_content>; only the content counts for the chat.
    text = re.sub(r"</?pasted_content[^>]*>", "", text).strip()
    # First prompt of Mochi Squad: the chat shows only the task, not the briefing.
    if text.startswith(SESSION_LINES) and "\n" in text and common.BRIEFING_MARK in text.split("\n", 2)[1]:
        text = text.split("\n", 1)[1]
    if text.startswith(common.BRIEFING_MARK):
        for mark in (common.TASK_MARK,) + common.LEGACY_TASK_MARKS:
            if mark in text:
                return text.split(mark, 1)[1].strip()
    if text.lstrip().startswith(("<local-command-", "<command-name>", "<system-reminder>", "<task-notification>", "<teammate-message", "<cross-session-message", "# AGENTS.md instructions")):
        return ""
    return text.strip()


DIRECTIVE = re.compile(r"^[ \t]*::[a-z][a-z0-9-]*\{[^\n]*\}[ \t]*$\n?", re.M)


def agent_text(text):
    """Codex ends some turns with directives for its own app (`::browser-complete{title="..."}`). They are not
    meant for the reader."""
    return DIRECTIVE.sub("", text).strip() if isinstance(text, str) else ""


def codex_item(item):
    """(role, text) of a user or agent message from Codex's item_completed, otherwise ("", "")."""
    if not isinstance(item, dict) or item.get("type") not in ("UserMessage", "AgentMessage"):
        return "", ""
    parts = item.get("content") or []
    text = "\n\n".join(p.get("text", "") for p in parts if isinstance(p, dict) and isinstance(p.get("text"), str))
    if item["type"] == "UserMessage":
        return "user", user_text(text)
    return "assistant", agent_text(text)


def records(f):
    while True:
        start = f.tell()
        line = f.readline()
        if not line or not line.endswith(b"\n"):
            f.seek(start)
            break
        try:
            yield start, json.loads(line)
        except (ValueError, TypeError):
            pass


def claude_dir(project):
    return common.claude_home() / "projects" / common.project_key(project)


def list_chats(project):
    items = []
    for path in claude_dir(project).glob("*.jsonl"):
        try:
            with path.open("rb") as f:
                title, verified, first = "", False, ""
                for offset, row in records(f):
                    if row.get("cwd") and row.get("type") in ("user", "assistant"):
                        verified = os.path.realpath(row["cwd"]) == project
                        if not verified:
                            break
                    if row.get("type") == "user" and not row.get("isMeta"):
                        content = row.get("message", {}).get("content")
                        first = user_text(content)
                        if first and verified:
                            break
                    if offset > 4000000:
                        break
                if not verified:
                    continue
                f.seek(max(0, path.stat().st_size - 262144))
                if f.tell():
                    f.readline()
                for _, row in records(f):
                    if row.get("type") == "custom-title":
                        title = row.get("customTitle") or title
                items.append(dict(id=path.stem, path=str(path), provider="claude",
                                  title=title or " ".join(first.split())[:100] or "Claude session",
                                  modified=path.stat().st_mtime))
        except OSError:
            continue
    for index, home in enumerate(common.codex_homes()):
        items += codex_threads(Path(os.environ.get("CODEX_SQLITE_HOME", home)) if index == 0 else home, project)
    items += archived_chats(project, {item["path"] for item in items})
    return sorted(items, key=lambda x: -x["modified"])


def archived_chats(project, known, data=None):
    """Conversations the app moved out of an agent's chat in this project that no client index lists (a Codex
    history without a database entry, for example). Only history files of the two clients are taken."""
    agents = common.read_json(Path(data or common.DATA) / "agents.json", []) or []
    items = []
    for agent in agents if isinstance(agents, list) else []:
        if not isinstance(agent, dict) or not isinstance(agent.get("project"), str):
            continue
        if os.path.realpath(agent["project"]) != project:
            continue
        for path in agent.get("archivedJournals") or []:
            if not isinstance(path, str) or path in known or not path.endswith(".jsonl") or not os.path.isfile(path):
                continue
            provider = "codex" if Path(path).name.startswith("rollout-") else "claude"
            title = ""
            try:
                with open(path, "rb") as f:
                    for message in messages(f, provider, {}, True):
                        if message["role"] == "user":
                            title = message["text"]
                            break
                        if f.tell() > 2 * 1024 * 1024:
                            break
            except OSError:
                continue
            known.add(path)
            items.append(dict(id=Path(path).stem, path=path, provider=provider,
                              title=" ".join(title.split())[:120] or ("Codex session" if provider == "codex" else "Claude session"),
                              modified=os.path.getmtime(path)))
    return items


def codex_threads(db_root, project):
    """Chats of a Codex folder for a project, from the newest readable database."""
    for dbfile in sorted(db_root.glob("state_*.sqlite"), key=lambda p: p.stat().st_mtime, reverse=True):
        items = []
        try:
            with sqlite3.connect(dbfile.as_uri() + "?mode=ro", uri=True, timeout=1) as db:
                rows = db.execute("SELECT id, rollout_path, title, first_user_message, updated_at FROM threads WHERE cwd=? AND archived=0 ORDER BY updated_at DESC", (project,))
                for ident, path, title, first, updated in rows:
                    if not path or not Path(path).is_file():
                        continue
                    label = user_text(title) or user_text(first) or "Codex session"
                    if (first or "").startswith(SESSION_LINES):
                        label = user_text(first)
                    items.append(dict(id=ident, path=path, provider="codex", title=" ".join(label.split())[:120], modified=updated))
            return items
        except (OSError, sqlite3.Error):
            continue
    return []


# For the first page of a long history only the end of the file is read; enough for a few dozen messages.
TAIL_BYTES = 4 * 1024 * 1024


def messages(f, provider, stats, from_start):
    """Yields the messages of a history from the file's current position on, as dicts (id, role, text, timestamp),
    and collects model and usage numbers in `stats`. `from_start`: the reading began at the session's start, so the
    first usage seen is what the session started with (its base)."""
    for pos, row in records(f):
        kind = row.get("type")
        role, text = "", ""
        if provider == "claude":
            if kind == "attachment" and (row.get("attachment") or {}).get("type") == "queued_command" and not row.get("isSidechain"):
                # Message delivered while the agent worked: counts like a user line.
                queued = user_text((row.get("attachment") or {}).get("prompt"))
                if queued:
                    yield dict(id=pos, role="user", text=queued, timestamp=row.get("timestamp") or "")
                continue
            if kind == "attachment":
                attachment = row.get("attachment") or {}
                if attachment.get("type") == "skill_listing" and attachment.get("skillCount") is not None:
                    stats["skills"] = attachment["skillCount"]
            if kind == "api-request-shape":
                tools = (row.get("shape") or {}).get("tools")
                if isinstance(tools, list):
                    stats["tools"] = len(tools)
            if kind not in ("assistant", "user") or row.get("isMeta") or row.get("isSidechain"):
                continue
            msg = row.get("message") or {}
            body = msg.get("content")
            if isinstance(body, list):
                body = "\n\n".join(x.get("text", "") for x in body if isinstance(x, dict) and x.get("type") == "text")
            if kind == "assistant":
                used = claude_usage(row)
                if msg.get("model") != "<synthetic>":
                    stats["model"] = msg.get("model") or stats.get("model")
                if used is not None:
                    usage = msg["usage"]
                    stats["fresh"] = usage["input_tokens"]
                    stats["cacheWrite"] = usage.get("cache_creation_input_tokens", 0)
                    stats["cached"] = usage.get("cache_read_input_tokens", 0)
                    stats["used"] = used
                    if from_start and "base" not in stats:
                        stats["base"] = used
                    stats["output"] = usage.get("output_tokens")
                text = body or ""
            else:
                text = user_text(body)
            role = kind
        else:
            had_base = "base" in stats
            codex_record(stats, row)
            if not from_start and not had_base:
                stats.pop("base", None)
            payload = row.get("payload") or {}
            if kind == "event_msg" and payload.get("type") in ("agent_message", "user_message"):
                role = "assistant" if payload["type"] == "agent_message" else "user"
                text = payload.get("message", "")
                text = user_text(text) if role == "user" else agent_text(text)
            elif kind == "event_msg" and payload.get("type") == "item_completed":
                # Newer Codex versions report messages as completed items.
                role, text = codex_item(payload.get("item"))
        if isinstance(text, str) and text.strip():
            yield dict(id=pos, role=role, text=text.strip(), timestamp=row.get("timestamp") or "")


def claude_usage(row):
    """Tokens a Claude answer read, or None. Claude Code's own error notes ("<synthetic>") have no usage that counts."""
    msg = row.get("message") or {}
    usage = msg.get("usage") or {}
    if row.get("type") != "assistant" or msg.get("model") == "<synthetic>" or row.get("isMeta") or row.get("isSidechain"):
        return None
    if not isinstance(usage.get("input_tokens"), int):
        return None
    return usage["input_tokens"] + int(usage.get("cache_read_input_tokens") or 0) + int(usage.get("cache_creation_input_tokens") or 0)


def read(path, provider, offset, count):
    """Messages from `offset` on, at most the last `count`. A first read (offset 0) of a long file starts near
    its end instead of parsing everything for one page; `older` then says that more exists.

    The base (what the session started with) always comes from the session's first usage: from this read if it
    began at the start, otherwise from a look at the file's beginning, the same way for both clients."""
    result = deque(maxlen=count)
    total, stats = 0, {}
    with open(path, "rb") as f:
        size = os.fstat(f.fileno()).st_size
        skipped = offset == 0 and size > TAIL_BYTES and count * 40_000 <= TAIL_BYTES
        f.seek(size - TAIL_BYTES if skipped else offset)
        if skipped:
            f.readline()
        from_start = offset == 0 and not skipped
        for message in messages(f, provider, stats, from_start):
            result.append(message)
            total += 1
        if not from_start and stats.get("used") is not None and "base" not in stats:
            base = first_base(f, provider)
            if base is not None:
                stats["base"] = base
        # Claude reports the context without the answer just written; Codex counts the answer in. The display needs to know.
        stats["answerInside"] = provider == "codex"
        return dict(messages=list(result), position=f.tell(), older=total > count or skipped, usage=stats)


def first_base(f, provider, limit=2 * 1024 * 1024):
    """Tokens of the first usage in a history: what the session started with. Read from the file's start, at most
    `limit` bytes, with the same rules as a full read (no side chains, no meta lines, no synthetic answers)."""
    end = f.tell()
    try:
        f.seek(0)
        read_bytes = 0
        while read_bytes < limit:
            line = f.readline()
            if not line:
                break
            read_bytes += len(line)
            marker = b'"input_tokens"' if provider == "claude" else b'"token_count"'
            if marker not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if provider == "claude":
                used = claude_usage(row)
            else:
                probe = {}
                codex_record(probe, row)
                used = probe.get("base")
            if used is not None:
                return used
        return None
    finally:
        f.seek(end)



def activity(path, provider):
    """Recent public updates and tool names. Read a bounded tail even for long-running jobs."""
    events = deque(maxlen=14)
    modern = False  # Codex with item_completed: commands come from there
    with open(path, "rb") as f:
        f.seek(max(0, os.fstat(f.fileno()).st_size - 512 * 1024))
        if f.tell():
            f.readline()
        for pos, row in records(f):
            stamp = row.get("timestamp") or ""
            def add(index, label, file=None):
                if not label:
                    return
                events.append(dict(id=f"{pos}.{index}", stamp=stamp, text=label[:450], file=file))
            if provider == "claude" and row.get("type") == "assistant":
                blocks = row.get("message", {}).get("content") or []
                for i, block in enumerate(blocks):
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text" and block.get("text"):
                        add(i, block["text"])
                    elif block.get("type") == "tool_use":
                        args = block.get("input") or {}
                        filename = args.get("file_path") or args.get("path")
                        name = block.get("name", "tool")
                        add(i, name + (" · " + Path(filename).name if isinstance(filename,str) else ""), filename if isinstance(filename,str) else None)
            elif provider == "codex":
                item = row.get("payload") or {}
                if row.get("type") == "event_msg" and item.get("type") == "agent_message":
                    add(0, agent_text(item.get("message")))
                elif row.get("type") == "event_msg" and item.get("type") == "item_completed":
                    modern = True
                    done = item.get("item") or {}
                    if done.get("type") == "AgentMessage":
                        add(0, codex_item(done)[1])
                    elif done.get("type") == "CommandExecution":
                        command = done.get("command")
                        add(0, "$ " + (command[-1] if isinstance(command, list) and command else str(command or ""))[:160])
                elif row.get("type") == "response_item" and item.get("type") in ("function_call","custom_tool_call") and not modern:
                    add(0, item.get("name") or "tool")
    return list(events)


def thread(paths, count):
    """Earlier sessions of an agent as one history: in time order, copies from continuations only once."""
    merged, seen, older = [], set(), False
    for path in paths:
        provider = "codex" if path.startswith(str(common.codex_home())) or "/rollout-" in path else "claude"
        try:
            page = read(path, provider, 0, count)
        except OSError:
            continue
        older = older or page["older"]
        for line in page["messages"]:
            key = (line["role"], line["timestamp"], line["text"][:200])
            if key not in seen:
                seen.add(key)
                merged.append(line)
    merged.sort(key=lambda line: line["timestamp"] or "~")
    older = older or len(merged) > count
    merged = merged[-count:]
    for index, line in enumerate(merged):
        line["id"] = -(1000 + index)  # own numbers so that they do not collide with file positions
    return dict(messages=merged, position=0, older=older, usage={})


if __name__ == "__main__":
    if sys.argv[1] == "activity":
        print(json.dumps(activity(sys.argv[2],sys.argv[3])))
    elif sys.argv[1] == "thread":
        print(json.dumps(thread(sys.argv[3:], int(sys.argv[2]))))
    elif sys.argv[1] == "list":
        print(json.dumps(list_chats(os.path.realpath(sys.argv[2]))))
    else:
        print(json.dumps(read(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]))))
