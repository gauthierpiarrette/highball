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
# The patches, by name (spike/patches/moltenvk-<name>.patch), in this order: shadow-import (the Sims,
# 32-bit Vulkan titles) and linear-fallback (Red Dead Redemption 2's linear 3D and mipmapped images). The
# Wine 11 engines ship 1.4.2 with both; the Wine 10 engines ship 1.4.1 with shadow-import only, which
# MVK_PATCHES="shadow-import" builds. The package name lists the patches it carries.
read -r -a PATCH_NAMES <<< "${MVK_PATCHES:-shadow-import linear-fallback}"
for NAME_ in "${PATCH_NAMES[@]}"; do
  PATCH="$PATCHES/moltenvk-$NAME_.patch"
  echo "[moltenvk] applying $(basename "$PATCH")"
  git apply --check "$PATCH" && git apply "$PATCH"
done
./fetchDependencies --macos
xcodebuild build -project MoltenVKPackaging.xcodeproj -scheme "MoltenVK Package (macOS only)" \
  -destination "generic/platform=macOS" -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO -quiet
# The dynamic dylib, explicitly: 1.4.2's package also carries static and xcframework copies
# under Package/Release, and `find | head -1` picked one without the patch markers.
DYLIB="Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
test -f "$DYLIB"
# Read the strings once: `strings | grep -q` under pipefail failed when grep stopped reading early
# and strings died of SIGPIPE, which reads as a missing patch (2026-10-07).
MARKS="$(strings -a "$DYLIB")"
for NAME_ in "${PATCH_NAMES[@]}"; do
  grep -q "HIGHBALL $NAME_" <<< "$MARKS" || { echo "patch missing from build: $NAME_"; exit 1; }
done
mkdir -p "$OUT/pkg" && cp "$DYLIB" "$OUT/pkg/libMoltenVK.dylib"
NAME="moltenvk-${TAG#v}$(printf -- "-%s-1" "${PATCH_NAMES[@]}")-x86_64.tar.gz"
tar -czf "$OUT/$NAME" -C "$OUT/pkg" libMoltenVK.dylib
echo "[moltenvk] $OUT/$NAME"
echo "  sha256: $(shasum -a 256 "$OUT/$NAME" | awk '{print $1}')"
echo "  size:   $(stat -f %z "$OUT/$NAME")"
