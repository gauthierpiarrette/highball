#!/bin/bash
# Integration regression: requires an existing disposable/test Wine bottle.
# Runs only cmd.exe; does not install or launch Steam or a game.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <highball-cli> <bottle>\n' "$0" >&2
    exit 2
fi

cli=$1
bottle=$2

for expected in 0 7; do
    actual=0
    output=$(timeout 60 "$cli" run "$bottle" cmd -- /c exit "$expected" 2>&1) || actual=$?
    if [[ $actual -ne $expected ]]; then
        printf 'FAIL: Windows exit %s returned shell status %s\n%s\n' "$expected" "$actual" "$output" >&2
        exit 1
    fi
    printf 'PASS: Windows exit %s returned shell status %s\n' "$expected" "$actual"
done
