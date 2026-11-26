#!/usr/bin/python3
"""Agenten-Post: Nachrichten zwischen den Agenten eines Projekts.

  post liste                      zeigt die erreichbaren Agenten
  post sende <Name> <Nachricht>   stellt die Nachricht zu; die Antwort kommt als neue Nachricht in den eigenen Chat

Briefe landen als out-*.json im Postausgang der Sitzung (MOCHI_OUTBOX). Die App holt sie ab und schreibt die
Rückmeldung als out-*.result daneben.
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
    """Brief aus den Argumenten oder None bei falscher Benutzung."""
    if args == ["liste"]:
        return {"to": "?", "text": ""}
    if len(args) >= 3 and args[0] == "sende" and " ".join(args[2:]).strip():
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
        return "Nicht zugestellt: Mochi Squad hat die Nachricht nicht abgeholt. Versuche es später erneut."
    except FileNotFoundError:
        return "Mochi Squad hat die Nachricht abgeholt, aber noch nicht bestätigt. Sende sie nicht doppelt; prüfe später den Chat."


def outbox():
    """Der Postausgang dieser Sitzung. Die App legt ihn an; nur die Sandbox dieser Sitzung darf hineinschreiben."""
    root = (Path.home() / "Library" / "Caches" / "dev.mochisquad.app" / "outbox").resolve()
    box = Path(os.environ.get("MOCHI_OUTBOX", "")).resolve()
    return box if box.parent == root and box.is_dir() else None


def main(argv):
    letter = parse(argv)
    if letter is None:
        raise SystemExit(__doc__)
    if len(letter["text"]) > MAX_TEXT:
        raise SystemExit("Nicht gesendet: Die Nachricht ist länger als 12 000 Zeichen. Lege den Inhalt als Datei ab und sende den Pfad.")
    box = outbox()
    if box is None:
        raise SystemExit("Nicht gesendet: Diese Sitzung hat keinen Postausgang.")
    print(send(box, letter))


if __name__ == "__main__":
    main(sys.argv[1:])
