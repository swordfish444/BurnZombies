#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
git rev-parse HEAD
test_dirty_entries="$(git status --porcelain=v1 | wc -l | tr -d ' ')"
printf 'Working-tree changes: %s\n' "$test_dirty_entries"
git status --porcelain=v1
shasum -a 256 .build/debug/BurnProof
test_result=0
.build/debug/BurnProof "$@" || test_result=$?
printf 'EXIT %s\n' "$test_result"
exit "$test_result"
