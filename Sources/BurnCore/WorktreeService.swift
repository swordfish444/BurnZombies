import CBurn
import CryptoKit
import Darwin
import Foundation

/// One authority for inventory, policy, claims and worktree operations.
public actor WorktreeService {
  let store: WorktreeStore
  let visibility: @Sendable (String) -> Int32
  let access: @Sendable () -> FullDiskAccessStatus
  let recoveryKey: @Sendable () throws -> SymmetricKey
  let existingRecoveryKey: @Sendable () throws -> SymmetricKey
  let interactiveRecoveryKey: @Sendable () throws -> SymmetricKey
  let interactiveExistingKey: @Sendable () throws -> SymmetricKey
  let scanRunner: WorktreeScanRunner?
  var scanControl: WorktreeScanControl?
  var plans: [String: WorktreePlan] = [:]
  var batches: [String: (String, [WorktreePlan])] = [:]
  var generation = 0
  var scanning = false
  var executing = false
  var lastScan = Date.distantPast
  var scanGaps: [String] = []
  var closing = false
  var workJobs: [UUID: @Sendable () -> Void] = [:]
  public init(root: URL, visibility: (@Sendable (String) -> Int32)? = nil,
    access: @escaping @Sendable () -> FullDiskAccessStatus = { FullDiskAccess.status() },
    recoveryKey: (@Sendable () throws -> SymmetricKey)? = nil, legacy: [WorkspaceClaim] = [], scanRunner: WorktreeScanRunner? = nil) throws {
    self.store = try WorktreeStore(root: root); self.visibility = visibility ?? { bz_path_in_use($0) }; self.access = access
    self.recoveryKey = recoveryKey ?? { try WorktreeRecoveryKey.load() }
    self.existingRecoveryKey = recoveryKey ?? { try WorktreeRecoveryKey.load(create: false) }
    self.interactiveRecoveryKey = recoveryKey ?? { try WorktreeRecoveryKey.load(allowInteraction: true) }
    self.interactiveExistingKey = recoveryKey ?? { try WorktreeRecoveryKey.load(create: false, allowInteraction: true) }
    self.scanRunner = scanRunner ?? (visibility == nil ? WorktreeScanRunner() : nil)
    if !legacy.isEmpty {
      try store.put("pending", kind: "migration", id: "legacy")
      for old in legacy where old.state != "cleaned" { try Self.importLegacy(old, into: store) }
    }
    // A restart never repeats a destructive step. Keep every recovery dependency.
    for var operation in try store.values(WorktreeOperation.self, kind: "operation") where !["completed", "rescued", "quarantined", "repaired", "reconciled-absent", "refused", "failed", "uncertain"].contains(operation.phase) {
      operation.interruptedPhase = operation.phase
      operation.phase = "uncertain"; operation.diskCredit = 0; operation.detail = "Interrupted operation. Inspect recovery before any further action; no credit."
      try store.put(operation, kind: "operation", id: operation.id)
    }
    for var attempt in try store.values(WorktreeRestoreAttempt.self, kind: "restore") where attempt.phase == "prepared" {
      attempt.phase = "uncertain"; attempt.detail = "Restoration interrupted; inspect the partial destination. Original archive retained."
      try store.put(attempt, kind: "restore", id: attempt.id)
    }
    for var op in try store.values(WorktreeOperation.self, kind: "operation") where op.purgePending == true {
      let expected = store.root.appendingPathComponent("worktree-recovery").appendingPathComponent(op.id).path
      var metadata = stat()
      if UUID(uuidString: op.id) != nil, op.recoveryPath == expected,
        lstat(expected, &metadata) != 0, errno == ENOENT {
        op.purged = true; op.purgePending = false; op.archiveBytes = 0
        try store.put(op, kind: "operation", id: op.id)
      }
    }
  }
  func requireAccess() throws {
    let a = access(); guard a.canScan else { throw StoreError.message(a.detail) }
  }
  func records() throws -> [WorktreeRecord] { try store.values(WorktreeRecord.self, kind: "record") }
  func claims(_ id: String) throws -> [WorktreeClaim] {
    try store.values(WorktreeClaim.self, kind: "claim").filter { $0.worktreeID == id }.sorted { $0.id < $1.id }
  }
  func record(_ id: String?) throws -> WorktreeRecord {
    guard let id, let r = try store.value(WorktreeRecord.self, kind: "record", id: id) else { throw StoreError.message("Unknown exact worktree ID.") }; return r
  }
  func policy() throws -> WorktreePolicy {
    let p = try store.value(WorktreePolicy.self, kind: "policy", id: "current") ?? WorktreePolicy()
    try p.validate(); return p
  }
  func claimRevision(_ id: String) throws -> String { WorkEvidence.hash(try WorktreeEncoding.data(claims(id)).base64EncodedString()) }
  func publish(_ inspected: WorktreeRecord) throws -> WorktreeRecord {
    var r = inspected
    let alias = try store.value(String.self, kind: "location", id: WorkEvidence.hash(r.repository + "|" + r.path)) ?? r.id
    if let old = try store.value(WorktreeRecord.self, kind: "record", id: alias) {
      if r.missing && r.identity == nil { r.identity = old.identity }
      if old.retired, let identity = r.identity, identity != old.identity {
        r.id = WorkEvidence.hash(old.id + "|" + identity.id)
        try store.transaction {
          try store.put(r, kind: "record", id: r.id)
          try store.put(r.id, kind: "location", id: WorkEvidence.hash(r.repository + "|" + r.path))
        }
        return r
      }
      r.id = old.id
      if !r.missing && r.gaps == ["Detailed inspection pending."] && r.revision.isEmpty && !old.revision.isEmpty && r.head == old.head { return old }
      if old.observedAt > r.observedAt { return old }
      r.firstSeen = old.firstSeen; r.managed = old.managed && old.identity == r.identity; r.kept = old.kept; r.retired = old.retired
      if old.revision == r.revision && old.identity == r.identity { r.changedAt = old.changedAt; r.confirmedRevision = old.confirmedRevision; r.confirmedAt = old.confirmedAt }
    }
    let active = try claims(r.id).filter { $0.state != "released" }
    if !active.isEmpty { r.consumer = "in use"; r.blockers.append("\(active.count) owner claim(s) retain this worktree.") }
    r.readinessRevision = WorkEvidence.hash(r.consumer + "|" + r.blockers.sorted().joined(separator: "|") + "|" + r.gaps.sorted().joined(separator: "|"))
    try store.put(r, kind: "record", id: r.id); return r
  }
  public func inspect(_ id: String) async throws -> WorktreeRecord {
    try requireAccess(); let r = try record(id), visibility = visibility
    guard !r.retired else { return r }
    guard try policy().roots.contains(where: { WorkspaceSafety.contains($0, r.path) }) || WorkspaceSafety.contains(store.root.appendingPathComponent("workspaces").path, r.path) else { return r }
    let fresh = try await runWork { WorktreeInspection.inspect(r, visibility: visibility) }
    return try publish(fresh)
  }
  public func scan() async throws -> WorktreeReply {
    try requireAccess(); guard !scanning else { throw StoreError.message("A worktree scan is already running.") }
    scanning = true; generation += 1; let current = generation
    defer { scanning = false }
    var roots = try policy().roots
    let privateRoot = store.root.appendingPathComponent("workspaces").path
    if FileManager.default.fileExists(atPath: privateRoot), !roots.contains(where: { WorkspaceSafety.contains($0, privateRoot) }) { roots.append(privateRoot) }
    let visibility = visibility
    let result: WorktreeDiscoveryResult
    if let runner = scanRunner {
      let control = WorktreeScanControl(); scanControl = control
      let root = store.root
      let cursor = try store.value(Int.self, kind: "scan", id: "cursor") ?? 0
      result = try await runWork {
        runner.run(roots: roots, root: root, inspectOffset: cursor, publish: { row in Task { await self.acceptScan(row, generation: current) } }, keepGoing: { control.active })
      }
      scanControl = nil
    } else {
      result = try await runWork { WorktreeDiscovery.scan(roots: roots, visibility: visibility) }
    }
    guard generation == current else { throw StoreError.message("Discovery settings changed; stale scan discarded.") }
    for row in result.records { _ = try publish(row) }
    // Missing discoveries are not tombstoned merely because a scan is partial.
    try store.put(result.nextInspection, kind: "scan", id: "cursor")
    scanGaps = result.gaps; lastScan = Date()
    var reply = try snapshot(); reply.gaps = result.gaps; return reply
  }
  func acceptScan(_ row: WorktreeRecord, generation expected: Int) {
    guard generation == expected else { return }; _ = try? publish(row)
  }
  public func snapshot(offset: Int = 0, operationOffset: Int = 0, selectedIDs: [String]? = nil) throws -> WorktreeReply {
    guard offset >= 0, offset <= 100_000 else { throw StoreError.message("Invalid worktree cursor.") }
    if let selectedIDs { guard selectedIDs.count <= 50, Set(selectedIDs).count == selectedIDs.count else { throw StoreError.message("Select at most 50 unique inventory IDs.") } }
    var reply = WorktreeReply()
    let rows = try selectedIDs.map { try $0.map { try record($0) } } ?? store.page(WorktreeRecord.self, kind: "record", offset: offset, limit: 101)
    reply.records = Array(rows.prefix(100)); reply.policy = try policy()
    reply.suggestedRoots = (try store.value([String].self, kind: "suggestions", id: "roots") ?? []).filter { !reply.policy.roots.contains($0) }
    let operations = try store.page(WorktreeOperation.self, kind: "operation", offset: operationOffset, limit: 101, newest: true)
    reply.operations = Array(operations.prefix(100))
    reply.restores = try store.page(WorktreeRestoreAttempt.self, kind: "restore", offset: 0, limit: 100, newest: true)
    if operations.count > 100 { reply.nextOperationOffset = operationOffset + 100 }
    reply.gaps = scanGaps
    let ids = Set(reply.records.map(\.id))
    reply.owners = try store.values(WorktreeClaim.self, kind: "claim").filter { ids.contains($0.worktreeID) }.map {
      .init(id: $0.id, worktreeID: $0.worktreeID, label: $0.label, condition: $0.condition, evidence: $0.evidence, state: $0.state, updated: $0.updated, releasedHead: $0.head, releasedRevision: $0.releasedRevision)
    }
    reply.advice = try store.values(WorktreeAdvice.self, kind: "advice").filter { a in reply.records.contains { $0.id == a.id && $0.revision == a.revision } }
    reply.delivery = try store.values(WorktreeDeliveryEvidence.self, kind: "delivery").filter { d in reply.records.contains { $0.id == d.id && $0.head == d.head } }
    if rows.count > 100 && selectedIDs == nil { reply.nextOffset = offset + 100 }
    // Keep IPC frames bounded without hiding later records or recovery items.
    // Cursors advance only over items actually included in this response.
    while try WorktreeEncoding.data(reply).count > 220_000 {
      if reply.operations.count > 1 {
        reply.operations.removeLast(); reply.nextOperationOffset = operationOffset + reply.operations.count
      } else if reply.records.count > 1 && selectedIDs == nil {
        reply.records.removeLast(); reply.nextOffset = offset + reply.records.count
        let included = Set(reply.records.map(\.id))
        reply.owners.removeAll { !included.contains($0.worktreeID) }
        reply.advice.removeAll { !included.contains($0.id) }; reply.delivery.removeAll { !included.contains($0.id) }
      } else if reply.restores.count > 1 { reply.restores.removeLast() }
      else { throw StoreError.message("Inventory selection exceeds its bounded response. Inspect fewer exact records.") }
    }
    return reply
  }
  func expected(_ request: WorktreeRequest) throws -> WorktreeRecord {
    let r = try record(request.id)
    guard !r.retired, request.revision == r.revision else { throw StoreError.message("Exact current evidence revision required. Inspect again.") }
    return r
  }
  public func suggestRoots(_ paths: [String]) throws {
    let roots = Array(Set(paths.filter { $0.hasPrefix("/") && $0.utf8.count < 4096 && $0 != "/" && $0 != NSHomeDirectory() })).sorted()
    let bounded = Array(roots.prefix(32))
    if try store.value([String].self, kind: "suggestions", id: "roots") != bounded { try store.put(bounded, kind: "suggestions", id: "roots") }
  }
  public func request(_ q: WorktreeRequest, caller: String, management: Bool = true) async throws -> WorktreeReply {
    guard !closing else { throw StoreError.message("Worktree service is shutting down; new work is paused.") }
    guard try store.values(String.self, kind: "migration").first != "pending" else { throw StoreError.message("Legacy cutover is incomplete; worktree mutation is paused.") }
    let readOnly: Set<String> = ["list", "operations", "inspect", "scan", "preview", "retire", "claim", "release", "retain", "advise"]
    guard management || readOnly.contains(q.action) else { throw StoreError.message("This endpoint cannot change management, human decisions, policy or recovery.") }
    if q.action == "cancel_scan" { generation += 1; scanControl?.cancel(); return try snapshot() }
    if q.action == "list" { return try snapshot(offset: q.offset ?? 0, selectedIDs: q.ids) }
    if q.action == "operations" { return try snapshot(operationOffset: q.offset ?? 0) }
    try requireAccess()
    guard !executing || ["keep", "retain"].contains(q.action) else { throw StoreError.message("A worktree operation is in progress.") }
    switch q.action {
    case "diff":
      let row = try await inspect(q.id ?? "")
      guard q.revision == row.revision, !row.missing, !row.retired else { throw StoreError.message("Inspect the exact current checkout before viewing local changes.") }
      let text = try await runWork {
        let flags = ["--no-color", "--no-ext-diff", "--no-textconv"]
        let staged = try WorktreeGit.text(row.path, ["diff", "--cached"] + flags + ["--"])
        let working = try WorktreeGit.text(row.path, ["diff"] + flags + ["--"])
        return "Local view only. Untracked/ignored contents are preserved by recovery but not included in Git diffs.\n\nStaged changes:\n" + String(staged.prefix(10_000)) + "\n\nUnstaged changes:\n" + String(working.prefix(10_000)) + "\n\nEach section is limited to 10,000 characters."
      }
      var reply = WorktreeReply(); reply.records = [row]; reply.detail = text; return reply
    case "check_key":
      _ = try captureKey(interactive: true)
      var reply = try snapshot(); reply.detail = "Recovery key is available. Each archive still requires its own integrity and restore verification."; return reply
    case "reconcile":
      let op = try await reconcile(q); var reply = try snapshot(); reply.operations = [op]; reply.detail = op.detail; return reply
    case "repair":
      let row = try await repair(q); var reply = try snapshot(); reply.records = [row]
      reply.detail = "Exact moved-worktree registration repaired. Review its current ownership before retirement."; return reply
    case "registration_advice":
      let row = try expected(q)
      let dryRun = try WorktreeGit.text(row.repository, ["worktree", "prune", "--dry-run", "--verbose"])
      var reply = try snapshot()
      reply.detail = "Read-only repository metadata preview: " + String(dryRun.prefix(4000)) + " Missing volumes and unique Git state require review. This app does not run broad metadata pruning; locate the checkout and use exact registration repair when possible."
      return reply
    case "refresh_delivery":
      let row = try expected(q)
      let result = try await runWork { WorktreeOwner.fetch(row) }
      guard try record(row.id).head == row.head else { throw StoreError.message("HEAD changed during metadata refresh.") }
      try store.put(result, kind: "delivery", id: row.id)
    case "batch_preview": return try await batchPreview(q, caller: caller)
    case "batch_retire": return try await batchRetire(q, caller: caller)
    case "finish_quarantine":
      let operation = try await finishQuarantine(q)
      var reply = try snapshot(); reply.operations = [operation]; reply.detail = operation.detail; return reply
    case "advise":
      let r = try expected(q)
      guard let summary = q.evidence, let next = q.condition, (20...1200).contains(summary.count), (10...500).contains(next.count) else { throw StoreError.message("Provide bounded factual advice and one practical next step.") }
      try store.put(WorktreeAdvice(id: r.id, revision: r.revision, summary: summary, nextStep: next, date: Date()), kind: "advice", id: r.id)
    case "scan": return try await scan()
    case "add_root", "remove_root":
      guard let path = q.path, path.hasPrefix("/"), path == WorkspaceSafety.canonical(path), path != "/", path != NSHomeDirectory(), path.count < 4096 else { throw StoreError.message("Choose an exact canonical discovery folder.") }
      var p = try policy()
      if q.action == "add_root" { guard p.roots.count < 32 else { throw StoreError.message("Discovery root limit reached.") }; if !p.roots.contains(path) { p.roots.append(path) } }
      else { p.roots.removeAll { $0 == path } }
      generation += 1; scanControl?.cancel(); try store.put(p, kind: "policy", id: "current")
    case "inspect":
      let r = try await inspect(q.id ?? ""); return try snapshot(selectedIDs: [r.id])
    case "keep", "unkeep", "adopt", "confirm":
      var r = try expected(q)
      if q.action == "keep" { r.kept = true; r.confirmedRevision = nil }
      if q.action == "unkeep" { r.kept = false }
      if q.action == "adopt" {
        guard !r.main, !r.bare, !r.ownerManaged, r.identity != nil else { throw StoreError.message("This checkout stays with its repository/owning application.") }; r.managed = true
      }
      if q.action == "confirm" {
        guard r.managed, !r.kept, (try claims(r.id)).allSatisfy({ $0.state == "released" }), let evidence = q.evidence, (20...1200).contains(evidence.count) else { throw StoreError.message("Manage this checkout, release every consumer and provide a factual retirement decision.") }
        r.confirmedRevision = r.revision; r.confirmedAt = Date()
        try store.put(evidence, kind: "decision", id: r.id)
      }
      try store.put(r, kind: "record", id: r.id); plans = [:]
    case "claim":
      let r = try expected(q)
      guard r.managed, let evidence = q.evidence, let condition = q.condition,
        (20...1200).contains(evidence.count), (10...500).contains(condition.count) else { throw StoreError.message("Managed checkout, factual purpose and completion condition required.") }
      guard try claims(r.id).count < 64 else { throw StoreError.message("Worktree owner limit reached; existing claims stay protected.") }
      let token = UUID().uuidString + UUID().uuidString
      let c = WorktreeClaim(id: UUID().uuidString, worktreeID: r.id, tokenHash: WorkEvidence.hash(token), label: caller,
        condition: condition, evidence: evidence, state: "active", head: nil, updated: Date())
      try store.put(c, kind: "claim", id: c.id); plans = [:]
      var reply = try snapshot(); reply.token = token; reply.detail = "Owner claim retained. Keep its token private."; return reply
    case "release", "retain":
      guard let token = q.token, token.count == 72, let evidence = q.evidence, (20...1200).contains(evidence.count),
        var c = try store.values(WorktreeClaim.self, kind: "claim").first(where: { $0.tokenHash == WorkEvidence.hash(token) }) else { throw StoreError.message("Owning task's private token and factual evidence required.") }
      let r: WorktreeRecord
      if q.action == "retain" { r = try record(c.worktreeID) }
      else { r = try await inspect(c.worktreeID) }
      c.state = q.action == "release" ? "released" : "active"; c.evidence = evidence; c.updated = Date(); c.head = q.action == "release" ? r.head : nil
      c.releasedRevision = q.action == "release" ? r.revision : nil
      try store.put(c, kind: "claim", id: c.id); plans = [:]
    case "automatic":
      let r = try expected(q); guard r.managed, !r.ownerManaged, let enabled = q.enabled else { throw StoreError.message("Exact managed repository and explicit enabled state required.") }
      var p = try policy(); p.automaticRepositories.removeAll { $0 == r.repository }
      if enabled { p.automaticRepositories.append(r.repository) }
      try store.put(p, kind: "policy", id: "current"); plans = [:]
    case "preview", "preview_dirty":
      let plan = try await preview(q, caller: caller, dirty: q.action == "preview_dirty", automatic: !management, interactive: management)
      var reply = try snapshot(); reply.token = plan.token; reply.detail = "Exact single-use preview, valid for 60 seconds. No files removed."; return reply
    case "retire", "retire_dirty", "quarantine":
      let operation = try await retire(q.token ?? "", caller: caller, dirty: q.action != "retire", quarantine: q.action == "quarantine")
      var reply = try snapshot(); reply.operations = [operation]; reply.detail = operation.detail; return reply
    case "rescue":
      let operation = try await rescue(q, caller: caller)
      var reply = try snapshot(); reply.operations = [operation]; reply.detail = operation.detail; return reply
    case "restore":
      let operation = try await restore(q)
      var reply = try snapshot(); reply.operations = [operation]; reply.detail = "Restored to a new destination; original retirement receipt preserved."; return reply
    case "purge":
      guard q.evidence == "PURGE RECOVERY", let id = q.id,
        var op = try store.value(WorktreeOperation.self, kind: "operation", id: id), ["completed", "rescued", "failed", "reconciled-absent"].contains(op.phase), op.archiveDigest != nil, !op.purged else { throw StoreError.message("Select a finished verified recovery item and confirm PURGE RECOVERY. This removes its independent archive.") }
      let expected = store.root.appendingPathComponent("worktree-recovery").appendingPathComponent(op.id).path
      guard UUID(uuidString: op.id) != nil, op.recoveryPath == expected else { throw StoreError.message("Recovery path identity mismatch.") }
      _ = try WorkspaceSafety.statAt(expected)
      op.purgePending = true; try store.put(op, kind: "operation", id: op.id)
      try FileManager.default.removeItem(atPath: expected); op.purged = true; op.archiveBytes = 0
      op.purgePending = false
      try store.put(op, kind: "operation", id: op.id)
    default: throw StoreError.message("Unsupported worktree action.")
    }
    return try snapshot()
  }
}
