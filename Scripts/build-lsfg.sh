#!/bin/zsh
# builds the lsfg-metal component (rust, MIT) and packages it as renderers/lsfg for a local engine manifest
# usage: Scripts/build-lsfg.sh [tag] [path-to-lsfg-metal]
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-macos-local}"
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid tag" >&2; exit 1; }
SRC="${2:-../lsfg-metal}"
export PATH="$HOME/.cargo/bin:$PATH"
# the version is compiled into the dylib (build.rs reads LSFGM_VERSION), so it must be known before the build
# and cannot contain the dylib's own hash; the SHA-256 travels as its own line in source.txt
PORT_VERSION="lsfg-metal-$(git -C "$SRC" rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
export LSFGM_VERSION="$PORT_VERSION"
(cd "$SRC" && cargo build --release && cargo test --release)
DYLIB="$SRC/target/x86_64-apple-darwin/release/liblsfg_metal.dylib"
# exactly four exported text symbols, the names Wine dlsyms (objc2 class statics are data, not T)
SYMBOLS="$(nm -gU "$DYLIB" | awk '$2=="T"')"
COUNT="$(printf '%s\n' "$SYMBOLS" | grep -c . || true)"
[[ "$COUNT" -eq 4 ]] || { echo "expected 4 exported functions, found $COUNT:" >&2; printf '%s\n' "$SYMBOLS" >&2; exit 1; }
for symbol in vkGetInstanceProcAddr vkGetDeviceProcAddr vkCreateMetalSurfaceEXT vkCreateMacOSSurfaceMVK; do
  printf '%s\n' "$SYMBOLS" | grep -q " _$symbol\$" || { echo "missing export: $symbol" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/pkg"
mkdir -p "$PKG/renderers/lsfg" dist
cp "$DYLIB" "$PKG/renderers/lsfg/libMoltenVK.dylib"
codesign -s - -f "$PKG/renderers/lsfg/libMoltenVK.dylib"
SHA="$(shasum -a 256 "$PKG/renderers/lsfg/libMoltenVK.dylib" | awk '{print $1}')"
ln -s ../../frameworks/libMoltenVK.dylib "$PKG/renderers/lsfg/libMoltenVK.real.dylib"
cp "$SRC/LICENSE" "$PKG/renderers/lsfg/LICENSE"
printf '%s\n' "Source: https://github.com/itsOwen/lsfg-metal" "License: MIT (see LICENSE)" \
  "Dylib SHA-256: $SHA" "Version: $PORT_VERSION" \
  > "$PKG/renderers/lsfg/source.txt"
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
manifest['displayName']+=' + local lsfg-metal'
manifest['components']['lsfg']={'kind':'renderer','order':1,'version':archive.stem,
    'url':archive.resolve().as_uri(),'sha256':sha,'size':archive.stat().st_size,
    'license':'MIT',
    'extract':{'subpath':'renderers/lsfg','into':'renderers/lsfg'}}
manifest.setdefault('notes',[]).append('LOCAL ONLY: uses an absolute file URL on the build machine. Do not promote this manifest to the bundled public manifest.')
output=archive.parent/'lsfg-local-engine.json';output.write_text(json.dumps(manifest,indent=2)+'\n')
print(f'{archive}: sha256 {sha}, size {archive.stat().st_size}')
print(f'Local manifest: {output}')
PY
