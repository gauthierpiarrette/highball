#!/bin/bash
# build the pinned local port
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-macos-local}"
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid tag" >&2; exit 1; }
UPSTREAM="${2:-../lsfg-vk}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
read -r PIN REPOSITORY PATCH < <(python3 - <<'PY'
import json
s=json.load(open('spike/lsfg-source.json'));print(s['commit'], s['repository'], s['patch'])
PY
)
if ! git -C "$UPSTREAM" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  UPSTREAM="$WORK/upstream"
  git clone --no-checkout "$REPOSITORY" "$UPSTREAM"
fi
mkdir -p "$WORK/src"
git -C "$UPSTREAM" archive "$PIN" | tar -xf - -C "$WORK/src"
git -C "$WORK/src" apply --check "$PWD/$PATCH"
git -C "$WORK/src" apply "$PWD/$PATCH"
PATCH_SHA="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
PORT_VERSION="macos-${PIN:0:7}-${PATCH_SHA:0:12}"
cmake -S "$WORK/src" -B "$WORK/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DLSFGVK_VERSION_OVERRIDE="$PORT_VERSION" \
  -DLSFGVK_BUILD_LAYER=ON -DLSFGVK_BUILD_CLI=OFF -DLSFGVK_BUILD_UI=OFF
ninja -C "$WORK/build" lsfg-vk-shim lsfg-vk-macos-check
ctest --test-dir "$WORK/build" --output-on-failure
DYLIB="$WORK/build/lsfg-vk-layer/libMoltenVK.dylib"
nm -gU "$DYLIB" > "$WORK/symbols"
for symbol in vkGetInstanceProcAddr vkGetDeviceProcAddr vkCreateMetalSurfaceEXT vkCreateMacOSSurfaceMVK; do
  grep -q " _$symbol$" "$WORK/symbols" || { echo "missing export: $symbol" >&2; exit 1; }
done
PKG="$WORK/pkg"
mkdir -p "$PKG/renderers/lsfg" dist
cp "$DYLIB" "$PKG/renderers/lsfg/libMoltenVK.dylib"
ln -s ../../frameworks/libMoltenVK.dylib "$PKG/renderers/lsfg/libMoltenVK.real.dylib"
cp "$WORK/src/LICENSE.txt" "$PKG/renderers/lsfg/LICENSE"
printf '%s\n' "Source: $REPOSITORY" "Commit: $PIN" "Patch SHA-256: $PATCH_SHA" "Version: $PORT_VERSION" \
  > "$PKG/renderers/lsfg/source.txt"
# keep archive metadata reproducible
python3 - "$PKG" "dist/lsfg-$TAG.tar.xz" <<'PY'
import pathlib,sys,tarfile,json,hashlib
root=pathlib.Path(sys.argv[1]);archive=pathlib.Path(sys.argv[2])
with tarfile.open(archive,'w:xz',format=tarfile.PAX_FORMAT) as tar:
    for path in sorted(root.rglob('*')):
        info=tar.gettarinfo(str(path),str(path.relative_to(root)))
        info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0;info.pax_headers={}
        if info.isfile():
            with path.open('rb') as content:tar.addfile(info,content)
        else:tar.addfile(info)
sha=hashlib.sha256(archive.read_bytes()).hexdigest()
manifest=json.load(open('spike/engine-manifest.json'))
manifest['id']='x64-sikarugir10.0_6-r3-lsfg-local'
manifest['displayName']+=' + local lsfg-vk'
manifest['components']['lsfg']={'kind':'renderer','order':1,'version':archive.stem,
    'url':archive.resolve().as_uri(),'sha256':sha,'size':archive.stat().st_size,
    'license':'CC-BY-NC-ND-4.0 (local modified build; not approved for redistribution)',
    'extract':{'subpath':'renderers/lsfg','into':'renderers/lsfg'}}
manifest.setdefault('notes',[]).append('LOCAL ONLY: uses an absolute file URL on the build machine. Do not promote this manifest to the bundled public manifest.')
output=archive.parent/'lsfg-local-engine.json';output.write_text(json.dumps(manifest,indent=2)+'\n')
print(f'{archive}: sha256 {sha}, size {archive.stat().st_size}')
print(f'Local manifest: {output}')
PY
