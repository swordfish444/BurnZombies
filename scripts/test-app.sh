#!/bin/bash
# Local app, IPC, UI and installer validation. Every cleanup uses private fixtures;
# native UI proofs render without opening windows or taking the operator's focus.
set -euo pipefail
cd "$(dirname "$0")/.."
proof_artifacts="$(mktemp -d /tmp/bz-local-proof.XXXXXX)"
printf 'Local proof artifacts: %s\n' "$proof_artifacts"
proof_failures=0

step() {
  printf 'Local check: %s\n' "$*"
  if ! "$@"; then
    printf 'FAIL local check: %s\n' "$*"
    proof_failures=$((proof_failures + 1))
  fi
}

scripts/build-app.sh --debug
step .build/debug/BurnProof --worktree-native
step .build/debug/BurnProof --worktree-refresh-native
step .build/debug/BurnZombiesApp --worktree-view-proof "$proof_artifacts/worktrees"
step .build/debug/BurnZombiesApp --worktree-inventory-proof
step .build/debug/BurnZombiesApp --findings-proof "$proof_artifacts/findings.png"
step .build/debug/BurnZombiesApp --burn-pit-proof "$proof_artifacts/burn-pit"
step .build/debug/BurnZombiesApp --observer-schedule-proof
step env LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 .build/debug/BurnProof --transport
step python3 scripts/test-mcp.py
step python3 scripts/test-autopilot-mcp.py
step python3 scripts/test-disk-discovery.py
step python3 scripts/test-harness-install.py
step python3 scripts/test-lifecycle-install.py
step python3 scripts/test-machine-setup.py
step .build/debug/BurnZombiesApp --settings-proof "$proof_artifacts/settings.png"
step .build/debug/BurnZombiesApp --settings-layout-proof "$proof_artifacts/settings-layout"
step .build/debug/BurnProof --app-updates
step .build/debug/BurnZombiesApp --about-proof "$proof_artifacts/about"
step .build/debug/BurnZombiesApp --access-banner-proof "$proof_artifacts/access-banner"
# scripts/test.sh --full already covers security boundaries and every Autopilot
# native policy/process/worktree/disk/sweep/look-only group in its integration run.
step .build/debug/BurnZombiesApp --autopilot-proof "$proof_artifacts/autopilot"
step .build/debug/BurnZombiesApp --impact-proof "$proof_artifacts/impact"
step .build/debug/BurnZombiesApp --mini-proof "$proof_artifacts/mini"
step .build/debug/BurnZombiesApp --hunt-proof "$proof_artifacts/hunt"
step .build/debug/BurnZombiesApp --hunt-scene-proof "$proof_artifacts/hunt-scene"
step python3 scripts/test-install-control.py
step env COPYFILE_DISABLE=1 tar -czf "$proof_artifacts/BurnZombies-test.tar.gz" -C dist BurnZombies.app
step python3 scripts/test-install.py "$proof_artifacts/BurnZombies-test.tar.gz" --fixture-signer
printf 'Local app/IPC/UI/installer failures: %s; artifacts: %s\n' "$proof_failures" "$proof_artifacts"
[[ "$proof_failures" -eq 0 ]]
