#!/bin/zsh
# Cut a Highball release: build+sign+notarize the app, sign the update for Sparkle,
# update appcast.xml, publish the GitHub release.
# Usage: Scripts/release.sh 0.3.1 "One-line summary" [notes-file.md]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version> <summary> [notes.md]}"
SUMMARY="${2:?summary required}"
NOTES_FILE="${3:-}"

Scripts/make-app.sh release "$VERSION"
ZIP="dist/Highball-$VERSION.zip"
ditto -c -k --keepParent dist/Highball.app "$ZIP"

# Sparkle EdDSA signature for the appcast.
SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
ED_ATTRS=$("$SIGN" "$ZIP" | tr -d '\n')   # sparkle:edSignature="…" length="…"

DOWNLOAD_URL="https://github.com/gauthierpiarrette/highball/releases/download/v$VERSION/Highball-$VERSION.zip"
DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

# Create appcast.xml if missing, then insert the new item after <channel>.
if [ ! -f appcast.xml ]; then
  cat > appcast.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Highball</title>
    <link>https://github.com/gauthierpiarrette/highball</link>
    <description>Run Windows games on Apple Silicon.</description>
  </channel>
</rss>
XML
fi
# Insert via python, not sed: the summary is arbitrary text (a '|' or '&' must not break the release).
HB_VERSION="$VERSION" HB_SUMMARY="$SUMMARY" HB_DATE="$DATE" HB_URL="$DOWNLOAD_URL" HB_ED="$ED_ATTRS" python3 - <<'PY'
import os, xml.dom.minidom
v = os.environ['HB_VERSION']
item = f"""    <item>
      <title>Highball {v}</title>
      <description><![CDATA[{os.environ['HB_SUMMARY']}]]></description>
      <pubDate>{os.environ['HB_DATE']}</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="{os.environ['HB_URL']}" sparkle:version="{v}" sparkle:shortVersionString="{v}" {os.environ['HB_ED']} type="application/octet-stream"/>
    </item>"""
s = open('appcast.xml').read()
anchor = '<description>Run Windows games on Apple Silicon.</description>'
assert anchor in s, 'appcast anchor missing'
assert f'v{v}/' not in s, f'version {v} already in appcast'
open('appcast.xml', 'w').write(s.replace(anchor, anchor + '\n' + item, 1))
xml.dom.minidom.parse('appcast.xml')
print('appcast.xml valid')
PY

# DMG is THE user-facing download: unzip and many third-party unarchivers destroy the zip's
# Sparkle symlinks, which breaks the signature and triggers Gatekeeper's malware warning
# (proven 2026-08-25, repeated Reddit reports). A DMG has no extraction step to mangle.
# The zip stays as the Sparkle update enclosure. Landing/README link
# .../releases/latest/download/Highball.dmg, so the DMG asset name must stay unversioned.
DMG="dist/Highball.dmg"
rm -rf dist/dmg-stage "$DMG"; mkdir dist/dmg-stage
ditto dist/Highball.app dist/dmg-stage/Highball.app
ln -s /Applications dist/dmg-stage/Applications
hdiutil create -volname "Highball" -srcfolder dist/dmg-stage -ov -format UDZO "$DMG" -quiet
codesign --sign "Developer ID Application: Gauthier PIARRETTE (B95M7DARU4)" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile highball --wait
xcrun stapler staple "$DMG"

if [ -n "$NOTES_FILE" ]; then
  gh release create "v$VERSION" "$ZIP" "$DMG" --latest --title "Highball $VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "v$VERSION" "$ZIP" "$DMG" --latest --title "Highball $VERSION" --notes "$SUMMARY"
fi

git add appcast.xml && git commit -m "release: v$VERSION appcast" && git push

# Post-publish gate: download the published assets back and verify them exactly as users do.
# Any failure aborts loudly (set -e) — a release is not done until this passes.
GATE=$(mktemp -d)
curl -sL -o "$GATE/app.dmg" "https://github.com/gauthierpiarrette/highball/releases/download/v$VERSION/Highball.dmg"
xcrun stapler validate "$GATE/app.dmg"
spctl --assess --type open --context context:primary-signature "$GATE/app.dmg"
curl -sL -o "$GATE/app.zip" "$DOWNLOAD_URL"
ditto -x -k "$GATE/app.zip" "$GATE/x"
xcrun stapler validate "$GATE/x/Highball.app"
spctl --assess --type execute "$GATE/x/Highball.app"
rm -rf "$GATE"
echo "post-publish verification passed: dmg + zip notarized as downloaded"
echo "released v$VERSION — appcast live once the push lands"
