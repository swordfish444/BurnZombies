#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
git rev-parse HEAD
git status --porcelain=v1
shasum -a 256 .build/debug/BurnProof
.build/debug/BurnProof "$@"
