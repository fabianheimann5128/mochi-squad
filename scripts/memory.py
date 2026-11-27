"""Mochi Memory: what the agents remember, as plain Markdown notes that Obsidian can open.

The folder holds one note about the user ("mochi: profile" in its properties) and one note per project
("mochi: project" and "project: <path>"). Every list line ("- ", "* " or "+ ") below the properties is an entry; the app
adds them as "- <text> · <agent> · <date>", the user may write them any way. The app writes; agents read what the
launcher puts into their briefing and ask the app to remember more through their post tool.
"""
import os
import re
import stat
from pathlib import Path

import common

DEFAULT_FOLDER = "Mochi Memory"
ENTRY = re.compile(r"^\s*[-*+]\s+(?!\[\[)(.+?)\s*$")
ATTRIBUTION = re.compile(r"^(.*?)\s+·\s+([^·]{1,60}?)\s+·\s+(\d{4}-\d{2}-\d{2})$")
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
    """A property value: one pair of outer quotes removed, escapes inside double quotes undone."""
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        inner = value[1:-1]
        if value[0] == "'":
            return inner.replace("''", "'")
        return re.sub(r"\\(.)", r"\1", inner)
    return value


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
    """The entries of a note as (text, author or None), below the properties only."""
    found = []
    for line in split(text)[1]:
        match = ENTRY.match(line)
        if not match:
            continue
        body = match.group(1).strip()
        attributed = ATTRIBUTION.match(body)
        if attributed:
            found.append((attributed.group(1).strip(), attributed.group(2).strip()))
        elif body:
            found.append((body, None))
    return [entry for entry in found if entry[0]]


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


def clip(items):
    """The newest entries that fit: at most MAX_LINES, MAX_CHARS in all, each at most MAX_ENTRY characters.
    Chosen from the newest backwards, shown oldest first. Lines that look like secrets are left out."""
    kept, size = [], 0
    for text, author in reversed(items):
        if looks_secret(text):
            continue
        if len(text) > MAX_ENTRY:
            text = text[:MAX_ENTRY - 1].rstrip() + "…"
        if len(kept) >= MAX_LINES or size + len(text) > MAX_CHARS:
            break
        kept.append((text, author))
        size += len(text) + 3
    return list(reversed(kept))


def for_project(project, settings=None, home=None, trusted=None):
    """What an agent in `project` should know: (folder, entries about the user, entries about the project).

    `trusted` decides per author whether the recipient may get that author's entries (None: all may). Lines without
    an author are the user's own and always count.
    """
    root = folder(settings, home)
    profile, projects = notes(root)
    try:
        key = str(Path(project).resolve())
    except OSError:
        key = str(project)
    own = projects.get(str(project)) or projects.get(key) or []
    if trusted is not None:
        profile = [entry for entry in profile if entry[1] is None or trusted(entry[1])]
        own = [entry for entry in own if entry[1] is None or trusted(entry[1])]
    return root, clip(profile), clip(own)
