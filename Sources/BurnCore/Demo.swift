import Foundation

public enum Demo {
  public static func state() -> ViewState {
    var state = ViewState()
    state.processCount = 128
    let now = Date()
    let owner = ProcessIdentity(pid: 90000, seconds: 1)
    let o = Observation(
      identity: ProcessIdentity(pid: 90001, seconds: 2), executable: "/example/disposable-helper",
      rss: 48 * 1024 * 1024, time: now, monotonic: 200)
    state.catalog.records[o.identity.key] = Record(o)
    let lease = Lease(
      label: "Finished browser test", owner: owner, members: [Member(o)], allowCleanup: true)
    state.findings = [
      Finding(
        id: lease.id.uuidString, title: lease.label, disposition: .eligible,
        reason: "These helpers remained after their session ended.",
        evidence: [
          "Explicit disposable-helper permission", "Owning session ended four minutes ago",
          "Repeated idle observations; no recent disk activity",
        ],
        uncertainty:
          "Demo data. This preview cannot signal any process. Detached children may escape observation in real workloads.",
        members: [o.identity.key], leaseID: lease.id, rss: o.rss),
      Finding(
        id: "growth", title: "Analysis worker", disposition: .investigate,
        reason: "Memory has kept growing across repeated observations.",
        evidence: ["Resident footprint grew by 320 MiB across six observations"],
        uncertainty:
          "Session ownership is unknown. Growth can be legitimate work; no stop action is available.",
        members: [], leaseID: nil, rss: 768 * 1024 * 1024),
      Finding(
        id: "active", title: "Overnight evaluation", disposition: .protected,
        reason: "The owning session is still running. Its helpers are protected.",
        evidence: ["Launch wrapper is alive", "Exact process identities match"],
        uncertainty: "A long runtime alone does not establish abandonment.", members: [],
        leaseID: nil, rss: 128 * 1024 * 1024),
    ]
    return state
  }
}
