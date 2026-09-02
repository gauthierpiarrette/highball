#!/bin/zsh
# Assemble the folder that becomes the Highball disk image: the app, the Applications
# drop link, the rendered window background, the volume icon, and the committed Finder
# layout. Shared by release.sh (the real image) and dmg-layout.sh (which re-bakes the layout).
# Usage: Scripts/dmg-stage.sh <stage-dir>   (needs dist/Highball.app)
set -euo pipefail
cd "$(dirname "$0")/.."
STAGE="${1:?usage: dmg-stage.sh <stage-dir>}"
test -d dist/Highball.app || { echo "dist/Highball.app missing" >&2; exit 1; }

rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
ditto dist/Highball.app "$STAGE/Highball.app"
ln -s /Applications "$STAGE/Applications"

# Window background, rendered from source so no image binary lives in git. The 1x and 2x
# renders are folded into one TIFF: Finder picks the Retina page on Retina displays.
BG=.build/dmg-background
mkdir -p "$BG"
swift Scripts/make-dmg-background.swift "$BG/bg1x.png" "$BG/bg2x.png" >/dev/null
tiffutil -cathidpicheck "$BG/bg1x.png" "$BG/bg2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# The mounted volume shows the app icon instead of the generic disk-image icon.
cp dist/Highball.app/Contents/Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"

# Finder layout baked by Scripts/dmg-layout.sh; absent only while that tool creates it.
if [ -f Scripts/dmg/DS_Store ]; then cp Scripts/dmg/DS_Store "$STAGE/.DS_Store"; fi
