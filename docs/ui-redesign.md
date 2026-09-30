# Highball UI redesign

Local changes on `codex/ui-redesign`. No commit, push or pull request.

## One window

`AppShell` owns a persistent sidebar and one shared navigation history. Home, Search,
Installed, Ready to download, Steam, Epic, Programs, Add games, Engines and Settings
are destinations in the same window. Settings (Command-comma), file requests,
confirmations, error recovery, licences and the activity log use the same detail column.
There are no application sheets, alerts, confirmation dialogs or popovers. Native file
pickers and Sparkle's updater retain their system interfaces.

Leaving an unresolved confirmation keeps an attention banner with a Review action.
Back restores its underlying page. Search, collection filters, selected environments
and environment-settings categories survive navigation. Command-F focuses Search.

## Home and settings

Installed games get 2:3 portrait artwork at 1.5× the adaptive download-card width and direct Play actions at the top of Home, sorted
by recent play. Featured artwork uses fit scaling, including custom images and wide fallbacks, to preserve the full picture. Below is a smaller overview of 12 owned games ready to download;
See all opens the full collection. Both card sizes keep image drops, cover controls,
Mac app creation/removal, Stop, program removal and uninstall actions.

Settings categories are Environments, Storage, Updates and Troubleshooting. Engines
has a direct sidebar destination. Environment settings groups Graphics, Display,
Compatibility, Engine, Dependencies and Advanced. Files, recovery and process tools
expand inline. Destructive confirmations wait for current work to finish.

Creation and account pages have a readable content column, generous fields, short
explanations and adjacent actions. `HBActionStyle` gives page actions consistent
rounded proportions and a clear primary action; compact system controls remain native.

## Materials and motion

`Design.swift` centralizes the palette, panel surfaces, glass, controls and motion.
Glass is reserved for controls and navigation. Content uses simple matte panels.
macOS 26 uses native Liquid Glass; macOS 14-25 falls back to system material. Compiler
guards support toolchains predating the glass API. Reduce Motion disables custom
movement and hover scaling. Reduce Transparency replaces custom glass with solid
surfaces.

Animations are short and tied to interaction or actual operation state. The redesign
adds no decorative animation timer, shader or artificial operation delay. Collection
views are lazy and Home renders a limited download overview.

## Engine changes

Installed-engine moves, download-then-move operations and bundled-engine updates expose an `EngineChange`
through the existing task lifecycle. The main detail column shows the Highball mark,
environment, source/destination engine, current stage and real download progress.
Details navigates to the activity log; Back returns to the operation. The sidebar stays
available while it runs. Completion, failure and cancellation restore the previous page.
Download cancellation is removed before Windows setup begins.

## Local review and validation

- `swift build --product HighballApp`: passed.
- `swift test`: 399 tests executed, 5 skipped, zero failures.
- `git diff --check`: passed.
- Native review uses the user's real Highball data, installed engines and library.
- Verified Home layout, same-window Settings, environment settings, game details,
  search and Back persistence, creation-page navigation and the installed-engine list.
- A source audit compared former dialog actions and game-card actions to their replacements.
- No real engine migration, game launch or deletion was performed by the agent for this review.

The runnable review bundle is `.build/ui-review/Highball.app`. It has no fixture data
path. Its Info.plist sets `HighballDisableAutomaticEngineUpdates` to prevent automatic
engine changes during visual review; manually requested engine operations remain
available. The regular packaging script does not set this flag. The installed app was
not replaced.

Older macOS rendering and comparative CPU/GPU performance have not been measured on
this host. Existing Swift concurrency warnings remain outside this UI change.
