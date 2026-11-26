# Mitwirken

Schön, dass du Mochi Squad besser machen willst.

## Vor dem Start

Öffne für größere Änderungen zuerst ein Issue, damit wir die Richtung abstimmen können. Kleine Korrekturen gern direkt als Pull Request.

## Entwickeln

```bash
swift build          # bauen
./tools/test.sh      # alle Tests (Swift und Python)
./install.sh         # nach ~/Applications installieren
```

Voraussetzung sind macOS 14 und die Xcode-Befehlszeilenwerkzeuge; Xcode selbst wird nicht benötigt.

## Leitlinien

- **Klein und lesbar.** Lieber eine klare Funktion als eine clevere. Kommentare erklären das Warum.
- **Sicherheit zuerst.** Die Rechte eines Agenten entstehen in `scripts/launcher.py` (Regeln und Sandbox), `Sessions/AgentSession.swift` (Sitzungsordner, Postausgang) und `Sessions/SessionManager.swift` (Werkzeuge, Limits). Änderungen dort brauchen Tests und einen Blick in [SECURITY.md](SECURITY.md).
- **Keine neuen Abhängigkeiten** ohne Absprache. Die Python-Helfer nutzen nur die Standardbibliothek (Python 3.9).
- **Oberfläche.** Farben und Formen kommen aus `Sources/MochiSquad/UI/Theme.swift`. Texte der App sind deutsch und sprechen den Nutzer mit „du“ an.
- **Tests.** Neue Logik bekommt Tests; `./tools/test.sh` muss grün sein.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `Sources/MochiSquad/Core` | Datenmodell und Speicherung |
| `Sources/MochiSquad/Sessions` | Sitzungen, Zusammenarbeit, Routinen, Werkzeugserver |
| `Sources/MochiSquad/UI` | Oberfläche |
| `scripts/` | Python-Helfer, die in die App kopiert werden |
| `Tests/MochiSquadTests`, `Tests/python` | Swift- und Python-Tests |
