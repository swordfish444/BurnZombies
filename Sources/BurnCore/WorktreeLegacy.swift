import Darwin
import Foundation

extension WorktreeService {
  nonisolated func finishMigration() throws { try store.put("ready", kind: "migration", id: "legacy") }
  public func legacyClaims() throws -> [WorkspaceClaim] {
    let retired = Set(try records().filter(\.retired).map(\.id))
    return try store.values(WorkspaceClaim.self, kind: "legacy").filter { !retired.contains($0.id) }
  }
  static func importLegacy(_ old: WorkspaceClaim, into store: WorktreeStore) throws {
    guard !(try store.values(WorkspaceClaim.self, kind: "legacy")).contains(where: { $0.id == old.id }) else { return }
    let i = old.identity
    let cs = try? WorkspaceSafety.statAt(i.common), ads = try? WorkspaceSafety.statAt(i.gitDirectory)
    var row = WorktreeRecord(id: old.id, path: i.path, repository: i.common,
      identity: .init(path: i.path, common: i.common, administration: i.gitDirectory, device: i.device, inode: i.inode,
        commonInode: cs?.st_ino ?? 0, administrationInode: ads?.st_ino ?? 0))
    row.managed = true; row.firstSeen = old.created; row.head = old.head
    let claim = WorktreeClaim(id: old.id, worktreeID: row.id, tokenHash: old.tokenHash, label: old.label,
      condition: old.completionCondition, evidence: old.evidence, state: old.state, head: old.head, updated: old.updated)
    try store.transaction {
      try store.put(old, kind: "legacy", id: old.id); try store.put(row, kind: "record", id: row.id)
      try store.put(row.id, kind: "location", id: WorkEvidence.hash(row.repository + "|" + row.path))
      try store.put(claim, kind: "claim", id: claim.id)
    }
  }
  public func legacyRequest(_ q: AgentRequest) async throws -> (String?, String, WorkspaceClaim?) {
    try requireAccess(); guard !executing || q.action == "retain" else { throw StoreError.message("A worktree operation is running.") }
    guard let action = q.action, let evidence = q.rationale, (20...1200).contains(evidence.count) else { throw StoreError.message("Factual ownership evidence required.") }
    if action == "create" {
      guard let rawRepository = q.workspacePath, rawRepository.hasPrefix("/"), let label = q.label,
        (1...80).contains(label.count), let condition = q.completionCondition, (10...500).contains(condition.count),
        try legacyClaims().count < 64 else { throw StoreError.message("Exact repository, task label and completion condition required; at most 64 legacy workspaces.") }
      let repository = WorkspaceSafety.canonical(rawRepository)
      let config = try WorktreeGit.text(repository, ["config", "--null", "--name-only", "--list"])
      guard !config.split(separator: "\0").contains(where: { $0.hasPrefix("filter.") }) else { throw StoreError.message("Checkout filters require the owning tool.") }
      let parent = store.root.appendingPathComponent("workspaces")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      _ = try WorkspaceSafety.statAt(parent.path)
      let id = UUID().uuidString, path = parent.appendingPathComponent(id).path
      let head = try WorktreeGit.line(repository, ["rev-parse", "HEAD^{commit}"])
      _ = try WorktreeGit.run(repository, ["worktree", "add", "--detach", "--", path, head])
      let identity = try WorkspaceSafety.identity(path, root: store.root)
      let token = UUID().uuidString + UUID().uuidString
      let old = WorkspaceClaim(id: id, tokenHash: WorkEvidence.hash(token), identity: identity, label: label,
        purpose: evidence, completionCondition: condition, state: "active", evidence: evidence, head: nil, created: Date(), updated: Date())
      try Self.importLegacy(old, into: store)
      _ = try await inspect(id)
      return (token, "Disposable worktree created with a private owner token. Release only after preserving output and finishing consumers.", old)
    }
    guard ["release", "retain"].contains(action), let token = q.workToken,
      var old = try legacyClaims().first(where: { $0.tokenHash == WorkEvidence.hash(token) }) else { throw StoreError.message("Owning workspace token required.") }
    _ = try await request(.init(action, token: token, evidence: evidence), caller: "legacy-owner")
    let row = try record(old.id); old.state = action == "release" ? "released" : "active"; old.head = action == "release" ? row.head : nil
    old.evidence = evidence; old.updated = Date(); try store.put(old, kind: "legacy", id: old.id)
    if action == "release" { try HarnessHook.requestCleanup(root: store.root) }
    return (nil, "Workspace owner evidence saved; no files removed.", old)
  }
  public func legacyPreview(_ id: String) async throws -> WorkspaceClaim {
    guard let old = try legacyClaims().first(where: { $0.id == id }) else { throw StoreError.message("Unknown legacy workspace.") }
    let row = try await inspect(id)
    _ = try WorkspaceSafety.check(old, root: store.root, visibility: visibility)
    try eligible(row, dirty: false, automatic: false); return old
  }
  public func legacyClean(_ old: WorkspaceClaim) async throws -> WorktreeOperation {
    let current = try await legacyPreview(old.id)
    guard current.updated == old.updated, current.head == old.head else { throw StoreError.message("Workspace claim changed after preview.") }
    let r = try record(old.id), p = try await preview(.init("preview", id: r.id, revision: r.revision), caller: "legacy-executor", dirty: false, automatic: false)
    return try await retire(p.token, caller: "legacy-executor", dirty: false)
  }
  public func projectedReceipts() throws -> [WorkspaceReceipt] {
    let rows = try records()
    return try store.values(WorktreeOperation.self, kind: "operation").filter { $0.phase == "completed" }.compactMap { op in
      guard let r = rows.first(where: { $0.id == op.worktreeID }), let i = r.identity, let id = UUID(uuidString: op.id) else { return nil }
      return WorkspaceReceipt(id: id, workspaceID: r.id,
        identity: .init(path: i.path, common: i.common, gitDirectory: i.administration, device: i.device, inode: i.inode),
        label: "Worktree retired", head: op.head, recoveryRef: "refs/burnzombies/worktrees/" + op.id,
        date: op.date, verifiedAt: op.completedAt, outcome: "verified", diskReclaimedBytes: op.diskCredit,
        detail: op.detail + " Restore through Worktrees → Recovery: " + op.id)
    }
  }
}
