#!/bin/zsh
# Release gate: the automated checks in one run, one result file. Scripts/release.sh refuses a beta
# or stable release without a passing result younger than 24 hours for the commit being released
# (--hotfix skips the gate and only warns, so an urgent fix is never hostage to a ten-minute run).
#
# Required: upgrade-smoke (an existing home stays visible after an update), firstrun-smoke (an empty
# home installs the engine and shows the window), launch-window-smoke (the main window comes back
# after a relaunch). Advisory, recorded but never blocking until their false-fail rate is zero:
# game-smoke (the Sims capture, the CS:GO one-in-six escape) and, with --with-render, render-smoke
# (a long benchmark run, worth it when the engine or a renderer changed).
#
# Needs the screen unlocked: the smokes launch the app and look at its windows.
# Usage: Scripts/gate.sh [--with-render]
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=private/gate; mkdir -p "$OUT"
WITH_RENDER=0; [ "${1:-}" = "--with-render" ] && WITH_RENDER=1
COMMIT=$(git rev-parse HEAD)
git diff-index --quiet HEAD -- || echo "note: tracked files modified, so this result is for $COMMIT plus local changes" >&2

echo "gate: building dist/Highball.app from the working tree"
Scripts/make-app.sh >"$OUT/make-app.log" 2>&1 || { echo "gate: make-app failed, see $OUT/make-app.log" >&2; exit 2; }

typeset -A R T
run() {
  local name=$1; shift; local start=$(date +%s)
  if "$@" >"$OUT/$name.log" 2>&1; then R[$name]=pass; else R[$name]=fail; fi
  T[$name]=$(( $(date +%s) - start ))
  printf '  %-14s %s (%ss)\n' "$name" "${R[$name]}" "${T[$name]}"
}
echo "gate: required checks"
run upgrade Scripts/upgrade-smoke.sh --screen
run firstrun Scripts/firstrun-smoke.sh --screen
run launch-window Scripts/launch-window-smoke.sh
echo "gate: advisory checks"
run game Scripts/game-smoke.sh
[ $WITH_RENDER = 1 ] && run render Scripts/render-smoke.sh

passed=true
for n in upgrade firstrun launch-window; do [ "${R[$n]}" = pass ] || passed=false; done
json="{"
for n in ${(k)R}; do json+="\"$n\":{\"result\":\"${R[$n]}\",\"seconds\":${T[$n]}},"; done
json="${json%,}}"
HB_JSON="$json" HB_COMMIT="$COMMIT" HB_PASSED="$passed" python3 - "$OUT/latest.json" <<'PY'
import json, os, sys, time
json.dump({"passed": os.environ['HB_PASSED'] == 'true', "epoch": int(time.time()), "date": time.strftime('%Y-%m-%d'),
           "commit": os.environ['HB_COMMIT'], "required": ["upgrade", "firstrun", "launch-window"],
           "checks": json.loads(os.environ['HB_JSON'])}, open(sys.argv[1], 'w'), indent=2)
PY
if [ $passed = true ]; then echo "GATE PASSED for ${COMMIT:0:7} ($OUT/latest.json)"; else echo "GATE FAILED for ${COMMIT:0:7}: see $OUT/*.log"; exit 1; fi
