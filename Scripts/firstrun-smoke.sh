#!/bin/zsh
# First-run smoke: a brand-new user must get a working engine. Issue #57 (and #21) were
# first-run/onboarding failures where the engine tab stayed empty and creating an environment
# did nothing. Every other check assumes an engine already exists; this one starts from nothing.
#
# Installs the engine from the SHIPPED bundled manifest (the exact bytes a real first run pulls)
# into a throwaway HIGHBALL_HOME and asserts the engine lists. With --screen it also launches the
# app on an empty home, confirms it shows onboarding (no engine yet), and — because getStarted
# then downloads ~250 MB and waits ~90 s for the first boot — leaves that to a human; the
# headless half is what CI runs. Records private/firstrun-smoke/latest.json.
#
# Usage: Scripts/firstrun-smoke.sh [--screen]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HB="$ROOT/.build/debug/highball"; [ -x "$HB" ] || swift build --package-path "$ROOT" >/dev/null
MAN="$ROOT/dist/Highball.app/Contents/Resources/engine-manifest.json"
[ -f "$MAN" ] || MAN="$ROOT/spike/engine-manifest.json"
H="${FIRSTRUN_SMOKE_HOME:-${TMPDIR:-/tmp}/hb-firstrun-smoke}"; rm -rf "$H"; mkdir -p "$H"
OUT="$ROOT/private/firstrun-smoke"; mkdir -p "$OUT"
fail(){ echo "FIRSTRUN SMOKE FAILED: $*" >&2; python3 -c "import json,time;json.dump({'passed':False,'epoch':int(time.time()),'date':time.strftime('%Y-%m-%d')},open('$OUT/latest.json','w'))"; exit 1; }

echo "== engine URLs in the shipped manifest are reachable"
python3 - "$MAN" <<'PY' | while read k u; do
import json,sys
d=json.load(open(sys.argv[1]))
for k,v in d["components"].items():
    if v.get("url"): print(k, v["url"])
PY
  code=$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 30 "$u")
  [ "$code" = "200" ] || { echo "  $k: HTTP $code ($u)"; touch "$H/.urlfail"; }
  echo "  $k: HTTP $code"
done
[ -e "$H/.urlfail" ] && fail "an engine component URL is not reachable"

echo "== install the engine into an empty home (the first-run download)"
t0=$(date +%s)
HIGHBALL_HOME="$H" "$HB" engine install "$MAN" 2>&1 | tail -2 || fail "engine install errored"
echo "   took $(( $(date +%s) - t0 ))s"
HIGHBALL_HOME="$H" "$HB" engine list 2>&1 | grep -q . || fail "engine list is empty after install"
echo "   engine: $(HIGHBALL_HOME="$H" "$HB" engine list 2>&1 | head -1)"

if [ "${1:-}" = "--screen" ]; then
  APP="$ROOT/dist/Highball.app/Contents/MacOS/Highball"; WL="$ROOT/Scripts/winlist"
  E="$H/empty"; rm -rf "$E"; mkdir -p "$E"       # truly empty: no engine, must show onboarding
  pkill -f "dist/Highball.app/Contents/MacOS/Highball" 2>/dev/null; sleep 1
  HIGHBALL_HOME="$E" "$APP" >/dev/null 2>&1 &
  sleep 1; pid=$(pgrep -n -f "dist/Highball.app/Contents/MacOS/Highball")
  n=0; until "$WL" 2>/dev/null | grep -E "pid=$pid" | grep -q on=true || [ $n -ge 20 ]; do sleep 1; n=$((n+1)); done
  sleep 4; id=$("$WL" 2>/dev/null | grep -E "pid=$pid" | grep on=true | head -1 | awk '{print $1}')
  [ -n "$id" ] && screencapture -x -l "$id" "$OUT/onboarding.png" && echo "   onboarding capture: private/firstrun-smoke/onboarding.png (should offer Get Started, not an empty library)"
  kill "$pid" 2>/dev/null
fi
python3 -c "import json,time;json.dump({'passed':True,'epoch':int(time.time()),'date':time.strftime('%Y-%m-%d'),'screen':'${1:-}'=='--screen'},open('$OUT/latest.json','w'),indent=2)"
rm -rf "$H"
echo "FIRSTRUN SMOKE PASSED"
