#!/bin/bash
# Builds Mochi Squad and installs the app.
#   ./install.sh [target.app]     default: ~/Applications/Mochi Squad.app
# MOCHI_SIGN=<identity> signs with your own identity; without it the app is signed ad hoc.
# MOCHI_UNIVERSAL=1 builds one app for Apple silicon and Intel Macs (for the download; takes twice as long).
#
# The new app is put together and signed next to the target and then swapped in with one rename.
# An interrupted install therefore never leaves a half-updated app behind.
set -euo pipefail
cd "$(dirname "$0")"

app="${1:-$HOME/Applications/Mochi Squad.app}"
bundle_id="dev.mochisquad.app"
if [[ -e "$app" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)" != "$bundle_id" ]]; then
    echo "Another application is already at the target: $app" >&2
    exit 1
fi

swift build -c release --product MochiSquad
bin="$(swift build -c release --show-bin-path)"
binary="$bin/MochiSquad"
if [[ "${MOCHI_UNIVERSAL:-}" == 1 ]]; then
    # The command line tools cannot build both architectures in one go: the other one gets its own build folder.
    other=x86_64; [[ "$(uname -m)" == x86_64 ]] && other=arm64
    swift build -c release --product MochiSquad --triple "$other-apple-macosx14.0" --scratch-path ".build/$other"
    binary="$(mktemp -d)/MochiSquad"
    lipo -create "$bin/MochiSquad" ".build/$other/release/MochiSquad" -output "$binary"
fi

mkdir -p "$(dirname "$app")"
stage="$(mktemp -d "$(dirname "$app")/.mochi-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
new="$stage/$(basename "$app")"
resources="$new/Contents/Resources"
mkdir -p "$new/Contents/MacOS" "$resources/whatsapp"
install -m 755 "$binary" "$new/Contents/MacOS/MochiSquad"
cp Resources/Info.plist "$new/Contents/Info.plist"
cp Resources/AppIcon.icns "$resources/"
# Language folders: macOS shows its standard menus and permission dialogs in English or German.
cp -R Resources/en.lproj Resources/de.lproj "$resources/"
cp scripts/*.py "$resources/"
cp scripts/whatsapp/bridge.mjs scripts/whatsapp/package.json "$resources/whatsapp/"
cp LICENSE NOTICE CHANGELOG.md CHANGELOG.de.md "$resources/"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$resources/SwiftTerm-LICENSE.txt"
if [[ -d "$bin/SwiftTerm_SwiftTerm.bundle" ]]; then
    ditto "$bin/SwiftTerm_SwiftTerm.bundle" "$resources/SwiftTerm_SwiftTerm.bundle"
fi

# Hardened runtime as Apple requires it for notarization; local builds use it too, so they behave like the download.
identity="${MOCHI_SIGN:--}"
sign=(codesign --force --options runtime --entitlements Resources/MochiSquad.entitlements --sign "$identity")
[[ "$identity" != - ]] && sign+=(--timestamp)
"${sign[@]}" "$new" >/dev/null 2>&1
codesign --verify --deep --strict "$new"

# Swap: the old app steps aside, the new one takes its place, then the old one goes.
if [[ -e "$app" ]]; then
    mv "$app" "$stage/previous.app"
    if ! mv "$new" "$app"; then
        mv "$stage/previous.app" "$app"
        echo "The new app could not be put in place; the previous one was kept." >&2
        exit 1
    fi
else
    mv "$new" "$app"
fi
echo "Installed: $app"
