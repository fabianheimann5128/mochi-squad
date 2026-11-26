#!/bin/bash
# Mochi Squad einrichten: Voraussetzungen prüfen, App bauen und nach ~/Applications installieren.
#   ./setup.sh            prüft, baut und installiert
#   ./setup.sh --check    prüft nur die Voraussetzungen
set -euo pipefail
cd "$(dirname "$0")"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; missing=1; }
missing=0

echo "Mochi Squad – Voraussetzungen"

major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$major" -ge 14 ]]; then ok "macOS $(sw_vers -productVersion)"; else fail "macOS 14 (Sonoma) oder neuer wird benötigt, gefunden: $(sw_vers -productVersion)"; fi

if command -v swift >/dev/null 2>&1; then
    ok "Swift $(swift --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/')"
else
    fail "Swift fehlt. Installiere die Xcode-Befehlszeilenwerkzeuge mit: xcode-select --install"
fi

if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    ok "Python $(/usr/bin/python3 -c 'import platform; print(platform.python_version())')"
else
    fail "/usr/bin/python3 (3.9 oder neuer) fehlt. Es kommt mit den Xcode-Befehlszeilenwerkzeugen: xcode-select --install"
fi

# Mindestens ein Agent-Programm wird gebraucht; angemeldet wird später in der App mit dem eigenen Abo.
agents=0
for cli in claude codex; do
    if command -v "$cli" >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/$cli" ]]; then
        ok "$cli gefunden"; agents=1
    fi
done
if [[ "$agents" -eq 0 ]]; then
    warn "Weder Claude Code (claude) noch Codex (codex) gefunden. Die App startet trotzdem, Agenten brauchen aber eins davon:"
    warn "  Claude Code: https://docs.claude.com/claude-code   ·   Codex: https://developers.openai.com/codex/cli"
fi

if [[ "$missing" -ne 0 ]]; then
    echo; echo "Bitte die markierten Punkte beheben und ./setup.sh erneut starten."; exit 1
fi
[[ "${1:-}" == "--check" ]] && exit 0

echo; echo "App wird gebaut (beim ersten Mal einige Minuten) …"
./install.sh
echo
echo "Fertig. Öffne „Mochi Squad“ aus ~/Applications. Beim ersten Start führt dich die App durch die Einrichtung."
