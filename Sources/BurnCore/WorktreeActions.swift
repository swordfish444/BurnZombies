import Darwin
import Foundation

extension WorktreeService {
  func eligible(_ r: WorktreeRecord, dirty: Bool, automatic: Bool) throws {
    guard r.managed, !r.retired, !r.kept, !r.main, !r.bare, !r.ownerManaged,
      r.identity != nil, r.head != nil, r.gaps.isEmpty, r.blockers.isEmpty,
      r.consumer == "none observed"
    else {
      throw StoreError.message(
        (r.blockers + r.gaps + [
          "Retirement requires exact managed identity, complete inspection and no active consumer."
        ]).joined(separator: " "))
    }
    guard
      !(try store.values(WorktreeOperation.self, kind: "operation")).contains(where: {
        $0.worktreeID == r.id && $0.phase == "uncertain"
      })
    else {
      throw StoreError.message(
        "An uncertain prior operation must be reconciled before another retirement.")
    }
    let owners = try claims(r.id)
    if let delivery = try store.value(WorktreeDeliveryEvidence.self, kind: "delivery", id: r.id),
      let name = delivery.defaultBranch, r.branch == "refs/heads/" + name
    {
      throw StoreError.message("GitHub's recorded default-branch checkout is protected.")
    }
    guard owners.allSatisfy({ $0.state == "released" }) else {
      throw StoreError.message("An owner still retains this checkout.")
    }
    let released =
      !owners.isEmpty
      && owners.allSatisfy {
        $0.head == r.head && $0.releasedRevision == r.revision && $0.evidence.count >= 20
      }
    guard r.confirmedRevision == r.revision || released else {
      throw StoreError.message("Owner completion or an exact human retirement decision is missing.")
    }
    guard dirty || r.changes + r.ignored == 0 else {
      throw StoreError.message(
        "Local changes or ignored files require Rescue / Archive and retire.")
    }
    if automatic {
      let p = try policy()
      let now = Date()
      guard !dirty, released, p.automaticRepositories.contains(r.repository),
        owners.allSatisfy({
          now.timeIntervalSince($0.updated) >= Double(p.releaseGraceHours) * 3600
        })
      else {
        throw StoreError.message(
          "Automatic retirement requires explicit repository policy and released owners past the grace period."
        )
      }
      let today = Calendar.current.startOfDay(for: now)
      let done = try store.values(WorktreeOperation.self, kind: "operation").filter {
        $0.phase == "completed" && ($0.completedAt ?? $0.date) >= today
      }
      guard done.count < p.maximumPerDay else {
        throw StoreError.message("Daily worktree retirement allowance reached.")
      }
      let disk = try DiskPolicy.load(Store(root: store.root))
      let catalog = try Store(root: store.root).load()
      guard try WorkspaceSafety.freeBytes(r.path) < UInt64(disk.targetFreeGB) * 1_000_000_000 else {
        throw StoreError.message(
          "The shared free-space goal is already satisfied; automatic retirement deferred.")
      }
      let diskUsed = (catalog.diskReceipts ?? []).filter {
        $0.outcome == "verified" && $0.date >= today
      }.reduce(UInt64(0)) { $0 + $1.diskReclaimedBytes }
      guard disk.mode == "automatic",
        done.reduce(diskUsed, { $0 + $1.diskCredit }) + r.allocated <= UInt64(disk.maximumGBPerDay)
          * 1_000_000_000
      else {
        throw StoreError.message(
          "Shared automatic disk-removal policy or allowance does not permit this retirement.")
      }
    }
  }
  func preview(
    _ q: WorktreeRequest, caller: String, dirty: Bool, automatic: Bool, interactive: Bool = false
  ) async throws -> WorktreePlan {
    let r = try await inspect(q.id ?? "")
    guard q.revision == r.revision, let identity = r.identity else {
      throw StoreError.message("Worktree changed; inspect and review again.")
    }
    try eligible(r, dirty: dirty, automatic: automatic)
    plans = plans.filter { (0...60).contains(Date().timeIntervalSince($0.value.created)) }
    guard plans.count < 100 else { throw StoreError.message("Preview queue is full.") }
    let p = WorktreePlan(
      token: UUID().uuidString, worktreeID: r.id, revision: r.revision,
      claimRevision: try claimRevision(r.id), policyRevision: try policy().revision,
      identity: identity,
      created: Date(), caller: caller + (automatic ? "|automatic" : "|manual"), dirty: dirty,
      interactive: interactive)
    plans[p.token] = p
    return p
  }
  func operation(_ r: WorktreeRecord, kind: String) throws -> WorktreeOperation {
    let id = UUID().uuidString.lowercased()
    let recovery = store.root.appendingPathComponent("worktree-recovery").appendingPathComponent(id)
    return WorktreeOperation(
      id: id, worktreeID: r.id, originalPath: r.path, repository: r.repository,
      head: r.head ?? "", phase: "prepared", kind: kind, date: Date(), recoveryPath: recovery.path,
      detail: "Prepared preservation. No files removed or storage credit.", allocated: r.allocated)
  }
  func save(_ operation: WorktreeOperation) throws {
    try store.put(operation, kind: "operation", id: operation.id)
  }
  func validate(_ plan: WorktreePlan, caller: String) async throws -> WorktreeRecord {
    let automatic = plan.caller.hasSuffix("|automatic")
    guard plan.caller == caller + (automatic ? "|automatic" : "|manual"),
      (0...60).contains(Date().timeIntervalSince(plan.created)),
      try policy().revision == plan.policyRevision,
      try claimRevision(plan.worktreeID) == plan.claimRevision
    else {
      throw StoreError.message(
        "Preview expired, changed owner/policy or belongs to another caller.")
    }
    let r = try await inspect(plan.worktreeID)
    guard r.identity == plan.identity, r.revision == plan.revision else {
      throw StoreError.message("Checkout changed after preview.")
    }
    try eligible(r, dirty: plan.dirty, automatic: automatic)
    return r
  }
  func retire(_ token: String, caller: String, dirty: Bool, quarantine: Bool = false) async throws
    -> WorktreeOperation
  {
    guard !executing else { throw StoreError.message("Another worktree operation is running.") }
    executing = true
    defer { executing = false }
    guard let plan = plans.removeValue(forKey: token), plan.dirty == dirty else {
      throw StoreError.message("Fresh single-use matching preview required.")
    }
    let r = try await validate(plan, caller: caller)
    let repositoryLock = try InstanceLock(
      url: URL(fileURLWithPath: r.repository).appendingPathComponent("burnzombies-worktree.lock"))
    defer { withExtendedLifetime(repositoryLock) {} }
    var op = try operation(r, kind: dirty ? "dirty" : "clean")
    try save(op)
    do {
      op.phase = "preserving"
      op.detail =
        "Waiting for recovery-key access. Original content is retained; no cleanup credit."
      try save(op)
      let key = try await captureKey(interactive: plan.interactive == true)
      let captured = op
      let proof = try await runWork {
        try WorktreeRecovery.capture(r, operation: captured, key: key)
      }
      op.archiveDigest = proof.0
      op.archiveBytes = proof.1
      op.phase = "preservation-verified"
      try save(op)
      let verified = op
      try await runWork { try WorktreeRecovery.verifySource(r, operation: verified, key: key) }
      // Preservation may outlast a preview's issue window. Its initial consumption was
      // time-bound; current authority, identity and content are checked independently.
      try requireAccess()
      let fresh = WorktreeInspection.inspect(try record(r.id), visibility: visibility)
      guard fresh.identity == plan.identity, fresh.revision == plan.revision,
        try claimRevision(r.id) == plan.claimRevision, try policy().revision == plan.policyRevision
      else { throw StoreError.message("Work changed during preservation; original retained.") }
      try eligible(fresh, dirty: dirty, automatic: plan.caller.hasSuffix("|automatic"))
      if quarantine {
        let parent = store.root.appendingPathComponent("worktree-quarantine")
        try FileManager.default.createDirectory(
          at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let s = try WorkspaceSafety.statAt(parent.path)
        guard s.st_dev == plan.identity.device else {
          throw StoreError.message(
            "Quarantine requires the same volume; choose explicit verified retirement instead.")
        }
        let destination = parent.appendingPathComponent(op.id).path
        op.quarantinePath = destination
        op.phase = "moving"
        try save(op)
        _ = try WorktreeGit.run(
          r.repository, ["worktree", "move", "--", r.path, destination], seconds: 60)
        op.quarantineIdentity = try WorktreeInspection.identity(destination)
        op.phase = "quarantined"
        op.detail =
          "Verified archive retained; checkout moved to quarantine. No disk reclaimed. Review again after seven days or explicitly retire now."
        var quarantined = r
        quarantined.retired = true
        try store.transaction {
          try save(op)
          try store.put(quarantined, kind: "record", id: r.id)
        }
        return op
      }
      op.phase = "removing"
      try save(op)
      let before = try WorkspaceSafety.freeBytes(r.path)
      _ = try WorktreeGit.run(
        r.repository, ["worktree", "remove"] + (dirty ? ["--force"] : []) + ["--", r.path],
        seconds: 60)
      op.phase = "verifying"
      try save(op)
      var s = stat()
      guard lstat(r.path, &s) != 0, errno == ENOENT else {
        throw StoreError.message("Worktree disappearance was not verified.")
      }
      let rows = try WorktreeDiscovery.parse(
        WorktreeGit.run(r.repository, ["worktree", "list", "--porcelain", "-z"]),
        repository: r.repository)
      guard !rows.contains(where: { $0.path == r.path }) else {
        throw StoreError.message("Git registration remains; preserve recovery.")
      }
      let after = try WorkspaceSafety.freeBytes((r.path as NSString).deletingLastPathComponent)
      op.diskCredit = min(r.allocated, after > before ? after - before : 0)
      op.phase = "completed"
      op.completedAt = Date()
      op.detail =
        "Retirement verified. Encrypted independent recovery retained; disk credit is capped observed free-space gain, not a guarantee of physical attribution."
      var retired = r
      retired.retired = true
      try store.transaction {
        try save(op)
        try store.put(retired, kind: "record", id: r.id)
      }
      return op
    } catch {
      op.interruptedPhase = op.phase
      op.diskCredit = 0
      op.phase = ["moving", "removing", "verifying"].contains(op.phase) ? "uncertain" : "failed"
      op.detail = error.localizedDescription + " Recovery retained; no credit."
      try? save(op)
      throw error
    }
  }
  func rescue(_ q: WorktreeRequest, caller: String) async throws -> WorktreeOperation {
    guard !executing else { throw StoreError.message("Another worktree operation is running.") }
    executing = true
    defer { executing = false }
    let r = try await inspect(q.id ?? "")
    let repositoryLock = try InstanceLock(
      url: URL(fileURLWithPath: r.repository).appendingPathComponent("burnzombies-worktree.lock"))
    defer { withExtendedLifetime(repositoryLock) {} }
    guard q.revision == r.revision else {
      throw StoreError.message("Content changed; inspect before rescue.")
    }
    // Rescue preserves files without requiring retirement intent, but active writers
    // and unsupported state still prevent us claiming a coherent backup.
    guard r.managed, !r.main, !r.ownerManaged, r.blockers.isEmpty, r.gaps.isEmpty,
      r.consumer == "none observed", (try claims(r.id)).allSatisfy({ $0.state == "released" })
    else {
      throw StoreError.message(
        "Finish consumers and resolve inspection blockers before coherent rescue.")
    }
    var op = try operation(r, kind: "rescue")
    try save(op)
    do {
      let key = try await captureKey(interactive: true)
      let captured = op
      let result = try await runWork {
        try WorktreeRecovery.capture(r, operation: captured, key: key)
      }
      op.archiveDigest = result.0
      op.archiveBytes = result.1
      op.phase = "rescued"
      op.detail =
        "Encrypted snapshot restored and verified independently. Original checkout retained; no disk credit."
      try save(op)
      return op
    } catch {
      op.phase = "failed"
      op.detail = error.localizedDescription
      try? save(op)
      throw error
    }
  }
  func restore(_ q: WorktreeRequest) async throws -> WorktreeOperation {
    guard let id = q.id, let path = q.path,
      var op = try store.value(WorktreeOperation.self, kind: "operation", id: id),
      !op.purged, let digest = op.archiveDigest
    else {
      throw StoreError.message("Choose a verified unpurged recovery item and a new destination.")
    }
    executing = true
    defer { executing = false }
    let key = try await readRecoveryKey(interactiveExistingKey)
    let captured = op
    var attempt = WorktreeRestoreAttempt(
      id: UUID().uuidString, recoveryID: op.id, destination: path,
      phase: "prepared", date: Date(),
      detail: "Restoration requested into a new directory. Original archive retained.")
    try store.put(attempt, kind: "restore", id: attempt.id)
    do {
      try await runWork {
        try WorktreeRecovery.restore(captured, destination: path, key: key, digest: digest)
      }
      op.restoredPaths.append(path)
      op.purgePending = false
      attempt.phase = "completed"
      attempt.detail = "Independent restoration verified."
      try store.transaction {
        try save(op)
        try store.put(attempt, kind: "restore", id: attempt.id)
      }
      return op
    } catch {
      attempt.phase = "failed"
      attempt.detail =
        "Restoration failed; partial destination may remain. " + error.localizedDescription
      try? store.put(attempt, kind: "restore", id: attempt.id)
      throw error
    }
  }
  func finishQuarantine(_ q: WorktreeRequest) async throws -> WorktreeOperation {
    guard let id = q.id,
      var op = try store.value(WorktreeOperation.self, kind: "operation", id: id),
      op.phase == "quarantined", !op.purged, q.revision == op.archiveDigest,
      let path = op.quarantinePath, let identity = op.quarantineIdentity,
      path
        == store.root.appendingPathComponent("worktree-quarantine").appendingPathComponent(op.id)
        .path,
      q.evidence == "RETIRE QUARANTINE" || q.evidence == "RETIRE QUARANTINE NOW"
    else {
      throw StoreError.message(
        "Exact quarantined item, archive revision and explicit final-retirement confirmation required."
      )
    }
    guard Date().timeIntervalSince(op.date) >= 7 * 86400 || q.evidence == "RETIRE QUARANTINE NOW"
    else {
      throw StoreError.message(
        "Quarantine's seven-day grace has not elapsed. Keep it or explicitly choose retire now.")
    }
    var r = try record(op.worktreeID)
    r.path = path
    r.identity = identity
    r.retired = false
    r = WorktreeInspection.inspect(r, visibility: visibility)
    guard r.identity == identity, r.gaps.isEmpty, r.blockers.isEmpty, r.consumer == "none observed",
      (try claims(r.id)).allSatisfy({ $0.state == "released" })
    else {
      throw StoreError.message(
        "Quarantine has changed, is in use or has incomplete inspection; preserved.")
    }
    executing = true
    defer { executing = false }
    let repositoryLock = try InstanceLock(
      url: URL(fileURLWithPath: op.repository).appendingPathComponent("burnzombies-worktree.lock"))
    defer { withExtendedLifetime(repositoryLock) {} }
    let key = try await readRecoveryKey(interactiveExistingKey)
    let captured = op
    let row = r
    try await runWork { try WorktreeRecovery.verifySource(row, operation: captured, key: key) }
    try requireAccess()
    let final = WorktreeInspection.inspect(r, visibility: visibility)
    guard final.identity == identity, final.revision == r.revision,
      final.consumer == "none observed", final.gaps.isEmpty,
      final.blockers.isEmpty, !((try record(r.id)).kept),
      (try claims(r.id)).allSatisfy({ $0.state == "released" })
    else {
      throw StoreError.message("Quarantine content, identity, protection or consumers changed.")
    }
    op.phase = "removing"
    try save(op)
    do {
      let before = try WorkspaceSafety.freeBytes(path)
      _ = try WorktreeGit.run(
        op.repository, ["worktree", "remove", "--force", "--", path], seconds: 60)
      guard !FileManager.default.fileExists(atPath: path),
        !(try WorktreeDiscovery.parse(
          WorktreeGit.run(op.repository, ["worktree", "list", "--porcelain", "-z"]),
          repository: op.repository)).contains(where: { $0.path == path })
      else { throw StoreError.message("Final quarantine removal not verified.") }
      let after = try WorkspaceSafety.freeBytes(store.root.path)
      op.diskCredit = min(op.allocated, after > before ? after - before : 0)
      op.phase = "completed"
      op.completedAt = Date()
      op.detail = "Quarantine retirement verified; independent recovery retained."
      try save(op)
      return op
    } catch {
      op.phase = "uncertain"
      op.diskCredit = 0
      op.detail = error.localizedDescription
      try? save(op)
      throw error
    }
  }
}
