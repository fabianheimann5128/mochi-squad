"""Switches on Claude Code's own desktop control ("computer-use") for a project.

  computer.py <project>      prints one JSON line: {"state": "enabled" | "already" | "unavailable" | "failed"}

Claude Code offers no flag or setting for this: the built-in server is enabled per project in the client's
`/mcp` dialog, and the choice is remembered there. This helper does exactly what a user would do, once, in a
short session of its own that sends no message to the model: open `/mcp`, go to computer-use, choose Enable.
"""
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

import common

SERVER = "computer-use"
ESCAPES = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]")


def plain(raw):
    """Terminal output without control sequences and without blanks, one entry per line.

    The client positions text with cursor moves instead of spaces, so blanks carry no meaning here.
    """
    text = ESCAPES.sub("", raw.decode("utf-8", "replace")).replace("\r", "\n")
    return ["".join(line.split()) for line in text.split("\n") if line.strip()]


def marked(lines):
    """Is the selection mark on the computer-use entry in the lines drawn last?"""
    pointed = [line for line in lines if line.startswith("❯")]
    return bool(pointed) and SERVER in pointed[-1]


def view_state(lines):
    """What the entry's detail view offers: "enable", "enabled" or None if it is not that view."""
    text = "\n".join(lines)
    if "Status" not in text:
        return None
    if "disabled" in text and "Enable" in text:
        return "enable"
    return "enabled" if "enabled" in text or "connected" in text or "Disable" in text else None


class Terminal:
    def __init__(self, argv, cwd, env):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 120, 0, 0))

    def read(self, seconds):
        """Everything the client draws within the given time, as plain lines."""
        data, end = b"", time.monotonic() + seconds
        while time.monotonic() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.2)
            if ready:
                try:
                    data += os.read(self.fd, 65536)
                except OSError:
                    break
        return plain(data)

    def press(self, keys, wait):
        os.write(self.fd, keys)
        return self.read(wait)

    def close(self):
        for _ in range(3):
            try:
                self.press(b"\x1b", 0.3)
            except OSError:
                break
        # Close our end of the terminal first: a process that still has output queued for it cannot finish
        # exiting otherwise. Then ask the client to quit, wait briefly, and end it for good if it is still there.
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.kill(self.pid, signal.SIGTERM)
            for _ in range(30):
                if os.waitpid(self.pid, os.WNOHANG)[0]:
                    return
                time.sleep(0.1)
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except (OSError, ChildProcessError):
            pass


def enable(binary, project):
    env = common.client_path_env(common.clean_child_env())
    env["TERM"] = "xterm-256color"
    terminal = Terminal([binary, "--model", "haiku"], project, env)
    try:
        start = terminal.read(7)
        # A folder the user has not trusted yet shows a question first; that decision is theirs, in the chat.
        if any("trust" in line.lower() for line in start) and any("Entertoconfirm" in line for line in start):
            return "failed"
        terminal.press(b"/mcp", 1.2)
        listing = terminal.press(b"\r", 4)
        if not any(SERVER in line for line in listing):
            return "unavailable"
        # The entry is the last one; one step up from the top wraps around to it. Otherwise walk down to it.
        found = marked(terminal.press(b"\x1b[A", 0.8))
        for _ in range(60):
            if found:
                break
            found = marked(terminal.press(b"\x1b[B", 0.4))
        if not found:
            return "failed"
        state = view_state(terminal.press(b"\r", 2.5))
        if state == "enabled":
            return "already"
        if state != "enable":
            return "failed"
        terminal.press(b"\r", 4)
        return "enabled"
    finally:
        terminal.close()


def marker():
    return common.DATA / "computer-use.json"


def ensure(binary, project):
    """Enables desktop control for the project unless that was done before. Returns the state."""
    done = common.read_json(marker(), [])
    done = done if isinstance(done, list) else []
    if project in done:
        return "already"
    state = enable(binary, project)
    if state in ("enabled", "already"):
        common.write_private(marker(), json.dumps(sorted(set(done + [project]))))
    return state


if __name__ == "__main__":
    client = common.find_client("claude")
    print(json.dumps({"state": enable(client, os.path.realpath(sys.argv[1])) if client and len(sys.argv) == 2 else "unavailable"}))
