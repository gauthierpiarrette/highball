#!/bin/zsh
# Engine probes: small Windows programs that measure one Wine-on-macOS fact an engine patch
# exists for, run through the CLI in an environment on that engine. A rebuilt engine that
# quietly loses a patch fails here in seconds, where a game would fail an hour into a test.
#
# lasterr (patch 0011, engine x64-crossover26.3-r11 and later): after DeleteFileW on a missing
# file, GetLastError(), TEB->LastErrorValue and %gs:0x68 must all read 2, and 1234 after
# SetLastError(1234). Before 0011, %gs:0x68 on macOS was libc's TSD slot and held a heap pointer,
# which MSVC-built code (Unity's Mono) read as the error: The Last Flame's Start did nothing
# (highball#99). The probe source is spike/lasterr/lasterr.c; it is built here with mingw when
# the binary is missing.
#
# Exit 0 when every applicable probe passes, 1 on a wrong value, 3 (skipped) when no environment
# sits on an engine the probe applies to or mingw is absent. Needs no screen and no sign-in.
set -u
HB=${HB:-.build/debug/highball}
OUT=private/engine-probe; mkdir -p "$OUT"
PROBE=spike/lasterr/lasterr.exe
if [ ! -x "$PROBE" ] && [ ! -f "$PROBE" ]; then
  command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "engine-probe: no mingw to build $PROBE"; exit 3; }
  x86_64-w64-mingw32-gcc -O1 -o "$PROBE" spike/lasterr/lasterr.c || { echo "engine-probe: build of $PROBE failed"; exit 1; }
fi
# The first environment on a CrossOver-tree engine at revision 11 or later.
bottle=""
while IFS=$'\t' read -r name engine rest; do
  id=${engine#engine=}
  case "$id" in
    x64-crossover26.3-r*) rev=${id##*-r}; [ "$rev" -ge 11 ] 2>/dev/null && { bottle=$name; engine_id=$id; break; } ;;
  esac
done < <($HB bottle list 2>/dev/null)
[ -n "$bottle" ] || { echo "engine-probe: no environment on a Wine 11 engine at r11 or later (lasterr not applicable)"; exit 3; }
$HB run "$bottle" "$PWD/$PROBE" --verbose > "$OUT/lasterr.txt" 2>&1
cat "$OUT/lasterr.txt" | grep -v "^exit=\|^# exit="
python3 - "$OUT/lasterr.txt" "$bottle" "$engine_id" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m1 = re.search(r'DeleteFileW ok=(\d+) GetLastError=(\d+) \(0x[0-9a-f]+\) TEB->LastErrorValue=(\d+) %gs:0x68=(\d+)', text)
m2 = re.search(r'after SetLastError\(1234\): GetLastError=(\d+) %gs:0x68=(\d+)', text)
if not (m1 and m2):
    print(f"ENGINE PROBE FAILED on {sys.argv[2]} ({sys.argv[3]}): lasterr printed nothing usable"); sys.exit(1)
ok, api, teb, gs = m1.groups(); api2, gs2 = m2.groups()
if (ok, api, teb, gs) != ('0', '2', '2', '2') or (api2, gs2) != ('1234', '1234'):
    print(f"ENGINE PROBE FAILED on {sys.argv[2]} ({sys.argv[3]}): expected 2/2/2 then 1234/1234, got {api}/{teb}/{gs} then {api2}/{gs2} (patch 0011 missing?)"); sys.exit(1)
print(f"ENGINE PROBE PASSED on {sys.argv[2]} ({sys.argv[3]}): lasterr 2/2/2 and 1234/1234")
PY
