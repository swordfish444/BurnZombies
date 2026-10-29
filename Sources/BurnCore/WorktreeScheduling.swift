import Foundation

extension WorktreeService {
  public func tick() async throws -> [ReviewEvidence] {
    try requireAccess()
    if !scanning, !executing, Date().timeIntervalSince(lastScan) >= 6 * 3600,
      !(try policy().roots).isEmpty || FileManager.default.fileExists(atPath: store.root.appendingPathComponent("workspaces").path) { _ = try await scan() }
    let p = try policy(), now = Date()
    let advice = try store.values(WorktreeAdvice.self, kind: "advice")
    var queue: [ReviewEvidence] = []
    let legacy = try legacyClaims()
    for c in legacy where c.state == "released" {
      let row = try record(c.id)
      queue.append(.init(id: c.id, revision: WorkEvidence.hash(c.id + "|\(c.updated.timeIntervalSinceReferenceDate)|" + (row.readinessRevision ?? "")), processCount: 0))
    }
    for r in try records() where !r.retired && !r.kept && !r.main && !r.bare {
      if legacy.contains(where: { $0.id == r.id }) { continue }
      if (try? eligible(r, dirty: false, automatic: true)) != nil {
        queue.append(.init(id: "worktree:" + r.id,
          revision: WorkEvidence.hash(r.revision + (r.readinessRevision ?? "") + (try claimRevision(r.id)) + p.revision), processCount: 0))
      } else if (now.timeIntervalSince(r.changedAt) >= Double(p.staleDays) * 86400 || (r.apparentIdleDays ?? 0) >= p.staleDays),
        !advice.contains(where: { $0.id == r.id && $0.revision == r.revision }) {
        queue.append(.init(id: "worktree-advice:" + r.id, revision: r.revision, processCount: 0, recommendationOnly: true))
      }
    }
    return Array(queue.prefix(32))
  }
}
