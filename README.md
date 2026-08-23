# Highball

**Run Windows games on Apple Silicon. Free, open, engine-agnostic.**

Highball is the successor to the idea behind [Whisky](https://github.com/Whisky-App/Whisky):
a native macOS app (and CLI) that sets up Wine, DXMT, D3DMetal and DXVK for you, installs
Steam and other launchers with one click, and tells you honestly what runs, what doesn't,
and which renderer to use — backed by an open, CC0 compatibility database.

A highball is whisky made easy-drinking. Same idea.

> Status: **pre-release**. The CLI works end to end (engine install → bottle → Steam →
> game, with per-bottle renderer switching). The SwiftUI app is in progress.

## Why Highball exists when Whisky died

Whisky's developer archived it in 2025 after concluding it repackaged CodeWeavers' work
while giving "practically zero" back to Wine. Highball is designed around that lesson:

- **Zero Wine patches, zero hosted binaries.** Engines are assembled from *pinned,
  SHA-256-verified* upstream releases ([Gcenx](https://github.com/Gcenx)'s builds,
  [DXMT](https://github.com/3Shain/dxmt), the
  [Sikarugir](https://github.com/Sikarugir-App/Sikarugir) runtime). An engine update is a
  JSON pull request, not a build pipeline.
- **The database is the product.** Recipes ("Steam needs `sync: none`; this game needs
  DXVK") are versioned CC0 data anyone can use — including CrossOver users. Nothing like
  it exists in the open today.
- **Additive to the ecosystem.** Bugs go upstream, donations links point at Gcenx and
  DXMT, and if you want commercial-grade support you should buy
  [CrossOver](https://www.codeweavers.com/crossover) — it funds most of Wine's Mac work.

## Install (CLI, today)

Requires Apple Silicon, macOS 14+, Rosetta 2 (`softwareupdate --install-rosetta`).

```sh
swift build -c release
.build/release/highball engine install spike/engine-manifest.json
.build/release/highball engine accept x64-sikarugir10.0_6-r0 apple-gptk-license-2023-08-17  # optional: D3DMetal
.build/release/highball bottle create play --recipe steam
.build/release/highball run play steam
```

Everything lives in `~/Library/Application Support/Highball/`. Nothing touches `/usr` or
`/Library`; deleting that folder is a full uninstall.

## What works (verified 2026-08-23, M1 Pro, macOS 14.6)

| | |
|---|---|
| Steam 64-bit client | ✅ login, store, downloads (`sync: none` required — see the recipe) |
| Aperture Desk Job | ✅ DXVK correct ~31 fps · ⚠️ D3DMetal fast but corrupted · ❌ DXMT black screen |
| Renderer switching | ✅ per bottle and per pinned program, no reinstall |
| 32-bit programs | ✅ via Wine WoW64 (Steam's own 32-bit bootstrapper ran) |
| Kernel anti-cheat (Valorant, Fortnite, Destiny 2…) | ❌ structurally impossible — flagged in the DB before you download 80 GB |

## Architecture in one paragraph

`highball` (CLI) and the app are thin views over **HighballKit**: an *engine* is a
manifest-defined bundle (Wine + runtime dylibs + renderer overlays) laid out under
`engines/<id>`; a *bottle* is a `WINEPREFIX` plus `bottle.json`; renderers (WineD3D /
DXMT / D3DMetal / DXVK) are directory overlays selected per launch via
`WINEDLLPATH_PREPEND`; *recipes* are declarative JSON steps (installer, registry,
winetricks, sync, renderer, pin, note) applied to a bottle. D3DMetal is gated behind
explicit acceptance of Apple's Game Porting Toolkit license and is never redistributed in
this repository.

## Contributing

- **Reports**: run something, then `highball report <bottle> "<title>" --rating N` — it
  opens a pre-filled issue on [highball-db](https://github.com/gauthierpiarrette/highball-db). Accepted reports are folded into `db/reports/` by CI.
- **Recipes**: PRs to [highball-db](https://github.com/gauthierpiarrette/highball-db) `recipes/` with the CLI output attached. Every recipe carries
  `lastVerified` (engine id, macOS, chip) so stale data is visible, not silently wrong.
- **Engines**: manifest PRs bumping pinned versions, with a verification note.

## Licensing

App + CLI + HighballKit: **GPL-3.0** ([LICENSE](LICENSE)). Recipes and database:
**CC0-1.0** (in [highball-db](https://github.com/gauthierpiarrette/highball-db)). Wine is LGPL; DXMT is MIT/LGPL; DXVK is
Zlib; D3DMetal is Apple-licensed (non-commercial, downloaded separately, never modified).
Highball has no paid tier and never will — that's a license requirement, not a promise.

## Credits

Standing on: [Wine](https://winehq.org) · [Gcenx](https://github.com/Gcenx) (the entire
free Mac Wine supply chain) · [3Shain's DXMT](https://github.com/3Shain/dxmt) ·
[Sikarugir](https://github.com/Sikarugir-App/Sikarugir) · Apple's Game Porting Toolkit ·
[Whisky](https://github.com/Whisky-App/Whisky), whose honesty about its own limits shaped
this design.
