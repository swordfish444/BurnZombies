# Contributing

Start with the [safety contract](docs/SAFETY.md) and [detection matrix](docs/DETECTION_MATRIX.md). Keep changes small and explain which evidence changes the decision.

All validation runs locally on a Mac. Do not use GitHub Actions or hosted runners for builds, tests or releases.

Run `scripts/test.sh` before opening a PR: script/version/doc checks, the build, core safety checks and Autopilot policy. Run the affected targeted proofs for the change. For broad lifecycle/security changes or a release that needs full coverage, run `caffeinate -i -m scripts/test.sh --full`: native lifecycle plus the worktree, transport, MCP, Settings, updater, Autopilot, UI and installer proofs. The app/IPC/UI/installer portion can also run independently with `scripts/test-app.sh`. Its synthetic screenshots and other artifacts stay in the private local directory printed by the script. Reuse passing evidence for unchanged code; documentation, workflow removal and unrelated metadata edits do not require another full run.

Releases are built and signed on the maintainer's Mac: `scripts/package-release.sh` builds a clean commit's downloads into `dist/release` and stops unless the app is signed with the release certificate. Validate that signed package locally with `python3 scripts/test-install.py dist/release/BurnZombies-macOS-universal.tar.gz` and `python3 scripts/test-app-update.py dist/BurnZombies.app`.

For lifecycle/action changes, add a sacrificial regression fixture. For UI changes, exercise the native view in an agreed test session and label fixture screenshots in validation notes. Never take focus during another operator task. State the tested commit, macOS/architecture, actual test duration and limitations in the PR. Never test cleanup against real work.

Build with macOS 14+ and Swift 6.2+: `scripts/build-app.sh`. Use `scripts/build-app.sh --universal` for an Apple Silicon + Intel bundle. The app's monitor has no third-party dependencies; the separate MCP executable uses the official Swift SDK and its pinned dependencies. `Package.resolved` is committed.

Every release since v0.13.0 is signed with one self-signed certificate, and macOS ties Full Disk Access to it, so a Mac that builds releases needs that same key, never a new one. The maintainer keeps it in 1Password: `scripts/release-identity.sh save` stores it from the Mac that has it, and `scripts/release-identity.sh load` installs it on another Mac without anyone approving it. [AGENTS.md](AGENTS.md) has the release steps.

Run `python3 scripts/test-machine-setup.py` for private setup, provider pinning and reviewer cancellation. `python3 scripts/test-harness-install.py` covers the optional legacy interactive integration. Run `python3 scripts/test-mcp.py` after building to exercise the actual stdio server. `scripts/test.sh --full` includes a real preview/burn/replay-refusal lifecycle through the shared agent service. Installer validation accepts a locally packaged release: `python3 scripts/test-install.py PATH_TO_ARCHIVE`.

Format Swift with `swift format format --in-place --recursive Package.swift Sources Proof`. Keep C in the small platform adapter.

New evidence or attention signals must document missing-data behavior, identity rules, overhead and protection interactions. Abandonment decisions belong to the connected harness. A signal that justifies investigation does not automatically justify termination. New automatic action categories require explicit operator authority, failure/respawn tests, and an honest verification metric. Do not add health scores, estimated time saved, or shared-memory sums presented as physical savings.

Use invented labels and paths in fixtures. Do not submit raw catalogs, process arguments, environment variables, session logs, personal paths, credentials, device identifiers, diagnostic dumps, or real customer/workspace screenshots. A minimal synthetic reproducer is preferred.

Contributions are licensed under the repository's MIT license. Report security issues privately using [SECURITY.md](SECURITY.md).
