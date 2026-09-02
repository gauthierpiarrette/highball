#!/bin/zsh
# Dev-time tool: bake the Finder window layout of the Highball disk image (icon view, 128 px
# icons, no toolbar, background picture, icon positions) into Scripts/dmg/DS_Store.
# Release builds copy that file into the image, so Finder is never automated at release
# time and the layout is byte-for-byte reproducible. Rerun only when the geometry in
# Scripts/make-dmg-background.swift changes, then commit the new DS_Store.
# Usage: Scripts/dmg-layout.sh    (needs dist/Highball.app — Scripts/make-app.sh debug is enough)
set -euo pipefail
cd "$(dirname "$0")/.."
test -d dist/Highball.app || { echo "dist/Highball.app missing; run Scripts/make-app.sh debug first" >&2; exit 1; }
test ! -e /Volumes/Highball || { echo "a Highball volume is already mounted; eject it first" >&2; exit 1; }

# Geometry: keep in sync with make-dmg-background.swift (WIN_W x WIN_H is the content area).
# Finder's AppleScript bounds include the title bar, measured at 32 pt on macOS 26; the
# background has spare height below the content so a shorter title bar elsewhere is harmless.
WIN_W=660; WIN_H=400; TITLEBAR=32; ICON=128
APP_X=150; APP_Y=185; APPS_X=510; APPS_Y=185
WIN_X=200; WIN_Y=140   # where the window opens on the user's screen (Finder stores this too)

WORK=$(mktemp -d)
STAGE="$WORK/stage"
Scripts/dmg-stage.sh "$STAGE"
rm -f "$STAGE/.DS_Store"   # layout is what we are about to create, never a stale copy

hdiutil create -volname "Highball" -srcfolder "$STAGE" -format UDRW -ov "$WORK/layout.dmg" -quiet
hdiutil attach -readwrite -noverify -noautoopen "$WORK/layout.dmg" -quiet
test -d /Volumes/Highball || { echo "image did not mount at /Volumes/Highball" >&2; exit 1; }

osascript <<EOS
tell application "Finder"
  tell disk "Highball"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {$WIN_X, $WIN_Y, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H + TITLEBAR))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $ICON
    set text size of viewOptions to 12
    set label position of viewOptions to bottom
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to true
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Highball.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOS
sync; sleep 2
test -f /Volumes/Highball/.DS_Store || { echo "Finder wrote no .DS_Store" >&2; exit 1; }
mkdir -p Scripts/dmg
cp /Volumes/Highball/.DS_Store Scripts/dmg/DS_Store
hdiutil detach /Volumes/Highball -quiet
rm -rf "$WORK"
echo "wrote Scripts/dmg/DS_Store ($(stat -f %z Scripts/dmg/DS_Store) bytes) — commit it"
