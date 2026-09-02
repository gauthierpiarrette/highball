#!/bin/bash
# Issue #21 probe: does a D3D9 fullscreen launch wedge on this macOS where windowed
# does not? Runs Heaven (no Steam needed) under the d9vk overlay, fullscreen 1920x1080
# vs windowed control, and captures a `sample` of any wedge. Designed for the macos-26
# CI runner but runs anywhere. Artifacts land in $PROBE_OUT (default ./probe-out).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${PROBE_OUT:-probe-out}"; mkdir -p "$OUT"
export HIGHBALL_HOME="${HIGHBALL_HOME:-$HOME/hb-probe}"
HB=.build/debug/highball
HEAVEN_URL="https://assets.unigine.com/d/Unigine_Heaven-4.0.exe"
HEAVEN_SHA="497865a09af205a7d2e8812bfc2dd54870216cc1e95541b63cef89a4433b0e5f"

log(){ echo "[probe] $*" | tee -a "$OUT/probe.log"; }
sw_vers | tee "$OUT/os.txt"

swift build --product highball 2>&1 | tail -2
"$HB" engine install spike/engine-manifest.json 2>&1 | tail -3

DL="$HIGHBALL_HOME/downloads/Unigine_Heaven-4.0.exe"; mkdir -p "$(dirname "$DL")"
if [ ! -f "$DL" ] || [ "$(shasum -a 256 "$DL" | awk '{print $1}')" != "$HEAVEN_SHA" ]; then
  curl -fSL --retry 3 -o "$DL" "$HEAVEN_URL"
fi
"$HB" bottle create probe 2>&1 | tail -1
"$HB" run probe "$DL" -- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- 2>&1 | tail -1
EXE="$HIGHBALL_HOME/bottles/probe/drive_c/Program Files (x86)/Unigine/Heaven Benchmark 4.0/bin/Heaven.exe"
test -f "$EXE" || { log "FATAL: Heaven install failed"; exit 1; }
ARGS=(-project_name Heaven -data_path ../ -engine_config ../data/heaven_4.0.cfg
      -system_script heaven/unigine.cpp -sound_app null -video_app direct3d9
      -video_multisample 0 -video_mode -1 -extern_define RELEASE)
D="$HIGHBALL_HOME/bottles/probe/drive_c/highball/logs/Heaven_d3d9.log"

leg(){ # name fullscreen(0|1) width height
  local name="$1" fs="$2" w="$3" h="$4" verdict=WEDGE
  log "leg $name: fullscreen=$fs ${w}x${h}"
  "$HB" bottle kill probe >/dev/null 2>&1; sleep 5
  rm -f "$D"
  "$HB" run probe "$EXE" --renderer dxvk -- "${ARGS[@]}" -video_fullscreen "$fs" -video_width "$w" -video_height "$h" >/dev/null 2>&1 &
  for i in $(seq 1 10); do
    sleep 12
    if grep -qa "compiler threads\|Presenter: Actual swap chain" "$D" 2>/dev/null; then verdict=RENDERING; break; fi
  done
  local pid; pid=$(ps -Ao pid=,command= | grep -F "Heaven.exe" | grep -v -e grep -e zsh | awk '{print $1; exit}')
  if [ -n "${pid:-}" ]; then
    sample "$pid" 10 -f "$OUT/sample-$name.txt" 2>/dev/null || true
  else
    [ "$verdict" = WEDGE ] && verdict=DIED
  fi
  cp "$D" "$OUT/d3d9-$name.log" 2>/dev/null || true
  log "leg $name VERDICT: $verdict"
  echo "$name: $verdict" >> "$OUT/VERDICTS.txt"
  "$HB" bottle kill probe >/dev/null 2>&1; sleep 3
}

leg windowed-800   0 800 600
leg fullscreen-1080 1 1920 1080
leg fullscreen-native 1 0 0

log "verdicts:"; cat "$OUT/VERDICTS.txt"
# Exit 0 always: the probe reports, the workflow judges nothing — humans read artifacts.
exit 0
