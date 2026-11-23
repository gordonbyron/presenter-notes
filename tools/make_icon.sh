#!/bin/bash
# Redraws the app icon and rebuilds Resources/AppIcon.icns and Resources/AppIcon.png.
# usage: tools/make_icon.sh [letters|lines]
set -euo pipefail
cd "$(dirname "$0")/.."

STYLE="${1:-letters}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift tools/make_icon.swift "$WORK/icon-1024.png" "$STYLE"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET" Resources
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
sips -z 256 256 "$WORK/icon-1024.png" --out Resources/AppIcon.png >/dev/null
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon.png ($STYLE)"
