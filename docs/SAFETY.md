# Safety boundaries

## Authority and uncertainty

BurnZombies is a local utility running as the current user. It is not a security boundary against malicious code already running as that user. Its private lease files are trusted local authority records written by its own wrapper; never import them from another user or a downloaded bundle. There is no root helper or cross-user signaling.

Ordinary monitored processes never acquire stop permission. Automatic cleanup needs two explicit choices: the wrapper's `--allow-cleanup` grant for a new disposable activity and the app's global opt-in. Manual cleanup still requires the exact same evidence. The grant must not be used for interactive shells, general agent sessions, unsaved work, browser profiles, recordings, transfers, devices, credentials, or shared services.

No detector claims application-level idleness from low CPU. Network work, a blocked request, or data held in memory can be important despite flat CPU/disk counters. The disposable contract is therefore indispensable. For software without a dependable contract, use monitoring only.

## Action behavior

Prefer the owning tool's supported shutdown. This release has no arbitrary remote-control integration and does not invoke `launchctl`, close another app's windows, delete profiles, or infer a shutdown endpoint from a port. The available action is one SIGTERM to each exact registered target. There is no SIGKILL action and no signal to the whole process group.

The monitor confirms eligibility, current membership, ownership, protection, identity, and recent activity again. It refuses visible unregistered descendants. The permission is durably consumed before signals, so crash/restart cannot turn a one-off cleanup into a kill loop. A hung process receives a partial-failure receipt, not escalation. Termination is irreversible.

**Residual race:** macOS's public PID-based signal API does not atomically bind a signal to our recorded start time. A final identity/path/UID check narrows but cannot eliminate a tiny exit/PID-reuse race before `kill`. This is a reason to keep the action surface narrow, not to advertise perfect safety. Future audit-token/event integrations require separate platform proof.

**Incomplete ancestry:** polling cannot guarantee observing short-lived intermediate parents, detached descendants, or rapid exec transitions. Unregistered identities are never swept up by name. The UI does not claim a full process tree has been reclaimed. Same-path reappearance is deliberately conservative and can deny credit to an unrelated new job.

**Boot and sleep:** boot time participates in identities. Restart/wake/sampling gaps discard action continuity. Interrupted pending verification becomes unverified without credit. Older-boot ownership never authorizes a current PID. Catalog errors pause cleanup and surface the error; state is preserved.

## Data and retention

Collected: executable path, PID/start/boot, UID, observed parent PID, resource counters, a bounded time series, user-supplied session label, explicit membership, decisions, preferences and receipts. Not collected: argv, environment, prompts, terminal contents, browser data, repository contents, recording/upload contents, credentials, socket payloads or file contents.

Private directories are mode 0700 and files 0600. Reads reject symlinks at the file and directory boundaries checked, check ownership and size, and use no-follow opens. Checkpoints are atomic and fsynced. Decompression has a 24 MiB output limit. This is not encryption at rest; rely on your operating-system account and disk protection.

The app has no telemetry or automatic remote requests. The documentation link opens GitHub only when selected. A default scan is capped at 16,384 PID slots and 4,096 retained own-user records. Cap/visibility failures suppress unsafe action. Eight samples per record, 24-hour disappeared-record retention, 500 receipts/30 days and bounded leases prevent unbounded history growth. Only expired, fully exited leases and the app's own old interrupted-write debris are automatically removed. User files are never cleaned.

No crash dump or private machine inventory belongs in an issue or public PR. Use synthetic fixtures and aggregate results. See [SECURITY.md](../SECURITY.md).
