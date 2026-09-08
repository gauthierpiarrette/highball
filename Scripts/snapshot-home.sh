#!/bin/zsh
# Upgrade replay fixture: the exact files this build writes for a fresh home (engine manifest,
# bottle settings, library index), frozen under Tests/Fixtures/homes/<version>/ so every later
# build proves it still reads them (Tests/HighballKitTests/UpgradeReplayTests.swift). The 0.8.0
# regression (#21) was an on-disk shape nobody had frozen. Run at each release and commit the
# folder. Needs the network for the engine unless the real home's download cache is seeded.
# Usage: Scripts/snapshot-home.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?version, e.g. 0.9.0}"
HB=.build/debug/highball; [ -x "$HB" ] || swift build >/dev/null
H="${TMPDIR:-/tmp}/hb-snapshot-$V"; rm -rf "$H"; mkdir -p "$H/downloads"
# Reuse cached tarballs so the engine install takes seconds, not minutes.
for f in "$HOME/Library/Application Support/Highball/downloads"/*; do [ -f "$f" ] && ln "$f" "$H/downloads/$(basename "$f")" 2>/dev/null || true; done
HIGHBALL_HOME="$H" "$HB" engine install spike/engine-manifest.json >/dev/null
HIGHBALL_HOME="$H" "$HB" bottle create Games >/dev/null
OUT="Tests/Fixtures/homes/$V"; rm -rf "$OUT"; mkdir -p "$OUT/engine" "$OUT/bottle"
ENGINE_ID=$(python3 -c "import json;print(json.load(open('spike/engine-manifest.json'))['id'])")
cp "$H/engines/$ENGINE_ID/manifest.json" "$OUT/engine/manifest.json"
cp "$H/bottles/Games/bottle.json" "$OUT/bottle/bottle.json"
[ -f "$H/library.json" ] && cp "$H/library.json" "$OUT/library.json"
(cd "$H" && find . -maxdepth 3 -not -path './downloads*' -not -path '*/drive_c/*' -not -path '*/engine/*' -not -path '*/frameworks/*' -not -path '*/renderers/*' | sort) > "$OUT/listing.txt"
printf '{"version": "%s", "engine": "%s", "date": "%s"}\n' "$V" "$ENGINE_ID" "$(date +%Y-%m-%d)" > "$OUT/snapshot.json"
rm -rf "$H"
echo "snapshot $V: $(ls "$OUT" | tr '\n' ' ')"
