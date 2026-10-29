#!/bin/bash
# Arma build/Frontbot.app: binario release + Node + sidecar.
# Sin variables se firma ad-hoc (solo funciona en este Mac). Para repartirla:
#   DEVELOPER_ID="Developer ID Application: Nombre (TEAMID)"  firma con runtime endurecido
#   NOTARY_PROFILE=frontbot  además notariza y grapa el ticket; crea el perfil una vez con
#     xcrun notarytool store-credentials frontbot --apple-id <email> --team-id <TEAMID>
# El resultado para repartir queda en build/Frontbot.zip.
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
# Traducciones: el español es el idioma de desarrollo (las claves); el inglés se une desde app/Localization/en/*.strings.
mkdir -p "$APP/Contents/Resources/es.lproj" "$APP/Contents/Resources/en.lproj"
: > "$APP/Contents/Resources/es.lproj/Localizable.strings"
cat "$ROOT"/app/Localization/en/*.strings > "$APP/Contents/Resources/en.lproj/Localizable.strings"
plutil -lint "$APP/Contents/Resources/en.lproj/Localizable.strings" >/dev/null

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Frontbot</string>
  <key>CFBundleDisplayName</key><string>Frontbot</string>
  <key>CFBundleIdentifier</key><string>app.frontbot.Frontbot</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
  <key>CFBundleExecutable</key><string>Frontbot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Frontbot usa el micrófono para dictar mensajes en el chat.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Frontbot convierte tu voz en texto para escribir en el chat.</string>
</dict>
</plist>
PLIST

if [ -z "${DEVELOPER_ID:-}" ]; then
  echo "→ Firmando (ad-hoc)"
  codesign --force --deep -s - "$APP" >/dev/null 2>&1
  echo "✓ $APP ($(du -sh "$APP" | cut -f1))"
  exit 0
fi

echo "→ Firmando con $DEVELOPER_ID"
ENTITLEMENTS="$ROOT/scripts/Frontbot.entitlements"
sign() { codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" -s "$DEVELOPER_ID" "$1"; }
# De dentro hacia fuera: cada binario anidado (node, claude, addons nativos) y al final la app.
while IFS= read -r f; do
  file "$f" | grep -q "Mach-O" && sign "$f"
done < <(find "$APP/Contents/Resources" -type f \( -perm -u+x -o -name "*.node" -o -name "*.dylib" \))
sign "$APP"
codesign --verify --strict --deep "$APP"

ZIP="$ROOT/build/Frontbot.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "→ Notarizando (tarda unos minutos)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP" # de nuevo, ya con el ticket grapado
  spctl --assess --type execute "$APP"
fi
echo "✓ $APP ($(du -sh "$APP" | cut -f1)) → $ZIP ($(du -sh "$ZIP" | cut -f1))"
