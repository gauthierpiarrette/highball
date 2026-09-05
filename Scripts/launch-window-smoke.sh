#!/bin/zsh
# Launch-window smoke (issue #58): the app must open its main window at launch even when the
# previous session ended with only the Settings window open. 0.8.0 added a Settings scene and
# macOS window restoration brought it back alone at relaunch; the library was reachable only via
# Cmd-N. This reproduces the report's shape on an empty HIGHBALL_HOME: launch, open Settings
# (Cmd-,), close the main window, quit, relaunch, and assert a main window is visible.
# Needs the screen (Accessibility permission for System Events). Records
# private/launch-window-smoke/latest.json.
#
# Usage: Scripts/launch-window-smoke.sh [path/to/Highball.app]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Highball.app}"; BIN="$APP/Contents/MacOS/Highball"
[ -x "$BIN" ] || { echo "no app at $APP (run Scripts/make-app.sh)"; exit 2; }
OUT="$ROOT/private/launch-window-smoke"; mkdir -p "$OUT"
H="${TMPDIR:-/tmp}/hb-launch-window-smoke"; rm -rf "$H"; mkdir -p "$H"
wins(){ osascript -e 'tell application "System Events" to tell process "Highball" to get name of every window' 2>/dev/null | tr -d '\n'; }
record(){ python3 -c "import json,time;json.dump({'passed':'$1'=='true','epoch':int(time.time()),'date':time.strftime('%Y-%m-%d'),'windows':'$2'},open('$OUT/latest.json','w'),indent=2)"; }
pkill -f "$BIN" 2>/dev/null; sleep 1
HIGHBALL_HOME="$H" "$BIN" >/dev/null 2>&1 & sleep 6
osascript -e 'tell application "Highball" to activate' >/dev/null 2>&1; sleep 1
echo "after launch:        $(wins)"
osascript -e 'tell application "System Events" to tell process "Highball" to keystroke "," using command down' >/dev/null 2>&1; sleep 2
echo "after Cmd-,:         $(wins)"
osascript -e 'tell application "System Events" to tell process "Highball" to click button 1 of window "Highball"' >/dev/null 2>&1; sleep 1
echo "after closing main:  $(wins)"
osascript -e 'tell application "System Events" to tell process "Highball" to keystroke "q" using command down' >/dev/null 2>&1; sleep 3
pgrep -f "$BIN" >/dev/null && pkill -9 -f "$BIN"; sleep 1
HIGHBALL_HOME="$H" "$BIN" >/dev/null 2>&1 & sleep 7
w=$(wins); echo "after relaunch:      $w"
pkill -f "$BIN" 2>/dev/null; rm -rf "$H"
if echo "$w" | grep -q 'Highball'; then record true "$w"; echo "LAUNCH WINDOW SMOKE PASSED (main window present after relaunch)"; exit 0
else record false "$w"; echo "LAUNCH WINDOW SMOKE FAILED: no main window after relaunch (windows: $w)"; exit 1; fi
