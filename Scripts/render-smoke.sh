#!/bin/bash
# On-demand renderer smoke (the release gate's evidence). Runs Unigine Heaven in a
# scratch bottle across the renderer matrix that issue #21 taught us to cover:
#   dxmt/D3D11, dxvk/D3D11, dxvk/D3D9 with async on, dxvk/D3D9 with async off.
# Pass criterion is liveness (still rendering at T+45 s, no dyld/library failure,
# expected DXVK banner state) — a headless script cannot judge pixels; real-game
# verification stays a human job. Result lands in private/render-smoke/latest.json,
# which release.sh checks for freshness.
#
# Run it on the dev machine when convenient (windows will appear briefly).
set -euo pipefail
cd "$(dirname "$0")/.."

HEAVEN_URL="https://assets.unigine.com/d/Unigine_Heaven-4.0.exe"
HEAVEN_SHA="497865a09af205a7d2e8812bfc2dd54870216cc1e95541b63cef89a4433b0e5f"
HOLD=45
BOTTLE=rsmoke

swift build --product highball
HB=.build/debug/highball

DL="$HOME/Library/Application Support/Highball/downloads/Unigine_Heaven-4.0.exe"
if [ ! -f "$DL" ] || [ "$(shasum -a 256 "$DL" | awk '{print $1}')" != "$HEAVEN_SHA" ]; then
  echo "downloading Heaven (~260 MB, one-time)…"
  curl -fSL --retry 3 -o "$DL" "$HEAVEN_URL"
  [ "$(shasum -a 256 "$DL" | awk '{print $1}')" = "$HEAVEN_SHA" ] || { echo "Heaven installer sha mismatch"; exit 1; }
fi

"$HB" bottle delete "$BOTTLE" 2>/dev/null || true
"$HB" bottle create "$BOTTLE"
"$HB" run "$BOTTLE" "$DL" -- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
EXE="$HOME/Library/Application Support/Highball/bottles/$BOTTLE/drive_c/Program Files (x86)/Unigine/Heaven Benchmark 4.0/bin/Heaven.exe"
test -f "$EXE" || { echo "Heaven install failed"; exit 1; }
ARGS_COMMON=(-project_name Heaven -data_path ../ -engine_config ../data/heaven_4.0.cfg
             -system_script heaven/unigine.cpp -sound_app null -video_multisample 0
             -video_fullscreen 0 -video_mode -1 -video_width 800 -video_height 600 -extern_define RELEASE)

run_case() { # name renderer video_app async(0|1|-)
  local name="$1" renderer="$2" vapp="$3" async="$4" out pass=1
  echo; echo "=== $name"
  [ "$async" != "-" ] && "$HB" bottle set "$BOTTLE" dxvkasync "$async" >/dev/null
  local tmp; tmp=$(mktemp)
  "$HB" run "$BOTTLE" "$EXE" --renderer "$renderer" -- -video_app "$vapp" "${ARGS_COMMON[@]}" >"$tmp" 2>&1 &
  local shpid=$!
  sleep "$HOLD"
  if ! pgrep -qf "Heaven.exe"; then echo "FAIL: process died before T+${HOLD}s"; pass=0; fi
  "$HB" bottle kill "$BOTTLE" >/dev/null 2>&1 || true
  wait "$shpid" 2>/dev/null || true
  local log; log=$(sed -n 's/.*log: //p' "$tmp" | tail -1)
  if [ -n "$log" ] && [ -f "$log" ]; then
    if grep -qi 'Library not loaded' "$log"; then echo "FAIL: runtime dylib failure"; pass=0; fi
    case "$renderer:$async" in
      dxvk:1) grep -q 'async compiler threads' "$log" || { echo "FAIL: async expected but absent"; pass=0; } ;;
      dxvk:0) grep -q 'async compiler threads' "$log" && { echo "FAIL: async present despite toggle off"; pass=0; } ;;
    esac
    if [ "$renderer" = dxvk ]; then
      grep -q 'DXVK' "$log" || { echo "FAIL: no DXVK banner"; pass=0; }
    fi
  else
    echo "FAIL: no run log found"; pass=0
  fi
  rm -f "$tmp"
  [ "$pass" -eq 1 ] && echo "PASS: $name"
  RESULTS="$RESULTS{\"name\":\"$name\",\"pass\":$([ "$pass" -eq 1 ] && echo true || echo false)},"
  [ "$pass" -eq 1 ] || ALL=0
}

RESULTS=""; ALL=1
run_case "dxmt-d3d11"      dxmt direct3d11 "-"
run_case "dxvk-d3d11"      dxvk direct3d11 "1"
run_case "dxvk-d3d9-async" dxvk direct3d9  "1"
run_case "dxvk-d3d9-sync"  dxvk direct3d9  "0"

"$HB" bottle kill "$BOTTLE" >/dev/null 2>&1 || true
"$HB" bottle delete "$BOTTLE" || true

ENGINE_ID=$("$HB" engine list | head -1 | cut -f1)
mkdir -p private/render-smoke
python3 - "$ENGINE_ID" "$ALL" "${RESULTS%,}" <<'PY'
import json, sys, time
engine, ok, results = sys.argv[1], sys.argv[2] == "1", json.loads("[" + sys.argv[3] + "]")
json.dump({"epoch": int(time.time()), "date": time.strftime("%Y-%m-%d"), "engineId": engine,
           "passed": ok, "results": results}, open("private/render-smoke/latest.json", "w"), indent=2)
PY
echo
[ "$ALL" -eq 1 ] && echo "RENDER SMOKE PASSED (private/render-smoke/latest.json)" || { echo "RENDER SMOKE FAILED"; exit 1; }
