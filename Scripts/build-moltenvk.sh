#!/bin/bash
# Reproducible build of the engine's MoltenVK component: a pinned upstream tag plus Highball's
# patches, x86_64 only (the engine's Wine is x86_64 under Rosetta), packaged as the tarball the
# engine manifest points at. Usage: Scripts/build-moltenvk.sh [tag] [out-dir]
set -euo pipefail
TAG="${1:-v1.4.1}"
OUT="${2:-$(pwd)/build-moltenvk}"
PATCH="$(cd "$(dirname "$0")/.." && pwd)/spike/patches/moltenvk-shadow-import.patch"
WORK="$(mktemp -d)"
echo "[moltenvk] tag $TAG, work dir $WORK"
git clone -q --depth 1 --branch "$TAG" https://github.com/KhronosGroup/MoltenVK.git "$WORK/src"
cd "$WORK/src"
git apply --check "$PATCH" && git apply "$PATCH"
./fetchDependencies --macos
xcodebuild build -project MoltenVKPackaging.xcodeproj -scheme "MoltenVK Package (macOS only)" \
  -destination "generic/platform=macOS" -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO -quiet
DYLIB="$(find Package/Release -name libMoltenVK.dylib -path '*macOS*' | head -1)"
test -f "$DYLIB"
strings "$DYLIB" | grep -q "HIGHBALL shadow-import" || { echo "patch missing from build"; exit 1; }
mkdir -p "$OUT/pkg" && cp "$DYLIB" "$OUT/pkg/libMoltenVK.dylib"
NAME="moltenvk-${TAG#v}-shadow-import-1-x86_64.tar.gz"
tar -czf "$OUT/$NAME" -C "$OUT/pkg" libMoltenVK.dylib
echo "[moltenvk] $OUT/$NAME"
echo "  sha256: $(shasum -a 256 "$OUT/$NAME" | awk '{print $1}')"
echo "  size:   $(stat -f %z "$OUT/$NAME")"
