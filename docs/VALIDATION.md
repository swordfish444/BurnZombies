# Computer-wide validation

Validated on macOS 15.8.1 / Apple Silicon. Version 0.4 removes the dependency on an active chat: one resident observer samples across projects and sessions, and its own schedule dispatches bounded reviews through an installed harness.

## Verified

- 22 native checks include impact-period accounting, model/effort migration and persistence, first-review dispatch without chat events, changed-state coalescing, stale-signal refusal, persistent failure pause, no provider fallback, inert legacy hooks and cross-project process visibility.
- Impact filters use local completion dates: Today starts at midnight, 7 days includes today and the previous six dates, and All time uses retained lifetime totals. Regression cases cover both daylight-saving transitions, time zones, midnight rollover, out-of-order receipts, legacy receipts, empty history and period-aware previews. Offscreen SwiftUI rendering verifies that changing periods actually changes the displayed counters immediately; new burns within a period retain their animation.
- Existing execution safeguards cover 32 real OS zombies with eight live controls, 4,096 mixed mechanical safety scenarios, exact identities, unknown IPC-peer refusal, corrupt storage and active-work preservation.
- Version 0.6 live Codex and Claude tests have a working agent perform a real report calculation, register helpers while active and release only the completed job. A separate production reviewer reads the saved evidence after an observer restart, gracefully stops that helper, and verifies one receipt after the native watch. The retained follow-up helper and unrelated uncertain helper survive. The controller supplies fixture scope, not completed-job labels. Codex's successful run used natural task instructions without an explicit skill invocation; Claude's run explicitly loaded the skill.
- Codex's successful reviewer used four MCP calls: status, inspect, preview and burn. Native child identities removed its dependency on a denied supplemental `ps` call. Older shell-only working-agent tests hit the normal sandbox boundary; the default installer now connects MCP. Python.app fixtures remained protected rather than weakening application safety to make a test pass.
- Lifecycle checks cover private capabilities, persisted owner claims, shared-consumer protection, stale identities, active parent protection, a retain arriving after preview, failed storage writes and redacted readback. MCP tests enforce the reviewer-only tool surface and its call budget.
- Native setup tests cover five providers, preservation of unrelated settings and hooks, parsed Codex TOML with conflict refusal, portable skill installation, idempotent setup, provider pinning and cancellation of a TERM-resistant reviewer group while an unrelated active process survives.
- The compact menu renders at 360 × 550 points. Offscreen OCR checks verify readable labels, the footer, an empty first-use state, populated impact, paused reviews, a quiet day with earlier history, and cleanups without a speed measurement. These fixtures never start an observer or write live history.
- Settings tests cover draft/save/reopen, default reset, invalid-input refusal, preservation of disabled reviews, and offscreen rendering of the native SwiftUI controls. Five-provider subprocess captures verify that saved model/effort selections reach the actual review worker; no model is invoked by those tests.
- MCP protocol and compatibility tests cover live status/inspection, strict arguments, protected identities, invalid preview refusal, quiet legacy callbacks and EOF shutdown.

## Worktree validation (0.7)

Real isolated Git fixtures exercise creation, owner release/retain, dirty/staged/untracked/ignored files, locks, assume-unchanged entries, changed/unpushed HEAD, symlinks, open-file consumers, unknown workspaces, private tokens, preview reuse, new ignored output after preview, interrupted receipts and period totals. The positive deletion test uses a scoped simulated complete-consumer observation on hosts where macOS hides handles; Git removal, persistence, free-space measurement, commit retention and restoration are real. This is not proof of production-wide handle visibility.

On the development Mac, the production native reader and actual MCP server **refused removal** because Apple services and a large VM descriptor table prevent complete inspection. The checkout remained intact. The operator explicitly selected this strict behavior. No incomplete-visibility override is exposed through settings, CLI or MCP, and no existing/Codex-managed worktree can be adopted. Live unattended worktree cleanup has not been demonstrated on that Mac. The GitHub macOS runner completed the actual production MCP create/release/preview/clean flow with the native visibility guard enabled, without the fixture visibility simulation.

Both displays expose four counters. Offscreen OCR and native click tests cover the new layout and unchanged period navigation. Worktree-only benefit states and accounting preserve zero-credit interrupted operations; no prior process cleanup is converted into disk/worktree credit.

## Boundaries

The observer sees visible processes owned by the logged-in user across the computer. It does not gain root authority or stop restricted OS services or other users' processes. A broad process inventory is not proof that a process is abandoned.

Live background-model cleanup is verified for Codex and Claude. Cursor, Copilot and Gemini have launch/configuration adapters, but live execution is not verified on this machine. Their permissions may prevent unattended cleanup; there is no blanket bypass. Default setup selects one provider and never switches after a failure.

The public 0.4 installer launched the real menu bar observer without opening a window or taking focus. Automatic Codex reviews ran independently of chats. The first real-workload reviews preserved uncertain work and reported a denied supplemental process-inspection command. Later automatic reviews produced verified process-exit receipts; those remain separate from controlled fixtures and do not establish worktree-cleanup success. Controlled-fixture cleanup proof is separate from that trial. Settings rendering and save/reopen behavior are exercised offscreen; foreground mouse/keyboard interaction remains untested under the operator's no-focus restriction.

Universal packaging supports arm64 and x86_64; execution is tested on Apple Silicon only. Releases are ad-hoc signed, not notarized. Source tests and local packages do not by themselves establish a published release; public installer verification is a separate delivery check.

## Reproduce without displaying an app

```sh
scripts/test.sh --integration
.build/debug/BurnProof --worktrees
python3 scripts/test-machine-setup.py
python3 scripts/test-mcp.py
python3 scripts/test-harness-install.py
python3 scripts/test-lifecycle-install.py
.build/debug/BurnZombiesApp --impact-proof /tmp/bz-impact-proof
.build/debug/BurnZombiesApp --mini-proof /tmp/bz-mini-proof
scripts/build-app.sh --universal
COPYFILE_DISABLE=1 tar -czf /tmp/BurnZombies-test.tar.gz -C dist BurnZombies.app
python3 scripts/test-install.py /tmp/BurnZombies-test.tar.gz
```

Real-client tests are opt-in and use existing login state, private storage and disposable workers in separate directories. Run `scripts/test-lifecycle-e2e.py --help` for ownership-to-cleanup proof; keep account outputs, process inventories and logs private. A policy refusal or no-op is not successful cleanup.

## Passive observation, usage and disk tuning (0.8)

The native regression suite and integration watch pass on Apple Silicon: real kernel zombies, live controls, 4,096 safety scenarios and three disposable process cleanups remain covered. New fixtures cover passive Codex/Claude turn completion, exact session/process binding, resumed/missing/truncated-session refusal, cache-aware per-model accounting, cumulative-event deduplication, unknown usage, DST, 1–30 day filters and persistence.

An actual Codex app-server review at the existing default model with Low thinking completed one status call against an empty private fixture. It reported 21,063 input tokens (15,232 cached) and 83 output tokens. This is a bounded live usage/protocol check, not proof of real-workload cleanup or a promised per-review cost. The optional protocols for all five providers pass mocked configuration/selection/cancellation tests; no new live Cursor, Copilot or Gemini proof is claimed.

Disk fixtures exercise exact regenerable permission, ignored versus tracked scope, protected descendants, Git locks, newest-run retention, sensitive/special-file refusal, active/unknown visibility, policy changes between preview and removal, single-use tokens, untouched source, verified bytes and separate worktree counts. Successful generated-output deletion uses an isolated complete-visibility fixture. Production native visibility still refuses disk removal on the development Mac; real folders were not deleted to obtain a passing test.

Offscreen native Settings rendering verifies collapsed defaults, range/model selection, hourly/daily charts, durable cost snapshots, disk presets and policy persistence. It neither activates the app nor invokes a model. Foreground pointer interaction is not claimed. The shared reviewer admits only new evidence, has a one-hour minimum interval and preserves its existing daily bounds. Installer-owned global lifecycle instructions are retired by verified hash; customized files are preserved.
