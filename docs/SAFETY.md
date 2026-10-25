# Safety boundaries

## The harness decides; the native app executes narrowly

BurnZombies no longer infers abandonment with fixed age/CPU/ownership heuristics. The user's agent combines live process evidence with session and workspace context. Cleanup must be within the user's authorization, including an ongoing hygiene request. The model can still misjudge ownership: uncertainty means leave it running, not force a reboot or bulk kill.

The native action surface requires exact process identities, a preview, a rationale and a fresh single-use token. It checks same-user ownership, PID/start time/boot/executable, user protections, current requesting-harness and app ancestry, complete scan coverage and reviewed live children. OS services, main app processes and harness executables are mechanically protected. A passed check is not proof that the task is disposable.

Prefer the owning tool's supported teardown. The only signal exposed is SIGTERM to each reviewed identity. There is no SIGKILL, process-group kill, reboot, credential change, file sweep, or automatic escalation. A hanging target receives a partial receipt. The app writes intent before signals and never retries a spent preview.

**Residual race:** macOS's public PID-based signal API cannot atomically bind a signal to a recorded start time. The final identity/path/UID check narrows but cannot eliminate an exit/PID-reuse race before `kill`. Polling also cannot guarantee observing short-lived parent edges or a child created between checks. Do not advertise perfect safety.

## Continuous operation and impact

Lifecycle hooks send bounded context to the active model; they never diagnose or stop processes. They coalesce changed-state signals across harnesses. There are no Stop or startup hooks, blocking decisions or forced turns. Hook trust and MCP approvals remain client-owned. Idle/offline models and blocked tool calls cannot receive a fresh model turn solely through MCP.

The app verifies exact exits and watches for new same-executable children under the same verified parent identity for 120 seconds. Existing siblings and unrelated parents do not count as recurrence. Reparented replacements cannot be reliably attributed. Pending, interrupted, unknown and partial results earn no verified credit. Sleep/restart or large sample gaps invalidate pending continuity. Older-boot identities never authorize a current PID. The app does not need a restart to clean up.

Memory release uses pre-stop resident footprints; shared pages may overlap. CPU savings project a measured rate over a bounded future hour. Speed compares local command-launch samples; it does not measure remote model latency. Missing data stays unavailable.

## Privacy and storage

The app observes executable paths, PID/start/boot, UID, parent PID and resource counters, plus a bounded sample history, agent-provided rationale and receipts. It does not collect command arguments, environment, prompts, repository/file contents, browser profiles, terminal text or credentials. MCP inspect evidence is visible to the chosen harness and its model provider.

The bridge is a private same-user Unix socket and verifies the peer PID for ancestry protection. It is not a security boundary against malicious code already running as that user. No root helper, HTTP listener, telemetry service or separate model account is used.

State directories are 0700, files 0600; bounded reads, no-follow checks, atomic checkpoints and a 24 MiB decompression ceiling constrain storage. The monitor retains at most 4,096 process records, eight samples per record, disappeared records for 24 hours, and 500 receipts for 30 days. Historical wrapper leases remain readable for migration but no longer grant execution authority. No private process inventory or Slack feedback belongs in a public issue or test artifact.
