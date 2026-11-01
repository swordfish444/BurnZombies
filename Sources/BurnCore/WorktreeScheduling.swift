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
    let selected = try records().filter { row in
      !row.main && !row.bare && !row.retired && !row.kept && !row.ownerManaged
        && Date().timeIntervalSince(row.observedAt) >= 120
        && (p.roots.contains(where: { WorkspaceSafety.contains($0, row.path) })
          || WorkspaceSafety.contains(privateRoot, row.path))
    }.sorted { $0.observedAt < $1.observedAt }.prefix(8)
    guard !selected.isEmpty else { return }
    refreshingFindings = true
    defer { refreshingFindings = false }
    let rows = Array(selected)
    let current = generation
    let customVisibility = scanRunner == nil ? visibility : nil
    let fresh = try await runWork {
      let deadline = ProcessInfo.processInfo.systemUptime + 20
      let consumers =
        customVisibility == nil ? WorktreeConsumerSnapshot(roots: rows.map(\.path)) : nil
      let visibility: @Sendable (String) -> Int32 = { path in
        customVisibility?(path) ?? consumers!.state(path)
      }
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
