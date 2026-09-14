#!/bin/bash
# run integration checks without xcode
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product highball
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -D FRAMEGEN_STANDALONE -parse-as-library -I .build/debug \
  Tests/HighballKitTests/FrameGenerationTests.swift .build/debug/HighballKit.o \
  -o "$CHECK_DIR/check-framegen"
"$CHECK_DIR/check-framegen"
