# Validation and overhead

Validation date: 2026-10-25. Development host: Apple Silicon, macOS 15.8.1, 16 logical CPUs, 128 GiB RAM, Swift 6.2.3 / Command Line Tools. The application targets macOS 14+. Other OS versions and Intel hardware have not been locally validated.

## Automated evidence

`scripts/test.sh --integration`: **35 checks, zero failures**, plus the full three-worker lifecycle. The three independently owned detached helpers became eligible after **196 seconds** of monitoring; cleanup, recurrence watching, CPU projections, deduplication and persisted accounting completed at **327 seconds**. The wrapper setup occurs before this timed monitor interval.

Coverage includes explicit authority, active/unknown owners, consumed permissions, PID reuse and executable changes, real and synthetic zombies, CPU/disk activity, grace periods, stale/missing observations, protection/snooze, independent jobs, sustained growth, restart loops, restart/wake continuity reset, private storage, corruption, symlinks, single-instance locking, retention, partial/unknown/recurring outcomes, interrupted verification, actual SIGTERM, a real hung process, and real wrapper cancellation.

### Pressure tests

- **32 simultaneous real kernel zombies + eight live idle controls, five inventory passes.** All 32 unreaped children were found and classified as kernel zombies on every pass. All eight live controls remained alive and were never mislabeled as zombies. Native signaling refused every zombie. No cleanup authority was inferred. Test teardown reaped only its own exited children and stopped only its own live controls.
- **4,096 mixed policy cases.** Exactly 512 explicitly owned, abandoned, idle cases qualified. Active owners, unknown owners, consumed grants, missing metrics, fresh disk activity, reused identities and protected workers were refused. These are deterministic simulations, not a measured false-positive rate on arbitrary user workloads.
- **Three independent real abandoned helpers.** Each retained its own ownership record and one-attempt grant. All exited after SIGTERM, passed the recurrence watch, and contributed exactly once to count, resident-footprint and CPU-projection totals. Reloaded accounting matched. Both responsiveness probes were present.
- **Accounting regression.** A large historical CPU total is subtracted out: only the sampled rate is projected. Missing data produces no estimate; an idle baseline produces zero. Repeated refresh does not double-count.

The original real-kernel-zombie test failed before the sysctl fallback and passed afterward. Its parent deliberately leaves an exited child unreaped, checks direct and inventory detection, checks zero resident footprint and refusal to signal, then calls `waitpid`.

The cancellation test uses the real wrapper and `/bin/sleep`, verifies membership, cancels the wrapper, and confirms its child exits and the lease ends without cleanup permission. The hung fixture ignores SIGTERM; the product records partial failure without escalation. Test teardown alone can forcibly remove its own exact sacrificial fixture.

Sleep/wake, app restart, PID reuse, missing metrics and partial visibility are state-machine tests. No physical sleep, forced system crash, permission-policy change, notification grant or login-item enablement was performed. Full OS-matrix and long-uptime field validation remain future work.

## Native operator journeys

The final 428 × 795-point compact view and 1008 × 930-point Impact window were inspected in native macOS rendering. Public [Impact](media/impact.jpg), [compact](media/menu-bar.jpg) and [Burn Log](media/burn-log.jpg) captures use synthetic demo data only.

- Fixed the headline using actual glyph ink bounds, verified the two-line spacing, mascot, subtitle clearance and metric alignment.
- Checked smaller unit type, CPU time in place of disk, soft surfaces and status colors.
- Removed the responsiveness subtext and reduced the speed cards to 160 points in Impact and 84 points in the compact view.
- Exercised Today / 7 days / All time, Impact details, Burn Log, finding details and Settings navigation.
- Used the demo-only animation control: count changed from 128 to 146, memory from 6.4 to 7.6 GB; the flame perked, six embers rose, then the surface settled. [Native animation capture](media/burn.gif).
- Verified the real NSPopover through accessibility. The persistent compact capture hosts the identical view to avoid transient dismissal during capture.
- Earlier live UI testing reviewed an explicitly registered sacrificial helper, protected and unprotected it, previewed a graceful stop, requested it, and confirmed a persisted receipt with exactly one helper credited. No active user workload was terminated.

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

A release build before the final visual refinement ran for **900.004 seconds**, with 91 samples across monitoring, native UI interaction and a controlled cleanup. Its five-minute settled interval was measured separately. These establish bounded development behavior, not weeks of reliability.

| Metric | 15-minute mixed activity | 5-minute settled interval |
|---|---:|---:|
| CPU, percent of one core | 0.00656% | 0.00239% |
| Physical footprint start → end | 74.27 → 110.03 MiB | 102.69 → 110.05 MiB |
| Sampled peak physical footprint | 112.14 MiB | 112.14 MiB |
| Interrupt wakeups / second | 0.4211 | 0.0800 |
| Package-idle wakeups / second | 0 | 0 |
| Disk bytes written | 1,511,424 | 618,496 |
| Logical bytes written | 1,617,920 | 630,784 |

The settled write rate extrapolates to roughly **173 MiB/day**, not a measured day-long total. The observed catalog checkpoint was 615,817 bytes with 2,972 retained records. The final app bundle is approximately 3.2 MiB on disk, including artwork and the bundled font. Individual process visibility and unrelated workload churn vary over time.

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

Use an isolated `BURNZOMBIES_HOME` for fixtures. Keep catalogs, personal paths and raw diagnostics private. Public evidence contains only synthetic screenshots, fixture outcomes, aggregate measurements and reproducible commands.
