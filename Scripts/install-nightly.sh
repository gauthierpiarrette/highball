#!/bin/zsh
# Installs (or with --remove, removes) the launchd agent that runs the launcher nightly at
# 03:30 on this Mac, with the display kept awake for the run. Logs land in private/nightly/.
# The loop is deliberately light (one session per launcher, sign-in window only), see
# Scripts/launcher-nightly.sh. Usage: Scripts/install-nightly.sh [--remove]
set -eu
LABEL=com.highball.launcher-nightly
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = --remove ]; then launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; echo "removed $LABEL"; exit 0; fi
mkdir -p "$HOME/Library/LaunchAgents" "$REPO/private/nightly"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string><string>-dis</string>
    <string>/bin/zsh</string><string>-lc</string>
    <string>cd "$REPO" &amp;&amp; swift build >/dev/null 2>&amp;1; Scripts/launcher-nightly.sh</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$REPO/private/nightly/launcher-nightly.log</string>
  <key>StandardErrorPath</key><string>$REPO/private/nightly/launcher-nightly.err</string>
  <key>RunAtLoad</key><false/>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL (03:30 daily): $PLIST"
