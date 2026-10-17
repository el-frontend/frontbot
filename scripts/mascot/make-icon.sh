#!/bin/bash
# Genera AppIcon.icns a partir de logo.png. Uso: scripts/mascot/make-icon.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RES="$HERE/../../app/Sources/FrontbotApp/Resources"
WORK="$HERE/out/AppIcon.iconset"
rm -rf "$WORK" && mkdir -p "$WORK"
swift "$HERE/make-icon.swift" "$RES/Mascot/logo.png" "$HERE/out/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$HERE/out/icon-1024.png" --out "$WORK/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$HERE/out/icon-1024.png" --out "$WORK/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK" -o "$RES/AppIcon.icns"
echo "✓ $RES/AppIcon.icns"
