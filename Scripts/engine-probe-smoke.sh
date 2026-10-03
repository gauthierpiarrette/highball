#!/bin/zsh
# Engine probes: small Windows programs that measure one Wine-on-macOS fact an engine patch
# exists for, run through the CLI in an environment on the newest Wine 11 engine this build
# ships. A rebuilt engine that quietly loses a patch, or a patch that breaks something a game
# reads, fails here in seconds, where a game would fail an hour into a test.
#
# lasterr (patches 0011 and 0016, engine x64-crossover26.3-r11 and later): after DeleteFileW on
# a missing file, GetLastError(), TEB->LastErrorValue and %gs:0x68 must all read 2, and 1234
# after SetLastError(1234). Before 0011, %gs:0x68 on macOS was libc's TSD slot and held a heap
# pointer, which MSVC-built code (Unity's Mono) read as the error: The Last Flame's Start did
# nothing (highball#99). Then after a display call, a window and a message to it, GetLastError()
# must still be an error code, never a pointer: 0011 as shipped in r11 to r14 wrote the error
# back a second time on every user-mode callback return, and the Rockstar Games Launcher
# installer refused to install on those engines (highball-db#272; fixed by 0016 in r15). The gate
# passed on r12 for two weeks because the probe made no display call. Now it does.
#
# The probe runs on the newest x64-crossover26.3 manifest under spike/engines: the engine is
# installed when it is missing, in a throwaway environment named after it, so what is probed is
# what ships, not whatever environment happens to exist. The probe source is spike/lasterr/
# lasterr.c; it is built here with mingw when the binary is missing.
#
# Exit 0 when every probe passes, 1 on a wrong value, 3 (skipped) when mingw is absent or the
# engine cannot be installed. Needs no screen and no sign-in.
set -u
HB=${HB:-.build/debug/highball}
OUT=private/engine-probe; mkdir -p "$OUT"
PROBE=spike/lasterr/lasterr.exe
if [ ! -x "$PROBE" ] && [ ! -f "$PROBE" ]; then
  command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "engine-probe: no mingw to build $PROBE"; exit 3; }
  x86_64-w64-mingw32-gcc -O1 -o "$PROBE" spike/lasterr/lasterr.c || { echo "engine-probe: build of $PROBE failed"; exit 1; }
fi
# The newest Wine 11 manifest this build ships.
manifest=$(for f in spike/engines/x64-crossover26.3-r*.json; do n=${f##*-r}; printf '%s\t%s\n' "${n%.json}" "$f"; done | sort -n | tail -1 | cut -f2)
engine_id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$manifest")
rev=${engine_id##*-r}
[ "$rev" -ge 11 ] 2>/dev/null || { echo "engine-probe: $engine_id predates patch 0011 (lasterr not applicable)"; exit 3; }
if ! $HB engine list 2>/dev/null | cut -f1 | grep -qx "$engine_id"; then
  echo "engine-probe: installing $engine_id from $manifest"
  $HB engine install "$manifest" > "$OUT/install.txt" 2>&1 || { tail -3 "$OUT/install.txt"; echo "engine-probe: could not install $engine_id"; exit 3; }
fi
bottle="probe-$engine_id"
# One probe environment per shipped revision; the ones for earlier revisions go.
while IFS=$'\t' read -r name rest; do
  case "$name" in probe-x64-crossover26.3-r*) [ "$name" = "$bottle" ] || $HB bottle delete "$name" >/dev/null 2>&1 ;; esac
done < <($HB bottle list 2>/dev/null)
if ! $HB bottle list 2>/dev/null | cut -f1 | grep -qx "$bottle"; then
  echo "engine-probe: creating $bottle (the Windows setup takes about 90 s)"
  $HB bottle create "$bottle" --engine "$engine_id" --renderer dxmt > "$OUT/create.txt" 2>&1 || { tail -3 "$OUT/create.txt"; echo "engine-probe: could not create $bottle"; exit 1; }
fi
$HB run "$bottle" "$PWD/$PROBE" --verbose > "$OUT/lasterr.txt" 2>&1
grep -E "^(DeleteFileW|after )" "$OUT/lasterr.txt"
python3 - "$OUT/lasterr.txt" "$bottle" "$engine_id" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
where = f"{sys.argv[2]} ({sys.argv[3]})"
m1 = re.search(r'DeleteFileW ok=(\d+) GetLastError=(\d+) \(0x[0-9a-f]+\) TEB->LastErrorValue=(\d+) %gs:0x68=(\d+)', text)
m2 = re.search(r'after SetLastError\(1234\): GetLastError=(\d+) %gs:0x68=(\d+)', text)
if not (m1 and m2):
    print(f"ENGINE PROBE FAILED on {where}: lasterr printed nothing usable"); sys.exit(1)
ok, api, teb, gs = m1.groups(); api2, gs2 = m2.groups()
if (ok, api, teb, gs) != ('0', '2', '2', '2') or (api2, gs2) != ('1234', '1234'):
    print(f"ENGINE PROBE FAILED on {where}: expected 2/2/2 then 1234/1234, got {api}/{teb}/{gs} then {api2}/{gs2} (patch 0011 missing?)"); sys.exit(1)
# After a callback the value may be a code Wine set on the way (0, 1400, 5 are all seen), never
# a pointer: patch 0011 without 0016 put the thread's libc slot there, a number in the millions.
after = dict(re.findall(r'after (GetSystemMetrics|CreateWindowExW|SendMessageW): GetLastError=(\d+)', text))
if set(after) != {'GetSystemMetrics', 'CreateWindowExW', 'SendMessageW'}:
    print(f"ENGINE PROBE FAILED on {where}: the callback lines are missing ({sorted(after)})"); sys.exit(1)
bad = {k: v for k, v in after.items() if int(v) > 0xFFFF}
if bad:
    print(f"ENGINE PROBE FAILED on {where}: GetLastError returned a pointer after a window callback: {bad} (patch 0016 missing? the Rockstar installer refuses to install on this engine)"); sys.exit(1)
print(f"ENGINE PROBE PASSED on {where}: lasterr 2/2/2 and 1234/1234, after callbacks {after}")
PY
