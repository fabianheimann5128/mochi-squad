#!/bin/bash
# Baut Mochi Squad und installiert die App.
#   ./install.sh [ziel.app]     Standard: ~/Applications/Mochi Squad.app
# MOCHI_SIGN=<Identität> signiert mit einer eigenen Identität; ohne Angabe wird ad hoc signiert.
set -euo pipefail
cd "$(dirname "$0")"

app="${1:-$HOME/Applications/Mochi Squad.app}"
bundle_id="dev.mochisquad.app"
if [[ -e "$app" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)" != "$bundle_id" ]]; then
    echo "Am Ziel liegt bereits eine andere Anwendung: $app" >&2
    exit 1
fi

swift build -c release --product MochiSquad
bin="$(swift build -c release --show-bin-path)"

resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources"
install -m 755 "$bin/MochiSquad" "$app/Contents/MacOS/MochiSquad"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$resources/"
# Leerer Sprachordner: Damit zeigt macOS die Standardmenüs der App auf Deutsch.
mkdir -p "$resources/de.lproj"
cp scripts/*.py "$resources/"
cp LICENSE NOTICE CHANGELOG.md "$resources/"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$resources/SwiftTerm-LICENSE.txt"
if [[ -d "$bin/SwiftTerm_SwiftTerm.bundle" ]]; then
    rm -rf "$resources/SwiftTerm_SwiftTerm.bundle"
    ditto "$bin/SwiftTerm_SwiftTerm.bundle" "$resources/SwiftTerm_SwiftTerm.bundle"
fi

codesign --force --sign "${MOCHI_SIGN:--}" "$app" >/dev/null 2>&1
codesign --verify --deep --strict "$app"
echo "Installiert: $app"
