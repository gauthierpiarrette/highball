#!/bin/bash
# Nightly canary: do the bytes users depend on still exist and match their pins?
#  1. Re-hash every component URL in BOTH the repo manifest and the manifest inside
#     the latest RELEASE bundle. Checking only repo HEAD recreates the #27/#28 blast
#     pattern: shipped users install from the bundled copy, not from main.
#  2. Validate the published DMG + zip exactly as release.sh's post-publish gate does.
#  3. Appcast consistency: newest item version == latest release tag, enclosure fetchable.
#
# Drift and availability are DIFFERENT signals: a hash mismatch (DRIFT) is never
# retried; transport problems (AVAILABILITY) get curl's --retry. When run in CI,
# kind=drift|availability|none lands in $GITHUB_OUTPUT for the alerting job.
set -uo pipefail   # deliberately not -e: failures are aggregated, not fatal mid-run
cd "$(dirname "$0")/.."

REPO=gauthierpiarrette/highball
DRIFT=0; AVAIL=0

hash_check() { # name url expected-sha
  local name="$1" url="$2" sha="$3" got
  got=$(curl -fsSL --retry 3 --max-time 900 "$url" | shasum -a 256 | awk '{print $1}') || got=DOWNLOAD-FAILED
  if [ "$got" = "$sha" ]; then
    echo "ok: $name"
  elif [ "$got" = "DOWNLOAD-FAILED" ]; then
    echo "AVAILABILITY: $name unreachable: $url"; AVAIL=1
  else
    echo "DRIFT: $name expected=$sha got=$got url=$url"; DRIFT=1
  fi
}

manifest_sweep() { # manifest-path label
  echo "--- manifest sweep: $2 ($1)"
  while read -r name url sha; do
    hash_check "$2/$name" "$url" "$sha"
  done < <(python3 -c 'import json,sys
for k, v in json.load(open(sys.argv[1]))["components"].items(): print(k, v["url"], v["sha256"])' "$1")
  # The alternatives block is informational — EngineManifest never decodes or
  # downloads it (Manifest.swift) — so it is not hashed here; the unit tripwire
  # testManifestURLsAreImmutablyPinned guards its URL shape statically.
}

manifest_sweep spike/engine-manifest.json repo

G=$(mktemp -d); trap 'rm -rf "$G"' EXIT

echo "--- published DMG (the download every new user gets)"
if curl -fsSL --retry 3 --max-time 900 -o "$G/app.dmg" "https://github.com/$REPO/releases/latest/download/Highball.dmg"; then
  xcrun stapler validate "$G/app.dmg" || { echo "DRIFT: DMG stapler validation failed"; DRIFT=1; }
  spctl --assess --type open --context context:primary-signature "$G/app.dmg" || { echo "DRIFT: DMG spctl assessment failed"; DRIFT=1; }
else
  echo "AVAILABILITY: latest DMG unreachable"; AVAIL=1
fi

echo "--- published zip (the Sparkle update enclosure) + its bundled manifest"
# Resolve the latest release tag via the API. Unauthenticated calls hit the
# shared-runner-IP rate limit (403 -> empty body -> JSON traceback -> false
# availability alarm; run 33204538325), so authenticate with GH_TOKEN when the
# workflow provides it and retry with backoff on anything that isn't a usable
# answer. A definitive 404 (no release published) is never retried: that is
# DRIFT, not availability. Headers go via a file, not an array: /bin/bash on
# macOS is 3.2, where empty-array expansion trips set -u.
printf 'Accept: application/vnd.github+json\n' > "$G/api-headers"
[ -n "${GH_TOKEN:-}" ] && printf 'Authorization: Bearer %s\n' "$GH_TOKEN" >> "$G/api-headers"
TAG=""; TAG_HTTP=000
for attempt in 1 2 3; do
  TAG_HTTP=$(curl -sSL --max-time 60 -H @"$G/api-headers" \
    -o "$G/latest-release.json" -w '%{http_code}' \
    "https://api.github.com/repos/$REPO/releases/latest") || TAG_HTTP=000
  [ "$TAG_HTTP" = "404" ] && break
  if [ "$TAG_HTTP" = "200" ]; then
    TAG=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("tag_name") or "")
except Exception: pass' "$G/latest-release.json")
    [ -n "$TAG" ] && break
  fi
  if [ "$attempt" -lt 3 ]; then
    echo "note: releases/latest attempt $attempt returned HTTP $TAG_HTTP without a usable tag; retrying in $((attempt == 1 ? 10 : 30))s"
    sleep $((attempt == 1 ? 10 : 30))
  fi
done
if [ -n "$TAG" ]; then
  VER=${TAG#v}
  if curl -fsSL --retry 3 --max-time 900 -o "$G/app.zip" "https://github.com/$REPO/releases/download/$TAG/Highball-$VER.zip"; then
    # ditto, never unzip: unzip flattens Sparkle's symlinks and manufactures a
    # codesign failure (the proven 2026-08-25 Gatekeeper incident).
    ditto -x -k "$G/app.zip" "$G/x"
    xcrun stapler validate "$G/x/Highball.app" || { echo "DRIFT: zip app stapler validation failed"; DRIFT=1; }
    spctl --assess --type execute "$G/x/Highball.app" || { echo "DRIFT: zip app spctl assessment failed"; DRIFT=1; }
    if [ -f "$G/x/Highball.app/Contents/Resources/engine-manifest.json" ]; then
      manifest_sweep "$G/x/Highball.app/Contents/Resources/engine-manifest.json" "released-bundle-$TAG"
    else
      echo "DRIFT: released bundle carries no engine-manifest.json"; DRIFT=1
    fi
  else
    echo "AVAILABILITY: release zip unreachable for $TAG"; AVAIL=1
  fi
elif [ "$TAG_HTTP" = "404" ]; then
  echo "DRIFT: GitHub reports no latest release (HTTP 404) — the release users install from is gone"; DRIFT=1
else
  echo "AVAILABILITY: GitHub API failed to return the latest release after 3 attempts (last HTTP $TAG_HTTP) — API-availability failure, not a missing release"; AVAIL=1
fi

echo "--- appcast consistency"
if curl -fsSL --retry 3 -o "$G/appcast.xml" "https://raw.githubusercontent.com/$REPO/main/appcast.xml"; then
  PARSED=$(python3 - "$G/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
item = root.find('./channel/item')           # release.sh inserts newest first
enc = item.find('enclosure')
print(enc.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}version'), enc.get('url'))
PY
) || PARSED=""
  if [ -n "$PARSED" ]; then
    ac_ver=${PARSED%% *}; ac_url=${PARSED#* }
    if [ -n "$TAG" ] && [ "$TAG" != "null" ] && [ "v$ac_ver" != "$TAG" ]; then
      echo "DRIFT: appcast newest ($ac_ver) != latest release tag ($TAG)"; DRIFT=1
    fi
    curl -fsIL --retry 3 -o /dev/null "$ac_url" || { echo "DRIFT: appcast enclosure not fetchable: $ac_url"; DRIFT=1; }
  else
    echo "DRIFT: appcast unparsable"; DRIFT=1
  fi
else
  echo "AVAILABILITY: appcast unreachable"; AVAIL=1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  kind=none
  [ "$AVAIL" -eq 1 ] && kind=availability
  [ "$DRIFT" -eq 1 ] && kind=drift        # drift outranks availability for labeling
  echo "kind=$kind" >> "$GITHUB_OUTPUT"
fi
if [ "$DRIFT" -eq 0 ] && [ "$AVAIL" -eq 0 ]; then echo; echo "CANARY PASSED"; exit 0; fi
echo; echo "CANARY FAILED (drift=$DRIFT availability=$AVAIL)"; exit 1
