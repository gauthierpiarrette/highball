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
ITEM="    <item>\\
      <title>Highball $VERSION</title>\\
      <description><![CDATA[$SUMMARY]]></description>\\
      <pubDate>$DATE</pubDate>\\
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\\
      <enclosure url=\"$DOWNLOAD_URL\" sparkle:version=\"$VERSION\" sparkle:shortVersionString=\"$VERSION\" $ED_ATTRS type=\"application/octet-stream\"/>\\
    </item>"
sed -i '' "s|<description>Run Windows games on Apple Silicon.</description>|<description>Run Windows games on Apple Silicon.</description>\\
$ITEM|" appcast.xml
plutil -lint /dev/null >/dev/null 2>&1 || true
python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('appcast.xml')" && echo "appcast.xml valid"

if [ -n "$NOTES_FILE" ]; then
  gh release create "v$VERSION" "$ZIP" --prerelease --title "Highball $VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "v$VERSION" "$ZIP" --prerelease --title "Highball $VERSION" --notes "$SUMMARY"
fi

git add appcast.xml && git commit -m "release: v$VERSION appcast" && git push
echo "released v$VERSION — appcast live once the push lands"
