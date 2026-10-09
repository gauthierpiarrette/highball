#!/bin/sh
# Builds the three programs. sigbench and smcbench are x86_64 (they run under Rosetta), sigbench_arm64 is native.
set -e
clang -arch x86_64 -O2 -mmacosx-version-min=13.0 -o sigbench sigbench.c
clang -arch x86_64 -O2 -mmacosx-version-min=13.0 -o smcbench smcbench.c
clang -arch arm64 -O2 -mmacosx-version-min=13.0 -o sigbench_arm64 sigbench_arm64.c
echo built
