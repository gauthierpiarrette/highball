#!/bin/zsh
# Cut a Highball release: build+sign+notarize the app, sign the update for Sparkle,
# update appcast.xml, publish the GitHub release.
# Usage: Scripts/release.sh [--beta|--hotfix] 0.3.1 "One-line summary" [notes-file.md]
#        Scripts/release.sh --promote 0.3.1     (beta -> stable, phased over seven days)
set -euo pipefail
cd "$(dirname "$0")/.."
# Channels (2026-09-07): a normal release goes to beta first (`--beta`), then `--promote <version>`
# turns the same signed artifact into a stable, phased rollout by editing the appcast: no rebuild,
# so what testers ran is byte for byte what everyone gets. `--hotfix` is stable at once, no phasing.
CHANNEL=stable
case "${1:-}" in
  --beta) CHANNEL=beta; shift ;;
  --hotfix) CHANNEL=hotfix; shift ;;
  --promote)
    PV="${2:?usage: release.sh --promote <version>}"
    git diff-index --quiet HEAD -- || { echo "tracked files modified; commit before promoting" >&2; exit 1; }
    HB_VERSION="$PV" HB_DATE="$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")" python3 - <<'PY'
import os, re, xml.dom.minidom
v = os.environ['HB_VERSION']
s = open('appcast.xml').read()
m = re.search(r'(    <item>\n      <title>Highball ' + re.escape(v) + r'</title>.*?</item>)', s, re.S)
assert m, f'no appcast item for {v}'
item = m.group(1)
assert '<sparkle:channel>beta</sparkle:channel>' in item, f'{v} is not a beta item'
new = item.replace('      <sparkle:channel>beta</sparkle:channel>\n', '      <sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>\n')
# The phased rollout counts from pubDate, so promotion is the item's new date.
new = re.sub(r'<pubDate>.*?</pubDate>', f"<pubDate>{os.environ['HB_DATE']}</pubDate>", new)
open('appcast.xml', 'w').write(s.replace(item, new, 1))
xml.dom.minidom.parse('appcast.xml')
print(f'appcast: {v} promoted to stable, phased over seven days from now')
PY
    gh release edit "v$PV" --prerelease=false --latest --title "Highball $PV"
    git add appcast.xml && git commit -m "release: promote v$PV to stable" && git push
    echo "promoted v$PV"
    exit 0 ;;
esac
VERSION="${1:?usage: release.sh [--beta|--hotfix] <version> <summary> [notes.md]  |  release.sh --promote <version>}"
SUMMARY="${2:?summary required}"
NOTES_FILE="${3:-}"
export HB_CHANNEL="$CHANNEL"

# The tag below marks HEAD as the source of this build, so the tree must be clean.
git diff-index --quiet HEAD -- || { echo "tracked files modified; commit before releasing" >&2; exit 1; }

# Release gate (2026-09-07): Scripts/gate.sh runs every automated check and records
# private/gate/latest.json. A beta or stable release needs a passing result younger than 24 hours
# for this very commit: the tree that was tested is the tree that ships. A hotfix skips the gate
# (an urgent fix is never hostage to a ten-minute run) and only warns about stale smoke results.
if [ "$CHANNEL" != hotfix ]; then
  HB_HEAD="$(git rev-parse HEAD)" python3 - <<'PY' || exit 1
import json, os, sys, time
try:
    d = json.load(open("private/gate/latest.json"))
except Exception:
    print("release gate: no Scripts/gate.sh result. Run Scripts/gate.sh (about ten minutes), or --hotfix for an urgent fix.", file=sys.stderr); sys.exit(1)
required = d.get("required", []); checks = d.get("checks", {})
if not d.get("passed"):
    failed = [k for k in required if checks.get(k, {}).get("result") != "pass"]
    print(f"release gate: the last Scripts/gate.sh run failed ({', '.join(failed)}). Fix it, or --hotfix for an urgent fix.", file=sys.stderr); sys.exit(1)
age = time.time() - d.get("epoch", 0)
if age > 86400:
    print(f"release gate: the last passing Scripts/gate.sh run is {age/3600:.0f} hours old. Run it again, or --hotfix for an urgent fix.", file=sys.stderr); sys.exit(1)
if d.get("commit") != os.environ["HB_HEAD"]:
    print(f"release gate: Scripts/gate.sh ran on {d.get('commit', '?')[:7]}, HEAD is {os.environ['HB_HEAD'][:7]}. Run it again on this commit, or --hotfix for an urgent fix.", file=sys.stderr); sys.exit(1)
advisory = [f"{k} ({v.get('result')})" for k, v in checks.items() if k not in required and v.get("result") != "pass"]
print("release gate: passed." + (f" Advisory checks: {', '.join(advisory)} (private/gate/*.log)." if advisory else ""), file=sys.stderr)
PY
else
  for check in render-smoke upgrade-smoke firstrun-smoke launch-window-smoke game-smoke; do
    if ! HB_CHECK="$check" python3 - <<'PY' 2>/dev/null
import json, os, sys, time
d = json.load(open(f"private/{os.environ['HB_CHECK']}/latest.json"))
sys.exit(0 if d.get("passed") and time.time() - d.get("epoch", 0) < 14*86400 else 1)
PY
    then echo "WARNING (hotfix): no passing $check result from the last 14 days." >&2; fi
  done
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
# Channel: a beta item is only seen by installs that opted in; a stable item rolls out in phases
# (Sparkle: seven groups, one per interval, from pubDate; manual checks get it at once). A hotfix
# is stable with no phasing.
channel = os.environ.get('HB_CHANNEL', 'stable')
extra = ''
if channel == 'beta':
    extra = '      <sparkle:channel>beta</sparkle:channel>\n'
elif channel == 'stable':
    extra = '      <sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>\n'
item = f"""    <item>
      <title>Highball {v}</title>
      <description><![CDATA[{os.environ['HB_SUMMARY']}]]></description>
      <pubDate>{os.environ['HB_DATE']}</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
{extra}      <enclosure url="{os.environ['HB_URL']}" sparkle:version="{v}" sparkle:shortVersionString="{v}" {os.environ['HB_ED']} type="application/octet-stream"/>
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
# A beta is a GitHub prerelease and never "latest": the website's latest-download link and the
# stable appcast item stay on the previous stable until promotion.
if [ "$CHANNEL" = beta ]; then FLAGS="--prerelease"; TITLE="Highball $VERSION (beta)"; else FLAGS="--latest"; TITLE="Highball $VERSION"; fi
publish() {
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" "$DMG" --clobber
    gh release edit "v$VERSION" --draft=false $FLAGS --title "$TITLE"
  elif [ -n "$NOTES_FILE" ]; then
    gh release create "v$VERSION" "$ZIP" "$DMG" $FLAGS --title "$TITLE" --notes-file "$NOTES_FILE"
  else
    gh release create "v$VERSION" "$ZIP" "$DMG" $FLAGS --title "$TITLE" --notes "$SUMMARY"
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
