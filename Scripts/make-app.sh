#!/bin/zsh
# Assemble dist/Highball.app from the SwiftPM build (ad-hoc signed; notarization needs an Apple Developer account).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product HighballApp
APP=dist/Highball.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/HighballApp" "$APP/Contents/MacOS/Highball"
# Ship the manifest, recipes and the GPTK license text inside the bundle.
cp spike/engine-manifest.json "$APP/Contents/Resources/engine-manifest.json"
cp spike/d3dmetal-license.txt "$APP/Contents/Resources/d3dmetal-license.txt"
# Recipes come from the highball-db repo (sibling checkout, or a shallow clone into .build).
RECIPES="../highball-db/recipes"
if [ ! -d "$RECIPES" ]; then
  RECIPES=".build/highball-db/recipes"
  [ -d "$RECIPES" ] || git clone --depth 1 https://github.com/gauthierpiarrette/highball-db.git .build/highball-db
fi
for f in "$RECIPES"/launchers/*.json "$RECIPES"/games/*.json; do cp "$f" "$APP/Contents/Resources/"; done
# Compatibility DB entries (for in-app status pills on the games grid).
DBDIR="$(dirname "$RECIPES")/db/games"
if [ -d "$DBDIR" ]; then mkdir -p "$APP/Contents/Resources/db-games"; cp "$DBDIR"/*.json "$APP/Contents/Resources/db-games/"; fi
# App icon: rendered from source, packed to icns.
ICONWORK=.build/icon
mkdir -p "$ICONWORK/AppIcon.iconset"
swift Scripts/make-icon.swift "$ICONWORK/AppIcon-1024.png" >/dev/null
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$ICONWORK/AppIcon-1024.png" --out "$ICONWORK/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
  d=$((sz*2)); sips -z $d $d "$ICONWORK/AppIcon-1024.png" --out "$ICONWORK/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONWORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
sips -z 512 512 "$ICONWORK/AppIcon-1024.png" --out "$APP/Contents/Resources/AppIcon.png" >/dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Highball</string>
  <key>CFBundleIdentifier</key><string>app.highball.Highball</string>
  <key>CFBundleName</key><string>Highball</string>
  <key>CFBundleDisplayName</key><string>Highball</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0 — no paid tier, ever.</string>
</dict></plist>
PLIST
# Prefer a Developer ID certificate when one is in the keychain (hardened runtime, timestamp);
# fall back to ad-hoc. Notarization additionally needs: xcrun notarytool submit dist/Highball.zip
# --keychain-profile <profile> --wait && xcrun stapler staple dist/Highball.app
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --timestamp -s "$IDENTITY" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "Authority|Signature|flags" | head -3 || true
echo "built $APP"
