#!/bin/bash
# One real Autopilot sweep against sacrificial fixtures only (temporary repositories and
# processes this script starts), using your installed harness login. Costs one short
# AI run. Usage: scripts/test-autopilot-e2e.sh [claude|codex]
set -euo pipefail
cd "$(dirname "$0")/.."
harness="${1:-claude}"
executable="$(command -v "$harness")"
executable="$(cd "$(dirname "$executable")" && pwd -P)/$(basename "$executable")"
swift build
root="$(mktemp -d "${TMPDIR:-/tmp}/bz-autopilot-e2e.XXXXXX")"
trap 'rm -rf "$root"' EXIT
.build/debug/BurnProof --autopilot-e2e "$root" "$harness" "$executable"
