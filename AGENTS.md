# Agent instructions

## Local validation

Build, test and validate on the local Mac. Do not create, enable, trigger, wait for or require GitHub Actions workflows for this repository. GitHub is for source, PRs and release assets; hosted runners are not part of the development or release loop.

- Run `scripts/test.sh` for routine changes and the affected targeted proofs.
- Use `caffeinate -i -m scripts/test.sh --full` locally for broad lifecycle/security changes or releases that need full coverage. This includes the native lifecycle, worktree, transport, MCP, Settings, updater, Autopilot, UI and installer proofs. For narrow changes, use affected checks and reuse valid coverage; do not rerun the full suite for documentation, workflow removal or unrelated metadata edits. `scripts/test-app.sh` runs the app/IPC/UI/installer portion independently when only that portion needs rechecking.
- After packaging, run `python3 scripts/test-install.py dist/release/BurnZombies-macOS-universal.tar.gz` and `python3 scripts/test-app-update.py dist/BurnZombies.app` locally against the signed release.
- Reuse valid evidence for unchanged code. Repeat checks only for affected changes, failed checks or unresolved risks. Record the tested commit, macOS/architecture, results and limitations in the PR. Never run cleanup against real work or take focus for UI fixtures.
- Report native capability skips explicitly. Missing macOS process/file-handle visibility is unknown, not proof of successful cleanup; preserve the production refusal and test its safe hold. Do not weaken cleanup safeguards to make a fixture pass.

## Releases

Releases are packaged, signed, notarized and published from the maintainer's Mac, never in GitHub Actions.

### Local Apple Developer ID release pipeline (preferred)
1. **Verify signing & notarization credentials once:** run `scripts/setup-apple-signing.sh` to check for an installed `Developer ID Application` certificate and the `burnzombies-notary` Keychain profile (and follow its printed steps if either is missing).
2. **Build, sign, notarize, verify & stage all distribution channels:**
   ```sh
   caffeinate -i -m scripts/release-all.sh           # builds universal .app, notarized .dmg + .tar.gz + .mcpb, SHA256SUMS, renders Homebrew Cask & Nix Flake
   caffeinate -i -m scripts/release-all.sh --publish # also creates/updates GitHub Release and pushes Homebrew tap Cask
   ```
   `scripts/build-app.sh` automatically applies Hardened Runtime (`--options runtime --timestamp --entitlements packaging/direct/entitlements.plist`) whenever signing with a `Developer ID Application:` identity. `scripts/build-dmg.sh` creates the styled drag-to-Applications `.dmg` using `packaging/artwork/dmg-background@2x.png`.

### Legacy self-signed release identity (pre-Developer ID transition)
Every release from v0.13.0 through v0.20.0 was signed with the self-signed certificate "BurnZombies Local Signing" (SHA-1 `F6EE40DDEBB01F056DE8FC7910091F4FAC3D7B49`, SHA-256 `dbe8297fd599efa4bb942d0ebb5487e3bc27c15d7b71fadc8253da8ab1d697b9`), backed up in 1Password as "BurnZombies release signing identity" in the `skylar` vault (`scripts/release-identity.sh --legacy load`). Developer ID releases use team `7K3GR5QJRH`. The v0.20.0 updater pins the legacy certificate, so existing users need the installer once to cross the signing transition.

The maintainer uses `scripts/release-identity.sh save` to back up the dedicated Developer ID keychain to 1Password and prove restoration. Use `scripts/release-identity.sh load` to restore signing and notarization. Keep the legacy backup under its original item title.
