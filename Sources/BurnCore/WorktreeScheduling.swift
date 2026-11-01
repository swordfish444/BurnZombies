import Foundation

extension WorktreeService {
  public func tick() async throws -> [ReviewEvidence]? {
    try requireAccess()
    try refreshDiscoveryRoots()
    // An existing flight owns publication. Do not replace its previous evidence
    // with a transient error, nor begin a second inspection batch.
    guard !scanning, !executing, !refreshingFindings else { return nil }
    if !scanning, !executing, Date().timeIntervalSince(lastScan) >= 6 * 3600,
      !(try policy().roots).isEmpty
        || FileManager.default.fileExists(
          atPath: store.root.appendingPathComponent("workspaces").path)
    {
      _ = try await scan()
    }
    guard !scanning, !executing else { return nil }
    try await refreshKnownFindings()
    return try reviewEvidence()
  }
  /// Discovery stays cheap between full scans, but decision evidence cannot live
  /// for six hours. Refresh up to eight oldest known checkouts, sharing one
  /// native consumer snapshot, with a bounded inspection budget each tick.
  private func refreshKnownFindings() async throws {
    let p = try policy()
    let privateRoot = store.root.appendingPathComponent("workspaces").path
    func unblocked(_ row: WorktreeRecord) -> Bool {
      row.consumer == "none observed" && row.blockers.isEmpty && row.gaps.isEmpty
    }
    let candidates = try records().filter { row in
      !row.main && !row.bare && !row.retired && !row.kept && !row.ownerManaged
        && Date().timeIntervalSince(row.observedAt)
          >= (unblocked(row) ? 120 : 900)
        && (p.roots.contains(where: { WorkspaceSafety.contains($0, row.path) })
          || WorkspaceSafety.contains(privateRoot, row.path))
    }.sorted { $0.observedAt < $1.observedAt }
    // Reserve progress for both cohorts even after long-lived missing records
    // accumulate. Fill unused slots in oldest-first order.
    let ready = Array(candidates.filter(unblocked).prefix(6))
    let blocked = Array(candidates.filter { !unblocked($0) }.prefix(2))
    var selected: [WorktreeRecord] = []
    for index in 0..<max(ready.count, blocked.count) {
      if index < ready.count { selected.append(ready[index]) }
      if index < blocked.count { selected.append(blocked[index]) }
    }
    let reserved = Set(selected.map(\.id))
    selected += candidates.filter { !reserved.contains($0.id) }.prefix(8 - selected.count)
    guard !selected.isEmpty else { return }
    refreshingFindings = true
    defer { refreshingFindings = false }
    let rows = Array(selected)
    let current = generation
    if let runner = scanRunner {
      let root = store.root
      let identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
      let deadline = ProcessInfo.processInfo.systemUptime + 25
      let result = try await runWork {
        runner.run(
          roots: rows.map(\.path), root: root, knownRecords: rows,
          publish: { _ in }, keepGoing: { ProcessInfo.processInfo.systemUptime < deadline })
      }
      guard current == generation, !executing else { return }
      for row in result.records
      where identities[row.id]?.path == row.path && identities[row.id]?.repository == row.repository
        && !(row.revision.isEmpty && row.gaps == ["Detailed inspection pending."])
      {
        _ = try publish(row)
      }
      if !result.workerCompleted, let id = result.inspectionInProgress,
        let started = result.inspectionStartedAt, (result.inspectionElapsed ?? 0) >= 15,
        var row = identities[id]
      {
        // Only an explicitly started row gets an unknown observation. Deferred
        // rows remain eligible next tick; a slow row backs off for 15 minutes.
        row.observedAt = started
        row.consumer = "unknown"
        row.blockers = []
        row.gaps = ["Inspection exceeded the bounded refresh budget; retry is deferred."]
        _ = try publish(row)
      }
      guard result.workerCompleted, result.gaps.isEmpty else {
        throw StoreError.message("Known worktree refresh: " + result.gaps.joined(separator: ". "))
      }
      return
    }
    // Explicit proof visibility runs only against private bounded fixtures.
    let visibility = visibility
    let fresh = try await runWork {
      let deadline = ProcessInfo.processInfo.systemUptime + 20
      var result: [WorktreeRecord] = []
      for row in rows {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
        result.append(WorktreeInspection.inspect(row, visibility: visibility))
      }
      return result
    }
    guard current == generation, !executing else { return }
    for row in fresh { _ = try publish(row) }
  }
  /// Bypass only the observer cadence. Reuse a scan in flight and wait natively,
  /// leaving it owned by the service if the caller cancels or exhausts its budget.
  public func refreshForHunt(timeout: TimeInterval) async throws -> [ReviewEvidence] {
    try requireAccess()
    try refreshDiscoveryRoots()
    let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
    func waitForReadiness() async throws {
      try Task.checkCancellation()
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else {
        throw StoreError.message(
          "Worktree refresh is still pending; this Hunt has no ready worktree evidence.")
      }
      try await Task.sleep(nanoseconds: UInt64(min(0.05, remaining) * 1e9))
    }
    while executing { try await waitForReadiness() }
    try Task.checkCancellation()
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      throw StoreError.message("Worktree refresh preparation deadline reached.")
    }
    let flight = try scanFlight ?? startScan()
    let current = generation
    while scanFlight?.id == flight.id { try await waitForReadiness() }
    _ = try await flight.task.value
    guard current == generation else {
      throw StoreError.message(
        "Worktree discovery changed during Hunt preparation; evidence is not ready.")
    }
    return try reviewEvidence()
  }
  private func reviewEvidence() throws -> [ReviewEvidence] {
    let p = try policy()
    let now = Date()
    let advice = try store.values(WorktreeAdvice.self, kind: "advice")
    var queue: [ReviewEvidence] = []
    let legacy = try legacyClaims()
    for c in legacy where c.state == "released" {
      let row = try record(c.id)
      queue.append(
        .init(
          id: c.id,
          revision: WorkEvidence.hash(
            c.id + "|\(c.updated.timeIntervalSinceReferenceDate)|" + (row.readinessRevision ?? "")),
          processCount: 0))
    }
    for r in try records() where !r.retired && !r.kept && !r.main && !r.bare {
      guard p.roots.contains(where: { WorkspaceSafety.contains($0, r.path) }) else { continue }
      if legacy.contains(where: { $0.id == r.id }) { continue }
      if (try? eligible(r, dirty: false, automatic: true)) != nil {
        queue.append(
          .init(
            id: "worktree:" + r.id,
            revision: WorkEvidence.hash(
              r.revision + (r.readinessRevision ?? "") + (try claimRevision(r.id))
                + p.authorityRevision),
            processCount: 0))
      } else if now.timeIntervalSince(r.changedAt) >= Double(p.staleDays) * 86400
        || (r.apparentIdleDays ?? 0) >= p.staleDays,
        !advice.contains(where: {
          $0.id == r.id && $0.revision == r.revision && $0.readinessRevision == r.readinessRevision
        })
      {
        queue.append(
          .init(
            id: "worktree-advice:" + r.id,
            revision: WorkEvidence.hash(r.revision + (r.readinessRevision ?? "")), processCount: 0,
            recommendationOnly: true))
      }
    }
    return Array(queue.prefix(32))
  }
}
