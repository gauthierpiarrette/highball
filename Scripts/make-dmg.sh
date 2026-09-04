#!/bin/zsh
# Build dist/Highball.dmg from dist/Highball.app: the designed drag-to-Applications window
# (Scripts/dmg-stage.sh) on a compressed read-only image, with the app icon as the volume icon.
# Signing and notarization stay in release.sh so this can be run and inspected locally.
# Usage: Scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# A Highball volume left mounted by an earlier run aborted two releases; eject it instead.
if [ -e /Volumes/Highball ]; then echo "ejecting a mounted Highball volume" >&2; hdiutil detach /Volumes/Highball -force >/dev/null 2>&1 || { echo "could not eject /Volumes/Highball" >&2; exit 1; }; fi

DMG=dist/Highball.dmg
WORK=dist/dmg-work
rm -rf "$WORK" "$DMG"; mkdir -p "$WORK"
Scripts/dmg-stage.sh "$WORK/stage"

# Read-write first: the custom-icon flag lives on the mounted volume's root folder and cannot
# be set through -srcfolder. -nobrowse keeps Finder out of it. Then convert to the compressed
# read-only image users download.
hdiutil create -volname "Highball" -srcfolder "$WORK/stage" -format UDRW -ov "$WORK/rw.dmg" -quiet
hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$WORK/rw.dmg" -quiet
test -d /Volumes/Highball || { echo "image did not mount at /Volumes/Highball" >&2; exit 1; }
SetFile -a C /Volumes/Highball
sync
hdiutil detach /Volumes/Highball -quiet
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -rf "$WORK"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
