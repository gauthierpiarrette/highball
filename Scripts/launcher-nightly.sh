#!/bin/zsh
# Launcher nightly: every launcher recipe, installed into a fresh environment on the engine the
# recipe asks for, launched once up to its sign-in window, measured, then deleted. One session
# per launcher per run, never further than the sign-in window: Rockstar and Ubisoft flagged this
# machine's address after repeated scripted starts (2026-09), so the loop is deliberately light.
#
# Per launcher it records: whether the recipe applied (blocked recipes are expected-fail and
# recorded as such), the installer's exit, crash lines in the launch log, whether a window with
# owned by one of the environment's processes appeared, how much of it drew (only when the screen
# is unlocked and this process may capture it; a locked session records "locked", a process
# without Screen Recording access "no-screen-access", never a verdict), and the process-environment
# invariant (`highball bottle ps --expect`). Writes private/launcher-nightly/latest.json and one
# line per launcher on stdout. Scheduled by Scripts/install-nightly.sh, which runs it from a clone
# under ~/.highball-nightly. Usage: Scripts/launcher-nightly.sh [--only <id>...]
set -u
HB=${HB:-.build/debug/highball}
DB=${DB:-../highball-db/recipes/launchers}
OUT=private/launcher-nightly; mkdir -p "$OUT"
only=(); [ "${1:-}" = "--only" ] && { shift; only=("$@"); }
locked=$(ioreg -n Root -d1 2>/dev/null | grep -q 'CGSSessionScreenIsLocked"=Yes' && echo true || echo false)
winlist=Scripts/winlist; [ -x "$winlist" ] || winlist=""
# A recipe without an engine pin runs on the app's default engine (spike/engine-manifest.json),
# not on the CLI's "newest installed": on the maintainer's Mac that was r6 (2026-09-19), which
# is opt-in and not what a new user gets.
DEFAULT_ENGINE=$(python3 -c "import json;print(json.load(open('spike/engine-manifest.json'))['id'])" 2>/dev/null)
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
  [ "$engine" = default ] && [ -n "$DEFAULT_ENGINE" ] && engine=$DEFAULT_ENGINE
  engarg=(); [ "$engine" != default ] && engarg=(--engine "$engine")
  # A recipe may pin an engine this Mac has not installed (EA app pins r4, 2026-09-19). The app
  # downloads it before Play; the nightly does the same from the bundled manifest, so the
  # engine download path is exercised too and a missing engine is not counted as a failure.
  if [ "$engine" != default ] && ! $HB engine list 2>/dev/null | grep -q "^$engine	"; then
    if [ -f "spike/engines/$engine.json" ]; then
      echo "[$id] installing engine $engine first"
      $HB engine install "spike/engines/$engine.json" --accept-d3dmetal-license > "$OUT/$id-engine-install.log" 2>&1 || { echo "[$id] engine install FAILED (see $OUT/$id-engine-install.log)"; results+=("{\"id\":\"$id\",\"result\":\"engine-install-failed\"}"); continue; }
    else
      echo "[$id] recipe engine $engine is not bundled"; results+=("{\"id\":\"$id\",\"result\":\"engine-unknown\"}"); continue
    fi
  fi
  # A launcher's installer may be interactive (Rockstar opens a language dialog and waits for a
  # person, 2026-09-19), which is right for the app's flow and endless here. The install gets
  # ten minutes; past that the installer's window title is recorded as the result and the run
  # moves on, so the nightly stays bounded and says exactly where the recipe needs a hand.
  ( $HB bottle create "$b" "${engarg[@]}" --recipe "$f" > "$OUT/$id-install.log" 2>&1; echo $? > "$OUT/$id-install.rc" ) &
  ipid=$!; rm -f "$OUT/$id-install.rc"; it=0
  while [ ! -f "$OUT/$id-install.rc" ] && [ $it -lt 600 ]; do sleep 10; it=$((it+10)); done
  if [ ! -f "$OUT/$id-install.rc" ]; then
    ipids=$($HB bottle ps "$b" 2>/dev/null | awk -F'\t' '$1 ~ /^[0-9]+$/ {print $1}' | paste -sd'|' -)
    title=$( [ -n "$winlist" ] && [ -n "$ipids" ] && $winlist 2>/dev/null | grep -E "pid=($ipids)[[:space:]]" | grep "on=true" | grep -v "||" | head -1 | cut -f4 | tr -d '|' )
    echo "[$id] installer still running after ${it}s, waiting for a person (window: ${title:-none})"
    results+=("{\"id\":\"$id\",\"result\":\"install-waits\",\"window\":\"${title:-none}\"}")
    $HB bottle kill "$b" >/dev/null 2>&1; kill $ipid 2>/dev/null; sleep 3; $HB bottle delete "$b" >/dev/null 2>&1; continue
  fi
  if [ "$(cat "$OUT/$id-install.rc")" != "0" ]; then
    echo "[$id] install FAILED (see $OUT/$id-install.log)"; results+=("{\"id\":\"$id\",\"result\":\"install-failed\"}"); $HB bottle delete "$b" >/dev/null 2>&1; continue
  fi
  # Steam's first start is a chain of relaunches (exit 9 mid-download, exit 42 after the
  # update, then the client), so the launcher is sampled every 20 s up to a deadline rather than
  # checked once: a launcher that comes up and then quits (Steam's client stalled and died after
  # three minutes on 2026-09-19) is recorded as "exited after N s", never as "nothing ran".
  wait_s=90; [ "$id" = steam ] && wait_s=900
  ($HB run "$b" "$pinname" > "$OUT/$id-launch.log" 2>&1 &)
  win="none"; lit="n/a"; env_ok=false; seen=false; exited="null"; t=0
  while [ $t -lt $wait_s ]; do
    sleep 20; t=$((t+20))
    $HB bottle ps "$b" --expect > "$OUT/$id-ps.tick" 2>&1 && tick_ok=true || tick_ok=false
    if grep -q "	program	" "$OUT/$id-ps.tick"; then
      seen=true; env_ok=$tick_ok; cp "$OUT/$id-ps.tick" "$OUT/$id-ps.txt"
    elif [ "$seen" = true ]; then exited=$t; break
    else continue
    fi
    [ "$win" = yes ] && continue
    pids=$(awk -F'\t' '$1 ~ /^[0-9]+$/ {print $1}' "$OUT/$id-ps.txt" | paste -sd'|' -)
    [ -n "$winlist" ] && [ -n "$pids" ] || continue
    # Scripts/winlist prints "<id> pid=<n> wine |<title>| x,y wxh layer=<l> on=<bool>". The window
    # is matched by its owner's pid, one of this environment's processes, never by title: titles
    # need Screen Recording access, which a launchd agent does not have (winlist then reports
    # screen-access=false on stderr, and a capture would be blank).
    row=$($winlist 2>"$OUT/$id-winlist.err" | grep -E "pid=($pids)[[:space:]]+wine[[:space:]]" | grep "on=true" | head -1)
    [ -n "$row" ] || continue
    win="yes"; access=$(grep -o 'screen-access=[a-z]*' "$OUT/$id-winlist.err" | cut -d= -f2)
    if [ "$locked" = true ]; then lit="locked"
    elif [ "$access" = false ]; then lit="no-screen-access"
    else
      wid=$(echo "$row" | awk '{print $1}')
      screencapture -l "$wid" -o -x "$OUT/$id.png" 2>/dev/null && lit=$(python3 -c "
from PIL import Image; im=Image.open('$OUT/$id.png').convert('RGBA'); px=list(im.getdata()); n=len(px)
print('%.2f'%(sum(1 for q in px if q[3]>200 and (q[0]+q[1]+q[2])>90)/n))" 2>/dev/null || echo "n/a")
    fi
  done
  rm -f "$OUT/$id-ps.tick"
  crash=$(grep -cE 'int3|Unhandled exception|page fault' "$OUT/$id-launch.log")
  # Nothing ever running is a failure, not a pass: an invariant over nothing proves nothing.
  if [ "$seen" = false ]; then env_ok=false; echo "[$id] no program running within $wait_s s of the launch (see $OUT/$id-launch.log)"
  elif [ "$exited" != null ]; then echo "[$id] launcher exited after $exited s"; fi
  $HB bottle kill "$b" >/dev/null 2>&1; $HB bottle delete "$b" >/dev/null 2>&1
  echo "[$id] installed, crash lines $crash, window $win, lit $lit, env invariant $env_ok, exited after $exited ($(( $(date +%s) - t0 ))s)"
  results+=("{\"id\":\"$id\",\"result\":\"ran\",\"crashLines\":$crash,\"window\":\"$win\",\"lit\":\"$lit\",\"envInvariant\":$env_ok,\"programSeen\":$seen,\"exitedAfter\":$exited}")
done
printf '{"date":"%s","epoch":%s,"locked":%s,"results":[%s]}\n' "$(date +%Y-%m-%d)" "$(date +%s)" "$locked" "$(IFS=,; echo "${results[*]}")" > "$OUT/latest.json"
echo "launcher nightly: $OUT/latest.json"
