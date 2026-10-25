# Detection and action matrix

All thresholds are policy choices, not calibrated probabilities. `unknown` means insufficient evidence, not unhealthy. Observation history is invalidated after restart, wake, a sampling gap over 75 seconds, or incomplete scan coverage.

| Priority / category | Required evidence | Classification / action | Main false-positive or visibility limit |
|---|---|---|---|
| P0: owned disposable leftovers | Wrapper grant; exact PID/start/boot/path membership; owner confirmed gone; 180-second grace; ≥3 continuous samples spanning ≥120 seconds; <1% of one CPU core and unchanged disk counters between samples; every protection check passes | Eligible for one SIGTERM attempt after preview, or explicit global opt-in | Idle does not imply disposable; the operator's per-session contract is essential |
| P0: active or unknown owner | Owner identity still live or cannot be read | Protected; never terminate | A stale heartbeat does not override a live owner |
| P0: identity/visibility change | PID reused, executable changed, missing metrics, different boot, missing permission, stale observation, scan cap hit | Action refused | No “best effort” signaling after uncertainty |
| P0: protected tool | App/system path, known agent/browser/device/recording/transfer/credential executable, operator-protected path, or snoozed identity | Protected from cleanup | Name protections are defense in depth; explicit membership remains mandatory |
| P1: actual OS zombie | Kernel `SZOMB`, read through sysctl fallback when ordinary libproc lookup excludes it | Explain exited/unreaped state; no signal action | Parent must reap; important parent is not automatically terminated |
| P1: sustained RSS growth | ≥6 samples, ≥240 seconds, >256 MiB and >50% growth, almost every interval rising | Investigate only | Cache warming, deliberate batching, model loading |
| P1: sustained FD-table growth | ≥6 samples, ≥240 seconds, >128 additional allocated slots, almost every interval rising | Investigate only; inspect current descriptor count on demand | Allocated capacity is not open-handle count; legitimate expanding connection pools |
| P1: large helper family | ≥12 live identities with same executable and currently observed parent identity | One grouped review finding | An intentional pool is not a duplicate-service fault |
| P1: suspected restart loop | ≥5 recent start identities under same parent PID/executable in ten minutes, ≥3 exited | Investigate creator; never repeated kills | PID correlation is inferred; independent short jobs can resemble a loop |
| P1: hung target after request | Exact target still alive after 15-second graceful deadline | Partial failure; no credit, no automatic escalation | A task may need more time; user must use the owning tool |
| P1: suspected reappearance | A new matching executable appears during the 120-second watch | No credit; permission remains consumed | Matching path alone is conservative recurrence suspicion, not proven causality |
| P2: sockets and files | Capped on-demand descriptor table | Counts in details | No endpoint/file contents; no arbitrary deletion |
| Deferred: listener/service/workspace ownership | Requires supported integration or stronger OS event evidence | Unknown; no action | Names, ports, and paths alone cannot establish authority |
| Deferred: owned temporary artifacts | Would require exact creation provenance, retention contract, safe quarantine and readback | No file cleanup in v1 | Profiles, repos, recordings, credentials and queues are never inferred disposable |

Groups are display units, not kill targets. No process-group broadcast is used. Before signaling, the monitor refreshes, compares the reviewed membership set, rejects visible unregistered descendants, checks recent CPU/disk activity again, confirms the owner is still gone, and checks each target's identity immediately before SIGTERM.

Requests are serialized by the catalog owner and an in-flight action guard. A durable disarm and journal intent precede any signal. The disarm survives app failure. Exit is checked individually. Only a full successful operation earns a count; partial outcomes do not inflate totals. “No recurrence observed” is limited to periodic samples during the finite watch, not a guarantee that no brief process existed between samples.

See [zombie research](ZOMBIE_RESEARCH.md) for the kernel/API distinction and [safety](SAFETY.md) for residual risks.
