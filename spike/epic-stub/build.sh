#!/bin/bash
# Builds spike/epic-stub/EpicGamesLauncher.exe with mingw (brew install mingw-w64). make-app.sh
# runs this and ships the result in the app bundle; the source is the pinned input.
set -euo pipefail
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -s -municode -mwindows -static -o EpicGamesLauncher.exe EpicGamesLauncher.c
ls -la EpicGamesLauncher.exe | awk '{print $5, $9}'
shasum -a 256 EpicGamesLauncher.exe
