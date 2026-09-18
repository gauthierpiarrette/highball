#!/bin/zsh
# Launcher nightly: every launcher recipe, installed into a fresh environment on the engine the
# recipe asks for, launched once up to its sign-in window, measured, then deleted. One session
# per launcher per run, never further than the sign-in window: Rockstar and Ubisoft flagged this
# machine's address after repeated scripted starts (2026-09), so the loop is deliberately light.
#
# Per launcher it records: whether the recipe applied (blocked recipes are expected-fail and
# recorded as such), the installer's exit, crash lines in the launch log, whether a window with
# the launcher's title appeared, how much of it drew (only when the screen is unlocked; a locked
# session records "locked", never a verdict), and the process-environment invariant
# (`highball bottle ps --expect`). Writes private/launcher-nightly/latest.json and one line per
# launcher on stdout. Usage: Scripts/launcher-nightly.sh [--only <id>...]
set -u
HB=${HB:-.build/debug/highball}
DB=${DB:-../highball-db/recipes/launchers}
OUT=private/launcher-nightly; mkdir -p "$OUT"
only=(); [ "${1:-}" = "--only" ] && { shift; only=("$@"); }
locked=$(ioreg -n Root -d1 2>/dev/null | grep -q 'CGSSessionScreenIsLocked"=Yes' && echo true || echo false)
winlist=Scripts/winlist; [ -x "$winlist" ] || winlist=""
results=()
for f in "$DB"/*.json; do
  id=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['id'])" "$f")
  if [ ${#only[@]} -gt 0 ] && ! printf '%s\n' "${only[@]}" | grep -qx "$id"; then continue; fi
  read -r engine pinname winre blocked <<< "$(python3 - "$f" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
pin=[s for s in r['steps'] if s['type']=='pin']
name=pin[0]['pin']['name'] if pin else ''
print((r.get('engine') or 'default').replace(' ','_'), name.replace(' ','_'), r.get('windowTitle', name.split()[0] if name else 'x').replace(' ','_'), 'yes' if r.get('blocked') else 'no')
PY
)"
  pinname=${pinname//_/ }; winre=${winre//_/ }
  b="nightly-$id"; t0=$(date +%s)
  $HB bottle delete "$b" >/dev/null 2>&1
  if [ "$blocked" = yes ]; then
    echo "[$id] blocked by its recipe (expected)"; results+=("{\"id\":\"$id\",\"result\":\"blocked\"}"); continue
  fi
  engarg=(); [ "$engine" != default ] && engarg=(--engine "$engine")
  if ! $HB bottle create "$b" "${engarg[@]}" --recipe "$f" > "$OUT/$id-install.log" 2>&1; then
    echo "[$id] install FAILED (see $OUT/$id-install.log)"; results+=("{\"id\":\"$id\",\"result\":\"install-failed\"}"); $HB bottle delete "$b" >/dev/null 2>&1; continue
  fi
  # Steam's first start is a chain of relaunches (exit 9 mid-download, exit 42 after the
  # update, then the client), fifteen minutes or more under WoW64 and Rosetta; the others
  # show their sign-in window within a minute or two.
  wait_s=90; [ "$id" = steam ] && wait_s=900
  ($HB run "$b" "$pinname" > "$OUT/$id-launch.log" 2>&1 &)
  sleep "$wait_s"
  crash=$(grep -cE 'int3|Unhandled exception|page fault' "$OUT/$id-launch.log")
  win="none"; lit="n/a"
  if [ -n "$winlist" ]; then
    # Scripts/winlist prints "<id> pid=<n> wine |<title>| x,y wxh layer=<l> on=<bool>".
    row=$($winlist 2>/dev/null | grep -E "pid=[0-9]+[[:space:]]+wine[[:space:]]" | grep -i "$winre" | head -1); [ -n "$row" ] && win="yes"
    if [ "$win" = yes ] && [ "$locked" = false ]; then
      wid=$(echo "$row" | awk '{print $1}')
      screencapture -l "$wid" -o -x "$OUT/$id.png" 2>/dev/null && lit=$(python3 -c "
from PIL import Image; im=Image.open('$OUT/$id.png').convert('RGBA'); px=list(im.getdata()); n=len(px)
print('%.2f'%(sum(1 for q in px if q[3]>200 and (q[0]+q[1]+q[2])>90)/n))" 2>/dev/null || echo "n/a")
    elif [ "$locked" = true ]; then lit="locked"; fi
  fi
  # An empty process list is a failure, not a pass: the launcher exited or never started, and
  # an invariant over nothing proves nothing.
  $HB bottle ps "$b" --expect > "$OUT/$id-ps.txt" 2>&1 && env_ok=true || env_ok=false
  if ! grep -q "	program	" "$OUT/$id-ps.txt"; then env_ok=false; win="none"; echo "[$id] no program running 90 s after launch (see $OUT/$id-launch.log)"; fi
  $HB bottle kill "$b" >/dev/null 2>&1; $HB bottle delete "$b" >/dev/null 2>&1
  echo "[$id] installed, crash lines $crash, window $win, lit $lit, env invariant $env_ok ($(( $(date +%s) - t0 ))s)"
  results+=("{\"id\":\"$id\",\"result\":\"ran\",\"crashLines\":$crash,\"window\":\"$win\",\"lit\":\"$lit\",\"envInvariant\":$env_ok}")
done
printf '{"date":"%s","epoch":%s,"locked":%s,"results":[%s]}\n' "$(date +%Y-%m-%d)" "$(date +%s)" "$locked" "$(IFS=,; echo "${results[*]}")" > "$OUT/latest.json"
echo "launcher nightly: $OUT/latest.json"
