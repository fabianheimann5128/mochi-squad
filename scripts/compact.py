#!/usr/bin/python3
"""Summarises a long agent conversation, so the agent can go on in a fresh, small session.

  compact.py <format> <client> <history file> [account] [model]
      format: claude|codex, the program that wrote the history; client: claude|codex, the one that summarises
      prints {"summary": "..."} or {"error": "..."}

The summary comes from a one-off run of the agent's client with the user's subscription, in an empty temporary
folder: Claude without any tools, hooks or tool servers and without saving a session; Codex with its shell, browser,
plugins, hooks, sub-agents and the user's tool servers switched off, in a read-only sandbox, without saving a session.
Before a Codex summary, the tools that Codex would offer are checked against a stand-in on this Mac; if it offers any
that act, there is no summary.
"""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import threading
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
    """The conversation as text: the newest messages that fit into `limit` characters, in their order. If the
    next older message does not fit whole, its end fills the space that is left, marked as cut. While reading, only
    as many messages are kept as can still matter, so a long history needs little memory."""
    kept, size = deque(), 0
    with open(path, "rb") as f:
        for message in history.messages(f, provider, {}, True):
            line = ("User: " if message["role"] == "user" else "Agent: ") + message["text"].strip()
            kept.append(line)
            size += len(line) + 2
            # The oldest message goes once the newer ones fill the limit without it.
            while len(kept) > 1 and size - len(kept[0]) - 2 >= limit:
                size -= len(kept.popleft()) + 2
    picked, size = [], 0
    for line in reversed(kept):
        if size + len(line) + 2 <= limit:
            picked.append(line)
            size += len(line) + 2
            continue
        room = limit - size - 2
        role, _, text = line.partition(": ")
        cut = role + " (end of a longer message): …"
        if room > len(cut) + 200:
            picked.append(cut + text[-(room - len(cut)):])
        break
    return "\n\n".join(reversed(picked))


def revision(path):
    """A fingerprint of the history's content, so the app can tell whether it is still what was summarised."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# Codex features that act beyond writing text; off for the summary.
CODEX_OFF = ("shell_tool", "unified_exec", "apps", "plugins", "hooks", "browser_use", "browser_use_external", "in_app_browser",
             "computer_use", "tool_suggest", "skill_search", "sleep_tool", "remote_plugin", "goals", "multi_agent",
             "multi_agent_v2", "image_generation", "view_image", "memories", "code_mode")
# The only tool Codex may still offer: in `codex exec` it refuses to ask anything ("not supported in exec mode").
CODEX_ALLOWED_TOOLS = {"request_user_input"}
PROBE_TIMEOUT = 60


def claude_command(binary, prompt):
    return [binary, "-p", "--model", CLAUDE_MODEL, "--tools", "", "--no-session-persistence", "--strict-mcp-config",
            "--setting-sources", "user", "--settings", json.dumps({"disableAllHooks": True}), "--output-format", "text", prompt]


def codex_command(binary, prompt, folder, out, model="", servers=(), probe=None):
    """The summary run. With `probe` (a local address) the run goes to that address instead of the model service,
    with exactly the same options otherwise, to see which tools Codex would offer."""
    args = [binary, "exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "-o", str(out),
            "-c", 'model_reasoning_effort="low"', "-c", 'web_search="disabled"', "-c", "notify=[]"]
    for feature in CODEX_OFF:
        args += ["--disable", feature]
    if probe:
        args += ["-c", 'model_provider="mochi_probe"',
                 "-c", "model_providers.mochi_probe={name=\"Mochi Squad check\", base_url=\"%s\", wire_api=\"responses\", "
                       "requires_openai_auth=false, request_max_retries=0, stream_max_retries=0}" % probe]
    if model:
        args += ["-m", model]
    # The user's tool servers stay off, exactly as for sandboxed agents.
    for name, is_command, *rest in servers:
        if is_command:
            args += ["-c", f'mcp_servers.{name}.command="/usr/bin/false"']
        args += ["-c", f"mcp_servers.{name}.enabled=false"]
    return args + [prompt]


def offered_tools(command, folder, env):
    """The tools a Codex run built by `command(probe_address)` would offer the model, as names, or None when that
    could not be seen. A stand-in for the model service on this Mac records the first request and refuses it, so
    nothing leaves the Mac and no answer is generated."""
    seen = []

    class Recorder(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            try:
                body = json.loads(self.rfile.read(min(int(self.headers.get("content-length") or 0), 8 << 20)) or b"{}")
                tools = body.get("tools") if isinstance(body, dict) else None
                if isinstance(tools, list):
                    seen.append(sorted(str((tool or {}).get("name") or (tool or {}).get("type") or "?") for tool in tools))
            except (ValueError, OSError):
                pass
            self.send_response(400)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"Mochi Squad check"}}')

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        address = "http://127.0.0.1:%d/v1" % server.server_address[1]
        subprocess.run(command(address), cwd=folder, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                       timeout=PROBE_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        server.shutdown()
        server.server_close()
    return seen[0] if seen else None


def summarise(source, provider, path, account="", model=""):
    if provider not in ("claude", "codex") or source not in ("claude", "codex"):
        return {"error": t("Unknown client.", "Unbekannter Client.")}
    journal = Path(path)
    if not journal.is_file():
        return {"error": t("The conversation was not found.", "Der Verlauf wurde nicht gefunden.")}
    # The history is read in the format of the program that wrote it, whatever the agent uses now. The content
    # must stay the same while it is read; its fingerprint goes back to the app, which compares it before switching.
    try:
        before = revision(journal)
        text = conversation(journal, source)
        if revision(journal) != before:
            return {"error": t("The chat changed while it was being read. Tidy up again when it is quiet.",
                               "Der Chat hat sich beim Lesen geändert. Räum noch einmal auf, wenn Ruhe ist.")}
    except OSError:
        return {"error": t("The conversation could not be read.", "Der Verlauf konnte nicht gelesen werden.")}
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
            # Codex adds tools from version to version: the run goes ahead only if this one offers none that act.
            tools = offered_tools(lambda probe: codex_command(binary, "Reply with OK.", folder, folder / "check.txt", model,
                                                              servers, probe), folder, env)
            if tools is None or set(tools) - CODEX_ALLOWED_TOOLS:
                return {"error": t("This Codex version would give the summary tools to act with, so Mochi Squad does not use it for "
                                   "tidying up. Update Codex, or give the agent Claude Code for this.",
                                   "Diese Codex-Version gäbe dem Zusammenfassen Werkzeuge zum Handeln, daher nutzt Mochi Squad sie "
                                   "dafür nicht. Aktualisiere Codex oder nutze für diesen Agenten Claude Code.")
                        + (" (" + ", ".join(sorted(set(tools) - CODEX_ALLOWED_TOOLS)) + ")" if tools else "")}
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
    return {"summary": summary[:6000], "revision": before}


if __name__ == "__main__":
    args = sys.argv[1:] + ["", ""]
    json.dump(summarise(args[0], args[1], args[2], args[3], args[4]) if len(sys.argv) >= 4 else {"error": "usage"}, sys.stdout,
              ensure_ascii=False)
