#!/bin/zsh
# Build the msync-fixed wineserver and ntdll.so for the Sikarugir Wine 10.0 engines as one archive:
# dist/wine10-msync-<tag>.tar.xz holds both at its top level, and two manifest components lay them
# over engine/bin/wineserver and engine/lib/wine/x86_64-unix/ntdll.so once the Wine archive has
# unpacked (order 1). Same method as Scripts/build-winemac-focus.sh: this Sikarugir revision has no
# public source, so the fix goes in as byte edits to Gcenx's own binaries, each checked against the
# bytes it replaces, and a Wine archive with any other file stops the build.
#
# The fault (highball#224): a wait on several objects registers the thread with the wineserver's
# msync thread, then spins until the server answers. When an object became available during the
# spin, ntdll returned without telling the server, and the server kept the thread on every
# object's list; a registration that met a signaled object at index i also left objects 0..i-1
# registered when i was 1. Nothing took those entries off again, so an object that is rarely
# signaled grew by one list node per lost race: the pool ran out ("msync: warn: node memory pool
# exhausted" on every allocation after that) and the wineserver grew until the Mac ran out of
# memory. The same change in source form, against CrossOver 26.3's newer msync, is
# highball-engine's patches/0014-msync-unregister-early-return.patch.
# Usage: Scripts/build-wine10-msync.sh [tag]   -> prints the archive's sha256 and size
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-$(date +%Y%m%d)}"
WINE_URL=https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz
WINE_SHA=9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2
SERVER_SHA=6dfe1f9d2d8a67cc6a09a57966f5ef88fd461abe7321d6fb0d4a1672e8ff0350
NTDLL_SHA=8eae29d1f367cdb32932a03b62d8503c7035dc2e783c638fb7bc69be85ab04e2
OUT=dist/wine10-msync; rm -rf "$OUT"; mkdir -p "$OUT/out" dist

# The engine installer's download cache has the archive on any Mac that installed the default engine.
ARCHIVE="$HOME/Library/Application Support/Highball/downloads/WS12WineSikarugir10.0_6.tar.xz"
if [[ ! -f "$ARCHIVE" || "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$WINE_SHA" ]]; then
  ARCHIVE=dist/WS12WineSikarugir10.0_6.tar.xz
  [[ -f "$ARCHIVE" ]] || curl -fL --retry 3 -o "$ARCHIVE" "$WINE_URL"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" == "$WINE_SHA" ]] || { echo "the Wine archive's checksum is not $WINE_SHA" >&2; exit 1; }

tar -xJf "$ARCHIVE" -C "$OUT" wswine.bundle/bin/wineserver wswine.bundle/lib/wine/x86_64-unix/ntdll.so
SERVER="$OUT/wswine.bundle/bin/wineserver"
NTDLL="$OUT/wswine.bundle/lib/wine/x86_64-unix/ntdll.so"
[[ "$(shasum -a 256 "$SERVER" | cut -d' ' -f1)" == "$SERVER_SHA" ]] || { echo "wineserver is not the build these offsets were read from" >&2; exit 1; }
[[ "$(shasum -a 256 "$NTDLL" | cut -d' ' -f1)" == "$NTDLL_SHA" ]] || { echo "ntdll.so is not the build these offsets were read from" >&2; exit 1; }

python3 - "$SERVER" "$OUT/out/wineserver" "$NTDLL" "$OUT/out/ntdll.so" <<'EOF'
import sys
# (file offset, bytes there now, bytes written, what it does). __TEXT maps at file offset 0 in both
# (vmaddr 0x100000000 for wineserver, 0 for ntdll.so), so an offset plus that base is the address a
# disassembler prints.
FILES = [
    (sys.argv[1], sys.argv[2], [
        (0x1f762, '4983fd02', '4983fd01',
         'mach_message_pump: a registration that meets a signaled object at index i unregisters '
         'objects 0..i-1 whenever i > 0 (was i > 1, which left object 0 registered)'),
    ]),
    (sys.argv[3], sys.argv[4], [
        (0x2557a, '31d24183fd010f856b010000b803010000f6c1010f84e1010000',
                  '8b7dc44c89f64489eae808020000b803010000e9e301000090 90'.replace(' ', ''),
         'msync_wait_multiple: when an object becomes available while the registration is in '
         'flight, call server_remove_wait(msgh_id, objs, count) at 0x25790 and return '
         'STATUS_PENDING, as the timeout path at 0x25753 does, instead of lowering the waiter '
         'counts by hand and leaving the server holding the registration'),
    ]),
]
for src, dst, edits in FILES:
    b = bytearray(open(src, 'rb').read())
    for off, old, new, why in edits:
        old_b, new_b = bytes.fromhex(old), bytes.fromhex(new)
        assert len(old_b) == len(new_b), f'{off:#x}: an edit must keep the length'
        found = bytes(b[off:off + len(old_b)])
        if found != old_b:
            sys.exit(f'{off:#x}: expected {old}, found {found.hex()}')
        b[off:off + len(new_b)] = new_b
        print(f'{off:#x}  {old} -> {new}  {why}')
    open(dst, 'wb').write(b)
EOF

# Ad-hoc, like the originals, under the originals' identifiers.
for f in wineserver ntdll.so; do
  ORIG=$([[ $f == wineserver ]] && echo "$SERVER" || echo "$NTDLL")
  ID=$(codesign -dv "$ORIG" 2>&1 | sed -n 's/^Identifier=//p')
  chmod 755 "$OUT/out/$f"
  codesign -f -s - -i "$ID" "$OUT/out/$f"
  codesign -v "$OUT/out/$f"
  echo "$f sha256 $(shasum -a 256 "$OUT/out/$f" | cut -d' ' -f1)"
done
tar -C "$OUT/out" -cJf "dist/wine10-msync-$TAG.tar.xz" wineserver ntdll.so
echo "dist/wine10-msync-$TAG.tar.xz sha256 $(shasum -a 256 "dist/wine10-msync-$TAG.tar.xz" | cut -d' ' -f1) size $(stat -f %z "dist/wine10-msync-$TAG.tar.xz")"
