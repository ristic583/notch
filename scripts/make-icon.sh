#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from the 1024 px master
# Resources/AppIcon.png (transparent, body on Apple's 824-in-1024 grid).
#
#   scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/Resources/AppIcon.png"
# The master comes from the vector source, Resources/AppIcon.svg.
swift "$ROOT/scripts/render-icon.swift"
ICONSET="$ROOT/build/AppIcon.iconset"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "Wrote Resources/AppIcon.icns"

# The website, where there is one beside the app, uses the same icon: tab icon,
# home-screen icon and the logo.
if [[ -d "$ROOT/site" ]]; then
    sips -z 64 64 "$MASTER" --out "$ROOT/site/favicon.png" >/dev/null
    sips -z 180 180 "$MASTER" --out "$ROOT/site/apple-touch-icon.png" >/dev/null
    sips -z 256 256 "$MASTER" --out "$ROOT/site/icon.png" >/dev/null
    echo "Wrote site/{favicon,apple-touch-icon,icon}.png"
fi
