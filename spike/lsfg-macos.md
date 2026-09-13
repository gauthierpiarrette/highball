Local macOS frame-generation builds use the pinned base and complete port patch in
`spike/lsfg-source.json`. The script ignores uncommitted contents in the supplied upstream
checkout: it archives the pinned commit and applies only the recorded patch.

```sh
Scripts/build-lsfg.sh macos-local ../lsfg-vk
Scripts/check-framegen.sh
HIGHBALL_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk Scripts/make-app.sh debug 0.0.0-lsfg-local
```

The SDK override is needed only on this Command Line Tools installation; omit it when the
selected SDK has the SwiftUI compiler plugins it requires. The shared Swift integration checks
run through XCTest on Xcode machines and directly through `check-framegen.sh` on CLT machines.

The generated `dist/lsfg-local-engine.json` uses the local tarball's absolute file URL and verified
SHA-256. It is for this machine only. It replaces the earlier candidate that pointed at a 404;
no unavailable component has been added to the bundled public manifest. The engine installer
supports local component URLs with the same checksum checks as remote downloads.

The port is based on lsfg-vk (CC-BY-NC-ND-4.0); the component ships the upstream LICENSE and a
source fingerprint (commit + patch SHA-256) so its provenance is recorded. No release uploads are
performed by these scripts.

Frame generation works on every graphics mode. It needs the shim in the selected engine and a
readable `lsfg-vk.dll` from Lossless Scaling's Steam beta. `Bottle.environment` picks the hook:

- DXVK, vkd3d-proton: the shim stands in for `libMoltenVK.dylib` (`DYLD_LIBRARY_PATH`).
- DXMT, D3DMetal: the same dylib is inserted into the process (`DYLD_INSERT_LIBRARIES`) with
  `LSFGVK_METAL=1` and hooks `CAMetalLayer` presentation (lsfg-vk `macos/README.md`, "Metal front
  end"). The Vulkan hook stays armed as well for D3D9 titles, which run through DXVK there.
- WineD3D: `WINE_D3D_CONFIG=renderer=vulkan` puts it on MoltenVK, where the Vulkan hook applies.

D3DMetal is 64-bit only. On that mode a 32-bit D3D10/11 title used to fall to Wine's own D3D11
and fail ("Failed to initialize graphics", Absolute Drift); the dxmt overlay now follows D3DMetal
on `WINEDLLPATH_PREPEND`, so 32-bit lookups find DXMT while 64-bit ones still stop at D3DMetal.

Secondary Steam libraries are searched;
`LSFGVK_DLL_PATH` accepts Unix paths or Wine drive paths. Off/2×/3×/4× are consistent between
CLI and app. Bottle/per-launch overrides are resolved before the final launch environment.
The log header records what was requested; the shim logs a reason if it falls back at runtime.
Restart the bottle/Steam after changing settings so Steam-launched games inherit them.

The shim preserves native presentation for HDR/protected/multilayer swapchains,
multi-swapchain presents, extension payloads, and queues other than the adopted queue.
Those are safe fallback modes, not claims of working frame generation. Native graphics smoke
tests cannot certify every game or visual artifact; record actual gameplay separately.

To verify actual frame insertion, set `LSFGVK_STATS=1` and `DXVK_HUD=fps` in the bottle's
environment variables, and enable the Metal performance HUD. Restart the bottle/Steam.
The upper-left DXVK counter reports the game's frame rate; the Metal HUD reports
presentation FPS. On this Mac's 60 Hz display, a 2× test should show roughly 30 and 60.
On the Metal modes the stats line says "metal presents on this layer" and the count of
original frames per second is the game's rate. `LSFGVK_METAL_DUMP=<dir>` in the bottle's
environment writes the frames around the 90th original as PPM files to look at.

Verified 2026-09-13/14 on the M2 Air, 2× on the 60 Hz panel, `LSFGVK_STATS=1`, generated ==
original in every case: Absolute Drift (32-bit, D3D11) on DXVK, DXMT and D3DMetal (served by
32-bit DXMT there); Valheim (64-bit, D3D11) on D3DMetal (Metal HUD: Game Porting Toolkit 3.0)
and on WineD3D's Vulkan renderer. vkd3d-proton is not installed in this engine and was not run.
The shim additionally logs successful original/generated present counts by process ID
every 60 original frames. At 2×, `original=60 generated=60 total=120` confirms it submitted
an extra generated frame per original. A lone 60 FPS counter does not prove frame generation.
These checks establish frame insertion, not visual quality or lower input latency.
