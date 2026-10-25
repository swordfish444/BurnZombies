# Research and decisions

Research checked 2026-10-25. Links are primary documentation or upstream source. Version and maintenance observations are a dated snapshot, not an ongoing maintenance guarantee. No third-party implementation code is copied into the app.

## Decision

Use SwiftUI/AppKit, a small Darwin/libproc adapter, and a bounded local catalog. Observe ordinary processes immediately, but grant cleanup authority only to explicitly registered disposable helpers. Keep identity, evidence, and uncertainty separate. This is a native macOS application first; preserve a small OS boundary for a later Windows implementation, without carrying a cross-platform UI runtime today.

The serious alternatives were a Python monitor using psutil, an osquery deployment, and a supervisor-centered product. All can provide useful observations or lifecycle control. None can determine that an arbitrary existing worker is abandoned without evidence from its owner. Their additional runtime/configuration is unnecessary for the first handful of detectors.

## Ownership, cancellation, and supervision

The current [MCP Python SDK stdio implementation](https://github.com/modelcontextprotocol/python-sdk/blob/main/src/mcp/client/stdio.py) was inspected, including `_stop_server_process` (source blob `6a3ad121115006f25739e073d409349ed55265d7`). It closes input, waits, then delegates process-tree termination. Its comments distinguish process exit from inherited-pipe EOF, and explicitly handle kill survivors. This matters: a live pipe is not proof that its original server is alive, and killing the leader is not proof that every descendant exited. The [MCP lifecycle specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#shutdown) provides the transport shutdown contract. SDK timeout/escalation policy should not be mistaken for universal ownership authority.

For browser automation, [Playwright's Browser API](https://playwright.dev/docs/api/class-browser#browser-close) says explicitly created contexts should close before the browser, including for video completion. Therefore BurnZombies does not kill browsers or delete their profiles. A supported teardown adapter would need the actual owning context, not a socket guessed from a process name.

[Supervisor configuration](https://supervisord.org/configuration.html) provides `stopsignal`, `stopwaitsecs`, `stopasgroup`, `killasgroup`, retries, and start qualification. [Process Compose](https://f1bonacc1.github.io/process-compose/configuration/) supplies explicit process declarations, dependency/lifetime policy, shutdown controls, and recovery configuration. [PM2 restart strategies](https://pm2.keymetrics.io/docs/usage/restart-strategies/) describe delays and exponential backoff. These are useful principles: pair launch and teardown, preserve an owner, bound retries, and distinguish restart policy from cleanup. BurnZombies does not compete with an existing supervisor by repeatedly killing its children.

The wrapper records start identities and parent edges while launching a new command. A live owner is decisive negative evidence for cleanup. Owner death plus explicit disposable permission, observed membership, repeated idle samples, grace, and protection checks can establish a narrow action category. PPID 1 alone cannot: launchd owns legitimate services, adopted children, and intentionally detached jobs.

Process groups are useful cancellation mechanisms but not a complete census. `setsid`, group changes, double-forking, and short-lived parents can escape them. This release targets only individually recorded identities; it refuses an action when a visible unregistered descendant remains. It does not pretend polling can observe every fork/exec.

## macOS identity and visibility

Apple's [libproc wrappers](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c) and [proc_info definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h) were inspected alongside the installed SDK headers. `proc_bsdinfo` provides parent/group IDs, UID, process state, and start seconds/microseconds. `proc_taskinfo` supplies cumulative CPU, RSS, threads; `proc_pid_rusage` supplies disk counters and measurement counters. Identity includes boot time as well as PID/start time. The path is read through `proc_pidpath`, without fetching argv or the environment.

Visibility is not universal. A failed read is not an exit. The adapter distinguishes a confirmed ESRCH absence from a denied/unknown read. All observations are local and restricted to the current user's processes. No root helper or Endpoint Security entitlement is needed. Start-time revalidation occurs immediately before signaling; public `kill(pid, SIGTERM)` still has a residual PID-reuse race because it does not atomically accept the recorded start time. The release documents this limit instead of claiming pidfd semantics.

Descriptor enrichment reads a capped descriptor table only on demand. It reports counts, including sockets, without reading file contents or collecting remote addresses. The cheap `pbi_nfiles` field is **allocated descriptor-table capacity**, not an exact open-handle count: [Apple's proc_info.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c) assigns `fd_nfiles`, whose meaning is explicit in [filedesc.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/filedesc.h). Its sustained growth is labeled as a capacity signal; current counts require `PROC_PIDLISTFDS`. Listener ownership, launchd service labels, workspace/session names, and arbitrary agent protocol state are **unknown unless explicitly registered**. Endpoint inspection and service adapters are future work.

[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) is the supported login-item interface on modern macOS. Use it directly, with opt-in and visible errors. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) was evaluated; an AppKit status item/popover hosting SwiftUI provides explicit presentation and testability with the same small native dependency footprint. Do not install a launch daemon just to keep an icon available.

Apple's [App Nap guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html) and [timer tolerance API](https://developer.apple.com/documentation/foundation/timer/tolerance) favor letting the system coalesce background work. The app uses a tolerant timer, slows to 60 seconds when stable, briefly samples at 15 seconds around owned findings/verification, stops scheduling on sleep, and invalidates continuity on wake or long gaps. It does not assert a power-management exemption.

## Reuse evaluation

Repository metadata and license files were checked through GitHub on the research date. Last push is only a maintenance signal; it is not a release date or support commitment.

| Project | License checked | Last upstream push | Platform/runtime and practical fit | Decision |
|---|---|---|---|---|
| [osquery](https://github.com/osquery/osquery) | Apache-2.0 OR GPL-2.0-only; checked LICENSE | 2026-10-23 | Native daemon/query infrastructure, multiple desktop/server platforms; macOS event capture has entitlement/permission/deployment considerations | Excellent fleet inventory; excessive installation/log surface for this small user utility |
| [psutil](https://github.com/giampaolo/psutil) | BSD-3-Clause | 2026-10-25 | Python plus native extensions; macOS and Windows supported; permission failures remain possible | Best quick prototype alternative; avoid bundling Python for the shipping app |
| [Process Compose](https://github.com/F1bonacc1/process-compose) | Apache-2.0 | 2026-10-19 | Go process orchestration, declarations and supervisor lifecycle; Linux/macOS focus | Integrate its supported teardown later; do not embed a second supervisor |
| [Supervisor](https://github.com/Supervisor/supervisor) | BSD-derived license with modification-notice condition; checked LICENSES.txt | 2025-12-21 | Python/Unix supervisor; not a native Windows solution | Borrow explicit lifecycle principles; not an inventory/ownership solution for existing apps |
| [PM2](https://github.com/Unitech/pm2) | AGPL-3.0; checked LICENSE pointer | 2026-10-23 | Node process manager and daemon; cross-platform support varies by feature | Backoff reference; avoid runtime, daemon, and redistribution complexity |
| [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) | MIT | 2024-01-11 | Small Swift convenience over native login-item APIs | Direct SMAppService calls are enough; no dependency needed |

All six repositories were unarchived when checked. The [osquery auditing documentation](https://osquery.readthedocs.io/en/stable/deployment/process-auditing/) specifically warns about event volume and CPU overhead, and distinguishes modern macOS Endpoint Security events from older OpenBSM tables. The [psutil documentation](https://psutil.io/) confirms its broad platform scope. No comparative runtime benchmark was run against these alternatives; operational overhead judgments above concern required components and permissions, not invented CPU percentages.

## Explainable anomaly detection

Use deterministic conjunctions, not a confidence percentage. A process's own bounded history is its first workload baseline. Require both absolute and relative RSS growth, several rising samples, and elapsed time. FD-table capacity growth likewise needs sustained observations. Large families and churn are review-only, with explicit false-positive explanations. Duplicate-looking independent jobs must not merge simply because they execute the same binary.

The [Google SRE monitoring chapter](https://sre.google/sre-book/monitoring-distributed-systems/) separates symptoms, causes, and actionable alerts. Here, high consumption is a symptom, owner exit is lifecycle evidence, and explicit permission is authority. None substitutes for the others. Hysteresis comes from elapsed windows, bounded samples, fresh revalidation, one-attempt permissions, and notification cooldowns. Complex statistical scoring is deferred until labeled workloads demonstrate improvement over these rules.

## Wispr Flow and product meaning

Verified current official surfaces: [Your Usage documentation](https://docs.wisprflow.ai/articles/8760230576-your-usage-tab-track-your-dictation-stats-in-wispr-flow) and the [official release notes](https://wisprflow.ai/whats-new). The usage docs expose a small number of recognizable metrics, usage categories, daily activity, streaks, calculation definitions, and behavior when data is missing. Release notes describe the Insights views and link product screenshots. A browser successfully opened the release-note surface, but its site-safety policy blocked the linked screenshot CDN. **Pixel-level screenshot comparison was not completed**; no claim of having inspected those blocked images is made.

Principles applied: summarize meaningful activity instead of raw events; let the user drill into how a number is calculated; preserve uncertainty and missing-data states; make the quiet default useful. BurnZombies deliberately avoids streaks that reward unnecessary intervention, leaderboards, or estimated time saved. The reward is a small verified count and a readable receipt. Its flame mark, warm accent, plain-language activity rows, and native controls are original, rather than copied visual surfaces.

## KPIs and performance claims

Choose two cumulative KPIs: verified helper exits and verified cleanup operations. Every operation has one durable journal entry; partial failure and suspected reappearance receive no credit. Each success includes the finite observation window. Count a process identity once, not once per sample or parent group. Retain cumulative counts independently from trimmed detailed receipts.

The Impact surface attributes memory released from the pre-stop resident footprint of verified exits, once per receipt. All-time totals survive detailed-history pruning. Shared pages can overlap, so these are footprint totals, not an exact physical free-memory delta. The drilldown explains that distinction. The third headline metric is CPU time saved: a bounded one-hour projection from the helpers’ observed pre-stop CPU rate. It is credited once after verified exit and displayed with `~`; it is not historical CPU consumption or a guarantee that the workload would have remained unchanged. The drilldown contains the calculation. Missing measurements stay unavailable. Files are not cleaned in v1.

The implemented responsiveness probe times `/usr/bin/true` locally, discards one warm-up and retains the median of seven command launches before cleanup and after verified exit. Each launch has a one-second exit deadline; failure leaves the measurement unavailable. The UI presents `~(before / after - 1) × 100%` with the before/after values. It estimates local command-launch responsiveness, not model or network speed; scheduling, load and caches can change independently. The default panel stays compact; sample size and limitations live in Impact details. Future adapters should measure matched tool operations, p50/p95 and dispersion rather than extrapolate this tiny probe to all agent work.
