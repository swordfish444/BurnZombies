# Computer-wide validation

Validated on macOS 15.8.1 / Apple Silicon. Version 0.4 removes the dependency on an active chat: one resident observer samples across projects and sessions, and its own schedule dispatches bounded reviews through an installed harness.

## Verified

- 19 native checks include first-review dispatch without chat events, changed-state coalescing, stale-signal refusal, persistent failure pause, no provider fallback, inert legacy hooks and cross-project process visibility.
- Existing execution safeguards cover 32 real OS zombies with eight live controls, 4,096 mixed mechanical safety scenarios, exact identities, unknown IPC-peer refusal, corrupt storage and active-work preservation.
- Real Codex and Claude CLI tests use the production `MachineReviewer.execute` path, not interactive chats. Three real Node workers are created in separate project directories before the background review. Each model selects the two completed/cancelled disposable jobs from controller-provided lifecycle evidence, preserves the active job, and produces two verified exit receipts after the native watch. No test targets unrelated user work.
- Native setup tests cover five providers, private configuration only, idempotent setup, provider pinning and cancellation of a TERM-resistant reviewer group while an unrelated active process survives.
- MCP protocol and compatibility tests cover live status/inspection, strict arguments, protected identities, invalid preview refusal, quiet legacy callbacks and EOF shutdown.

## Boundaries

The observer sees visible processes owned by the logged-in user across the computer. It does not gain root authority or stop restricted OS services or other users' processes. A broad process inventory is not proof that a process is abandoned.

Live background-model cleanup is verified for Codex and Claude. Cursor, Copilot and Gemini have launch/configuration adapters, but live execution is not verified on this machine. Their permissions may prevent unattended cleanup; there is no blanket bypass. Default setup selects one provider and never switches after a failure.

Desktop UI acceptance and the background launch/upgrade UI path remain untested under the operator's no-focus restriction. No app windows were opened for validation. The installed app on the test Mac remains stopped and disconnected. Native observer, dispatcher and actual model/MCP behavior are exercised without launching the GUI.

Universal packaging supports arm64 and x86_64; execution is tested on Apple Silicon only. Releases are ad-hoc signed, not notarized. Source tests and local packages do not by themselves establish a published release; public installer verification is a separate delivery check.

## Reproduce without displaying an app

```sh
scripts/test.sh --integration
python3 scripts/test-machine-setup.py
python3 scripts/test-mcp.py
python3 scripts/test-harness-install.py
scripts/build-app.sh --universal
COPYFILE_DISABLE=1 tar -czf /tmp/BurnZombies-test.tar.gz -C dist BurnZombies.app
python3 scripts/test-install.py /tmp/BurnZombies-test.tar.gz
```

Real-client tests are opt-in and use existing login state, private storage and disposable workers in separate directories. Run `scripts/test-harness-e2e.py --help`; keep account outputs, process inventories and logs private. A policy refusal or no-op is not successful cleanup.
