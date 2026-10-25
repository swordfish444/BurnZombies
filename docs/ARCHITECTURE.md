# Architecture

```text
NSStatusItem / SwiftUI impact + detail views
             │
          Monitor actor ── deterministic DecisionEngine
             │            finite Verification states
     private bounded Catalog + receipt journal
             │
       Native adapter ── small C / libproc / sysctl boundary

burnzombies run ── observed identity/parent edges ── private Lease files
```

One monitor holds a nonblocking advisory lock on its state directory. The actor serializes catalog changes and permits only one cleanup at a time. A second instance can show an error but cannot become a competing monitor or cleanup worker. Wrappers serialize lease admission separately, then run independently. Lock descriptors are close-on-exec and released by process exit.

## Sampling and storage

The monitor reads current-user processes every 60 seconds when stable, or 15 seconds around actionable owned activities and receipt verification. Timer tolerance permits coalescing. It retains approximately minute-spaced samples so a brief faster polling period does not destroy the multi-minute growth baseline. Observation time and continuous monotonic time are separate; clock jumps and long gaps reset continuity.

Catalog persistence uses a compressed Codable checkpoint instead of a database dependency. At this bounded scale, a five-minute atomic checkpoint plus immediate writes for settings/actions is simple to inspect and recover. Recent uncheckpointed observations can be lost on a crash; cleanup intent and consumed permissions are persisted before irreversible action. Decompression and encoded sizes have fixed limits. No continuous diagnostic log is written.

The catalog is intentionally not a complete forensic flight recorder. A system-wide crash ends an observation epoch. It cannot turn missing processes into labeled abandonment examples. A longer event history would require a separate storage/overhead decision.

## Clean separation

- `Models.swift`: stable identities, samples, leases, findings, receipts, preferences.
- `DecisionEngine.swift`: pure classification; accepts owner facts rather than making OS calls.
- `Verification.swift`: finite receipt states with conservative partial/unknown/recurrence outcomes.
- `Monitor.swift`: actor, sampling, revalidation, journal, one-attempt action orchestration.
- `Store.swift`: private bounded atomic persistence; no arbitrary filesystem exploration.
- `Native.swift` / `CBurn`: OS observations, identity-checked SIGTERM, descriptor summaries and measurement counters.
- `ImpactAccounting.swift`: bounded CPU-time projection; `Responsiveness.swift`: timed local probe.
- `BurnApp`: native views, verified-receipt celebration and opt-in system integration.
- `BurnCLI`: explicit launch ownership; standard streams are inherited without capture.
- `AgentBridge.swift` / `AgentSocket.c`: same-user private IPC to the app's existing monitor; bounded frames, single-use previews, and a blocking listener with an explicit shutdown signal.
- `BurnMCP`: official SDK stdio server; exposes status, preview and burn plus the `tame_the_horde` prompt. It does not own a catalog or create a second cleanup worker.
- `Proof`: dependency-free tests and sacrificial processes.

The native app and monitor have no third-party dependencies. The separate MCP executable links the official MCP Swift SDK, Swift System, Swift Log and EventSource; their notices ship in the app bundle. No Node or Python runtime is needed to use the release. The macOS-specific call boundary is narrow enough to replace later; it is not hidden behind a speculative platform abstraction. Windows needs handle/creation-time identity and Job Objects, plus a native tray UI. Its semantics must be tested independently rather than translating POSIX signals mechanically.
