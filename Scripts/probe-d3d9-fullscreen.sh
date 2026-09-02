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
      -system_script heaven/unigine.cpp -sound_app null
      -video_multisample 0 -video_mode -1 -extern_define RELEASE)
DLOGS="$HIGHBALL_HOME/bottles/probe/drive_c/highball/logs"

leg(){ # name videoapp fullscreen(0|1) width height
  local name="$1" vapp="$2" fs="$3" w="$4" h="$5" verdict=WEDGE
  log "leg $name: fullscreen=$fs ${w}x${h}"
  "$HB" bottle kill probe >/dev/null 2>&1; sleep 5
  rm -f "$DLOGS"/Heaven_*.log; local D="$DLOGS/Heaven_d3d9.log"; [ "$vapp" = direct3d11 ] && D="$DLOGS/Heaven_d3d11.log"
  "$HB" run probe "$EXE" --renderer dxvk -- "${ARGS[@]}" -video_app "$vapp" -video_fullscreen "$fs" -video_width "$w" -video_height "$h" >/dev/null 2>&1 &
  for i in $(seq 1 20); do
    sleep 12
    if grep -qa "compiler threads\|Presenter: Actual swap chain" "$D" 2>/dev/null; then verdict=RENDERING; break; fi
  done
  # The game process's command line IS the exe path; the CLI wrapper's merely contains it.
  # Excluding our own binary matters: v1 sampled the Swift CLI three times (3 idle threads,
  # zero wine frames) and learned nothing.
  ps -Ao pid=,command= > "$OUT/ps-$name.txt"
  local pid; pid=$(ps -Ao pid=,command= | grep -F "Unigine/Heaven Benchmark 4.0/bin/Heaven.exe" | grep -v -e grep -e zsh -e "debug/highball" | awk '{print $1; exit}')
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

# MoltenVK 1.4.2 for the swap leg: the engine's template pins 1.4.1; if the newer dylib
# unwedges d3d9, the fix is an engine component bump.
MVK142="$HIGHBALL_HOME/downloads/mvk142"
if [ ! -f "$MVK142/libMoltenVK.dylib" ]; then
  mkdir -p "$MVK142"
  curl -fSL --retry 3 -o "$MVK142/mvk.tar" "https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar" \
    && tar -xf "$MVK142/mvk.tar" -C "$MVK142" \
    && cp "$(find "$MVK142" -name libMoltenVK.dylib -path "*macOS*" | head -1)" "$MVK142/libMoltenVK.dylib" \
    || log "WARN: MoltenVK 1.4.2 fetch failed; mvk142 leg will just re-test baseline"
fi
ENGINE_ID=$("$HB" engine list | head -1 | cut -f1)
FW="$HIGHBALL_HOME/engines/$ENGINE_ID/frameworks"
DYLD_ORIG="$FW:$FW/GStreamer.framework/Versions/1.0/lib"
setenv(){ "$HB" bottle set probe env "$1" >/dev/null 2>&1; }

# d3d11 first: the artifact discriminator. If the runner cannot render ANY Metal-backed
# API, every other verdict is noise about the VM, not about #21.
# v3 found: baseline/syncsubmit/mvk142 all WEDGE, but DXVK_LOG_LEVEL=debug RENDERED —
# a timing-sensitive race inside vkCreateDevice (wedged logs cut mid feature-dump; the
# healthy debug log continues straight into queue setup). v4 asks: does the debug pass
# repeat, and do race-targeted d3d9 options fix it at full speed?
CONF_DIR="$HIGHBALL_HOME/bottles/probe/drive_c"
useconf(){ # options... -> write probe.conf and point DXVK at it
  printf '%s\n' "$@" > "$CONF_DIR/probe.conf"
  setenv 'DXVK_CONFIG_FILE=C:\probe.conf'
}
stockconf(){ setenv 'DXVK_CONFIG_FILE=C:\highball\dxvk.conf'; }

leg baseline-a direct3d9 0 800 600
leg baseline-b direct3d9 0 800 600

setenv "DXVK_LOG_LEVEL=debug"
leg debuglog-a direct3d9 0 800 600
leg debuglog-b direct3d9 0 800 600
setenv "DXVK_LOG_LEVEL=info"

useconf "d3d9.deferSurfaceCreation = True" "dxvk.enableAsync = False"
leg defersurface direct3d9 0 800 600
useconf "dxvk.numCompilerThreads = 1" "dxvk.enableAsync = False"
leg onethread direct3d9 0 800 600
stockconf

log "verdicts:"; cat "$OUT/VERDICTS.txt"
# Exit 0 always: the probe reports, the workflow judges nothing — humans read artifacts.
exit 0
