<p align="center"><img src=".github/assets/logo.png" width="140" alt="Highball — a highball glass with ice"></p>
<h1 align="center">Highball</h1>
<p align="center"><b>Run Windows games on Apple Silicon. Free, open, engine-agnostic.</b></p>

<p align="center"><img src=".github/assets/app.png" width="760" alt="Highball showing a bottle with a verified game, renderer verdict from the open database, and one-click launcher installs"></p>

Highball is a native macOS app (and CLI) that sets up Wine, DXMT, D3DMetal and DXVK for
you, installs Steam and other launchers with one click, and tells you honestly what runs,
what doesn't, and which renderer to use — backed by an open, CC0 compatibility database
where every claim carries its provenance.

> Status: **beta**. Notarized, auto-updating, working end to end: engine install → bottle →
> Steam login → game, with per-bottle renderer switching and msync-accelerated launches.
> **[Download Highball](https://github.com/gauthierpiarrette/highball/releases/latest)** — Apple Silicon, macOS 14+.

## Design principles (learned the hard way)

This niche has a cautionary tale: [Whisky](https://github.com/Whisky-App/Whisky) was archived
in 2025 after its developer concluded it gave too little back to the Wine ecosystem it sat on.
Highball is built around that lesson:

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

## Install

**[Download Highball](https://github.com/gauthierpiarrette/highball/releases/latest)**, drag it
to Applications, open it. The app walks you through the rest — engine download, your first
bottle, Steam. Requires Apple Silicon and macOS 14+ (it prompts for Rosetta 2 if needed).

<details><summary>Prefer the terminal? The CLI does everything the app does.</summary>

```sh
git clone https://github.com/gauthierpiarrette/highball-db ../highball-db  # recipes + game database (CC0)
swift build -c release
.build/release/highball engine install spike/engine-manifest.json
.build/release/highball engine accept x64-sikarugir10.0_6-r0 apple-gptk-license-2023-08-17  # optional: D3DMetal
.build/release/highball bottle create play --recipe steam
.build/release/highball run play Steam
```
</details>

Everything lives in `~/Library/Application Support/Highball/`. Nothing touches `/usr` or
`/Library`; deleting that folder is a full uninstall.

## What works

*Reference test machine: Apple M1 Pro · macOS 14.6 — results on other chips welcome via `highball report`.*

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
