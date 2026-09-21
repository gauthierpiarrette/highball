# mfstub: a Media Foundation source reader that ends at once

`mfreadwrite-stub.c` builds a native `mfreadwrite.dll` (mingw, `x86_64-w64-mingw32-gcc -shared -O1
-o mfreadwrite.dll mfreadwrite-stub.c -Wl,--kill-at -lole32`) for games whose movies deadlock inside
Wine's WMV demuxer. Placed beside the game's executable with a per-program `mfreadwrite=n,b`
override it loads as native (proven with +loaddll on the RE Village demo, 2026-09-21).

Result on Resident Evil Village (Gold Edition demo, D3DMetal, r5), three variants:
1. reader creation fails (E_FAIL): the game crashes at once (access violation at re8GEDemo+0x47E18FB,
   CrashReport folder written; its crash handler then runs msinfo32, which is the "About System
   Information" window that appears).
2. reader created, media-type queries fail, ReadSample reports end of stream on stream 0 (sync and
   through the async callback): the game draws a black frame at 115 fps and spins at 230% CPU
   forever; keys do nothing.
3. as 2 with end of stream rotating over stream indices 0..3, "no such stream" for type queries, no
   streams selected: identical to 2.

So RE Engine's movie player does not skip a movie that cannot be read; it waits for frames. The
fix for highball#154 is a demuxer that delivers them, i.e. the winegstreamer deadlock itself
(private/drafts/winehq-re-village-wmvcore.md). The stub may still serve a game that handles a
failed movie gracefully but imports mfreadwrite statically (the Caretaker's mfplat="" trick kills
such a game at load, as it did here).
