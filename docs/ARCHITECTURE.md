# Architecture

```text
Resident macOS observer ── samples all current-user processes
          │ own schedule, change coalescing, one review at a time
          ▼
Selected installed harness ── bounded background reasoning
          │ MCP: status → inspect → preview → burn
          ▼
Native evidence / identity guards / graceful stop
          │ independent exit and recurrence verification
          ▼
Private catalog ── menu-bar impact + burn log
```

Observation and scheduling belong to the computer, not a chat. One selected harness provides reasoning through a supervised, bounded invocation using its existing authentication. There is no fixed abandonment classifier or mandatory launch wrapper for user jobs. Default setup writes only BurnZombies configuration and installs no chat hooks.

## Observation and storage

One monitor owns a nonblocking private lock. It observes current-user processes every 60 seconds, or every 15 seconds while verifying a cleanup. It retains up to eight minute-spaced samples per identity. Monotonic time and wall time are separate; sampling gaps, sleep and incomplete coverage invalidate continuity.

The catalog is compressed Codable data with bounded reads/decompression, a five-minute checkpoint and immediate durable action/settings writes. Before signaling, the monitor persists intent. Only a completed verified receipt contributes impact. A crash cannot turn absent processes into labeled training examples.

The aggregate signal contains observation time, process count, RSS and pressure. A complete fresh scan can start the initial review; later resource changes have a ten-minute cooldown, with an hourly review for ownership changes that do not increase totals. A manual request is independent of chats. These are scheduling rules, never kill criteria.

`MachineReviewer` persists review intent before launching. It owns one three-minute process-group supervisor, caps output at one MiB, keeps its run directory private and removes it afterward. Completion does not stop observation or receipt verification. Errors, quota failures, cancellation and interrupted reviews pause further invocations until explicit resume. No automatic provider fallback. No LaunchAgent, recurring codex exec, chat mutation or UI activation is installed.

## Execution

The agent supplies exact process identities and an ownership rationale. The app refreshes visibility, protects current caller/app ancestry, rejects protected identities and unreviewed children, and issues a single-use 60-second preview. Burn consumes that token, repeats checks and requests SIGTERM. The final syscall rechecks boot/start/PID/path/UID. macOS's PID-based API leaves a small unavoidable exit/reuse race.

Verification distinguishes unknown, partial, possible recurrence and verified exits. Recurrence requires a new same-executable child of the same still-live parent identity after the action. An existing sibling or unrelated new Node job is not a respawn. Reparented replacements cannot be reliably attributed. There is no kill loop or force escalation.

## Components

- `AgentSafety.swift`: mechanical protections; no abandonment classifier.
- `Monitor.swift`, `Verification.swift`: observation, durable intent, identity checks and receipts.
- `AgentBridge.swift`, `AgentSocket.c`: bounded same-user IPC, peer-PID authentication, expiring previews.
- `MachineReview.swift`, `ReviewWorker.c`: machine-wide scheduling, harness adapters and owned worker lifetime.
- `HarnessHook.swift`: cached signal publishing and inert legacy-hook compatibility.
- `MachineSetup.swift`: private provider selection without editing harness settings.
- `HarnessInstall.swift`: optional legacy interactive MCP/skill setup.
- `BurnMCP`: official Swift SDK protocol server; compatibility adapter for SDK 0.12.1 experimental capabilities.
- `BurnApp`: impact UI and optional details. Reopen events never show windows; presenting UI requires a menu action.
- `Store.swift`, `Native.swift`, `CBurn`: bounded persistence and small macOS API boundary.
- `Proof`: native fixtures, real OS zombies, active controls, pressure simulations and protocol tests.

The app and monitor have no third-party runtime dependencies. The MCP executable links the official SDK and its Swift dependencies. End users need neither Node nor Python. Legacy lease records remain readable for migration; they no longer authorize or block cleanup.

## Worktree service (0.11)

`WorktreeService` is the sole UI/CLI/MCP mutation authority. A private system-SQLite document store holds versioned inventory, identities, claims, policy, decisions, advice, operation journals and recovery dependencies. Transactions protect store updates; external Git/filesystem steps have explicit uncertain states and reconciliation. Legacy claims migrate once, retaining capabilities and IDs while clearing action-capable copies from the process catalog. Verified operations project into existing Impact counters without dual-writing receipts.

`WorktreeDiscovery` inventories Git registrations before deeper inspections. An owned subprocess publishes incremental JSONL observations, a rotating inspection cursor and explicit gaps under cancellation/deadline/output limits. One native consumer-path snapshot serves the scan; every action rechecks fresh coverage. `WorktreeInspection` binds the directory/common/admin identities, backlink, HEAD/branch, files/index and unsupported Git features. Readiness and content revisions are separate. Git subprocesses disable hooks/fsmonitor/network/lazy fetching and own their bounded process groups.

`WorktreeActions` consumes caller-bound previews, serializes per repository, journals intent, preserves independently encrypted recovery, verifies restoration/source content, rechecks authority and invokes exact Git operations. `WorktreeRecovery` preserves reachable/staged objects, index and supported working files in authenticated chunks; it restores to a new standalone repository without original configuration or hooks. Keychain key failure preserves the source. `WorktreeReconciliation` never replays an interrupted action or attributes an unexplained absence. `WorktreeBatch`, `WorktreeScheduling`, `WorktreeOwner` and `WorktreeRegistration` provide reviewed batches, explicit automatic policy, advisory exact-commit GitHub metadata and exact moved-checkout repair. Owner-managed archives and broad metadata prune remain handoffs.

The Worktrees window and Recovery tab use paginated bounded projections. The MCP worktree lane receives only queued IDs and a narrow tool; it cannot adopt, make human decisions, force dirty removal or purge recovery. Source content is restricted to local encrypted archives, outside model inventory.
