#!/bin/zsh
# Environment invariant: a program launched from a bottle must run with the stack the bottle
# would launch it with (renderer overlay, sync mode, custom variables), and so must the Windows
# services that outlive it. Every launch bug of 2026-09-18 broke this invariant while the launch
# log's header claimed the right stack: services booted under a setup-time environment, an
# installer's agent respawning the client without the overlay, a sync mode adopted silently.
# `highball bottle ps --expect` reads the live process environments and fails on a mismatch.
#
# Cold-starts the Steam client in the Gaming environment (Steam's own pin forces sync off, so
# the check compares against what that launch asked for), then asserts. Needs no sign-in and
# no screen. Exit 0 on pass, 1 on a mismatch, 2 when the environment or engine is missing.
set -u
HB=${HB:-.build/debug/highball}
B=${1:-Gaming}
OUT=private/env-invariant; mkdir -p "$OUT"
$HB bottle list 2>/dev/null | grep -q "^$B\b" || { echo "env-invariant: no environment named $B"; exit 2; }
$HB bottle kill "$B" >/dev/null 2>&1; sleep 3
# Steam's pin (sync none for its browser) is the launch whose stack the client must carry.
($HB run "$B" "Steam" > "$OUT/steam.log" 2>&1 &)
for i in $(seq 1 30); do sleep 2; pgrep -f 'Steam.steam\.exe' >/dev/null && break; done
sleep 20
$HB bottle ps "$B" --expect > "$OUT/ps.txt" 2>&1; rc=$?
cat "$OUT/ps.txt"
$HB bottle kill "$B" >/dev/null 2>&1
if [ $rc -eq 0 ]; then echo "ENV INVARIANT PASSED for $B"; else echo "ENV INVARIANT FAILED for $B: see $OUT/ps.txt"; fi
exit $rc
