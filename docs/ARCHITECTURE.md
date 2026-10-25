# Architecture

```text
Existing agent harness + Agent Skill (reasoning and ownership)
              │ MCP: status → inspect → preview → burn
     Native stdio server (no independent model)
              │ private same-user Unix socket; authenticated peer PID
         Monitor actor ── finite exit/recurrence verification
              │
       libproc / sysctl / identity-checked SIGTERM
              │
      private catalog ── menu-bar impact + burn log
```

The harness decides which work is abandoned. BurnZombies supplies evidence and mechanical execution boundaries. There is no idle-age classifier or mandatory launch wrapper. A separate callback delivers a small, rate-limited resource-change signal through the already-connected MCP server in Codex and Claude Code. Other supported harnesses use a short native callback. No callback invokes a model, scans processes, stops a process or presents UI.

## Observation and storage

One monitor owns a nonblocking private lock. It observes current-user processes every 60 seconds, or every 15 seconds while verifying a cleanup. It retains up to eight minute-spaced samples per identity. Monotonic time and wall time are separate; sampling gaps, sleep and incomplete coverage invalidate continuity.

The catalog is compressed Codable data with bounded reads/decompression, a five-minute checkpoint and immediate durable action/settings writes. Before signaling, the monitor persists intent. Only a completed verified receipt contributes impact. A crash cannot turn absent processes into labeled training examples.

A separate aggregate signal contains observation time, process count, summed RSS and OS pressure. Checkpoints read this small file; they do not rescan the machine. Normal first contact records a baseline. A pending manual request, pressure increase, 20 additional processes or 512 MiB of additional RSS can request model attention, with a shared ten-minute cooldown for automatic requests. These are notification thresholds, never kill criteria. Stale signals and unchanged state return an empty object. No startup hook, Stop hook or forced continuation exists.

## Execution

The agent supplies exact process identities and an ownership rationale. The app refreshes visibility, protects current caller/app ancestry, rejects protected identities and unreviewed children, and issues a single-use 60-second preview. Burn consumes that token, repeats checks and requests SIGTERM. The final syscall rechecks boot/start/PID/path/UID. macOS's PID-based API leaves a small unavoidable exit/reuse race.

Verification distinguishes unknown, partial, possible recurrence and verified exits. Recurrence requires a new same-executable child of the same still-live parent identity after the action. An existing sibling or unrelated new Node job is not a respawn. Reparented replacements cannot be reliably attributed. There is no kill loop or force escalation.

## Components

- `AgentSafety.swift`: mechanical protections; no abandonment classifier.
- `Monitor.swift`, `Verification.swift`: observation, durable intent, identity checks and receipts.
- `AgentBridge.swift`, `AgentSocket.c`: bounded same-user IPC, peer-PID authentication, expiring previews.
- `HarnessHook.swift`: cached signals and quiet cross-client coalescing.
- `HarnessInstall.swift`: transactional configuration/skill installation and owned-hook migration.
- `BurnMCP`: official Swift SDK protocol server; compatibility adapter for SDK 0.12.1 experimental capabilities.
- `BurnApp`: impact UI and optional details. Reopen events never show windows; presenting UI requires a menu action.
- `Store.swift`, `Native.swift`, `CBurn`: bounded persistence and small macOS API boundary.
- `Proof`: native fixtures, real OS zombies, active controls, pressure simulations and protocol tests.

The app and monitor have no third-party runtime dependencies. The MCP executable links the official SDK and its Swift dependencies. End users need neither Node nor Python. Legacy lease records remain readable for migration; they no longer authorize or block cleanup.
