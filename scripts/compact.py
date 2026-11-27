#!/usr/bin/python3
"""Summarises a long agent conversation, so the agent can go on in a fresh, small session.

  compact.py <format> <client> <history file> [account] [model]
      format: claude|codex, the program that wrote the history; client: claude|codex, the one that summarises
      prints {"summary": "..."} or {"error": "..."}

The summary comes from a one-off run of the agent's client with the user's subscription, in an empty temporary
folder: Claude without any tools, hooks or tool servers and without saving a session; Codex with its shell, browser,
plugins, hooks and the user's tool servers switched off, in a read-only sandbox, without saving a session.
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import common
import history
import launcher
from common import t

TIMEOUT = 240
MAX_CHARS = 60_000
CLAUDE_MODEL = "claude-haiku-5-5"

PROMPT = ("Below is a conversation between {owner} and an AI agent working for {owner}. The agent will continue in a fresh "
          "session that only gets your summary. Write a handover summary in the language the conversation is mostly "
          "written in, with these short parts: the goal; what was done so far, naming files and results; decisions "
          "and preferences of {owner}; open points and the very next step. At most 250 words, plain text with short "
          "headings and bullet points, no introduction and no closing remark. Do not invent anything.\n\n"
          "<conversation>\n{conversation}\n</conversation>")


def conversation(path, provider, limit=MAX_CHARS):
    """The conversation as text: the newest messages that fit into `limit` characters, in their order."""
    messages = history.read(path, provider, 0, 100_000)["messages"]
    picked, size = [], 0
    for m in reversed(messages):
        if not m.get("text"):
            continue
        line = ("User: " if m["role"] == "user" else "Agent: ") + m["text"].strip()
        if size + len(line) + 2 > limit:
            if not picked:
                picked.append(line[-limit:])
            break
        picked.append(line)
        size += len(line) + 2
    return "\n\n".join(reversed(picked))


# Codex features that act beyond writing text; off for the summary.
CODEX_OFF = ("shell_tool", "unified_exec", "apps", "plugins", "hooks", "browser_use", "browser_use_external", "in_app_browser",
             "computer_use", "tool_suggest", "skill_search", "sleep_tool", "remote_plugin")


def claude_command(binary, prompt):
    return [binary, "-p", "--model", CLAUDE_MODEL, "--tools", "", "--no-session-persistence", "--strict-mcp-config",
            "--setting-sources", "user", "--settings", json.dumps({"disableAllHooks": True}), "--output-format", "text", prompt]


def codex_command(binary, prompt, folder, out, model="", servers=()):
    args = [binary, "exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "-o", str(out),
            "-c", 'model_reasoning_effort="low"', "-c", 'web_search="disabled"', "-c", "notify=[]"]
    for feature in CODEX_OFF:
        args += ["--disable", feature]
    if model:
        args += ["-m", model]
    # The user's tool servers stay off, exactly as for sandboxed agents.
    for name, is_command, *rest in servers:
        if is_command:
            args += ["-c", f'mcp_servers.{name}.command="/usr/bin/false"']
        args += ["-c", f"mcp_servers.{name}.enabled=false"]
    return args + [prompt]


def summarise(source, provider, path, account="", model=""):
    if provider not in ("claude", "codex") or source not in ("claude", "codex"):
        return {"error": t("Unknown client.", "Unbekannter Client.")}
    journal = Path(path)
    if not journal.is_file():
        return {"error": t("The conversation was not found.", "Der Verlauf wurde nicht gefunden.")}
    # The history is read in the format of the program that wrote it, whatever the agent uses now.
    text = conversation(journal, source)
    if len(text) < 200:
        return {"error": t("The conversation is still short; there is nothing to tidy up.",
                           "Der Verlauf ist noch kurz; es gibt nichts aufzuräumen.")}
    binary = common.find_client(provider)
    if not binary:
        return {"error": t("The client is not installed on this Mac.", "Der Client ist auf diesem Mac nicht installiert.")}
    settings = common.read_json(common.DATA / "settings.json", {}) or {}
    prompt = PROMPT.format(owner=str(settings.get("ownerName") or "the user"), conversation=text)
    env = common.client_path_env(common.clean_child_env())
    folder = Path(tempfile.mkdtemp(prefix="mochi-compact-"))
    try:
        if provider == "codex":
            common.use_account(account, env)
            common.use_account(account)
            servers = launcher.codex_servers(binary, str(folder))
            if servers is None:
                # Without the list the user's tool servers cannot be switched off: no summary then.
                return {"error": launcher.unknown_servers()}
            out = folder / "summary.txt"
            result = subprocess.run(codex_command(binary, prompt, folder, out, model, servers), cwd=folder, env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TIMEOUT)
            summary = out.read_text(encoding="utf-8") if out.is_file() else ""
        else:
            result = subprocess.run(claude_command(binary, prompt), cwd=folder, env=env, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=TIMEOUT)
            summary = result.stdout
    except subprocess.TimeoutExpired:
        return {"error": t("Summarising took too long. Try again later.", "Das Zusammenfassen hat zu lange gedauert. Versuch es später noch einmal.")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    summary = summary.strip()
    if result.returncode != 0 or not summary:
        return {"error": t("The client could not write a summary.", "Der Client konnte keine Zusammenfassung schreiben.")
                         + (" " + (result.stderr or result.stdout).strip()[-300:] if (result.stderr or result.stdout) else "")}
    return {"summary": summary[:6000]}


if __name__ == "__main__":
    args = sys.argv[1:] + ["", ""]
    json.dump(summarise(args[0], args[1], args[2], args[3], args[4]) if len(sys.argv) >= 4 else {"error": "usage"}, sys.stdout,
              ensure_ascii=False)
