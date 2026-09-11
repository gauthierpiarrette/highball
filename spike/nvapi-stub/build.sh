#!/bin/bash
# Builds the 32-bit NVAPI stub as an engine component (one file, extracted to engine/lib/wine/i386-windows/nvapi.dll),
# stamped with Wine's builtin marker so the loader hands it to a 32-bit game that asks the
# system directory for nvapi.dll (NVIDIA's SDK loads it from there, never from the game folder).
# Needs Homebrew mingw-w64. Usage: spike/nvapi-stub/build.sh [out-dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$(pwd)/build-nvapi-stub}"; mkdir -p "$OUT/pkg"
CC=/opt/homebrew/bin/i686-w64-mingw32-gcc
"$CC" -shared -O2 -nostdlib -o "$OUT/pkg/nvapi.dll" "$HERE/nvapi.c" "$HERE/nvapi.def" -Wl,--kill-at -Wl,-e,_DllMain@12 -lkernel32
python3 "$ROOT/Scripts/mark-builtin.py" "$OUT/pkg/nvapi.dll"
grep -a -q "HIGHBALL NVAPI stub" "$OUT/pkg/nvapi.dll"
NAME="nvapi-stub-2-i386.tar.gz"
tar -czf "$OUT/$NAME" -C "$OUT/pkg" nvapi.dll
echo "[nvapi-stub] $OUT/$NAME"; echo "  sha256: $(shasum -a 256 "$OUT/$NAME" | awk '{print $1}')"; echo "  size:   $(stat -f %z "$OUT/$NAME")"
