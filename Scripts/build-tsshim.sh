#!/bin/zsh
# Build the D3DMetal timestamp shim (spike/tsshim) into a renderer overlay tarball for the engine
# manifest: renderers/d3dmetal-tsshim/wine/x86_64-windows/d3d12.dll, stamped as a Wine builtin so
# WINEDLLPATH_PREPEND picks it up. At launch, Highball lays the real D3DMetal d3d12.dll beside it
# as apd12.dll, export name patched to match (see InstalledEngine.timestampShimDir). Needs mingw-w64 (brew).
# Usage: Scripts/build-tsshim.sh [tag]   -> dist/d3dmetal-tsshim-<tag>.tar.xz, prints sha256 and size
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-$(date +%Y%m%d)}"
OUT=dist/tsshim; rm -rf "$OUT"; mkdir -p "$OUT/renderers/d3dmetal-tsshim/wine/x86_64-windows" dist
DLL="$OUT/renderers/d3dmetal-tsshim/wine/x86_64-windows/d3d12.dll"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -static-libgcc -o "$DLL" spike/tsshim/d3d12.c spike/tsshim/d3d12.def
python3 Scripts/mark-builtin.py "$DLL"
tar -C "$OUT" -cJf "dist/d3dmetal-tsshim-$TAG.tar.xz" renderers
echo "dist/d3dmetal-tsshim-$TAG.tar.xz sha256 $(shasum -a 256 "dist/d3dmetal-tsshim-$TAG.tar.xz" | cut -d' ' -f1) size $(stat -f %z "dist/d3dmetal-tsshim-$TAG.tar.xz")"
