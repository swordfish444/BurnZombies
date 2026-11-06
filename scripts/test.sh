#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# All checks run locally. Quick by default; --full adds lifecycle and app proofs.
test_full=false
if [[ $# -eq 0 ]]; then
  set -- --quick
elif [[ "$1" == --full ]]; then
  test_full=true
  shift
  set -- --integration "$@"
fi
scripts/check.sh
swift build --disable-automatic-resolution
git rev-parse HEAD
test_dirty_entries="$(git status --porcelain=v1 | wc -l | tr -d ' ')"
printf 'Working-tree changes: %s\n' "$test_dirty_entries"
git status --porcelain=v1
shasum -a 256 .build/debug/BurnProof
test_result=0
.build/debug/BurnProof "$@" || test_result=$?
if [[ "$test_result" -eq 0 && "$test_full" == true ]]; then
  scripts/test-app.sh || test_result=$?
fi
printf 'EXIT %s\n' "$test_result"
exit "$test_result"
