#!/bin/zsh
# Build the focus-fixed winemac.so for the Sikarugir Wine 10.0 engines as an engine component:
# dist/winemac-focus-<tag>.tar.xz holds winemac.so at its top level, and the manifest lays it over
# engine/lib/wine/x86_64-unix/winemac.so once the Wine archive has unpacked (order 1).
# The change itself, in source form and with the reasons, is spike/patches/winemac-sikarugir10.0-focus.patch.
# This Sikarugir revision has no public source, so it goes in as three byte edits to Gcenx's own
# binary, each checked against the bytes it replaces: a Wine archive with any other winemac.so
# stops the build instead of patching the wrong place.
# Usage: Scripts/build-winemac-focus.sh [tag]   -> prints the archive's sha256 and size
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:-$(date +%Y%m%d)}"
WINE_URL=https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_6.tar.xz
WINE_SHA=9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2
MAC_SHA=4cbf65e363d6d8b5a70dba719b50b811fb4b2705985e93f777c6cb7a12878eb0
OUT=dist/winemac-focus; rm -rf "$OUT"; mkdir -p "$OUT" dist

# The engine installer's download cache has the archive on any Mac that installed the default engine.
ARCHIVE="$HOME/Library/Application Support/Highball/downloads/WS12WineSikarugir10.0_6.tar.xz"
if [[ ! -f "$ARCHIVE" || "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" != "$WINE_SHA" ]]; then
  ARCHIVE=dist/WS12WineSikarugir10.0_6.tar.xz
  [[ -f "$ARCHIVE" ]] || curl -fL --retry 3 -o "$ARCHIVE" "$WINE_URL"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" == "$WINE_SHA" ]] || { echo "the Wine archive's checksum is not $WINE_SHA" >&2; exit 1; }

tar -xJf "$ARCHIVE" -C "$OUT" wswine.bundle/lib/wine/x86_64-unix/winemac.so
SRC="$OUT/wswine.bundle/lib/wine/x86_64-unix/winemac.so"
[[ "$(shasum -a 256 "$SRC" | cut -d' ' -f1)" == "$MAC_SHA" ]] || { echo "winemac.so is not the build these offsets were read from" >&2; exit 1; }

python3 - "$SRC" "$OUT/winemac.so" <<'EOF'
import sys
b = bytearray(open(sys.argv[1], 'rb').read())
# (file offset, bytes there now, bytes written, what it does). __TEXT maps at address 0, so a file
# offset is also the address a disassembler prints.
EDITS = [
    (0x40d87, '4883ec08', 'eb71',
     'macdrv_window_got_focus: jump past the made-up WM_MOUSEACTIVATE(HTMENU) straight to "setting foreground window" (upstream b568eaac4a)'),
    (0x193dc, '30', '20',
     'makeFocused: discard mask GOT_FOCUS|LOST_FOCUS (0x30000000) becomes LOST_FOCUS (0x20000000) (CrossOver Hack #18896)'),
    (0x1c584, '741d', '9090',
     'windowDidBecomeKey: no early return when Wine made the window key, so Wine hears about it (CrossOver Hack #18896)'),
]
for off, old, new, why in EDITS:
    old_b, new_b = bytes.fromhex(old), bytes.fromhex(new)
    found = bytes(b[off:off + len(old_b)])
    if found != old_b:
        sys.exit(f'{off:#x}: expected {old}, found {found.hex()}')
    b[off:off + len(new_b)] = new_b
    print(f'{off:#x}  {old} -> {new}  {why}')
open(sys.argv[2], 'wb').write(b)
EOF

# Ad-hoc, like the original, under the original's identifier.
ID=$(codesign -dv "$SRC" 2>&1 | sed -n 's/^Identifier=//p')
codesign -f -s - -i "$ID" "$OUT/winemac.so"
codesign -v "$OUT/winemac.so"
tar -C "$OUT" -cJf "dist/winemac-focus-$TAG.tar.xz" winemac.so
echo "winemac.so sha256 $(shasum -a 256 "$OUT/winemac.so" | cut -d' ' -f1)"
echo "dist/winemac-focus-$TAG.tar.xz sha256 $(shasum -a 256 "dist/winemac-focus-$TAG.tar.xz" | cut -d' ' -f1) size $(stat -f %z "dist/winemac-focus-$TAG.tar.xz")"
