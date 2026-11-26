#!/bin/bash
# Renders Resources/AppIcon.icns again (only needed when the Mochi changes).
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library -o "$work/make-icon" tools/make-icon/main.swift Sources/MochiSquad/UI/MochiAvatar.swift Sources/MochiSquad/Core/L10n.swift
"$work/make-icon" "$work/icon.png"
set="$work/AppIcon.iconset"; mkdir "$set"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon.png" --out "$set/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$work/icon.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
cp "$work/icon.png" docs/icon.png
echo "Resources/AppIcon.icns aktualisiert."
