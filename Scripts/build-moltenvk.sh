#!/bin/bash
# Reproducible build of the engine's MoltenVK component: a pinned upstream tag plus Highball's
# patches, x86_64 only (the engine's Wine is x86_64 under Rosetta), packaged as the tarball the
# engine manifest points at. Usage: Scripts/build-moltenvk.sh [tag] [out-dir]
set -euo pipefail
TAG="${1:-v1.4.1}"
OUT="${2:-$(pwd)/build-moltenvk}"
PATCHES="$(cd "$(dirname "$0")/.." && pwd)/spike/patches"
WORK="$(mktemp -d)"
echo "[moltenvk] tag $TAG, work dir $WORK"
git clone -q --depth 1 --branch "$TAG" https://github.com/KhronosGroup/MoltenVK.git "$WORK/src"
cd "$WORK/src"
# Every moltenvk-*.patch in spike/patches, in name order: shadow-import (the Sims, 32-bit Vulkan
# titles) and linear-fallback (Red Dead Redemption 2's linear 3D and mipmapped images).
for PATCH in "$PATCHES"/moltenvk-*.patch; do
  case "$PATCH" in *moltenvk-shadow-imported-host-memory.patch) continue;; esac
  echo "[moltenvk] applying $(basename "$PATCH")"
  git apply --check "$PATCH" && git apply "$PATCH"
done
./fetchDependencies --macos
xcodebuild build -project MoltenVKPackaging.xcodeproj -scheme "MoltenVK Package (macOS only)" \
  -destination "generic/platform=macOS" -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO -quiet
DYLIB="$(find Package/Release -name libMoltenVK.dylib -path '*macOS*' | head -1)"
test -f "$DYLIB"
for MARK in "HIGHBALL shadow-import" "HIGHBALL linear-fallback"; do
  strings "$DYLIB" | grep -q "$MARK" || { echo "patch missing from build: $MARK"; exit 1; }
done
mkdir -p "$OUT/pkg" && cp "$DYLIB" "$OUT/pkg/libMoltenVK.dylib"
NAME="moltenvk-${TAG#v}-shadow-import-1-linear-fallback-1-x86_64.tar.gz"
tar -czf "$OUT/$NAME" -C "$OUT/pkg" libMoltenVK.dylib
echo "[moltenvk] $OUT/$NAME"
echo "  sha256: $(shasum -a 256 "$OUT/$NAME" | awk '{print $1}')"
echo "  size:   $(stat -f %z "$OUT/$NAME")"
