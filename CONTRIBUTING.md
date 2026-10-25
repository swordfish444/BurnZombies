# Contributing

Start with the [safety contract](docs/SAFETY.md) and [detection matrix](docs/DETECTION_MATRIX.md). Keep changes small and explain which evidence changes the decision.

Run `scripts/test.sh` before opening a PR. For lifecycle/action changes, also run `scripts/test.sh --integration` and add a sacrificial regression fixture. For UI changes, exercise the actual native view and include synthetic-data screenshots. State macOS/architecture, actual test duration and limitations. Never test cleanup against real work.

Build with macOS 14+ and Swift 6.2+: `scripts/build-app.sh`. Use `scripts/build-app.sh --universal` for an Apple Silicon + Intel bundle. The app's monitor has no third-party dependencies; the separate MCP executable uses the official Swift SDK and its pinned dependencies. `Package.resolved` is committed.

Run `python3 scripts/test-mcp.py` after building to exercise the actual stdio server. `scripts/test.sh --integration` includes a real preview/burn/replay-refusal lifecycle through the shared agent service. Installer validation accepts a locally packaged release: `python3 scripts/test-install.py PATH_TO_ARCHIVE`.

Format Swift with `swift format format --in-place --recursive Package.swift Sources Proof`. Keep C in the small platform adapter.

New detectors must document false positives, missing-data behavior, identity rules, retention/overhead costs, and protection interactions. A signal that justifies investigation does not automatically justify termination. New automatic action categories require explicit operator authority, failure/respawn tests, and an honest verification metric. Do not add health scores, estimated time saved, or shared-memory sums presented as physical savings.

Use invented labels and paths in fixtures. Do not submit raw catalogs, process arguments, environment variables, session logs, personal paths, credentials, device identifiers, diagnostic dumps, or real customer/workspace screenshots. A minimal synthetic reproducer is preferred.

Contributions are licensed under the repository's MIT license. Report security issues privately using [SECURITY.md](SECURITY.md).
