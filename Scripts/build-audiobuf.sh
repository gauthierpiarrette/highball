#!/bin/zsh
# Build the audio buffer library as an engine component: dist/audiobuf-<tag>.tar.xz holds
# libhbaudiobuf.dylib (x86_64 for Wine's processes, arm64 so an arm64 helper Wine starts can load it
# too), ad hoc signed like the engine's other libraries. The manifest lays it at
# frameworks/libhbaudiobuf.dylib, and Bottle.environment inserts it when it is there (highball#127).
# Usage: Scripts/build-audiobuf.sh [tag]   -> prints the archive's sha256 and size
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-$(date +%Y%m%d)}"
OUT=dist/audiobuf; rm -rf "$OUT"; mkdir -p "$OUT" dist
clang -arch x86_64 -arch arm64 -dynamiclib -O2 -mmacosx-version-min=14.0 -o "$OUT/libhbaudiobuf.dylib" spike/audiobuf/audiobuf.c \
  -framework AudioToolbox -framework CoreAudio
codesign -f -s - "$OUT/libhbaudiobuf.dylib"
codesign -v "$OUT/libhbaudiobuf.dylib"
lipo -info "$OUT/libhbaudiobuf.dylib"
tar -C "$OUT" -cJf "dist/audiobuf-$TAG.tar.xz" libhbaudiobuf.dylib
echo "dist/audiobuf-$TAG.tar.xz sha256 $(shasum -a 256 "dist/audiobuf-$TAG.tar.xz" | cut -d' ' -f1) size $(stat -f %z "dist/audiobuf-$TAG.tar.xz")"
