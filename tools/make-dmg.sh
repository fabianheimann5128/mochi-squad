#!/bin/bash
# Builds Mochi Squad as a disk image to download: one app for Apple silicon and Intel Macs.
#
#   ./tools/make-dmg.sh
#       Test build, signed ad hoc. Opens on this Mac; on other Macs Gatekeeper refuses it.
#
#   MOCHI_SIGN="Developer ID Application: <name> (<team>)" ./tools/make-dmg.sh
#       Release: signed with your Developer ID, notarized by Apple and stapled, so it opens everywhere
#       without a warning. Needs the notary profile once:  xcrun notarytool store-credentials mochi-notary
#       (MOCHI_NOTARY=<profile> picks another one.)
#
# The result lands in dist/MochiSquad-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
identity="${MOCHI_SIGN:-}"
notary="${MOCHI_NOTARY:-mochi-notary}"
dmg="dist/MochiSquad-$version.dmg"

if [[ -n "$identity" ]] && ! security find-identity -v -p codesigning | grep -qF "$identity"; then
    echo "No signing identity \"$identity\" in the keychain." >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/root/Mochi Squad.app"
mkdir -p "$work/root" dist

MOCHI_UNIVERSAL=1 MOCHI_SIGN="${identity:--}" ./install.sh "$app"

notarize() {
    echo "Notarizing $(basename "$1") (usually a few minutes) …"
    xcrun notarytool submit "$1" --keychain-profile "$notary" --wait
}

if [[ -n "$identity" ]]; then
    # The app gets its own ticket first, so it also opens without a network connection after it left the disk image.
    ditto -c -k --keepParent "$app" "$work/app.zip"
    notarize "$work/app.zip"
    xcrun stapler staple "$app"
fi

# The window of the disk image: the app next to a link to Applications, to drag it over.
ln -s /Applications "$work/root/Applications"
rm -f "$dmg"
hdiutil create -volname "Mochi Squad" -srcfolder "$work/root" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$dmg" >/dev/null

if [[ -n "$identity" ]]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi

echo "Built: $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
