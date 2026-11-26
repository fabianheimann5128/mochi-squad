"""Telegram link for Mochi Squad: a bot the user created themselves, read by long polling.

No server and no public address are needed: this process asks Telegram for new messages (getUpdates) and the app
tells it what to send. Only private chats count, and after pairing only the one account the user confirmed.

Protocol with the app (one JSON object per line):
  app → stdin, first line: the bot token (never written anywhere, never printed)
  stdout: {"ready": true, "bot": "<user name>", "name": "<display name>"}
  stdout: {"start": {"code": "...", "user": <id>, "name": "...", "username": "..."}}   someone pressed Start with a pairing code
  stdout: {"message": {"user": <id>, "text": "..."}}       a text from the allowed account
  stdout: {"unsupported": {"user": <id>}}                  the allowed account sent something that is not text
  stdout: {"error": "token" | "network" | "conflict"}
  app → stdin: {"allow": <id or null>}   {"send": "<text>", "to": <id>}
When stdin closes (the app quit), the process ends.
"""
import json
import re
import sys
import threading
import time
import urllib.error
import urllib.request

API = "https://api.telegram.org/bot{token}/{method}"
CHUNK = 4000
POLL_SECONDS = 50
PAIRING = re.compile(r"/start\s+([A-Za-z0-9_-]{16,64})")


def emit(event, out=sys.stdout):
    out.write(json.dumps(event, ensure_ascii=False) + "\n")
    out.flush()


def call(token, method, params=None, timeout=20, opener=urllib.request.urlopen):
    """Calls the Bot API and returns the result, or raises OSError/ValueError. The token only ever goes to Telegram."""
    request = urllib.request.Request(API.format(token=token, method=method), data=json.dumps(params or {}).encode(),
                                     headers={"Content-Type": "application/json"})
    try:
        with opener(request, timeout=timeout) as response:
            body = json.loads(response.read())
    except urllib.error.HTTPError as error:
        # 401: wrong token. 409: another program is polling the same bot.
        raise ValueError({401: "token", 404: "token", 409: "conflict"}.get(error.code, "network")) from None
    if not isinstance(body, dict) or body.get("ok") is not True:
        raise ValueError("network")
    return body.get("result")


def chunks(text, size=CHUNK):
    """Splits a long text at line breaks where possible; Telegram takes at most 4096 characters per message."""
    parts = []
    while len(text) > size:
        cut = text.rfind("\n", size // 2, size)
        cut = cut if cut > 0 else size
        parts.append(text[:cut])
        text = text[cut:].lstrip("\n")
    return parts + ([text] if text else [])


def classify(update, allowed):
    """What an update means for the app: ("start", …), ("message", …), ("unsupported", …) or None to ignore it."""
    message = update.get("message") if isinstance(update, dict) else None
    if not isinstance(message, dict):
        return None
    sender, chat = message.get("from") or {}, message.get("chat") or {}
    user = sender.get("id")
    # Private chats only: in a group, anyone could talk to the bot.
    if not isinstance(user, int) or chat.get("type") != "private" or chat.get("id") != user or sender.get("is_bot"):
        return None
    text = message.get("text") if isinstance(message.get("text"), str) else ""
    pairing = PAIRING.fullmatch(text.strip())
    if pairing:
        name = " ".join(str(x) for x in (sender.get("first_name"), sender.get("last_name")) if x)[:200]
        return "start", {"code": pairing[1], "user": user, "name": name, "username": str(sender.get("username") or "")[:64]}
    if allowed is None or user != allowed:
        return None
    if text.strip() and not text.startswith("/start"):
        return "message", {"user": user, "text": text[:16000]}
    return ("unsupported", {"user": user}) if not text else None


class Link:
    def __init__(self, token, out=sys.stdout):
        self.token, self.out = token, out
        self.allowed = None
        self.lock = threading.Lock()

    def command(self, line):
        """One line from the app."""
        try:
            command = json.loads(line)
        except ValueError:
            return
        if not isinstance(command, dict):
            return
        if "allow" in command:
            with self.lock:
                self.allowed = command["allow"] if isinstance(command["allow"], int) else None
        elif isinstance(command.get("send"), str) and isinstance(command.get("to"), int):
            with self.lock:
                allowed = self.allowed
            # Answers go to the paired account only, whatever the caller asks for.
            if command["to"] != allowed:
                return
            for part in chunks(command["send"]):
                try:
                    call(self.token, "sendMessage", {"chat_id": allowed, "text": part, "disable_web_page_preview": True})
                except (OSError, ValueError):
                    emit({"error": "network"}, self.out)
                    break

    def poll(self):
        offset, pause = None, 1
        while True:
            try:
                updates = call(self.token, "getUpdates", {"timeout": POLL_SECONDS, "offset": offset, "allowed_updates": ["message"]},
                               timeout=POLL_SECONDS + 15)
                pause = 1
            except ValueError as error:
                emit({"error": str(error)}, self.out)
                if str(error) == "token":
                    return
                time.sleep(min(pause, 60))
                pause *= 2
                continue
            except OSError:
                time.sleep(min(pause, 60))
                pause *= 2
                continue
            for update in updates if isinstance(updates, list) else []:
                if isinstance(update, dict) and isinstance(update.get("update_id"), int):
                    offset = update["update_id"] + 1
                with self.lock:
                    allowed = self.allowed
                event = classify(update, allowed)
                if event:
                    emit({event[0]: event[1]}, self.out)


def main():
    token = sys.stdin.readline().strip()
    if not re.fullmatch(r"\d{5,15}:[A-Za-z0-9_-]{30,60}", token):
        emit({"error": "token"})
        return
    try:
        me = call(token, "getMe")
        # A webhook left over from another tool would keep getUpdates from working.
        call(token, "deleteWebhook", {"drop_pending_updates": False})
    except ValueError as error:
        emit({"error": str(error)})
        return
    except OSError:
        emit({"error": "network"})
        return
    emit({"ready": True, "bot": str(me.get("username") or ""), "name": str(me.get("first_name") or "")})
    link = Link(token)
    threading.Thread(target=link.poll, daemon=True).start()
    for line in sys.stdin:
        link.command(line)


if __name__ == "__main__":
    main()
