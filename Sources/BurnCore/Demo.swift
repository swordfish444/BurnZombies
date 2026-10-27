import Foundation

public enum Demo {
  public static func state(now: Date = Date(), calendar: Calendar = .current) -> ViewState {
    var state = ViewState()
    state.processCount = 128
    let today = calendar.startOfDay(for: now)
    addBurn(in: &state.catalog, count: 512, memory: 24_000_000_000, cpu: 15 * 3600,
      date: calendar.date(byAdding: .day, value: -12, to: today)!)
    addBurn(in: &state.catalog, count: 240, memory: 12_000_000_000, cpu: 7.5 * 3600,
      date: calendar.date(byAdding: .day, value: -3, to: today)!)
    addBurn(in: &state.catalog, count: 110, memory: 5_200_000_000, cpu: 3.8 * 3600 - 60,
      date: today)
    recordBurn(in: &state.catalog, now: max(today, now.addingTimeInterval(-120)))
    addWorkspaces(in: &state.catalog, count: 4, disk: 2_100_000_000, date: today)
    addWorkspaces(in: &state.catalog, count: 8, disk: 4_700_000_000, date: calendar.date(byAdding: .day, value: -3, to: today)!)
    addWorkspaces(in: &state.catalog, count: 6, disk: 3_200_000_000, date: calendar.date(byAdding: .day, value: -12, to: today)!)
    let owner = ProcessIdentity(pid: 90000, seconds: 1)
    let o = Observation(
      identity: ProcessIdentity(pid: 90001, seconds: 2), executable: "/example/disposable-helper",
      rss: 48 * 1024 * 1024, time: now, monotonic: 200)
    state.catalog.records[o.identity.key] = Record(o)
    let lease = Lease(
      label: "Finished helper job", owner: owner, members: [Member(o)], allowCleanup: true)
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

  /// Preview receipts stay in memory and use the same period accounting as real receipts.
  public static func recordBurn(in catalog: inout Catalog, now: Date = Date()) {
    addBurn(in: &catalog, count: 18, memory: 1_200_000_000, cpu: 60, date: now)
  }

  private static func addWorkspaces(in catalog: inout Catalog, count: Int, disk: UInt64, date: Date) {
    for _ in 0..<count {
      let receipt = WorkspaceReceipt(id: UUID(), workspaceID: UUID().uuidString,
        identity: .init(path: "/example/disposable-worktree", common: "/example/repo/.git", gitDirectory: "/example/repo/.git/worktrees/example", device: 0, inode: 0),
        label: "Completed task worktree", head: String(repeating: "0", count: 40), recoveryRef: "refs/burnzombies/worktrees/example",
        date: date, verifiedAt: date, outcome: "verified", diskReclaimedBytes: disk / UInt64(count), detail: "In-memory preview receipt.")
      catalog.workspaceReceipts = (catalog.workspaceReceipts ?? []) + [receipt]
    }
    catalog.lifetimeWorktreesCleaned = (catalog.lifetimeWorktreesCleaned ?? 0) + count
    catalog.lifetimeDiskReclaimedBytes = (catalog.lifetimeDiskReclaimedBytes ?? 0) + disk
  }

  private static func addBurn(in catalog: inout Catalog, count: Int, memory: UInt64, cpu: Double, date: Date) {
    var event = CleanupEvent(leaseID: UUID(), label: "Disposable helpers", date: date,
      targets: [], residentBefore: memory, outcome: "verified", detail: "In-memory preview receipt.")
    event.verifiedCount = count
    event.verificationDate = date
    event.cpuSecondsSavedEstimate = cpu
    event.responseBeforeMS = 2100
    event.responseAfterMS = 1700
    event.responseBeforeSamples = Array(repeating: 2100, count: 7)
    event.responseAfterSamples = Array(repeating: 1700, count: 7)
    catalog.events.append(event)
    catalog.lifetimeActions += 1
    catalog.lifetimeVerified += count
    catalog.lifetimeResidentReleased = (catalog.lifetimeResidentReleased ?? 0) + memory
    catalog.lifetimeCPUSecondsSaved = (catalog.lifetimeCPUSecondsSaved ?? 0) + cpu
  }
}
