#!/bin/zsh
# Upgrade smoke: this build must still see the install the previous build left behind.
#
# Seeds a home the way a real user's looks after 0.8: an environment that is NOT the default
# name ("CS"), holding an installed Steam game, written in the previous release's on-disk
# shape. Then checks, through the CLI, that the environment lists as real (not DAMAGED).
# With --screen it also launches the app on that home and requires a window within 20 s,
# saving a capture to look at. Records private/upgrade-smoke/latest.json, which
# Scripts/release.sh reads (warn-only, like render-smoke).
#
# Why: the 0.8.0 regression (#21) was invisible to every existing check because each one
# starts from an empty home. Unit tests cover the same contract headlessly
# (Tests/HighballKitTests/UpgradeInstallTests.swift); this is the end-to-end echo of it.
#
# Usage: Scripts/upgrade-smoke.sh [--screen]
# Env:   UPGRADE_SMOKE_HOME   (default: $TMPDIR/hb-upgrade-smoke, recreated)
#        UPGRADE_SMOKE_ENGINE (optional: path of an installed engine dir to link in, so the
#                              app has an engine and skips onboarding; the CLI part never needs it)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HB="$ROOT/.build/debug/highball"
[ -x "$HB" ] || swift build --package-path "$ROOT" >/dev/null
SCREEN=0; [ "${1:-}" = "--screen" ] && SCREEN=1
H="${UPGRADE_SMOKE_HOME:-${TMPDIR:-/tmp}/hb-upgrade-smoke}"
rm -rf "$H"; mkdir -p "$H/bottles/CS/drive_c/windows"
STEAM="$H/bottles/CS/drive_c/Program Files (x86)/Steam"
mkdir -p "$STEAM/steamapps/common/Counter-Strike Source"
: > "$STEAM/steam.exe"
cat > "$STEAM/steamapps/appmanifest_240.acf" <<'ACF'
"AppState"
{
	"appid"		"240"
	"name"		"Counter-Strike: Source"
	"installdir"		"Counter-Strike Source"
	"StateFlags"		"4"
	"SizeOnDisk"		"5000000000"
}
ACF
# The shape 0.8.0 writes (every key), kept in sync with UpgradeInstallTests.bottleJSON_0_8.
cat > "$H/bottles/CS/bottle.json" <<'JSON'
{
  "advertiseAVX" : false,
  "commandIsControl" : true,
  "commandIsControlSynced" : true,
  "created" : "2026-08-23T16:45:00Z",
  "dllOverrides" : "",
  "dpiScale" : 96,
  "dxvkAppConfig" : {},
  "dxvkAsync" : false,
  "engineID" : "x64-sikarugir10.0_6-r1",
  "environment" : {},
  "formatVersion" : 3,
  "fpsCap" : 0,
  "metalHUD" : false,
  "name" : "CS",
  "pins" : [],
  "recipes" : ["steam"],
  "renderer" : "dxmt",
  "rendererExplicit" : false,
  "sync" : "msync",
  "windowsVersion" : "win10"
}
JSON
if [ -n "${UPGRADE_SMOKE_ENGINE:-}" ] && [ -d "$UPGRADE_SMOKE_ENGINE" ]; then
  mkdir -p "$H/engines"; ln -s "$UPGRADE_SMOKE_ENGINE" "$H/engines/$(basename "$UPGRADE_SMOKE_ENGINE")"
fi
export HIGHBALL_HOME="$H"

fail() { echo "UPGRADE SMOKE FAILED: $*" >&2; record false; exit 1; }
record() {
  mkdir -p "$ROOT/private/upgrade-smoke"
  python3 - "$1" "$SCREEN" "$ROOT/private/upgrade-smoke/latest.json" <<'PY'
import json, sys, time
passed, screen, out = sys.argv[1] == "true", sys.argv[2] == "1", sys.argv[3]
json.dump({"passed": passed, "epoch": int(time.time()), "date": time.strftime("%Y-%m-%d"),
           "screen": screen}, open(out, "w"), indent=2)
PY
}

echo "== CLI: the existing environment is seen"
out="$("$HB" bottle list 2>&1)"; echo "$out"
echo "$out" | grep -q '^CS' || fail "environment 'CS' not listed"
echo "$out" | grep -q 'DAMAGED' && fail "environment reported as damaged"

if [ "$SCREEN" = 1 ]; then
  echo "== app: launches on that home and shows a window"
  APP="$ROOT/dist/Highball.app/Contents/MacOS/Highball"
  [ -x "$APP" ] || "$ROOT/Scripts/make-app.sh" >/dev/null
  pkill -f "dist/Highball.app/Contents/MacOS/Highball" 2>/dev/null || true; sleep 1
  "$APP" >/dev/null 2>&1 &
  sleep 1; pid=$(pgrep -n -f "dist/Highball.app/Contents/MacOS/Highball" || true)
  [ -n "$pid" ] || fail "app did not start"
  n=0; win=0
  until [ "$win" -ge 1 ] || [ $n -ge 20 ]; do
    sleep 1; n=$((n+1))
    win=$(osascript -e "tell application \"System Events\" to count windows of (first process whose unix id is $pid)" 2>/dev/null || echo 0)
  done
  [ "$win" -ge 1 ] || { kill "$pid" 2>/dev/null || true; fail "no window after 20 s"; }
  sleep 4
  screencapture -x "$ROOT/private/upgrade-smoke/library.png" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  echo "   window appeared; capture at private/upgrade-smoke/library.png (look: the game should show, not 'prepare an environment')"
fi

record true
echo "UPGRADE SMOKE PASSED"
