# Validation and overhead

Validation date: 2026-10-25. Development host: Apple Silicon, macOS 15.8.1, 16 logical CPUs, 128 GiB RAM, Swift 6.2.3 / Command Line Tools. The application targets macOS 14+. Other OS versions and Intel hardware have not been locally validated.

## Version 0.2: installation and MCP

The complete local integration suite passed **36 checks with zero failures**. Three independently owned detached helpers became eligible after **192 seconds**; their graceful exits, recurrence watch, deduplication and durable impact accounting completed at **322 seconds**. One cleanup used the same preview-token service exposed through MCP, including rejection of a reused token.

The real stdio server passed MCP initialization, tool discovery, live native monitoring, argument validation, refused unauthorized cleanup, prompt discovery and clean stdin-EOF shutdown. The native bridge also passed private-socket permissions, competing-listener refusal, symlink refusal and clean shutdown. A blocked socket accept discovered during testing was replaced with an explicit shutdown wakeup.

Installer tests exercised the actual packaged app and code signature with mocked downloads and client configuration commands: Codex and Claude Code arguments, paths containing spaces, repeat installation, existing configuration preservation, checksum failure and archive traversal refusal. The app, CLI and MCP executables each contain **arm64 and x86_64** slices. Local execution was on Apple Silicon; this is not an Intel hardware test.

The universal app is approximately **18 MiB** uncompressed and **5.2 MiB** downloaded. It bundles the MCP runtime; users need no Swift, Node or Python installation. The monitor itself does not link the MCP SDK. The operating measurements below predate this release and are retained as historical evidence, not new MCP overhead measurements.

[Version 0.2 source CI](https://github.com/swordfish444/BurnZombies/actions/runs/40227631808) runs the native integration suite, app build, MCP protocol and installer checks at source commit `4199dc8`. CI explicitly selects Xcode 26.2 to match the required Swift 6.2 generation instead of the runner's older default.

### Real MCP-to-app cleanup

The shipped universal MCP executable connected to the actual native app in isolated storage. A registered, abandoned test helper passed the production grace and repeated-idle checks. The agent client previewed it, received a token and requested cleanup. Impact remained at zero during verification, then automatically became **one verified helper / 51 MB released** after the recurrence watch. The child was gone, the receipt was `verified`, and the server exited cleanly when its input closed. No active user workload was stopped.

The README's [Impact capture](media/live-impact.jpg) and [before/after clip](media/live-cleanup.gif) come from this run. The clip shortens the verification wait. CPU time stayed at zero for this idle helper; the local launch probe produced the displayed before/after values. These are a controlled cleanup demonstration, not a general performance benchmark. The broader pressure-test coverage is described below.

## Version 0.1 automated evidence

`scripts/test.sh --integration`: **35 checks, zero failures**, plus the full three-worker lifecycle. The latest local receipt-regression run found the three independently owned detached helpers eligible after **192 seconds** of monitoring; cleanup, recurrence watching, CPU projections, deduplication and immediate persisted accounting completed at **321 seconds**. The wrapper setup occurs before this timed monitor interval.

[Final source CI](https://github.com/swordfish444/BurnZombies/actions/runs/40221396685) passed the full integration suite and release app build on `macos-15` at source commit `a8b2db6`. Later documentation-only commits do not rerun the source workflow.

Coverage includes explicit authority, active/unknown owners, consumed permissions, PID reuse and executable changes, real and synthetic zombies, CPU/disk activity, grace periods, stale/missing observations, protection/snooze, independent jobs, sustained growth, restart loops, restart/wake continuity reset, private storage, corruption, symlinks, single-instance locking, retention, partial/unknown/recurring outcomes, interrupted verification, actual SIGTERM, a real hung process, and real wrapper cancellation.

### Pressure tests

- **32 simultaneous real kernel zombies + eight live idle controls, five inventory passes.** All 32 unreaped children were found and classified as kernel zombies on every pass. All eight live controls remained alive and were never mislabeled as zombies. Native signaling refused every zombie. No cleanup authority was inferred. Test teardown reaped only its own exited children and stopped only its own live controls.
- **4,096 mixed policy cases.** Exactly 512 explicitly owned, abandoned, idle cases qualified. Active owners, unknown owners, consumed grants, missing metrics, fresh disk activity, reused identities and protected workers were refused. These are deterministic simulations, not a measured false-positive rate on arbitrary user workloads.
- **Three independent real abandoned helpers.** Each retained its own ownership record and one-attempt grant. All exited after SIGTERM, passed the recurrence watch, and contributed exactly once to count, resident-footprint and CPU-projection totals. Reloaded accounting matched. Both responsiveness probes were present.
- **Accounting regression.** A large historical CPU total is subtracted out: only the sampled rate is projected. Missing data produces no estimate; an idle baseline produces zero. Repeated refresh does not double-count.

The original real-kernel-zombie test failed before the sysctl fallback and passed afterward. Its parent deliberately leaves an exited child unreaped, checks direct and inventory detection, checks zero resident footprint and refusal to signal, then calls `waitpid`.

The cancellation test uses the real wrapper and `/bin/sleep`, verifies membership, cancels the wrapper, and confirms its child exits and the lease ends without cleanup permission. The hung fixture ignores SIGTERM; the product records partial failure without escalation. Test teardown alone can forcibly remove its own exact sacrificial fixture.

Sleep/wake, app restart, PID reuse, missing metrics and partial visibility are state-machine tests. No physical sleep, forced system crash, permission-policy change, notification grant or login-item enablement was performed. Full OS-matrix and long-uptime field validation remain future work.

## Version 0.1 native operator journeys

The final 428 × 795-point compact view and 1008 × 930-point Impact window were inspected in native macOS rendering. Public [Impact](media/impact.jpg), [compact](media/menu-bar.jpg) and [Burn Log](media/burn-log.jpg) captures use synthetic demo data only.

- Fixed the headline using actual glyph ink bounds, verified the two-line spacing, mascot, subtitle clearance and metric alignment.
- Checked smaller unit type, CPU time in place of disk, soft surfaces and status colors.
- Removed the responsiveness subtext and reduced the speed cards to 160 points in Impact and 84 points in the compact view.
- Exercised Today / 7 days / All time, Impact details, Burn Log, finding details and Settings navigation.
- Used the demo-only animation control: count changed from 128 to 146, memory from 6.4 to 7.6 GB; the flame perked, six embers rose, then the surface settled. [Native animation capture](media/burn.gif).
- Verified the real NSPopover through accessibility. The persistent compact capture hosts the identical view to avoid transient dismissal during capture.
- Live UI testing reviewed an explicitly registered sacrificial helper, protected and unprotected it, previewed a graceful stop, and requested it. A later independent helper became eligible automatically, was stopped through the native preview flow, and completed its recurrence watch. The lifetime count remained one while verification was pending, then became two; memory, CPU-time and before/after responsiveness values updated. The exact test child was gone and subsequent refreshes did not credit it again. No active user workload was terminated.

Two integration gaps surfaced during native acceptance. First, observations were not advancing reliably without manual refresh: the timer now runs explicitly on the main run loop in common modes. Settings showed successive automatic observations at 12:17:00 and 12:17:53 on the development host, followed by automatic eligibility. Second, a direct saved-catalog read showed that newly displayed credit could wait for the periodic checkpoint. Terminal receipt changes now trigger an immediate checkpoint, retrying on storage failure. The lifecycle regression reads the saved receipt and totals without calling `checkpoint()` itself.

The animation observes newly verified lifetime-count increments, skips initial catalog loading, and never credits a pending or failed request. Reduced Motion suppresses the custom burst and counter transitions; the OS preference itself was not changed on the development host. Full VoiceOver, multiple display arrangements and installed permission flows remain unvalidated.

## Operating budgets

These are targets for stable monitoring around 1,000 visible processes, not hard OS quotas or promises for every workload.

| Dimension | Budget / enforcement |
|---|---|
| Idle CPU | Under 0.5% of one core over five minutes |
| Physical memory | Under 128 MiB sampled physical footprint at this workload |
| Wakeups | Under one interrupt wakeup/second on average; also report package-idle wakeups |
| Catalog | Hard 4 MiB compressed checkpoint and 24 MiB decoded ceiling; 4,096 records × eight samples |
| Ownership files | Hard 256 leases × 256 KiB, 512 members each; maximum 64 MiB payloads |
| History | Hard 500 detailed attempts / 30 days; disappeared records retained at most 24 hours |
| Disk writes | Typical stable-monitoring target under 256 MiB/day of logical writes, extrapolated from the measured interval |

Normal checkpoints occur every five minutes. Preferences, grants and receipts require additional durable writes. At the hard 4 MiB checkpoint ceiling, that cadence alone can approach 1.125 GiB/day; the typical-write target is not a daily quota. High wrapper churn adds writes. Atomic replacement temporarily needs an extra checkpoint; interrupted-write debris is pruned. No continuous log is written.

### Measured development soak

The build with the corrected native scheduler ran for **600.001 seconds**, with 61 samples across automatic monitoring, native UI interaction and a controlled cleanup. The catalog reached its 4,096-record retention ceiling during development process churn. These establish bounded development behavior, not weeks of reliability.

| Metric | 10-minute automatic monitoring and cleanup |
|---|---:|
| CPU, percent of one core | 0.01172% |
| Physical footprint start → end | 92.49 → 133.02 MiB |
| Sampled peak physical footprint | 133.06 MiB |
| Interrupt wakeups / second | 0.7683 |
| Package-idle wakeups / second | 0 |
| Disk bytes written | 1,716,224 |
| Logical bytes written | 1,859,584 |

CPU and wakeups met their targets. Peak memory exceeded the 128 MiB target by 5.06 MiB. The subsequent build adds an autorelease pool around each synchronous observation pass to bound temporary Foundation allocations.

A **300.005-second** follow-up on that final build, using the same full catalog after restart, collected 31 samples. It measured **0.00333% of one CPU core**, **91.95 → 103.70 MiB physical footprint** (103.70 MiB sampled peak), **0.2067 interrupt wakeups/second**, and zero package-idle wakeups. These sampled CPU, memory and wakeup results met the targets. This interval contained no checkpoint write; its zero disk/logical-write deltas are not a zero daily-write claim. The longer run above includes real durable writes. The five-minute follow-up does not establish a long-uptime memory ceiling.

The app bundle is approximately 3.3 MiB on disk, including artwork and the bundled font. After testing, the final app was started with its normal private storage; test receipts remained in isolated validation storage, and automatic cleanup remained off.

Earlier 15-minute and five-minute development measurements predated the scheduler repair. They are not used as proof of unattended monitoring. Raw process evidence remains private; only aggregate results are published.

## What the numbers mean

A burned helper means its exact registered identity exited and no matching executable was seen during the finite watch. Memory released attributes pre-stop resident footprint and may overlap shared pages. CPU time saved is a one-hour projection of the observed pre-stop CPU rate, credited once; it is not CPU already consumed or guaranteed future savings. Agent speed compares the median of seven local command launches after a warm-up, before cleanup and after verification. It is a local responsiveness estimate, not remote model or network speed. Older missing measurements remain unavailable.

No file-cleanup, universal Mac-speed, avoided-recurrence or time-saved claim is made. Independent churn, cache/scheduling changes, App Nap and sparse sampling affect the evidence. Brief respawns between samples can escape observation. Long gaps reset eligibility.

## Reproduce safely

```sh
scripts/test.sh
scripts/test.sh --integration
scripts/build-app.sh
open dist/BurnZombies.app
# Use the exact PID of your own app instance; measure never signals it.
dist/BurnZombies.app/Contents/MacOS/burnzombies measure APP_PID 900
```

Use an isolated `BURNZOMBIES_HOME` for fixtures. Keep catalogs, personal paths and raw diagnostics private. Public evidence contains only controlled preview captures, fixture outcomes, aggregate measurements and reproducible commands.
