# Identifying real zombies, and proving abandoned helpers

Research date: 2026-10-25. This follow-up focuses on confidence, historical evidence, and the difference between detection and authority to intervene.

## The most useful result: ask the kernel, then test the adapter

An OS zombie is an exited process whose parent has not collected its termination status. This is a categorical kernel state, not a model prediction. On Darwin it is `SZOMB`. A process may still have a PID while already being dead. It consumes a process-table entry but has no running user-space task to accelerate by killing it. A parent that leaks many entries can still cause meaningful resource exhaustion.

[Apple's waitpid manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/waitpid.2.html) defines collecting child status. [psutil's FAQ](https://psutil.io/faq/) explicitly distinguishes `STATUS_ZOMBIE` from `is_running()`/`pid_exists()`: the latter can be true for a zombie, and signals cannot reap it. Therefore the remedy belongs to the parent lifecycle (`wait`/`waitpid`, correct child management), not a kill button on the zombie or an automatic kill of its potentially important parent.

The critical implementation detail was verified in [Apple's proc_info.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c), source blob `c061a09289afe73572456395af70de2cd92b69fc`: ordinary `PROC_PIDTBSDINFO` lookup does not automatically look up zombie references. The kernel has an explicit separate lookup path. Reading a status member from this API does not mean zombies will ever reach your code.

The mature [psutil Darwin implementation](https://github.com/giampaolo/psutil/blob/master/psutil/arch/osx/proc.c), blob `513d82ff18b6a7d299f1a47e8ccc49f274e027ae`, interprets `extern_proc.p_stat == SZOMB` from the kernel process structure. BurnZombies now uses `sysctl(KERN_PROC_PID)` as a bounded fallback when its normal live-process read fails. It does not need to guess from missing RSS, age, or an empty executable path. A denied lookup remains unknown.

**A real test caught the bug:** create a child with `fork`, immediately `_exit` in the child, deliberately delay `waitpid` in the test parent, and query the native adapter. Before the fallback, the adapter omitted this known zombie. The regression fixture checks the direct read, inclusion in the ordinary process scan, parent identity, zero RSS, refusal to signal, and final parent-side reaping. Synthetic status fields alone would not have caught this API behavior.

## Confidence ladder

| Evidence | What it establishes | What it does not establish |
|---|---|---|
| Kernel `SZOMB` for a stable PID/start/boot identity | Exited but unreaped process | That killing its parent is safe |
| Kernel absence or a different start identity on a reused PID | Old identity is no longer live | Why it exited, or whether it was abandoned |
| Recorded launch edge, owner exit, explicit disposable contract | A narrowly owned cleanup candidate | Completeness for unobserved escaped children |
| Supported session/task completion plus an acknowledged teardown contract | Strong application-level lifecycle evidence | Safety for unrelated children or shared services |
| CPU/RSS/FD trend, late heartbeat, age, PPID 1 | A reason to investigate | Permission to terminate |
| Process vanished at reboot/crash | Observation ended at a reset boundary | A trustworthy positive abandonment label |

For live leftovers, the practical algorithm is a conjunction: **explicit permission AND recorded stable membership AND owner gone AND continuous grace/idle observations AND no protections AND fresh pre-action revalidation**. Unknowns veto cleanup. This rule is intentionally conservative and does not use a calibrated-sounding percentage.

## Tools and strategies evaluated

**Native `ps` / `sysctl` / libproc.** Use `ps -axo pid,ppid,stat` for a manual cross-check without arguments. Use direct APIs in the product for typed status, start identity, permission handling, and bounded overhead. A status beginning with Z is qualitatively different from a sleeping S or an uninterruptible wait. Neither sleeping nor high thread count is abandonment evidence.

**psutil.** A useful cross-platform reference and diagnostic prototype. Its explicit process status, creation-time identity checks, and zombie exceptions encode important pitfalls. BurnZombies reuses the principles, not its Python runtime. Library success paths and exception semantics both need real OS fixtures.

**kqueue / Dispatch process sources.** [Apple's kqueue manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kqueue.2.html) documents process-event filters such as exit notifications. These can make registered-owner exit detection prompt and reduce polling. They do not retroactively recover ancestry, prove application-level completion, or confer a Linux pidfd-style atomic signal handle. A bounded source per registered owner is a good next improvement after the polling baseline.

**Endpoint Security / osquery process events.** Apple's [Endpoint Security events](https://developer.apple.com/documentation/endpointsecurity/event-types) can expose fork/exec/exit edges; [osquery's auditing docs](https://osquery.readthedocs.io/en/stable/deployment/process-auditing/) explain the macOS event backend and its overhead/deployment implications. An event graph would improve discovery of short-lived parents and detached descendants. It needs entitlement/permission handling, a bounded queue, event-loss detection, reconciliation, and a clearly degraded state when continuity is lost. Do not pretend event telemetry is complete merely because a client connected.

**Objective-See ProcessMonitor.** Its [upstream repository](https://github.com/objective-see/ProcessMonitor) is a concrete Endpoint Security process-monitor example, exposing ancestry and lifecycle events. It is GPL-3.0 and also collects arguments/environment in its described feature set. That makes it a research reference, not a drop-in dependency for this MIT, minimal-data application. No arguments/environment collection or ES installation was enabled for this research.

**Heartbeat / phi-accrual failure detection.** [Akka's current documentation](https://doc.akka.io/libraries/akka-core/current/typed/failure-detector.html) describes a suspicion measure based on historical heartbeat intervals, with pause allowances and threshold tradeoffs. This can rank suspected hung workers when an integration actually emits a defined progress/heartbeat signal. A quiet event loop, long GC pause, overloaded machine, sleep, or stalled observer can all make heartbeats late. A high phi value is not proof that a local process is safe to kill. No phi score or model training is included in v1; explicit local owner liveness is simpler and stronger for its cleanup category.

**Lifecycle prevention.** Prefer supported EOF/shutdown, prompt child reaping, close-on-exec file descriptors, structured cancellation, and bounded supervisor restart backoff. Repeated replacement processes indicate a creator defect. Killing replacements repeatedly hides the cause and can increase churn. BurnZombies consumes each session's cleanup permission once.

## How historical evidence should be used

Crash reports are not generally a full history of process ownership or session intent. They may identify a faulting task, thread stacks, resource pressure, or a system panic. A reboot ends all process observations together, which confounds healthy and abandoned work. A label such as “disappeared after crash” must remain **unknown**, not become “zombie.”

A bounded local check during development found crash reports but no trustworthy labeled pre-crash process table in the records checked. The app's usable catalog observations were from the later boot. Private reports, process inventories, paths, and session contents were neither copied here nor published. The negative finding is scoped to those checked records, not a claim that no older evidence exists anywhere on the machine.

Better future evidence is small and prospective: a boot identifier, stable process identities, observed parent edges, explicit session state, sample timestamps, visibility gaps, a decision reason, the chosen action, and the verified outcome. Record an uncertainty label at capture time. Keep per-machine raw evidence private; publish only hand-reviewed synthetic reproductions and aggregate test outcomes.

If learned ranking is ever justified, first build a labeled evaluation set containing legitimate long-running jobs, independent identical executables, idle services, completed sessions, crash boundaries, escaped children, and real kernel zombies. Split by workload/session and machine, not adjacent samples of the same process. Measure false cleanup eligibility separately from detector recall and notification volume. Require zero unsafe automatic actions on the protected suite; do not optimize a classifier against a noisy “process disappeared” label. The deterministic protection/authority boundary remains outside the learned ranker.
