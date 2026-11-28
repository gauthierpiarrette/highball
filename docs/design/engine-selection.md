# Environment engine selection

Status: implemented. Branch: `environment-engine-selection`.

Open [the interactive mockup](engine-selection.html) in a browser. It uses illustrative engines and local state; it does not install engines, create environments, or change the app.

## Recommendation

Make the engine a visible, explicit choice in both environment flows. Use the same chooser, names, and availability rules. Keep the default preselected when creating an environment, so creating one still takes one click after naming it.

### New environment

Order the sheet as Name → Engine → Install Steam → Create. Always show an Engine summary with its display name, exact ID, execution mode (Rosetta or native Apple silicon), and install status. A Change… button opens the shared chooser, including installed custom engines of either architecture. When only one engine is available, keep its summary and replace Change… with “No other engines are available for this Mac.”

Selecting an engine changes the draft only. Cancel restores the prior draft. Keep a selected engine pinned if changing the older-revisions filter would otherwise remove it. Choosing a downloadable engine displays “Downloads before setup” next to its size, when known. The final action becomes Download & create. A short note explains that architecture is fixed when the environment is created; other compatible engine builds can be chosen later.

### Existing environment

Add an **Engine** section immediately after Graphics in environment settings. Move engine selection out of Advanced; keep the current engine visible even when it is the only choice. Retain the short engine name in the settings header.

Show the same Engine summary and Change… action. Under it: “Changing the engine affects every program in this environment.” Picking another compatible engine opens the existing switch review, rather than saving immediately. Use Review switch… as the chooser's action so the exception to “Changes save automatically” is clear. Never change the persisted engine ID while browsing or cancelling.

The review names the old and new engine, the affected environment and programs, whether a download or Windows refresh is needed, and what stays installed. Reuse EngineTransitionSheet and EngineSwitchPlan. Switch begins work on the activity strip; closing the review keeps it running. On failure, retain the existing error and recovery flow.

## Shared chooser

Use a sheet with selectable rows instead of a long menu. Rows contain a display name, exact ID, execution mode, and Installed or Download status; sizes are optional and come from manifests. Installed custom engines appear alongside bundled engines, with a Custom label. Default marks the app's current creation default, not a promise of game compatibility; Current marks the engine assigned to an existing environment. These labels can coexist.

List the current/draft selection first, followed by installed engines and then available downloads. Use the existing numeric revision ordering within those groups. Show the latest downloadable revision per engine line and macOS requirement by default; retain all installed engines. Put Show older revisions below the list and keep it available even if the default list has one row.

For existing environments, put other architectures in a separate “Requires a new environment” group. Each row explains “This environment uses Rosetta. This engine requires a new environment.” (or the inverse) and offers **New environment…**. That action opens creation with the chosen engine preselected and an unused suggested name. It creates an independent environment; it does not transfer games, settings, saves, or Steam sign-in. Say this before Create. Keep the source environment unchanged.

Do not present a cross-architecture engine as a switch option or a disabled unexplained row. If no compatible alternative exists, say so and keep any other-architecture creation actions available. If no alternative of either kind exists, retain the current summary and an explanation instead of an empty chooser.

Engines installed through the existing CLI appear alongside the bundled engines. The Custom label identifies installed builds outside the catalog shipped with this app.

## Availability and exceptional states

| State | Proposed behavior |
| --- | --- |
| One engine available | Show its summary; explain that there are no alternatives. Keep access to older revisions. |
| Installed custom engine, same architecture | Selectable during creation and switching. Never hide it because it shares the default architecture. |
| Installed custom engine, other architecture | Selectable during creation; New environment… action for an existing environment. |
| Preview/beta engine | Respect existing channel visibility and game opt-ins. Label visible preview engines; this design does not enable hidden channels. |
| Engine requires newer macOS | Exclude unavailable downloads using existing manifest rules. For installed engines, show the requirement and prevent a new selection on an unsupported Mac. Keep an assigned unsupported engine visible with an explanation. |
| Current engine missing | Preserve its ID, label Missing, and offer supported replacements. Reuse repair/reinstall handling; never substitute another engine silently. Unknown current architecture keeps the existing backend policy. |
| No engine installed | Preserve initial setup. If creating from the chooser becomes available before setup, require an explicit downloadable default and complete its install first. |
| Busy operation | Allow inspection; disable actions that start installation, creation, or switching, with the existing busy explanation. |
| Download/install failure | Keep the prior environment engine; show the activity-strip error. Keep the draft choice available for retry. |

## Implementation outline

1. Replace the other-architecture-only `newEnvironmentAlternatives` path with shared engine choices built from installed engines and channel-visible manifests. Preserve macOS filtering, deduplication, newest-revision rules, and the current/draft selection. Carry display name, architecture, installation state, and whether an installed build is outside the shipped catalog rather than bare IDs.
2. Add a reusable SwiftUI EngineSummary and EngineChooser. Keep the selection in view-local draft state until the user confirms. Identify installed builds outside the complete bundled catalog as Custom, including engines installed through the CLI.
3. Update CreateBottleSheet to show the summary unconditionally and pass the selected ID to the existing createBottle path. Do not change the app-wide default when a user selects an engine for one environment.
4. Add `.engine` to EnvironmentSettingsSection. Route same-architecture choices through the existing EngineTransition and route other-architecture choices to creation with a preselected engine.
5. Localize new copy with the existing `L()` conventions. Use native controls, full accessible row labels, a visible selection indicator, VoiceOver announcements for selection changes, keyboard navigation, and wrapping names/IDs. Preserve cancel and default-action shortcuts.

## Acceptance checks for implementation

- Creation offers a same-architecture custom engine even when no other architecture is available.
- The default is preselected, and selecting a different engine affects only this new environment.
- Current engine remains visible when alone, missing, filtered out, or unsupported on this macOS.
- Installed custom engines of both architectures are discoverable in both flows.
- A compatible switch requires review; cancelling changes no saved settings.
- A cross-architecture action opens independent creation with that engine selected and the no-transfer explanation visible.
- Filtering revisions never hides the active draft selection; hidden channels stay hidden and unsupported downloads stay excluded.
- Download and Windows-refresh plans match the existing backend; failed work does not falsely report a completed change.
- Long names, narrow windows, keyboard-only use, and VoiceOver retain all actions and explanations.

The mockup demonstrates creation, choosing a same-architecture custom engine, reviewing a switch, and creating separately for another architecture. Progress, busy/missing/unsupported states, revision filtering, and error recovery are specified above rather than simulated.

## Validation

The app builds with Xcode 27.2 selected through `DEVELOPER_DIR`; the system-selected Command Line Tools lack the SwiftUI macro plugin. The catalog regression tests cover custom engines, both architecture directions, draft pinning, macOS requirements, missing assignments, channel filtering, metadata precedence, and unique IDs. The full XCTest suite passed against upstream main outside the execution sandbox: 902 tests, 9 skipped, zero failures. All 32 targeted engine tests passed. The sandboxed run could not exercise deep directory deletion and local Discord sockets; those checks passed without the sandbox. The localization audit found no duplicate keys, placeholder mismatches, or newline mismatches in either supported translation. Manual UI verification used an isolated app bundle and sample environments: the Engine section and creation dialog displayed their engine summaries, the shared chooser exposed a same-architecture custom engine, and cancelling the switch review preserved the assigned engine. No Wine processes, downloads, or environment changes were started.

## App screenshots

Captured from the local debug app with isolated sample environments and engine manifests.

- [New environment](screenshots/new-environment.png)
- [Shared engine chooser](screenshots/engine-chooser.png)
- [Existing environment Engine settings](screenshots/environment-engine.png)
- [Switch review](screenshots/switch-review.png)
