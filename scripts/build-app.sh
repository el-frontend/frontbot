#!/bin/bash
# Arma build/Frontbot.app: binario release + Node + sidecar, firmado ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Frontbot.app"
NODE_BIN="${NODE_BIN:-$(command -v node)}"

echo "→ Compilando la app (release)"
swift build --package-path "$ROOT/app" -c release --product FrontbotApp
BIN="$(swift build --package-path "$ROOT/app" -c release --show-bin-path)/FrontbotApp"

echo "→ Compilando el sidecar"
(cd "$ROOT/agent" && npm run build >/dev/null)

echo "→ Armando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/node/bin" "$APP/Contents/Resources/agent"
cp "$BIN" "$APP/Contents/MacOS/Frontbot"
cp "$NODE_BIN" "$APP/Contents/Resources/node/bin/node"
cp -R "$ROOT/agent/dist" "$ROOT/agent/package.json" "$ROOT/agent/package-lock.json" "$ROOT/agent/node_modules" "$APP/Contents/Resources/agent/"
(cd "$APP/Contents/Resources/agent" && npm prune --omit=dev --no-audit --no-fund >/dev/null)
# Recursos que SwiftPM genera junto al binario (p. ej. el bundle de GRDB).
for b in "$(dirname "$BIN")"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Mascota (modelo 3D y logo) e icono de la app.
cp -R "$ROOT/app/Sources/FrontbotApp/Resources/Mascot" "$APP/Contents/Resources/"
cp "$ROOT/app/Sources/FrontbotApp/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Frontbot</string>
  <key>CFBundleDisplayName</key><string>Frontbot</string>
  <key>CFBundleIdentifier</key><string>app.frontbot.Frontbot</string>
  <key>CFBundleExecutable</key><string>Frontbot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ Firmando (ad-hoc)"
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"
