# Environment reference

Paths, commands, and traps for investigating a Highball bug.

## Where things live

| What | Path |
|---|---|
| App data root | `~/Library/Application Support/Highball/` |
| Bottles (Wine prefixes) | `.../Highball/bottles/<name>/` |
| Engines | `.../Highball/engines/<engine-id>/` |
| Run logs | `.../Highball/logs/<stamp>-<bottle>-<program>.log` |
| Recipes and game database | sibling checkout `../highball-db/` |

Every run log starts with two `#` lines (engine, bottle, renderer, full argv) and ends with
`# exit=N (…) after Ns`. Read the last line first.

## Commands

```bash
swift build && swift test                    # from the repo root
.build/debug/highball bottle list
.build/debug/highball run <bottle> 'C:\path\to\app.exe' --verbose -- <args>
.build/debug/highball recipe apply <bottle> ../highball-db/recipes/<kind>/<id>.json
.build/debug/highball bottle kill <bottle>   # stop the wineserver before poking a prefix
```

`highball run` always exits 0. Assert on its output, never on `$?`.

## Smoke tests

Prove a capability in seconds instead of installing something large.

```bash
# 32-bit Windows support (most installers are 32-bit; fails when syswow64 is unpopulated)
.build/debug/highball run <bottle> 'C:\windows\syswow64\cmd.exe' --verbose -- /c ver

# 64-bit counterpart, to isolate which half is broken
.build/debug/highball run <bottle> 'C:\windows\system32\cmd.exe' --verbose -- /c ver

# prefix halves: a healthy win64 prefix has hundreds of files in both
ls "$B/drive_c/windows/system32" | wc -l
ls "$B/drive_c/windows/syswow64" | wc -l
```

Source games accept console commands through Steam, which makes them scriptable:
`-applaunch <appid> -novid +map <mapname>`.

## Traps

**Stale builds.** After changing a struct in HighballKit, run `swift package clean`. Stale
incremental builds produce phantom test failures against the old memory layout. A debug
print that does not appear is the tell.

**msync mismatch.** A bottle whose wineserver was started by the Steam UI pin runs with
`WINEMSYNC=0`. Any later wine command built from the bottle's normal environment joins that
server and dies at `msync_init`, silently. Run `bottle kill` first.

**Windows paths in `ps`.** Steam-spawned processes appear with backslash paths. Grep for
both forms, and exclude your own watcher (`grep -v` the shell) or it matches itself.

**Screenshots.** `screencapture` returns a black frame when the display is locked. Check
luminance before trusting an image. Capture a single window with `screencapture -o -l <id>`
rather than the whole screen. Never run two bottle GUI tests at once - windows from every
bottle share the same `wine` process name.

**Long runs.** Hold the machine awake with `caffeinate -dims` for anything over a few
minutes; sleep kills background agents and wine sessions mid-test.

**Uninterruptible wine processes.** A wine process wedged in a kernel wait (`UE` in `ps`)
ignores SIGKILL and clears on its own. It belongs to a dead session and blocks nothing.

## CI

Nightly E2E runs on the two newest hosted macOS images and prints the real product and
build version it tested (`tested on macOS X (BUILD)`). Read that line before claiming a
macOS version is covered: image labels lag the point release users are on, and there is no
hosted runner for the newest macOS. For that window, user reports are the only signal.
