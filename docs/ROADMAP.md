# Small next steps

1. **Long-uptime field validation.** Run opt-in monitoring across several real workload patterns for days, with bounded aggregate telemetry and reviewed false-positive cases. Do not expand automatic categories first.
2. **Owner event sources and teardown adapters.** Evaluate a bounded kqueue/Dispatch source for registered owners. Add explicit MCP/browser/supervisor lifecycle adapters only when the actual session can provide a supported teardown contract. Preserve unknowns and audit event loss.
3. **Quieter workload baselines.** Persist family-level notification signatures and expected pool sizes. Measure false alerts on restarts, interactive browsing, builds and evaluation batches. Add learned ranking only if a labeled dataset demonstrates value; never let ranking grant cleanup authority.
4. **Stronger OS identity signaling.** Investigate a supported, entitlement-compatible audit-token/event path. Keep the PID race documented until proven on all supported OS versions.
5. **Signed distribution.** Developer ID signing, notarization, update verification, installed login-item/notification acceptance, VoiceOver and broader Intel/Apple Silicon coverage.
6. **Owned artifact quarantine.** Only if an integration can attest exact creation ownership, retention, liveness and safe quarantine. No general cache sweeper.
7. **Windows.** Prototype process-handle creation-time identity, explicit ownership through Job Objects, handle/CPU/I/O observation, and a native tray surface. Port catalog/rule concepts; do not assume macOS ancestry or termination semantics.
8. **Richer responsiveness measurements.** Extend the existing local command-launch median with optional matched tool-latency trials, p50/p95, dispersion and workload context. Keep missing measurements unavailable; never extrapolate to remote model speed.
