"""Mochi Memory: what the agents remember, as plain Markdown notes that Obsidian can open.

The folder holds one note about the user ("mochi: profile" in its properties) and one note per project
("mochi: project" and "project: <path>"). Every list line ("- ", "* " or "+ ") below the properties is an entry; the app
adds them as "- <text> · <agent> · <date> %%mochi:1 …%%" (the comment says who saved it and with which rights, see
parse_mark), the user may write them any way. The app writes; agents read what the
launcher puts into their briefing and ask the app to remember more through their post tool.
"""
import hashlib
import os
import re
import stat
from pathlib import Path

import common

DEFAULT_FOLDER = "Mochi Memory"
ENTRY = re.compile(r"^\s*[-*+]\s+(?!\[\[)(.+?)\s*$")
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MARK = "%%mochi"
MARK_PREFIX = "%%mochi:1"
UUID_TEXT = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
HEX16 = re.compile(r"^[0-9a-fA-F]{16}$")
MAX_LINES = 60
MAX_CHARS = 6000
MAX_ENTRY = 400
MAX_NOTE = 512 * 1024

# The same patterns as the app's (Core/Memory.swift, looksSecret): such lines never reach a briefing.
SECRETS = [re.compile(p) for p in (
    r"(?i)\b(password|passwort|kennwort|passwd|pwd|pin|api[_ -]?key|secret|geheimnis|token|zugangsdaten)\b\s*[:=]",
    r"(?i)\b(my|mein|meine|the|das|der|die)\s+(password|passwort|kennwort|pin|api[_ -]?key|token|secret)\s+(is|ist|lautet|=)\b",
    r"-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)-----",
    r"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}", r"\bgh[pousr]_[A-Za-z0-9]{20,}", r"\bAKIA[0-9A-Z]{16}\b",
    r"\bxox[abposr]-[A-Za-z0-9-]{10,}", r"\bAIza[0-9A-Za-z_-]{30,}",
    r"\b\d{8,10}:AA[A-Za-z0-9_-]{30,}", r"[A-Za-z0-9+/=_-]{40,}")]


def looks_secret(text):
    return any(pattern.search(text) for pattern in SECRETS)


def folder(settings=None, home=None):
    """The memory folder: the one chosen in Settings, otherwise ~/Mochi Memory."""
    settings = settings if isinstance(settings, dict) else common.read_json(common.DATA / "settings.json", {}) or {}
    chosen = settings.get("memoryFolder")
    if isinstance(chosen, str) and chosen.startswith("/"):
        return Path(chosen)
    return Path(home or common.HOME) / DEFAULT_FOLDER


def unquoted(raw):
    """A property value: one pair of outer quotes removed, the escapes the app writes undone (as in Core/Memory.swift)."""
    value = raw.strip()
    if len(value) < 2 or value[0] != value[-1] or value[0] not in "\"'":
        return value
    inner = value[1:-1]
    if value[0] == "'":
        return inner.replace("''", "'")
    out, i = [], 0
    simple = {"n": "\n", "r": "\r", "t": "\t", "0": "\0"}
    while i < len(inner):
        char = inner[i]
        if char != "\\" or i + 1 == len(inner):
            out.append(char)
            i += 1
            continue
        code = inner[i + 1]
        if code in simple:
            out.append(simple[code])
            i += 2
        elif code in "ux":
            width = 4 if code == "u" else 2
            digits = inner[i + 2:i + 2 + width]
            try:
                out.append(chr(int(digits, 16)) if len(digits) == width else digits)
            except ValueError:
                out.append(digits)
            i += 2 + width
        else:
            out.append(code)
            i += 2
    return "".join(out)


def project_key(path):
    """The short, stable key of a project folder: the same as MemorySource.key in the app."""
    return hashlib.sha256(os.path.realpath(str(path)).encode("utf-8")).hexdigest()[:16]


def parse_mark(text):
    """The app's marker as a dict, or None when it is not exactly in the app's form."""
    if not (text.startswith(MARK_PREFIX + " ") and text.endswith("%%")) or len(text) <= len(MARK_PREFIX) + 3:
        return None
    mark, seen = {"user": False, "agent": None, "reach": "", "from": None, "ok": False}, set()
    for token in text[len(MARK_PREFIX) + 1:-2].split(" "):
        key, _, value = token.partition("=")
        if not token or key in seen:
            return None
        seen.add(key)
        if token in ("user", "ok"):
            mark[token] = True
        elif key == "agent" and UUID_TEXT.match(value):
            mark["agent"] = value.upper()
        elif key == "reach" and (value == "-" or (value and len(set(value)) == len(value) and set(value) <= set("fcx"))):
            mark["reach"] = "" if value == "-" else value
        elif key == "from" and HEX16.match(value):
            mark["from"] = value.lower()
        else:
            return None
    if mark["user"] == (mark["agent"] is not None) or (mark["agent"] and "reach" not in seen):
        return None
    return mark


def parse_entry(body):
    """(text, author, mark, broken) of one list line's text, the same way the app reads it."""
    mark, broken = None, False
    if body.endswith("%%") and MARK in body:
        start = body.rindex(MARK)
        mark = parse_mark(body[start:])
        broken = mark is None
        body = body[:start].strip()
    if not body or body.startswith("[["):
        return None
    parts = body.split(" · ")
    if len(parts) >= 3 and DAY.match(parts[-1]):
        author = parts[-2].strip()
        return (" · ".join(parts[:-2]), author or None, mark, broken or not author)
    return (body, None, mark, broken)


def split(text):
    """(properties, body lines) of a note; the body starts after the closing "---"."""
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, lines
    props = {}
    for index, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            return props, lines[index + 1:]
        key, colon, value = line.partition(":")
        if colon and key.strip() and not line.startswith((" ", "\t", "-")):
            props[key.strip().lower()] = unquoted(value)
    return {}, lines


def properties(text):
    return split(text)[0]


def entries(text):
    """The entries of a note, below the properties only, as dicts: text, author, mark (the app's marker or None)
    and broken (a marker or byline the app did not write in its form)."""
    found = []
    for line in split(text)[1]:
        match = ENTRY.match(line)
        parsed = parse_entry(match.group(1).strip()) if match else None
        if parsed and parsed[0]:
            found.append({"text": parsed[0], "author": parsed[1], "mark": parsed[2], "broken": parsed[3]})
    return found


def by_user(entry):
    """The user's own: typed in the app, or written by hand without a byline or marker."""
    mark = entry.get("mark")
    return bool(mark and mark["user"]) or (mark is None and not entry.get("broken") and entry.get("author") is None)


def may_get(entry, reach, project, profile):
    """Whether an agent whose session can do `reach` (letters f, c, x) in `project` may get this entry.

    The user's own entries and the ones the user confirmed reach everyone. An agent's entry reaches an agent only
    if its author could do at least as much (so a restricted agent cannot steer a privileged one), and, for facts
    about the user, only agents of the author's own project. Entries of unknown origin are treated like the most
    restricted agent's of no project.
    """
    if by_user(entry):
        return True
    mark = entry.get("mark") or {}
    if mark.get("ok"):
        return True
    if not set(reach) <= set(mark.get("reach", "")):
        return False
    return not profile or mark.get("from") == project_key(project)


def read_note(path):
    """The text of a note, or None. Only a plain file is read, never through a link and never more than MAX_NOTE."""
    try:
        handle = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_NOTE:
            return None
        data = os.read(handle, MAX_NOTE + 1)
    except OSError:
        return None
    finally:
        os.close(handle)
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def notes(root):
    """(profile entries, {project path: entries}) of all notes in the folder."""
    profile, projects = [], {}
    root = Path(root)
    if not root.is_dir():
        return profile, projects
    for note in sorted(root.glob("*.md")):
        text = read_note(note)
        if text is None:
            continue
        props = properties(text)
        if props.get("mochi") == "profile":
            profile += entries(text)
        elif props.get("mochi") == "project" and props.get("project"):
            projects.setdefault(props["project"], []).extend(entries(text))
    return profile, projects


def plain(text, author):
    return text


def clip(items, render=plain):
    """The newest entries that fit: at most MAX_LINES, MAX_CHARS in all as the briefing shows them (rendered,
    with "- " and the line break), each fact at most MAX_ENTRY characters. Chosen from the newest backwards, shown
    oldest first. Lines that look like secrets are left out. Returns the rendered lines."""
    kept, size = [], 0
    for entry in reversed(items):
        text, author = entry["text"], entry.get("author")
        if looks_secret(text):
            continue
        if len(text) > MAX_ENTRY:
            text = text[:MAX_ENTRY - 1].rstrip() + "…"
        line = render(text, author)
        if len(kept) >= MAX_LINES or size + len(line) + 3 > MAX_CHARS:
            break
        kept.append(line)
        size += len(line) + 3
    return list(reversed(kept))


def for_project(project, settings=None, home=None, reach="", render=plain):
    """What an agent in `project` whose session can do `reach` should know: (folder, lines about the user, lines
    about the project), each list within the briefing's budget."""
    root = folder(settings, home)
    profile, projects = notes(root)
    try:
        key = str(Path(project).resolve())
    except OSError:
        key = str(project)
    own = projects.get(str(project)) or projects.get(key) or []
    profile = [entry for entry in profile if may_get(entry, reach, project, True)]
    own = [entry for entry in own if may_get(entry, reach, project, False)]
    return root, clip(profile, render), clip(own, render)
