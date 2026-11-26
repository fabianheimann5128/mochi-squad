"""Liest die Verläufe von Claude Code und Codex eines Projekts direkt aus deren Dateien, ohne sie zu kopieren.

Ausgabe ist JSON auf stdout; die App ruft die Unterbefehle list, read, thread und activity auf.
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


def user_text(text):
    if not isinstance(text, str):
        return ""
    # Mehrzeilige Einfügungen verpackt Claude Code in <pasted_content>; für den Chat zählt nur der Inhalt.
    text = re.sub(r"</?pasted_content[^>]*>", "", text).strip()
    # Startprompt von Mochi Squad: Im Chat erscheint nur der Auftrag, nicht das Briefing.
    if text.startswith("Sitzung ") and "\n" in text and common.BRIEFING_MARK in text.split("\n", 2)[1]:
        text = text.split("\n", 1)[1]
    if text.startswith(common.BRIEFING_MARK) and common.TASK_MARK in text:
        return text.split(common.TASK_MARK, 1)[1].strip()
    if text.lstrip().startswith(("<local-command-", "<command-name>", "<system-reminder>", "<task-notification>", "<teammate-message", "<cross-session-message", "# AGENTS.md instructions")):
        return ""
    return text.strip()


def codex_item(item):
    """(Rolle, Text) einer Nutzer- oder Agentennachricht aus Codex' item_completed, sonst ("", "")."""
    if not isinstance(item, dict) or item.get("type") not in ("UserMessage", "AgentMessage"):
        return "", ""
    parts = item.get("content") or []
    text = "\n\n".join(p.get("text", "") for p in parts if isinstance(p, dict) and isinstance(p.get("text"), str))
    if item["type"] == "UserMessage":
        return "user", user_text(text)
    return "assistant", text


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
                                  title=title or " ".join(first.split())[:100] or "Claude-Sitzung",
                                  modified=path.stat().st_mtime))
        except OSError:
            continue
    home = common.codex_home()
    db_root = Path(os.environ.get("CODEX_SQLITE_HOME", home))
    for dbfile in sorted(db_root.glob("state_*.sqlite"), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            with sqlite3.connect(dbfile.as_uri() + "?mode=ro", uri=True, timeout=1) as db:
                rows = db.execute("SELECT id, rollout_path, title, first_user_message, updated_at FROM threads WHERE cwd=? AND archived=0 ORDER BY updated_at DESC", (project,))
                for ident, path, title, first, updated in rows:
                    if not path or not Path(path).is_file():
                        continue
                    label = user_text(title) or user_text(first) or "Codex-Sitzung"
                    if (first or "").startswith("Sitzung "):
                        label = user_text(first)
                    items.append(dict(id=ident, path=path, provider="codex", title=" ".join(label.split())[:120], modified=updated))
            break
        except (OSError, sqlite3.Error):
            continue
    return sorted(items, key=lambda x: -x["modified"])


def read(path, provider, offset, count):
    result = deque(maxlen=count)
    total, stats = 0, {}
    with open(path, "rb") as f:
        f.seek(offset)
        for pos, row in records(f):
            kind = row.get("type")
            role, text = "", ""
            if provider == "claude":
                if kind == "attachment" and (row.get("attachment") or {}).get("type") == "queued_command" and not row.get("isSidechain"):
                    # Während der Arbeit zugestellte Nachricht: zählt wie eine Nutzerzeile.
                    queued = user_text((row.get("attachment") or {}).get("prompt"))
                    if queued:
                        result.append(dict(id=pos, role="user", text=queued, timestamp=row.get("timestamp") or ""))
                        total += 1
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
                    usage = msg.get("usage") or {}
                    stats["model"] = msg.get("model") or stats.get("model")
                    if "input_tokens" in usage:
                        stats["fresh"] = usage["input_tokens"]
                        stats["cacheWrite"] = usage.get("cache_creation_input_tokens", 0)
                        stats["cached"] = usage.get("cache_read_input_tokens", 0)
                        stats["used"] = usage["input_tokens"] + stats["cached"] + usage.get("cache_creation_input_tokens", 0)
                        stats["output"] = usage.get("output_tokens")
                    text = body or ""
                else:
                    text = user_text(body)
                role = kind
            else:
                codex_record(stats, row)
                payload = row.get("payload") or {}
                if kind == "event_msg" and payload.get("type") in ("agent_message", "user_message"):
                    role = "assistant" if payload["type"] == "agent_message" else "user"
                    text = payload.get("message", "")
                    if role == "user":
                        text = user_text(text)
                elif kind == "event_msg" and payload.get("type") == "item_completed":
                    # Neuere Codex-Versionen melden Nachrichten als abgeschlossene Elemente.
                    role, text = codex_item(payload.get("item"))
            if isinstance(text, str) and text.strip():
                result.append(dict(id=pos, role=role, text=text.strip(), timestamp=row.get("timestamp") or ""))
                total += 1
        return dict(messages=list(result), position=f.tell(), older=total > count, usage=stats)



def activity(path, provider):
    """Recent public updates and tool names. Read a bounded tail even for long-running jobs."""
    events = deque(maxlen=14)
    modern = False  # Codex mit item_completed: Befehle kommen von dort
    with open(path, "rb") as f:
        f.seek(max(0, os.fstat(f.fileno()).st_size - 512 * 1024))
        if f.tell():
            f.readline()
        for pos, row in records(f):
            stamp = row.get("timestamp") or ""
            def add(index, label, file=None):
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
                        name = block.get("name", "Werkzeug")
                        add(i, name + (" · " + Path(filename).name if isinstance(filename,str) else ""), filename if isinstance(filename,str) else None)
            elif provider == "codex":
                item = row.get("payload") or {}
                if row.get("type") == "event_msg" and item.get("type") == "agent_message":
                    add(0, item.get("message") or "")
                elif row.get("type") == "event_msg" and item.get("type") == "item_completed":
                    modern = True
                    done = item.get("item") or {}
                    if done.get("type") == "AgentMessage":
                        add(0, codex_item(done)[1])
                    elif done.get("type") == "CommandExecution":
                        command = done.get("command")
                        add(0, "Befehl · " + (command[-1] if isinstance(command, list) and command else str(command or ""))[:160])
                elif row.get("type") == "response_item" and item.get("type") in ("function_call","custom_tool_call") and not modern:
                    add(0, item.get("name") or "Werkzeug")
    return list(events)


def thread(paths, count):
    """Frühere Sitzungen eines Agenten als ein Verlauf: zeitlich geordnet, Kopien aus Fortsetzungen nur einmal."""
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
        line["id"] = -(1000 + index)  # eigene Nummern, damit sie nicht mit Dateipositionen kollidieren
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
