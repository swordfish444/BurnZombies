# Safety boundaries

## The harness decides; the native app executes narrowly

BurnZombies no longer infers abandonment with fixed age/CPU/ownership heuristics. The user's agent combines live process evidence with ownership evidence across the computer. Cleanup must be within the user's authorization, including an ongoing hygiene request. The model can still misjudge ownership: uncertainty means leave it running, not force a reboot or bulk kill.

The native action surface requires exact process identities, a preview, a rationale and a fresh single-use token. It checks same-user ownership, PID/start time/boot/executable, user protections, current requesting-harness and app ancestry, complete scan coverage and reviewed live children. OS services, main app processes and harness executables are mechanically protected. A passed check is not proof that the task is disposable.

Prefer the owning tool's supported teardown. The only signal exposed is SIGTERM to each reviewed identity. There is no SIGKILL, process-group kill, reboot, credential change, file sweep, or automatic escalation. A hanging target receives a partial receipt. The app writes intent before signals and never retries a spent preview.

**Residual race:** macOS's public PID-based signal API cannot atomically bind a signal to a recorded start time. The final identity/path/UID check narrows but cannot eliminate an exit/PID-reuse race before `kill`. Polling also cannot guarantee observing short-lived parent edges or a child created between checks. Do not advertise perfect safety.

## Continuous operation and impact

The resident observer schedules reviews independently of chats. Only a fresh complete scan can dispatch a review. A single selected harness supplies reasoning; calls are bounded, coalesced and supervised. Failure or account limits pause review until explicit resume, with no model/provider/account fallback. Default setup installs no chat hooks and modifies no persistent harness permissions. Legacy hooks are inert once machine review is configured.

Cleanup targets still receive SIGTERM only. The dedicated reviewer supervisor may terminate its own process group after the grace period to prevent orphaned inference/MCP workers. This ownership boundary does not include user jobs or unrelated harnesses.

The app verifies exact exits and watches for new same-executable children under the same verified parent identity for 120 seconds. Existing siblings and unrelated parents do not count as recurrence. Reparented replacements cannot be reliably attributed. Pending, interrupted, unknown and partial results earn no verified credit. Sleep/restart or large sample gaps invalidate pending continuity. Older-boot identities never authorize a current PID. The app does not need a restart to clean up.

Memory release uses pre-stop resident footprints; shared pages may overlap. CPU savings project a measured rate over a bounded future hour. Speed compares local command-launch samples; it does not measure remote model latency. Missing data stays unavailable.

## Privacy and storage

The process observer records executable paths, PID/start/boot, UID, parent PID and resource counters, plus bounded sample history, agent-provided rationale and receipts. It does not collect command arguments, environment, prompts, browser profiles, terminal text or credentials. Storage discovery also records bounded directory metadata. Its explicit evidence tools can return short, filtered source/build/retention excerpts from a measured branch; private state, transcripts, credentials, linked files and online-only content are refused. MCP evidence is visible to the chosen harness and its model provider. See [disk discovery and cleanup](DISK-CLEANUP.md) for the separate file-removal boundary.

The bridge is a private same-user Unix socket and verifies the peer PID for ancestry protection. It is not a security boundary against malicious code already running as that user. No root helper, HTTP listener, telemetry service or separate model account is used.

State directories are 0700, files 0600; bounded reads, no-follow checks, atomic checkpoints and a 24 MiB decompression ceiling constrain storage. The monitor retains at most 4,096 process records, eight samples per record, disappeared records for 24 hours, and 500 receipts for 30 days. Historical wrapper leases remain readable for migration but no longer grant execution authority. The most recent review output is capped at one MiB in private local storage and may contain process evidence. No private process inventory or Slack feedback belongs in a public issue or test artifact.
