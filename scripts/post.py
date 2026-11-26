#!/usr/bin/python3
"""Agent post: messages between the agents of a project.

  post list                      shows the agents that can be reached
  post send <name> <message>     delivers the message; the answer arrives as a new message in the own chat

Letters land as out-*.json in the session's outbox (MOCHI_OUTBOX). The app collects them and writes the receipt
next to them as out-*.result. The wording of receipts comes from the app, in the user's interface language.
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

MAX_TEXT = 12000
WAIT_SECONDS = 20


def parse(args):
    """Letter from the arguments, or None for wrong usage. The German verbs of earlier versions still work."""
    if args in (["list"], ["liste"]):
        return {"to": "?", "text": ""}
    if len(args) >= 3 and args[0] in ("send", "sende") and " ".join(args[2:]).strip():
        return {"to": args[1], "text": " ".join(args[2:])}
    return None


def send(box, letter, wait=WAIT_SECONDS):
    name = "out-" + uuid.uuid4().hex
    draft = box / (name + ".tmp")
    draft.write_text(json.dumps(letter, ensure_ascii=False), encoding="utf-8")
    os.replace(draft, box / (name + ".json"))
    receipt = box / (name + ".result")
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if receipt.is_file():
            answer = receipt.read_text(encoding="utf-8")
            receipt.unlink()
            return answer
        time.sleep(0.25)
    try:
        (box / (name + ".json")).unlink()
        return "Not delivered: Mochi Squad did not collect the message. Try again later."
    except FileNotFoundError:
        return "Mochi Squad collected the message but has not confirmed it yet. Do not send it twice; check the chat later."


def outbox():
    """This session's outbox. The app creates it; only this session's sandbox may write into it."""
    root = (Path.home() / "Library" / "Caches" / "dev.mochisquad.app" / "outbox").resolve()
    box = Path(os.environ.get("MOCHI_OUTBOX", "")).resolve()
    return box if box.parent == root and box.is_dir() else None


def main(argv):
    letter = parse(argv)
    if letter is None:
        raise SystemExit(__doc__)
    if len(letter["text"]) > MAX_TEXT:
        raise SystemExit("Not sent: the message is longer than 12,000 characters. Save the content as a file and send its path.")
    box = outbox()
    if box is None:
        raise SystemExit("Not sent: this session has no outbox.")
    print(send(box, letter))


if __name__ == "__main__":
    main(sys.argv[1:])
