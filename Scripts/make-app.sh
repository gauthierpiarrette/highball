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

# A duplicate key in L10n's dictionary literal crashes the app at launch (2026-09-15); refuse to build one.
python3 - <<'PY' || exit 1
import re, collections
keys = re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"', open("Sources/HighballApp/L10n.swift").read(), re.M)
dups = [k for k, c in collections.Counter(keys).items() if c > 1]
if dups: print("error: duplicate L10n keys:", dups); raise SystemExit(1)
# English is the source language and French is the one translation kept complete; a string
# without a French line shows English on a French Mac (L() falls back), which is fine for a
# contributor's change, so this warns rather than refusing (2026-09-17). Translations are
# optional for contributors; the maintainer fills the French in before a release.
import glob
used = set()
for f in glob.glob("Sources/HighballApp/*.swift"):
    if f.endswith("L10n.swift"): continue
    used |= set(re.findall(r'\bL\("((?:[^"\\]|\\.)*)"\)', open(f).read()))
missing = sorted(used - set(keys))
if missing: print(f"warning: {len(missing)} L() strings without a French line (English shows instead):", missing)
PY
# SwiftPM's Bundle.module accessor looks for the resource bundle next to the executable or at the
# absolute build path of the machine that compiled it, never under Contents/Resources, so an app
# that reads it runs on the builder's Mac and crashes at launch everywhere else (PR #230,
# 2026-10-01). App resources go through Bundle.main, from the files this script copies.
if grep -rq "Bundle\.module" Sources/HighballApp; then echo "error: Sources/HighballApp reads Bundle.module; use Bundle.main and copy the file here" >&2; exit 1; fi
swift build -c "$CONFIG" --product HighballApp
APP=dist/Highball.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp ".build/$CONFIG/HighballApp" "$APP/Contents/MacOS/Highball"

# Sparkle framework (SwiftPM artifact) — embedded, rpath is baked into the binary.
SPARKLE_FW=$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework | head -1)
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"

# Highball's signed Wine loader for the arm64 engines (WineLoaderHelper.swift, private/notes/
# rosetta-transition-plan.md): a helper bundle, app.highball.WineLoader, whose one binary is built
# from spike/wineloader. Apple's cross-architecture entitlement is restricted, so the bundle carries
# the Developer ID provisioning profile from private/signing (gitignored; the account holder made it
# in the developer portal on 2026-10-04, it expires 2044-09-29) and is signed with the entitlements
# below. An arm64 engine points its `wine` at this binary; nothing is ever copied into the bundle.
# The loader links with -x86_64_layout_emulation, which only Xcode 26.4's linker knows. A release
# needs it; a debug build on an older Xcode (CI's macos-15 runners, a contributor's Mac) goes on
# without the helper, which only an arm64 engine would use and none ships yet (PR gate failure on
# highball#260, 2026-10-05: "ld: unknown options: -x86_64_layout_emulation").
HELPER="$APP/Contents/Helpers/WineLoader.app"
HAVE_LOADER=1
if ! spike/wineloader/build.sh >/dev/null 2>dist/wineloader-build.err; then
  if [ "$CONFIG" = release ]; then
    cat dist/wineloader-build.err >&2
    echo "error: the Wine loader helper did not build; a release needs Xcode 26.4 or later" >&2; exit 1
  fi
  echo "note: the Wine loader helper did not build ($(grep -m1 -i 'error\|unknown' dist/wineloader-build.err || echo 'see dist/wineloader-build.err')), so this debug build has none; it needs Xcode 26.4 or later"
  HAVE_LOADER=
fi
if [ -n "$HAVE_LOADER" ]; then
mkdir -p "$HELPER/Contents/MacOS"
cp .build/wineloader/wine "$HELPER/Contents/MacOS/wine"
cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.highball.WineLoader</string>
  <key>CFBundleExecutable</key><string>wine</string>
  <key>CFBundleName</key><string>Highball Wine Loader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.5</string>
</dict></plist>
PLIST
LOADER_PROFILE=private/signing/Highball_Wine_Loader_Developer_ID.provisionprofile
if [ -f "$LOADER_PROFILE" ]; then
  cp "$LOADER_PROFILE" "$HELPER/Contents/embedded.provisionprofile"
elif [ "$CONFIG" = release ]; then
  echo "error: release build without $LOADER_PROFILE: the Wine loader would ship without the cross-architecture entitlement and no arm64 engine could start" >&2; exit 1
else
  echo "note: no $LOADER_PROFILE, the Wine loader helper is signed without its entitlements (debug build)"
fi
fi   # HAVE_LOADER
cat > dist/wineloader.entitlements <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.developer.cross-architecture-support</key><true/>
  <key>com.apple.application-identifier</key><string>B95M7DARU4.app.highball.WineLoader</string>
  <key>com.apple.developer.team-identifier</key><string>B95M7DARU4</string>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict></plist>
ENTITLEMENTS

# Resources: engine manifest, GPTK license, recipes and DB entries (from highball-db).
cp spike/engine-manifest.json "$APP/Contents/Resources/engine-manifest.json"
# Other engines the app can offer (previous ones for rollback, candidates for Advanced).
if ls spike/engines/*.json >/dev/null 2>&1; then mkdir -p "$APP/Contents/Resources/engines"; cp spike/engines/*.json "$APP/Contents/Resources/engines/"; fi
cp spike/d3dmetal-license.txt "$APP/Contents/Resources/d3dmetal-license.txt"
# cabextract for winetricks (the core fonts tweak needs it and macOS has none, highball#96), built
# from its pinned source by spike/tools/build-cabextract.sh, GPL-3.0-or-later, licence shipped beside it.
spike/tools/build-cabextract.sh >/dev/null 2>&1 || { echo "error: could not build cabextract (spike/tools/build-cabextract.sh)" >&2; exit 1; }
mkdir -p "$APP/Contents/Resources/tools"
cp spike/tools/cabextract "$APP/Contents/Resources/tools/cabextract"
cp spike/tools/cabextract.LICENSE "$APP/Contents/Resources/tools/cabextract.LICENSE"
# A stand-in for `lipo -archs`, which winetricks asks which Wine it runs: macOS's own lipo needs
# Xcode's tools and an accepted Xcode licence, and without them the core fonts step failed
# (highball#135, #183). A shell script reading the Mach-O header; the bundle's seal covers it.
cp spike/tools/lipo "$APP/Contents/Resources/tools/lipo"
# The EpicGamesLauncher.exe stand-in for Rockstar games bought on Epic (highball#93), built from
# spike/epic-stub/EpicGamesLauncher.c with mingw. A release must carry it; a debug build without
# mingw goes on without it and the Epic launch path says so in the log.
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  spike/epic-stub/build.sh >/dev/null
  cp spike/epic-stub/EpicGamesLauncher.exe "$APP/Contents/Resources/EpicGamesLauncher.exe"
  spike/discord-bridge/build.sh
  cp spike/discord-bridge/highball-discord-bridge.exe "$APP/Contents/Resources/highball-discord-bridge.exe"
elif [ "$CONFIG" = release ]; then
  echo "error: release build needs mingw-w64 (brew install mingw-w64) to build spike/epic-stub" >&2; exit 1
else
  echo "note: no mingw-w64, the Epic stand-in and Discord pipe bridge are not bundled (debug build)"
fi
RECIPES="../highball-db/recipes"
if [ ! -d "$RECIPES" ]; then
  # Without a sibling checkout the build keeps its own clone in .build, and that clone must be the
  # database as published now: 0.10.6 shipped from a clone left at an earlier build's commit and
  # lacked the night's rows and the Bloody Spell recipe its notes announced (2026-10-05). The cache
  # is ours and never edited, so it is reset to origin's main on every build; a release build
  # refuses to go on when that fails.
  RECIPES=".build/highball-db/recipes"
  if [ -d .build/highball-db/.git ]; then
    if ! { git -C .build/highball-db fetch -q --depth 1 origin main && git -C .build/highball-db reset -q --hard FETCH_HEAD; }; then
      if [ "$CONFIG" = release ]; then echo "error: could not update .build/highball-db to origin/main; a release must bundle the current database" >&2; exit 1; fi
      echo "note: .build/highball-db could not be updated, bundling it as it is"
    fi
  else
    git clone -q --depth 1 https://github.com/gauthierpiarrette/highball-db.git .build/highball-db
  fi
fi
echo "database: $(git -C "$(dirname "$RECIPES")" log -1 --format='%h %cs %s' 2>/dev/null | cut -c1-80)"
for f in "$RECIPES"/launchers/*.json "$RECIPES"/games/*.json "$RECIPES"/tweaks/*.json; do cp "$f" "$APP/Contents/Resources/"; done
DBDIR="$(dirname "$RECIPES")/db/games"
if [ -d "$DBDIR" ]; then mkdir -p "$APP/Contents/Resources/db-games"; cp "$DBDIR"/*.json "$APP/Contents/Resources/db-games/"; fi

# App icon: the icns is the bundle's icon, the 512 px png the copy the app loads itself
# (its Dock icon, the empty environment view, launcher shortcuts in ~/Applications/Highball).
cp Resources/AppIcon.icns Resources/AppIcon.png "$APP/Contents/Resources/"

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
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUEnableInstallerLauncherService</key><false/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0 — no paid tier, ever.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Highball play link</string>
    <key>CFBundleURLSchemes</key><array><string>highball</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Windows program</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key><array><string>com.microsoft.windows-executable</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Windows installer or batch file</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>msi</string><string>bat</string></array>
    </dict>
  </array>
  <key>NSLocalNetworkUsageDescription</key><string>Steam and some games look for other players and devices on your network. macOS asks the first time one does.</string>
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
  # The XPC services exist on every Sparkle 2 build; a signing failure here must stop the build.
  # With the errors swallowed, one transient failure left Installer.xpc ad-hoc signed and the
  # notary rejected the whole app (2026-09-17, 0.9.25's first attempt).
  for xpc in Downloader Installer; do
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/$xpc.xpc"
  done
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  # Bundled command-line tools are Mach-O executables too: notarization rejects them unsigned
  # (cabextract, 2026-09-14: "not signed with a valid Developer ID", no hardened runtime).
  for tool in "$APP"/Contents/Resources/tools/*; do
    case "$tool" in *.LICENSE|*/lipo) ;; *) codesign --force --options runtime --timestamp -s "$IDENTITY" "$tool" ;; esac
  done
  # The Wine loader helper: its restricted entitlement is only honoured next to the profile, and a
  # binary claiming it without one is killed at exec, so without the profile it is signed plain.
  if [ ! -d "$HELPER" ]; then
    :   # a debug build on an Xcode too old to link the helper has none to sign
  elif [ -f "$HELPER/Contents/embedded.provisionprofile" ]; then
    codesign --force --options runtime --timestamp --entitlements dist/wineloader.entitlements -s "$IDENTITY" "$HELPER"
  else
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$HELPER"
  fi
  codesign --force --options runtime --timestamp --entitlements dist/entitlements.plist -s "$IDENTITY" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer|flags" | head -2 || true

# Notarize + staple when credentials are stored (xcrun notarytool store-credentials highball ...).
# Only a release build is notarized: a debug or e2e bundle is ad-hoc signed and stapling it can
# fail (error 73, 2026-09-13), and it should never look shippable anyway.
# The probe talks to Apple, so its failure is not always a missing profile: an expired developer
# agreement answers 403 here too (2026-10-01), and the old message sent us looking for credentials.
NOTARY_PROBE=""
[ "$CONFIG" = release ] && NOTARY_PROBE=$(xcrun notarytool history --keychain-profile highball 2>&1 >/dev/null) && NOTARY_OK=1 || NOTARY_OK=0
if [ "$CONFIG" = release ] && [ "$NOTARY_OK" = 1 ]; then
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
    if print -r -- "$NOTARY_PROBE" | grep -q "agreement"; then
      echo "error: Apple refuses notarization until the developer account accepts its updated agreement — refusing to ship unnotarized." >&2
      echo "fix: the account holder signs in at https://developer.apple.com/account and accepts the agreement, then run this again" >&2
    else
      echo "error: release build but notarytool cannot use the profile 'highball' — refusing to ship unnotarized." >&2
      echo "notarytool said: ${NOTARY_PROBE:-nothing}" >&2
      echo "fix: xcrun notarytool store-credentials highball --apple-id <id> --team-id B95M7DARU4" >&2
    fi
    exit 1
  fi
  echo "note: no notarytool profile 'highball' — skipping notarization (debug build)"
fi
echo "built $APP ($VERSION)"
