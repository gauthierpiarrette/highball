#!/bin/zsh
# Assemble dist/Highball.app from the SwiftPM build.
# Usage: Scripts/make-app.sh [debug|release] [version]
# Signs with Developer ID when available (hardened runtime); notarizes + staples when a
# notarytool keychain profile named "highball" exists.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION="${2:-0.0.0-dev}"
FEED_URL="https://raw.githubusercontent.com/gauthierpiarrette/highball/main/appcast.xml"
ED_PUBLIC_KEY="lntI8A+HC5Wo6xb4dZNQ6IYteI771cNybU8XNXmvMd8="

swift build -c "$CONFIG" --product HighballApp
APP=dist/Highball.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp ".build/$CONFIG/HighballApp" "$APP/Contents/MacOS/Highball"

# Sparkle framework (SwiftPM artifact) — embedded, rpath is baked into the binary.
SPARKLE_FW=$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework | head -1)
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# Resources: engine manifest, GPTK license, recipes and DB entries (from highball-db).
cp spike/engine-manifest.json "$APP/Contents/Resources/engine-manifest.json"
cp spike/d3dmetal-license.txt "$APP/Contents/Resources/d3dmetal-license.txt"
RECIPES="../highball-db/recipes"
if [ ! -d "$RECIPES" ]; then
  RECIPES=".build/highball-db/recipes"
  [ -d "$RECIPES" ] || git clone --depth 1 https://github.com/gauthierpiarrette/highball-db.git .build/highball-db
fi
for f in "$RECIPES"/launchers/*.json "$RECIPES"/games/*.json "$RECIPES"/tweaks/*.json; do cp "$f" "$APP/Contents/Resources/"; done
DBDIR="$(dirname "$RECIPES")/db/games"
if [ -d "$DBDIR" ]; then mkdir -p "$APP/Contents/Resources/db-games"; cp "$DBDIR"/*.json "$APP/Contents/Resources/db-games/"; fi

# App icon.
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
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${ED_PUBLIC_KEY}</string>
  <key>SUEnableInstallerLauncherService</key><false/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0 — no paid tier, ever.</string>
  <key>NSMicrophoneUsageDescription</key><string>Windows games and apps running in a bottle need the microphone for voice chat and recording. macOS asks the first time one uses it.</string>
</dict></plist>
PLIST

# Hardened-runtime entitlements: Wine processes are children of the app, so TCC attributes
# their device access to Highball — without audio-input declared, macOS silently denies the
# microphone to every game and never shows a prompt (user report, 2026-08-25).
cat > dist/entitlements.plist <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENTITLEMENTS

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --entitlements dist/entitlements.plist -s "$IDENTITY" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer|flags" | head -2 || true

# Notarize + staple when credentials are stored (xcrun notarytool store-credentials highball ...).
if xcrun notarytool history --keychain-profile highball >/dev/null 2>&1; then
  echo "notarizing…"
  ditto -c -k --keepParent "$APP" dist/Highball-notarize.zip
  xcrun notarytool submit dist/Highball-notarize.zip --keychain-profile highball --wait
  xcrun stapler staple "$APP"
  rm dist/Highball-notarize.zip
  echo "notarized and stapled"
else
  if [ "$CONFIG" = "release" ]; then
    # Never ship unnotarized again: 0.1–0.3 went out this way and macOS 15+ showed users
    # the "could not verify it's free of malware" dialog (retro-notarized 2026-08-24).
    echo "error: release build but no notarytool profile 'highball' — refusing to ship unnotarized." >&2
    echo "fix: xcrun notarytool store-credentials highball --apple-id <id> --team-id B95M7DARU4" >&2
    exit 1
  fi
  echo "note: no notarytool profile 'highball' — skipping notarization (debug build)"
fi
echo "built $APP ($VERSION)"
