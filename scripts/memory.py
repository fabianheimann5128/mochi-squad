"""Mochi Memory: what the agents remember, as plain Markdown notes that Obsidian can open.

The folder holds one note about the user ("mochi: profile" in its properties) and one note per project
("mochi: project" and "project: <path>"). Every line that starts with "- " is an entry; the app adds them as
"- <text> · <agent> · <date>", the user may write them any way. The app writes; agents read what the launcher
puts into their briefing and ask the app to remember more through their post tool.
"""
import re
from pathlib import Path

import common

DEFAULT_FOLDER = "Mochi Memory"
ENTRY = re.compile(r"^\s*[-*]\s+(?!\[\[)(.+?)\s*$")
MAX_LINES = 60
MAX_CHARS = 6000


def folder(settings=None, home=None):
    """The memory folder: the one chosen in Settings, otherwise ~/Mochi Memory."""
    settings = settings if isinstance(settings, dict) else common.read_json(common.DATA / "settings.json", {}) or {}
    chosen = settings.get("memoryFolder")
    if isinstance(chosen, str) and chosen.startswith("/"):
        return Path(chosen)
    return Path(home or common.HOME) / DEFAULT_FOLDER


def properties(text):
    """The properties block at the top of a note ("---" … "---") as a dict of strings."""
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        return {}
    result = {}
    for line in lines[1:]:
        if line.strip() == "---":
            return result
        key, colon, value = line.partition(":")
        if colon and key.strip():
            result[key.strip().lower()] = value.strip().strip('"\'')
    return {}


def entries(text):
    """The entries of a note, without the attribution the app appends."""
    found = []
    for line in text.replace("\r\n", "\n").split("\n"):
        match = ENTRY.match(line)
        if match:
            found.append(re.sub(r"\s+·\s+[^·]{1,60}\s+·\s+\d{4}-\d{2}-\d{2}$", "", match.group(1)).strip())
    return [entry for entry in found if entry]


def notes(root):
    """(profile entries, {project path: entries}) of all notes in the folder."""
    profile, projects = [], {}
    root = Path(root)
    if not root.is_dir():
        return profile, projects
    for note in sorted(root.glob("*.md")):
        try:
            if note.stat().st_size > 512 * 1024:
                continue
            text = note.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        props = properties(text)
        if props.get("mochi") == "profile":
            profile += entries(text)
        elif props.get("mochi") == "project" and props.get("project"):
            projects.setdefault(props["project"], []).extend(entries(text))
    return profile, projects


def clip(lines):
    """At most MAX_LINES entries and MAX_CHARS characters: the briefing stays small."""
    kept, size = [], 0
    for line in lines[-MAX_LINES:]:
        if size + len(line) > MAX_CHARS:
            break
        kept.append(line)
        size += len(line) + 3
    return kept


def for_project(project, settings=None, home=None):
    """What an agent in `project` should know: (folder, entries about the user, entries about the project)."""
    root = folder(settings, home)
    profile, projects = notes(root)
    try:
        key = str(Path(project).resolve())
    except OSError:
        key = str(project)
    own = projects.get(str(project)) or projects.get(key) or []
    return root, clip(profile), clip(own)
