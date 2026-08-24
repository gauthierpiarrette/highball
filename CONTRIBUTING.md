# Contributing

**Ran a game?** That's the most valuable contribution: `highball report <bottle> "<title>" --rating N`
opens a pre-filled issue on [highball-db](https://github.com/gauthierpiarrette/highball-db). Chip, macOS,
engine and renderer are captured automatically.

**Recipes** (install/config knowledge) are CC0 data in highball-db — PR with the CLI output attached.
Every recipe carries `lastVerified` so stale data is visible rather than silently wrong.

**Code**: `swift build && swift test` is the whole loop; `Scripts/make-app.sh debug` builds the app
bundle. Match the style around you. By contributing you license your work under GPL-3.0 (code) or
CC0 (data).

**Engines**: manifest PRs bumping pinned SHA-256s, with a note on what you verified. Highball never
hosts binaries and never carries Wine patches — that's a design rule, not a preference.
