#!/bin/zsh
# Installs (or with --remove, removes) the launchd agent that runs the launcher nightly at
# 03:30 on this Mac, with the display kept awake for the run. The loop is deliberately light
# (one session per launcher, sign-in window only), see Scripts/launcher-nightly.sh.
#
# The agent does not run from this checkout. A launchd agent cannot read ~/Documents or
# ~/Desktop (TCC answers "Operation not permitted" to every open, which showed up as zsh's
# "can't open input file", exit 127, on the first scheduled run), while ~/Library and the rest
# of the home are readable. So the agent keeps its own clones under ~/.highball-nightly, resets
# them to origin/main, builds there and runs the nightly from there: it measures what is pushed,
# not the working tree. Result: ~/.highball-nightly/latest.json, logs in ~/.highball-nightly/log,
# per-launcher files in ~/.highball-nightly/highball/private/launcher-nightly.
# Usage: Scripts/install-nightly.sh [--remove]
set -eu
LABEL=com.highball.launcher-nightly
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
NIGHTLY="$HOME/.highball-nightly"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = --remove ]; then launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; echo "removed $LABEL (clones under $NIGHTLY kept)"; exit 0; fi
APP_URL=$(git -C "$REPO" remote get-url origin 2>/dev/null || echo https://github.com/gauthierpiarrette/highball.git)
DB_URL=$(git -C "$REPO/../highball-db" remote get-url origin 2>/dev/null || echo https://github.com/gauthierpiarrette/highball-db.git)
mkdir -p "$HOME/Library/LaunchAgents" "$NIGHTLY/log"
cat > "$NIGHTLY/run.sh" <<RUN
#!/bin/zsh
# Written by Scripts/install-nightly.sh (Highball). Resets the clones here to origin/main,
# builds, and runs Scripts/launcher-nightly.sh from the app clone; arguments go to the nightly
# (for instance --only steam). See install-nightly.sh for why this lives outside ~/Documents.
set -u
cd "$NIGHTLY" || exit 1
sync_repo() {  # <url> <dir>: clone once, then follow origin/main
  if [ -d "\$2/.git" ]; then git -C "\$2" fetch -q origin && git -C "\$2" reset -q --hard origin/main
  else git clone -q "\$1" "\$2"; fi
}
sync_repo "$APP_URL" highball && sync_repo "$DB_URL" highball-db || { echo "nightly: clone failed"; exit 1; }
cd highball || exit 1
echo "nightly: app \$(git rev-parse --short HEAD), db \$(git -C ../highball-db rev-parse --short HEAD), \$(date '+%F %T')"
swift build > build.log 2>&1 || { tail -5 build.log; echo "nightly: build failed"; exit 1; }
Scripts/build-winlist.sh
Scripts/launcher-nightly.sh "\$@"
cp private/launcher-nightly/latest.json "$NIGHTLY/latest.json" 2>/dev/null
RUN
chmod +x "$NIGHTLY/run.sh"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string><string>-dis</string>
    <string>/bin/zsh</string><string>-lc</string>
    <string>$NIGHTLY/run.sh</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$NIGHTLY/log/launcher-nightly.log</string>
  <key>StandardErrorPath</key><string>$NIGHTLY/log/launcher-nightly.err</string>
  <key>RunAtLoad</key><false/>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (03:30 daily) running from $NIGHTLY: $PLIST"
