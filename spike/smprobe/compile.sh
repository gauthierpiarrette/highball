#!/bin/zsh
# compile.sh <highball CLI> <bottle> <unix dir holding dxc.exe> <unix dir of this folder> <unix output dir>
# Compiles every line of tests.txt with the official dxc.exe under Wine (one cmd.exe run), into <out>/<name>.dxil
# with the disassembly beside it as <name>.txt. The blobs are signed by dxil.dll when it sits next to dxcompiler.dll.
set -e
HB=$1; BOTTLE=$2; DXC=$3; SRC=$4; OUT=$5
mkdir -p "$OUT"
w() { printf 'Z:%s' "${1//\//\\}"; }
BAT="$OUT/compile.bat"
{
  printf '@echo off\r\n'
  printf '"%s\\dxc.exe" --version\r\n' "$(w "$DXC")"
  grep -v '^#' "$SRC/tests.txt" | while read -r name target src; do
    [ -z "$name" ] && continue
    printf 'echo == %s %s %s\r\n' "$name" "$target" "$src"
    printf '"%s\\dxc.exe" -T %s -E main -Fo "%s\\%s.dxil" -Fc "%s\\%s.txt" "%s\\hlsl\\%s"\r\n' "$(w "$DXC")" "$target" "$(w "$OUT")" "$name" "$(w "$OUT")" "$name" "$(w "$SRC")" "$src"
    printf 'if errorlevel 1 echo    FAILED %s\r\n' "$name"
  done
  printf 'echo == compile.bat done\r\n'
} > "$BAT"
"$HB" run "$BOTTLE" 'C:\windows\system32\cmd.exe' --verbose -- /c "$(w "$BAT")"
ls -la "$OUT"/*.dxil
