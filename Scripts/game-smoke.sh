#!/bin/zsh
# Game smoke: every verified title that is installed in the Gaming environment must still
# launch, show its window, and keep drawing. The "never regress" gate for games, the way
# render-smoke.sh is for renderers and upgrade-smoke.sh is for the app.
#
# For each entry in GAMES (appid, renderer, window regex, name, optional extra args): restart
# Steam under the row's renderer (a game inherits the running client's renderer), launch, wait
# for a window, then take three captures ten seconds apart and require that they differ (a
# frozen or blank window fails) and that no Wine crash dialog appeared. Records
# private/game-smoke/latest.json {passed, epoch, date, results[]}, which Scripts/release.sh
# reads (warn-only, 14-day window). Captures land in private/game-smoke/.
#
# Titles that are not installed are skipped (reported as "not installed"), so the gate only
# ever measures what this machine has; the release note says what was covered.
#
# Usage: Scripts/game-smoke.sh            (the whole table)
#        Scripts/game-smoke.sh 730 4465480 (only these appids)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HB="$ROOT/.build/debug/highball"; [ -x "$HB" ] || swift build --package-path "$ROOT" >/dev/null
H="$HOME/Library/Application Support/Highball"
ST="$H/bottles/Gaming/drive_c/Program Files (x86)/Steam/steamapps"
OUT="$ROOT/private/game-smoke"; mkdir -p "$OUT"
WINLIST="$ROOT/Scripts/winlist"   # CGWindowList helper built by Scripts/build-winlist.sh
[ -x "$WINLIST" ] || { echo "missing $WINLIST (run Scripts/build-winlist.sh)"; exit 2; }

# appid | renderer | window regex | name | extra launch args (map load etc.)
GAMES=(
  "730|dxmt|Counter-Strike 2|cs2|"
  "4465480|dxvk|Counter-Strike: Global|csgo-legacy|-novid +map de_dust2"
  "620|dxvk|PORTAL 2|portal2|"
  "400|dxvk|Portal|portal|"
  "1902490|dxvk|Aperture Desk Job|aperture|"
  "244210|d3dmetal|Assetto|assetto|"
  "230410|dxmt|Warframe|warframe|"
  "3314060|dxvk|Sims|sims|"
)
only=("$@")
results=(); passed=true
for row in "${GAMES[@]}"; do
  IFS='|' read -r appid renderer winre name extra <<< "$row"
  if [ ${#only[@]} -gt 0 ] && ! printf '%s\n' "${only[@]}" | grep -qx "$appid"; then continue; fi
  st=$(grep -E '"StateFlags"' "$ST/appmanifest_$appid.acf" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
  if [ "$st" != "4" ]; then echo "[$name] not installed"; results+=("{\"appid\":$appid,\"name\":\"$name\",\"result\":\"not installed\"}"); continue; fi
  echo "[$(date +%H:%M:%S)] $name ($appid) under $renderer"
  pkill -9 -f 'Steam/steam.exe' 2>/dev/null; pkill -9 -f steamwebhelper 2>/dev/null; sleep 3
  ($HB run Gaming 'C:\Program Files (x86)\Steam\steam.exe' --renderer $renderer -- -silent > /dev/null 2>&1 &); sleep 35
  ($HB run Gaming 'C:\Program Files (x86)\Steam\steam.exe' -- -applaunch $appid $extra > "$OUT/$name.log" 2>&1 &)
  n=0; until "$WINLIST" 2>/dev/null | grep -iE "wine.*($winre)" | grep -q 'on=true' || [ $n -ge 60 ]; do sleep 3; n=$((n+1)); done
  id=$("$WINLIST" 2>/dev/null | grep -iE "wine.*($winre)" | grep on=true | head -1 | awk '{print $1}')
  if [ -z "$id" ]; then echo "  FAIL: no window within $((n*3))s"; results+=("{\"appid\":$appid,\"name\":\"$name\",\"result\":\"no window\"}"); passed=false
  else
    # Capture three frames ten seconds apart. Prefer the per-window grab, but some games use a
    # layer-hosted (Metal) window that screencapture -l cannot image (it returns nothing/black);
    # fall back to a full-screen shot cropped to the window rect, which works for any window type.
    geo=$("$WINLIST" 2>/dev/null | grep -E "id=$id|^$id" | head -1); geo=$("$WINLIST" 2>/dev/null | awk -v id="$id" '$1==id{print $5}')
    gx=${geo%%,*}; rest=${geo#*,}; gy=${rest%% *}; wh=${geo##* }; gw=${wh%%x*}; gh=${wh##*x}
    grab(){ local out="$1"; screencapture -x -l "$id" "$out" 2>/dev/null
      # if the -l grab is missing or ~uniformly black, use full-screen + crop
      if [ ! -s "$out" ] || [ "$(sips -g pixelWidth "$out" 2>/dev/null | awk '/pixelWidth/{print $2}')" = "" ]; then
        screencapture -x "$OUT/.fs.png" 2>/dev/null
        [ -n "$gw" ] && sips --cropOffset $((gy*2)) $((gx*2)) -c $((gh*2)) $((gw*2)) "$OUT/.fs.png" --out "$out" >/dev/null 2>&1
      fi; }
    sleep 40; h=(); for k in 1 2 3; do grab "$OUT/$name-$k.png"; h+=("$(md5 -q "$OUT/$name-$k.png" 2>/dev/null)"); sleep 10; done
    crash=$("$WINLIST" 2>/dev/null | grep -iE 'Program Error|Wine Debugger' | grep -c on=true)
    if [ "$crash" -gt 0 ]; then echo "  FAIL: crash dialog"; results+=("{\"appid\":$appid,\"name\":\"$name\",\"result\":\"crash dialog\"}"); passed=false
    elif [ "${h[1]}" = "${h[2]}" ] && [ "${h[2]}" = "${h[3]}" ]; then echo "  FAIL: window frozen or blank (3 identical captures)"; results+=("{\"appid\":$appid,\"name\":\"$name\",\"result\":\"frozen\"}"); passed=false
    else echo "  ok: window after ~$((n*3))s, drawing"; results+=("{\"appid\":$appid,\"name\":\"$name\",\"result\":\"ok\",\"windowAfter\":$((n*3))}"); fi
  fi
  pkill -9 -f -iE "steamapps/common/[^ ]*($winre|$name)" 2>/dev/null; pkill -9 -f winedbg 2>/dev/null; sleep 2
  # kill the game by its window-owning wine process if still up (generic)
  for p in $(ps -axo pid,command | grep -E 'steamapps/common' | grep -vE 'grep|steam\.exe|steamwebhelper|gameoverlayui' | awk '{print $1}'); do kill -9 $p 2>/dev/null; done
done
pkill -9 -f 'Steam/steam.exe' 2>/dev/null; pkill -9 -f steamwebhelper 2>/dev/null
python3 - "$OUT/latest.json" "$passed" "$(IFS=,; echo "${results[*]}")" <<'PY'
import json,sys,time
out, passed, res = sys.argv[1], sys.argv[2]=="true", sys.argv[3]
json.dump({"passed": passed, "epoch": int(time.time()), "date": time.strftime("%Y-%m-%d"),
           "engine": "shipped", "results": json.loads("["+res+"]")}, open(out,"w"), indent=2)
print("GAME SMOKE", "PASSED" if passed else "FAILED", "->", out)
PY
$passed
