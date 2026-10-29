import CryptoKit
import Foundation

extension WorktreeService {
  func captureKey(interactive: Bool) throws -> SymmetricKey {
    // Never silently replace a missing key while known archives still depend on it.
    let needsExisting = try store.values(WorktreeOperation.self, kind: "operation").contains {
      !$0.purged && $0.archiveDigest != nil
    }
    if needsExisting { return try interactive ? interactiveExistingKey() : existingRecoveryKey() }
    return try interactive ? interactiveRecoveryKey() : recoveryKey()
  }
  func reconcile(_ q: WorktreeRequest) async throws -> WorktreeOperation {
    guard q.evidence == "RECONCILE RECOVERY", let id = q.id,
      var op = try store.value(WorktreeOperation.self, kind: "operation", id: id),
      op.phase == "uncertain"
    else {
      throw StoreError.message("Select an uncertain operation and explicitly reconcile recovery.")
    }
    var row = try record(op.worktreeID)
    executing = true
    defer { executing = false }
    let repositoryLock = try InstanceLock(
      url: URL(fileURLWithPath: op.repository).appendingPathComponent("burnzombies-worktree.lock"))
    defer { withExtendedLifetime(repositoryLock) {} }
    let exists = FileManager.default.fileExists(atPath: op.originalPath)
    if let digest = op.archiveDigest, !op.purged {
      let key = try interactiveExistingKey()
      let captured = op
      let check = URL(fileURLWithPath: op.recoveryPath).appendingPathComponent(
        "reconcile-" + UUID().uuidString
      ).path
      defer { try? FileManager.default.removeItem(atPath: check) }
      try await runWork {
        try WorktreeRecovery.restore(captured, destination: check, key: key, digest: digest)
      }
      try FileManager.default.removeItem(atPath: check)
      if exists {
        let fresh = WorktreeInspection.inspect(row, visibility: visibility)
        guard fresh.identity == row.identity else {
          throw StoreError.message(
            "Original directory identity changed; preserve recovery and resolve ownership.")
        }
        try await runWork {
          try WorktreeRecovery.verifySource(fresh, operation: captured, key: key)
        }
        row = fresh
        op.phase = "failed"
        op.detail =
          "Original content and independent recovery verified intact. The interrupted action is not replayed; a new reviewed action is required."
      } else if let path = op.quarantinePath, FileManager.default.fileExists(atPath: path) {
        let moved = try WorktreeInspection.identity(path)
        guard moved.inode == row.identity?.inode, moved.device == row.identity?.device,
          moved.common == row.repository
        else { throw StoreError.message("Quarantine identity is ambiguous; preserve it.") }
        var fresh = row
        fresh.path = path
        fresh.identity = moved
        try await runWork {
          try WorktreeRecovery.verifySource(fresh, operation: captured, key: key)
        }
        op.quarantineIdentity = moved
        op.phase = "quarantined"
        row.retired = true
        op.detail =
          "Exact quarantined checkout and independent recovery verified. No removal or disk credit."
      } else {
        let registrations = try WorktreeDiscovery.parse(
          WorktreeGit.run(op.repository, ["worktree", "list", "--porcelain", "-z"]),
          repository: op.repository)
        guard !registrations.contains(where: { $0.path == op.originalPath }) else {
          throw StoreError.message(
            "Missing directory still has a registration; resolve it before reconciliation.")
        }
        op.phase = "reconciled-absent"
        row.retired = true
        op.detail =
          "Checkout is absent and independent restoration verified. Cleanup attribution is unknown; no cleanup or disk credit."
      }
    } else {
      guard exists,
        ["prepared", "preserving", "preservation-verified"].contains(op.interruptedPhase ?? ""),
        try WorktreeInspection.identity(op.originalPath) == row.identity
      else {
        throw StoreError.message(
          "No verified archive or proven pre-mutation state; preserve this operation for manual recovery."
        )
      }
      op.phase = "failed"
      op.detail =
        "Preparation was interrupted before any removal phase. Original directory remains. No verified archive or benefit claimed."
    }
    op.diskCredit = 0
    try store.transaction {
      try save(op)
      try store.put(row, kind: "record", id: row.id)
    }
    return op
  }
}
