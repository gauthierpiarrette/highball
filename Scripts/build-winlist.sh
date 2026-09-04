#!/bin/zsh
# Builds Scripts/winlist, the CGWindowList helper the smoke scripts use to find a game window
# (id, owner pid, title, frame, on-screen). Wine windows are invisible to AppleScript, so the
# screen tests key off the window server instead.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o winlist winlist.swift -framework CoreGraphics -framework Foundation 2>&1 | grep -v warning || true
[ -x winlist ] && echo "built Scripts/winlist"
