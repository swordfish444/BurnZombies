# Computer-wide validation

Validated on macOS 15.8.1 / Apple Silicon. Version 0.4 removes the dependency on an active chat: one resident observer samples across projects and sessions, and its own schedule dispatches bounded reviews through an installed harness.

## Verified

- 21 native checks include impact-period accounting, model/effort migration and persistence, first-review dispatch without chat events, changed-state coalescing, stale-signal refusal, persistent failure pause, no provider fallback, inert legacy hooks and cross-project process visibility.
- Impact filters use local completion dates: Today starts at midnight, 7 days includes today and the previous six dates, and All time uses retained lifetime totals. Regression cases cover both daylight-saving transitions, time zones, midnight rollover, out-of-order receipts, legacy receipts, empty history and period-aware previews. Offscreen SwiftUI rendering verifies that changing periods actually changes the displayed counters immediately; new burns within a period retain their animation.
- Existing execution safeguards cover 32 real OS zombies with eight live controls, 4,096 mixed mechanical safety scenarios, exact identities, unknown IPC-peer refusal, corrupt storage and active-work preservation.
- Real Codex and Claude CLI tests use the production `MachineReviewer.execute` path, not interactive chats. Three real Node workers are created in separate project directories before the background review. Each model selects the two completed/cancelled disposable jobs from controller-provided lifecycle evidence, preserves the active job, and produces two verified exit receipts after the native watch. No test targets unrelated user work.
- Native setup tests cover five providers, private configuration only, idempotent setup, provider pinning and cancellation of a TERM-resistant reviewer group while an unrelated active process survives.
- Settings tests cover draft/save/reopen, default reset, invalid-input refusal, preservation of disabled reviews, and offscreen rendering of the native SwiftUI controls. Five-provider subprocess captures verify that saved model/effort selections reach the actual review worker; no model is invoked by those tests.
- MCP protocol and compatibility tests cover live status/inspection, strict arguments, protected identities, invalid preview refusal, quiet legacy callbacks and EOF shutdown.

## Boundaries

The observer sees visible processes owned by the logged-in user across the computer. It does not gain root authority or stop restricted OS services or other users' processes. A broad process inventory is not proof that a process is abandoned.

Live background-model cleanup is verified for Codex and Claude. Cursor, Copilot and Gemini have launch/configuration adapters, but live execution is not verified on this machine. Their permissions may prevent unattended cleanup; there is no blanket bypass. Default setup selects one provider and never switches after a failure.

The public 0.4 installer launched the real menu bar observer without opening a window or taking focus. Automatic Codex reviews ran independently of chats. The ongoing 24-hour real-workload trial has not yet demonstrated naturally occurring cleanup; its first reviews preserved uncertain work and reported a denied supplemental process-inspection command. Controlled-fixture cleanup proof is separate from that trial. Settings rendering and save/reopen behavior are exercised offscreen; foreground mouse/keyboard interaction remains untested under the operator's no-focus restriction.

Universal packaging supports arm64 and x86_64; execution is tested on Apple Silicon only. Releases are ad-hoc signed, not notarized. Source tests and local packages do not by themselves establish a published release; public installer verification is a separate delivery check.

## Reproduce without displaying an app

```sh
scripts/test.sh --integration
python3 scripts/test-machine-setup.py
python3 scripts/test-mcp.py
python3 scripts/test-harness-install.py
.build/debug/BurnZombiesApp --impact-proof /tmp/bz-impact-proof
scripts/build-app.sh --universal
COPYFILE_DISABLE=1 tar -czf /tmp/BurnZombies-test.tar.gz -C dist BurnZombies.app
python3 scripts/test-install.py /tmp/BurnZombies-test.tar.gz
```

Real-client tests are opt-in and use existing login state, private storage and disposable workers in separate directories. Run `scripts/test-harness-e2e.py --help`; keep account outputs, process inventories and logs private. A policy refusal or no-op is not successful cleanup.
