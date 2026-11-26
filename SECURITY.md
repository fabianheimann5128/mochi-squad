# Sicherheit

Mochi Squad startet KI-Agenten auf deinem Mac. Dieses Dokument beschreibt, was die App absichert, was nicht, und wie du Lücken meldest.

## Lücke melden

Bitte **nicht** als öffentliches Issue. Nutze „Report a vulnerability“ unter dem Reiter *Security* dieses Repositories. Du bekommst innerhalb weniger Tage eine Antwort.

## Sicherheitsmodell

**Jeder Agent läuft in einer Sandbox und kann sie nicht verlassen.** Was er darin darf, legst du pro Agent fest.

| Recht | Standard | Umsetzung (Claude Code) |
|---|---|---|
| Projekt lesen | immer | Leseregel der Dateiwerkzeuge nur für den Projektordner. Befehle in der Sandbox können auch außerhalb lesen, außer an den gesperrten Orten unten |
| Dateien im Projekt ändern | aus | nur mit „Darf Dateien ändern“; sonst sperrt die Sandbox das Schreiben im Projekt |
| Befehle außerhalb der Sandbox | nie | `allowUnsandboxedCommands: false` |
| Einstellungen der Clients und Git-Hooks im Projekt (`.claude/`, `.codex/`, `.git/hooks/`) ändern | nie | Sperrregel und Schreibsperre, damit sich ein Agent nicht selbst mehr Rechte gibt oder Code für spätere Sitzungen ablegt |
| Zugangsdaten und fremde Daten lesen | nie | Lesesperre für `~/.ssh`, `~/.aws`, `~/.codex`, `~/.claude`, Schlüsselbund, `~/Library/Application Support`, Browser- und Maildaten u. a. |
| Internet in Routinen | aus | je Routine einschaltbar |
| Veröffentlichen, Hochladen, Bezahlen | nie von selbst | Anweisung im Briefing; alles Riskante fragt der Client nach |

Rückfragen des Clients (z. B. „Darf ich diesen Befehl ausführen?“) erscheinen als Karte im Chat. Du entscheidest.

**Startdaten sind für Agenten unerreichbar.** Was eine Sitzung darf, schreibt die App in einen Sitzungsordner in ihren eigenen Daten. Agenten können dort weder lesen noch schreiben, und der Starter nimmt Startdaten nur aus diesem Ordner an. Pfade zu Werkzeugen stehen nie in diesen Daten, sondern ergeben sich aus dem Ordner.

**Projektordner.** Als Projekt nimmt Mochi Squad weder deinen Benutzerordner noch einen Ordner darüber noch etwas in `~/Library` an. Sonst lägen Zugangsdaten und die Daten der App im Arbeitsbereich eines Agenten.

**Agenten-Post.** Jede Sitzung hat einen eigenen Postausgang. Nur ihre eigene Sandbox darf hineinschreiben; damit steht der Absender einer Nachricht fest. Das Post-Werkzeug selbst liegt an einem Ort, den keine Sandbox beschreiben kann.

**Werkzeuge des Koordinators.** Der Koordinator spricht über einen lokalen Server mit der App. Der Server lauscht nur auf `127.0.0.1`, auf einem zufälligen Port, und verlangt ein Token, das bei jedem Start der App neu erzeugt wird. Das Token steht in keiner Datei; nur der Koordinator bekommt es über seine Umgebung. Anfragen aus dem Browser (mit `Origin`) und mit fremdem Hostnamen werden abgelehnt. Fremde Werkzeugserver lädt der Koordinator nicht.

**Zusammenarbeit.** Agenten können sich Nachrichten schicken und im Team-Chat Kollegen dazuholen. Den Koordinator erreichst nur du, im eigenen Chat oder im Team-Chat. Agenten können ihm nichts schicken, weil er über seine Werkzeuge projektübergreifend Aufträge vergeben und Verläufe lesen kann. Das ist je Projekt auf 24 Weitergaben pro halbe Stunde und insgesamt auf 8 gleichzeitige Sitzungen begrenzt, damit keine Schleifen entstehen.

**Zugangsdaten.** Mochi Squad speichert keine Passwörter oder Tokens deiner Abos. Die Anmeldung gehört Claude Code bzw. Codex. Für weitere ChatGPT-Abos legt Codex seine Anmeldung in einen eigenen Ordner unter `~/Library/Application Support/Mochi Squad/accounts/`; dieser Bereich ist für alle Agenten gesperrt.

## Bekannte Grenzen

- **Prompt-Injection.** Ein Agent, der Webseiten oder fremde Dateien liest, kann darin versteckten Anweisungen folgen. Die Rechte oben begrenzen den Schaden, verhindern ihn aber nicht vollständig. Gib Schreibrechte und Internetzugang nur Agenten, die sie brauchen, und halte wichtige Projekte unter Versionsverwaltung.
- **Codex über ein Rechteprofil.** Codex-Agenten bekommen ein eigenes Rechteprofil mit denselben Lesesperren und Schreibgrenzen wie Claude-Agenten; es gilt für die Befehle, die der Agent ausführt. Vor jedem Start prüft Mochi Squad mit `codex sandbox`, dass der installierte Client das Profil durchsetzt (ein gesperrter Ort ist weder lesbar noch beschreibbar), und startet sonst nicht. Die Prüfung läuft über diesen Unterbefehl, nicht in der Sitzung selbst.
- **Eigene Werkzeugserver.** Werkzeugserver (MCP) aus deiner persönlichen Konfiguration liefen außerhalb der Sandbox. Für Codex-Agenten schaltet Mochi Squad sie deshalb beim Start ab; lässt sich die Liste nicht lesen, startet der Agent nicht. Der Koordinator lädt nur die Werkzeuge von Mochi Squad. Andere Claude-Agenten laden deine Claude-Code-Server; deren Werkzeuge fragen nach, bevor sie laufen.
- **Fremde Postausgänge bei Claude-Agenten.** Codex-Agenten sehen nur ihren eigenen Postausgang. Claude-Agenten können die Postausgänge anderer Sitzungen lesen, aber nicht beschreiben.
- **Die Sandbox gehört dem Client.** Mochi Squad konfiguriert die Sandbox von Claude Code und Codex, baut aber keine eigene. Ihre Stärke hängt von der Version des Clients ab. Eigene Freigaben in deinen persönlichen Client-Einstellungen gelten zusätzlich.
- **Lesen im Projekt.** Jeder Agent liest den ganzen Projektordner. Lege dort keine Geheimnisse ab (z. B. `.env` mit Produktionsschlüsseln).
- **Internet in Routinen.** Eine Routine mit Internetzugang läuft unbeaufsichtigt und kann Inhalte aus dem Projekt an Webseiten senden, wenn sie dazu verleitet wird. Schalte das nur für Projekte ohne vertrauliche Inhalte ein.
- **Keine Trennung zwischen macOS-Nutzern.** Mochi Squad schützt nicht vor anderen Programmen, die unter deinem Benutzerkonto laufen.
