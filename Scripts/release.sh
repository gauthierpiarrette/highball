#!/bin/zsh
# Cut a Highball release: build+sign+notarize the app, sign the update for Sparkle,
# update appcast.xml, publish the GitHub release.
# Usage: Scripts/release.sh 0.3.1 "One-line summary" [notes-file.md]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version> <summary> [notes.md]}"
SUMMARY="${2:?summary required}"
NOTES_FILE="${3:-}"

# The tag below marks HEAD as the source of this build, so the tree must be clean.
git diff-index --quiet HEAD -- || { echo "tracked files modified; commit before releasing" >&2; exit 1; }

# Renderer regressions (the issue #21 class) ship via code/engine changes, not time,
# so a release wants a recent Scripts/render-smoke.sh result. Warn, don't block:
# hotfixes (like 0.7.9) must never be hostage to a benchmark run.
if ! python3 - <<'PY' 2>/dev/null
import json, sys, time
d = json.load(open("private/render-smoke/latest.json"))
sys.exit(0 if d.get("passed") and time.time() - d.get("epoch", 0) < 14*86400 else 1)
PY
then
  echo "" >&2
  echo "WARNING: no passing render-smoke result from the last 14 days." >&2
  echo "         Run Scripts/render-smoke.sh when convenient — renderer regressions ship silently without it." >&2
  echo "         Continuing in 5s…" >&2
  sleep 5
fi

# Upgrade regressions (the issue #21 class: 0.8.0 hid an existing user's environment) ship via
# UI and state changes, and every first-run check starts from an empty home, so a release wants
# a recent Scripts/upgrade-smoke.sh result too. Same rule as above: warn, don't block.
if ! python3 - <<'PY' 2>/dev/null
import json, sys, time
d = json.load(open("private/upgrade-smoke/latest.json"))
sys.exit(0 if d.get("passed") and time.time() - d.get("epoch", 0) < 14*86400 else 1)
PY
then
  echo "" >&2
  echo "WARNING: no passing upgrade-smoke result from the last 14 days." >&2
  echo "         Run Scripts/upgrade-smoke.sh --screen — an existing install going invisible ships silently without it." >&2
  echo "         Continuing in 5s…" >&2
  sleep 5
fi

# First-run regressions (issue #57/#21: engine tab empty, create-environment silent) hit brand-new
# users only, and every other check assumes an engine already exists. A release wants a recent
# Scripts/firstrun-smoke.sh result: an empty home installs the engine from the bundled manifest.
if ! python3 - <<'PY'
import json, sys, time
d = json.load(open("private/firstrun-smoke/latest.json"))
sys.exit(0 if d.get("passed") and time.time() - d.get("epoch", 0) < 14*86400 else 1)
PY
then
  echo "" >&2
  echo "WARNING: no passing firstrun-smoke result from the last 14 days." >&2
  echo "         Run Scripts/firstrun-smoke.sh: a broken first run leaves new users with no engine." >&2
  echo "         Continuing in 5s…" >&2
  sleep 5
fi

# Launch-window regressions (issue #58: only Settings came back after a relaunch) ship silently
# because every other check starts the app fresh. A release wants a recent
# Scripts/launch-window-smoke.sh result: Settings open, main closed, quit, relaunch, main is back.
if ! python3 - <<'PY'
import json, sys, time
d = json.load(open("private/launch-window-smoke/latest.json"))
sys.exit(0 if d.get("passed") and time.time() - d.get("epoch", 0) < 14*86400 else 1)
PY
then
  echo "" >&2
  echo "WARNING: no passing launch-window-smoke result from the last 14 days." >&2
  echo "         Run Scripts/launch-window-smoke.sh: the app must open its main window on relaunch." >&2
  echo "         Continuing in 5s…" >&2
  sleep 5
fi

# Game regressions (a launcher going silent, a map load freezing) ship via engine, app and OS
# changes alike, so a release wants a recent Scripts/game-smoke.sh result: every verified title
# installed here launched, showed its window and kept drawing. Same rule: warn, don't block.
if ! python3 - <<'PY'
import json, sys, time
d = json.load(open("private/game-smoke/latest.json"))
sys.exit(0 if d.get("passed") and time.time() - d.get("epoch", 0) < 14*86400 else 1)
PY
then
  echo "" >&2
  echo "WARNING: no passing game-smoke result from the last 14 days." >&2
  echo "         Run Scripts/game-smoke.sh: a verified game going silent ships unnoticed without it." >&2
  echo "         Continuing in 5s…" >&2
  sleep 5
fi

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
# The window layout (background, icon positions, volume icon) lives in Scripts/make-dmg.sh.
DMG="dist/Highball.dmg"
Scripts/make-dmg.sh
codesign --sign "Developer ID Application: Gauthier PIARRETTE (B95M7DARU4)" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile highball --wait
xcrun stapler staple "$DMG"

# Tag the exact commit this build came from and push it BEFORE gh release create:
# without an existing tag, gh tags the REMOTE default-branch head, which mislabeled
# v0.7.8 (local fix commits weren't pushed yet, so the tag landed on the v0.7.7 commit).
git tag "v$VERSION"
git push origin HEAD "v$VERSION"

# Publishing is one GitHub call that can fail on a network blip after the tag is already pushed
# (0.8.2: a read error on the final PATCH left a tag with no release and no appcast). Retry, and if
# a previous attempt left the release behind, finish it instead of failing: upload the assets again
# and make sure it is published.
publish() {
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" "$DMG" --clobber
    gh release edit "v$VERSION" --draft=false --latest --title "Highball $VERSION"
  elif [ -n "$NOTES_FILE" ]; then
    gh release create "v$VERSION" "$ZIP" "$DMG" --latest --title "Highball $VERSION" --notes-file "$NOTES_FILE"
  else
    gh release create "v$VERSION" "$ZIP" "$DMG" --latest --title "Highball $VERSION" --notes "$SUMMARY"
  fi
}
for attempt in 1 2 3 4; do
  if publish; then break; fi
  [ "$attempt" = 4 ] && { echo "release publish failed four times; the tag v$VERSION is pushed, run again to finish" >&2; exit 1; }
  echo "publish attempt $attempt failed, retrying in 15s…" >&2; sleep 15
done
# The assets exist only once the release is published; do not point the appcast at them before.
gh release view "v$VERSION" --json isDraft --jq '.isDraft' | grep -q false

git add appcast.xml && git commit -m "release: v$VERSION appcast" && git push

# GitHub's asset CDN lags the upload by a few seconds: wait until the zip downloads at full size.
for i in $(seq 1 24); do
  got=$(curl -sL -o /dev/null -w '%{size_download}' "$DOWNLOAD_URL" || echo 0)
  [ "$got" = "$(stat -f %z "$ZIP")" ] && break
  sleep 5
done

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
