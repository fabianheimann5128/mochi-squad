#!/bin/bash
# Releases a version of Mochi Squad: signed and notarized disk image, update feed for Sparkle, GitHub release.
#
#   ./tools/release.sh keys        once: create the update key in your keychain (or show the existing one)
#                                  and write its public half into Resources/Info.plist
#   ./tools/release.sh             build dist/MochiSquad-<version>.dmg and dist/appcast.xml, publish nothing
#   ./tools/release.sh publish     the same, then create the GitHub release v<version> with both files
#
# Before a release, raise CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist and add the
# version to CHANGELOG.md. Needs the Developer ID certificate and the notary profile (see tools/make-dmg.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

repo="fabianheimann5128/mochi-squad"
sparkle_version="2.10.1"
sparkle_sha256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
tools=".build/sparkle-tools"
plist="Resources/Info.plist"

# Sparkle's own release tools (generate_keys, generate_appcast), fetched once and checked against a known checksum.
if [[ ! -x "$tools/bin/generate_appcast" ]]; then
    mkdir -p "$tools"
    archive="$tools/Sparkle-$sparkle_version.tar.xz"
    curl -fsSLo "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
    echo "$sparkle_sha256  $archive" | shasum -a 256 -c - >/dev/null
    tar -xf "$archive" -C "$tools"
fi

if [[ "${1:-}" == keys ]]; then
    # The private key stays in the login keychain. Whoever loses it can no longer ship updates to existing users.
    "$tools/bin/generate_keys" >/dev/null
    public="$("$tools/bin/generate_keys" -p)"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public" "$plist"
    echo "Public update key written to $plist."
    echo "Back up the private key somewhere safe:  $tools/bin/generate_keys -x <file>"
    exit 0
fi

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$plist")" ]] || { echo "No update key yet: run ./tools/release.sh keys" >&2; exit 1; }
grep -q "^## $version\$" CHANGELOG.md || { echo "CHANGELOG.md has no section for $version." >&2; exit 1; }
if [[ "${1:-}" == publish ]]; then
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Commit your changes first." >&2; exit 1; }
    git fetch -q origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Push main first; the release is made from origin/main." >&2; exit 1; }
    ! gh release view "v$version" --repo "$repo" >/dev/null 2>&1 || { echo "Release v$version exists already." >&2; exit 1; }
fi

# The Developer ID in the keychain, unless MOCHI_SIGN names one.
identity="${MOCHI_SIGN:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$identity" ]] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }
MOCHI_SIGN="$identity" ./tools/make-dmg.sh

# Feed: only this version, with its notes from the changelog; Sparkle signs the entry with the update key.
feed="$(mktemp -d)"
trap 'rm -rf "$feed"' EXIT
cp "dist/MochiSquad-$version.dmg" "$feed/"
/usr/bin/python3 -B - "$version" > "$feed/MochiSquad-$version.html" <<'PY'
import html, re, sys
version, lines, inside = sys.argv[1], [], False
for line in open("CHANGELOG.md", encoding="utf-8"):
    if line.startswith("## "):
        inside = line.strip() == "## " + version
        continue
    if inside and line.startswith("- "):
        text = html.escape(line[2:].strip())
        lines.append("<li>" + re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text) + "</li>")
print("<ul>" + "".join(lines) + "</ul>")
PY
"$tools/bin/generate_appcast" --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
    --embed-release-notes -o "$feed/appcast.xml" "$feed" >/dev/null
cp "$feed/appcast.xml" dist/appcast.xml
echo "Built: dist/MochiSquad-$version.dmg and dist/appcast.xml"

if [[ "${1:-}" == publish ]]; then
    notes="$(mktemp)"
    awk -v v="## $version" '$0==v{f=1;next} /^## /{f=0} f' CHANGELOG.md > "$notes"
    gh release create "v$version" --repo "$repo" --target main --title "Mochi Squad $version" --notes-file "$notes" \
        "dist/MochiSquad-$version.dmg" dist/appcast.xml
    rm -f "$notes"
fi
