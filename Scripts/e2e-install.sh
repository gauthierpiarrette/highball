#!/bin/bash
# Fresh-install E2E guard. Replays the bug classes that actually shipped:
# winetricks pin drift broke every fresh install (#27/#28), fresh engines shipped
# broken runtime symlinks (0.7.9), and the winetricks/bash chain died under SIP (#16).
# Installs the engine the way a real user gets it — from the BUILT APP BUNDLE's
# manifest, winetricks fetched live — into an isolated HIGHBALL_HOME, then audits.
#
# Usage: Scripts/e2e-install.sh [--with-dotnet48] [--db <highball-db checkout>]
# Env:   HIGHBALL_HOME (default $HOME/hb-e2e). Everything except downloads/ and
#        xdg-cache/ is wiped at start; those two persist so CI can cache them
#        (every reused download is sha256-reverified by the app / by winetricks).
set -euo pipefail
cd "$(dirname "$0")/.."

WITH_DOTNET=0; DB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-dotnet48) WITH_DOTNET=1 ;;
    --db) DB="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

export HIGHBALL_HOME="${HIGHBALL_HOME:-$HOME/hb-e2e}"
# winetricks caches to ~/Library/Caches otherwise — keep the escape inside the home.
export XDG_CACHE_HOME="$HIGHBALL_HOME/xdg-cache"
step() { echo; echo "=== $1"; }

step "environment"
df -h / | tail -1
echo "HIGHBALL_HOME=$HIGHBALL_HOME"
mkdir -p "$HIGHBALL_HOME/downloads"
find "$HIGHBALL_HOME" -mindepth 1 -maxdepth 1 ! -name downloads ! -name xdg-cache -exec rm -rf {} +

step "build app bundle (debug, ad-hoc signed) — users install from ITS manifest, not the repo's"
Scripts/make-app.sh debug 0.0.0-e2e
MANIFEST=dist/Highball.app/Contents/Resources/engine-manifest.json
for f in "$MANIFEST" dist/Highball.app/Contents/Resources/vcrun2022.json dist/Highball.app/Contents/Resources/dotnet48.json; do
  test -f "$f" || { echo "bundle resource missing: $f"; exit 1; }
done

step "build CLI (release configuration, like shipped code)"
swift build -c release --product highball
HB=.build/release/highball

ENGINE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$MANIFEST")
ENGINE="$HIGHBALL_HOME/engines/$ENGINE_ID"
B="$HIGHBALL_HOME/bottles/e2e"
echo "engine id: $ENGINE_ID"

step "engine install from the bundled manifest (winetricks fetched live, never cached)"
rm -f "$HIGHBALL_HOME/downloads/winetricks"   # a cached copy would hide upstream drift
"$HB" engine install "$MANIFEST" | tr '\r' '\n'
"$HB" engine list
"$HB" engine list | grep -q "^$ENGINE_ID" || { echo "engine not listed after install"; exit 1; }
"$HB" engine list | grep "^$ENGINE_ID" | grep -q "dxvk" || { echo "dxvk renderer missing from listing"; exit 1; }
rm -f "$HIGHBALL_HOME/downloads/winetricks"   # and keep it out of the CI cache save

step "symlink audit (the 0.7.9 staging bug: absolute targets orphaned by the rename)"
abs=0; broken=0
while IFS= read -r -d '' l; do
  t=$(readlink "$l")
  case "$t" in /*) echo "ABSOLUTE: $l -> $t"; abs=1 ;; esac
  if [ ! -e "$l" ]; then echo "BROKEN: $l -> $t"; broken=1; fi
done < <(find "$ENGINE" -type l -print0)
[ "$abs" -eq 0 ] || { echo "absolute symlink targets found"; exit 1; }
[ "$broken" -eq 0 ] || { echo "broken symlinks found"; exit 1; }
n=$(find "$ENGINE/engine/lib" -maxdepth 1 -type l | wc -l | tr -d ' ')
[ "$n" -gt 0 ] || { echo "engine/lib has zero runtime links — linkRuntime no-op?"; exit 1; }
echo "symlinks ok: $n runtime links, none broken, none absolute"

step "bottle create (wineboot)"
"$HB" bottle create e2e

step "bare wine smoke — runtime must resolve through engine/lib with NO DYLD vars (the SIP/winetricks path)"
# Kill the create-step's wineserver first: it runs WITH the bottle's msync env, and a
# bare env-less wine against a live msync server dies on the sync-mode mismatch
# ("Server is running with WINEMSYNC but this process is not") — silently under -all.
"$HB" bottle kill e2e || true
sleep 3
st=0
out=$(WINEPREFIX="$B" WINEDEBUG=err+all "$ENGINE/engine/bin/wine" cmd.exe /c echo e2e-ok 2>&1) || st=$?
echo "$out" | grep -q 'e2e-ok' || { echo "smoke marker missing; output:"; echo "$out"; exit 1; }
if echo "$out" | grep -qi 'Library not loaded'; then echo "broken engine/lib runtime links"; exit 1; fi
[ "$st" -eq 0 ] || { echo "wine smoke exited $st"; exit 1; }
echo "wine smoke ok"

step "vcrun2022 recipe (live aka.ms fetch — its sha256 is null by design, Microsoft rotates in place)"
if [ -z "$DB" ]; then
  DB="$HIGHBALL_HOME/highball-db"
  git clone --depth 1 https://github.com/gauthierpiarrette/highball-db.git "$DB"
fi
"$HB" recipe apply e2e "$DB/recipes/tweaks/vcrun2022.json"
test -f "$B/drive_c/windows/system32/vcruntime140.dll" || { echo "vcruntime140 (x64) missing"; exit 1; }
test -f "$B/drive_c/windows/syswow64/vcruntime140.dll" || { echo "vcruntime140 (x86) missing"; exit 1; }
# NOTE: 'highball run' always exits 0 — assert on its output, never on $?.
out=$("$HB" run e2e reg --verbose -- query 'HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64' /v Installed)
echo "$out" | grep -qE 'Installed[[:space:]]+REG_DWORD[[:space:]]+0x1' || { echo "VC++ x64 marker missing:"; echo "$out"; exit 1; }
echo "$out" | grep -q 'exit=0' || { echo "reg query wine process failed:"; echo "$out"; exit 1; }
echo "vcrun2022 ok"

if [ "$WITH_DOTNET" -eq 1 ]; then
  step "dotnet48 recipe (winetricks through bash — the #16 chain; 5-40 min depending on cache)"
  "$HB" recipe apply e2e "$DB/recipes/tweaks/dotnet48.json"
  # 0x80eb1 = 528049 = .NET Framework 4.8's release id (update if the recipe ever targets a newer 4.x).
  out=$("$HB" run e2e reg --verbose -- query 'HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release)
  echo "$out" | grep -qi '0x80eb1' || { echo ".NET 4.8 marker (528049) missing:"; echo "$out"; exit 1; }
  echo "dotnet48 ok"
fi

step "teardown"
"$HB" bottle kill e2e || true
"$HB" bottle delete e2e || true
"$ENGINE/engine/bin/wineserver" -k 2>/dev/null || true
rm -rf "$HIGHBALL_HOME/engines/.$ENGINE_ID.partial"
echo
echo "E2E PASSED"
