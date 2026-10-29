import Foundation

extension WorktreeService {
  func repair(_ q: WorktreeRequest) async throws -> WorktreeRecord {
    let old = try expected(q)
    guard old.missing, !old.main, !old.bare, !old.ownerManaged, !old.locked,
      let original = old.identity,
      let path = q.path, path == WorkspaceSafety.canonical(path),
      try policy().roots.contains(where: { WorkspaceSafety.contains($0, path) }),
      !FileManager.default.fileExists(atPath: old.path)
    else {
      throw StoreError.message(
        "Repair requires an exact recorded moved checkout, an allowed new location and an absent old location."
      )
    }
    let moved = try WorktreeInspection.identity(path)
    guard moved.device == original.device, moved.inode == original.inode,
      moved.common == original.common,
      moved.commonInode == original.commonInode, moved.administration == original.administration,
      moved.administrationInode == original.administrationInode
    else {
      throw StoreError.message(
        "The selected directory is not the exact recorded moved worktree. Use the owner for ambiguous copies."
      )
    }
    for name in [
      "locked", "index.lock", "HEAD.lock", "MERGE_HEAD", "rebase-merge", "rebase-apply",
      "sequencer",
    ] {
      guard !FileManager.default.fileExists(atPath: moved.administration + "/" + name) else {
        throw StoreError.message("Complete Git operations and resolve locks before repair.")
      }
    }
    executing = true
    defer { executing = false }
    let repositoryLock = try InstanceLock(
      url: URL(fileURLWithPath: old.repository).appendingPathComponent("burnzombies-worktree.lock"))
    defer { withExtendedLifetime(repositoryLock) {} }
    var op = try operation(old, kind: "repair")
    try save(op)
    do {
      _ = try WorktreeGit.run(old.repository, ["worktree", "repair", "--", path])
      var row = old
      row.path = path
      row.identity = moved
      row.missing = false
      row.managed = false
      row.confirmedRevision = nil
      row.confirmedAt = nil
      row = WorktreeInspection.inspect(row, visibility: visibility)
      guard row.identity == moved,
        !row.gaps.contains(where: { $0.contains("backlink") || $0.contains("registration") })
      else { throw StoreError.message("Registration repair did not verify.") }
      op.phase = "repaired"
      op.detail = "Moved checkout registration repaired. No content removed or storage credited."
      try store.transaction {
        try store.put(row, kind: "record", id: old.id)
        try store.put(
          old.id, kind: "location", id: WorkEvidence.hash(row.repository + "|" + row.path))
        try save(op)
      }
      return row
    } catch {
      op.phase = "uncertain"
      op.detail = error.localizedDescription
      try? save(op)
      throw error
    }
  }
}
