import CBurn
import Darwin
import Foundation

public struct ViewState: Sendable {
  public var findings: [Finding] = []
  public var catalog = Catalog()
  public var processCount = 0
  public var hiddenCount = 0
  public var partial = false
  public var error: String?
  public var scanMS: Double = 0
  public var checkpointBytes = 0
  public var interval: Double = 60
  public init() {}
}

public actor Monitor {
  private let store: Store
  private let lock: InstanceLock
  private let native = Native()
  private let passive: PassiveCollector?
  private var diskSnapshot = DiskSnapshot()
  private var diskScanLoaded = false
  private let workspaceVisibility: @Sendable (String) -> Int32
  private var catalog: Catalog
  private var state = ViewState()
  private var lastSave = Date.distantPast
  private var receiptNeedsCheckpoint = false
  private var busy = false
  private var lastMonotonic: Double?
  private var lastWall: Date?
  private var lastAwake: Double?
  public init(root: URL = Store.defaultRoot, passiveHome: URL? = nil, workspaceVisibility: @escaping @Sendable (String) -> Int32 = { bz_path_in_use($0) }) throws {
    self.workspaceVisibility = workspaceVisibility
    store = try Store(root: root)
    passive = root.standardizedFileURL == Store.defaultRoot.standardizedFileURL || passiveHome != nil
      ? try PassiveCollector(store: store, home: passiveHome ?? FileManager.default.homeDirectoryForCurrentUser) : nil
    lock = try InstanceLock(url: root.appendingPathComponent("monitor.lock"))
    var loaded = try store.load()
    if loaded.lifetimeResidentReleased == nil {
      loaded.lifetimeResidentReleased = loaded.events.filter { $0.outcome == "verified" }.reduce(
        0
      ) { $0 + $1.residentBefore }
    }
    if loaded.lifetimeCPUSecondsSaved == nil {
      let measured = loaded.events.filter { $0.outcome == "verified" }.compactMap(
        \.cpuSecondsSavedEstimate)
      if !measured.isEmpty || loaded.lifetimeVerified == 0 {
        loaded.lifetimeCPUSecondsSaved = measured.reduce(0, +)
      }
    }
    if var receipts = loaded.workspaceReceipts {
      for i in receipts.indices where receipts[i].outcome == "prepared" {
        receipts[i].outcome = "unverified"
        receipts[i].detail = "Workspace operation interrupted. Preserve the recovery ref; no disk or worktree credit without the completed receipt."
      }
      loaded.workspaceReceipts = receipts
    }
    ImpactAccounting.migrate(&loaded)
    loaded.resetContinuity()
    catalog = loaded
  }
  public func snapshot() -> ViewState { state }
  public func resetContinuity() {
    receiptNeedsCheckpoint = receiptNeedsCheckpoint || catalog.events.contains { $0.outcome == "verifying" }
    catalog.resetContinuity()
    lastMonotonic = nil
    lastWall = nil
    lastAwake = nil
  }
  public func checkpoint() throws {
    state.checkpointBytes = try store.save(catalog)
    lastSave = Date()
    receiptNeedsCheckpoint = false
  }
  public func refresh() -> ViewState {
    // Swift concurrency workers do not drain Cocoa temporaries per observation.
    // Bound Foundation path/encoding allocations to this scan, including on errors.
    autoreleasepool { observe() }
  }
  private func observe() -> ViewState {
    let start = ProcessInfo.processInfo.systemUptime
    let scan = native.scan()
    let now = Date()
    let awake = native.awakeSeconds
    let previousWall = lastWall
    let previousAwake = lastAwake
    lastAwake = scan.partial ? nil : awake
    state.error = nil
    state.partial = scan.partial
    state.hiddenCount = scan.hidden
    state.processCount = scan.observations.count
    let priorOutcomes = catalog.events.map(\.outcome)
    if scan.partial { catalog.resetContinuity() }
    if let current = scan.observations.first?.monotonic, let previous = lastMonotonic,
      let wall = lastWall,
      current - previous > 75 || abs(now.timeIntervalSince(wall) - (current - previous)) > 5
    {
      catalog.resetContinuity()
    }
    lastMonotonic = scan.observations.first?.monotonic
    lastWall = now
    do {
      let present = Set(scan.observations.map { $0.identity.key })
      for observation in scan.observations.prefix(4096) {
        let key = observation.identity.key
        var r = catalog.records[key] ?? Record(observation)
        if let previous = r.samples.last, observation.monotonic - previous.monotonic >= 59 {
          r.samples.append(observation)
          r.samples = Array(r.samples.suffix(8))
        } else if r.samples.isEmpty {
          r.samples = [observation]
        }
        r.latest = observation
        r.missingSince = nil
        r.orphanSince = nil
        catalog.records[key] = r
      }
      if !scan.partial {
        for key in Array(catalog.records.keys)
        where !present.contains(key) && catalog.records[key]?.missingSince == nil {
          guard let identity = catalog.records[key]?.latest.identity else { continue }
          if native.ownerState(identity) == .gone { catalog.records[key]?.missingSince = now }
        }
      }
      if !scan.partial, let previousWall, let previousAwake {
        let ended = Set(catalog.events.filter { event in
          event.outcome == "verified" && event.cpuAccrualEnded != true &&
            Verification.recurrence(event: event, observations: scan.observations) { parent in
              guard case .found(let live) = native.probe(parent.identity.pid) else { return false }
              return Member(live) == parent && !live.zombie
            }
        }.map(\.id))
        let added = ImpactAccounting.accrue(&catalog, awakeSeconds: awake - previousAwake,
          wallSeconds: now.timeIntervalSince(previousWall), boot: native.boot, ended: ended)
        receiptNeedsCheckpoint = receiptNeedsCheckpoint || added > 0
      }
      verifyPending(now: now, observations: scan.observations)
      receiptNeedsCheckpoint = receiptNeedsCheckpoint || priorOutcomes != catalog.events.map(\.outcome)
      catalog.lastSample = now
      catalog.prune(now: now)
      if let passive {
        catalog.passiveEvidence = try passive.poll(records: catalog.records, claims: catalog.workEvidence ?? [], now: now, partial: scan.partial)
      }
      if store.root.standardizedFileURL == Store.defaultRoot.standardizedFileURL || FileManager.default.fileExists(atPath: store.root.appendingPathComponent("disk-policy.json").path) {
        let policy = try DiskPolicy.load(store)
        if !diskScanLoaded { diskSnapshot = try DiskSnapshot.load(store); diskScanLoaded = true }
        if now.timeIntervalSince(diskSnapshot.date) >= Double(policy.scanHours * 3600) || diskSnapshot.policyRevision != policy.revision {
          diskSnapshot = DiskInventory.scan(policy: policy, previous: diskSnapshot, visibility: workspaceVisibility)
          try diskSnapshot.save(store)
        }
        catalog.diskCandidates = diskSnapshot.candidates.filter { $0.reviewable && $0.decision == nil && diskSnapshot.freeBytes < UInt64(policy.targetFreeGB) * 1_000_000_000 }
      }
      // Observation is factual. The connected harness owns diagnosis and target selection.
      state.findings = []
      state.interval = catalog.events.contains { $0.outcome == "verifying" } ? 15 : 60
      if receiptNeedsCheckpoint || now.timeIntervalSince(lastSave) >= 300 {
        try checkpoint()
      }
      if !scan.partial {
        try HarnessHook.publish(.init(observedAt: now, processCount: scan.observations.count,
          residentBytes: scan.observations.reduce(0) { $0 + $1.rss }, pressure: native.memoryPressure(),
          reviewEvidence: ReviewEvidence.pending(in: catalog)), store: store)
      } else {
        try? FileManager.default.removeItem(at: store.root.appendingPathComponent("review-signal"))
      }
    } catch {
      try? FileManager.default.removeItem(at: store.root.appendingPathComponent("review-signal"))
      state.error = error.localizedDescription
      state.findings = []
    }
    state.catalog = catalog
    state.scanMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
    return state
  }
  private func verifyPending(now: Date, observations: [Observation]) {
    for i in catalog.events.indices where catalog.events[i].outcome == "verifying" {
      let e = catalog.events[i]
      let elapsed = now.timeIntervalSince(e.date)
      guard elapsed >= 15 else { continue }
      let statuses = e.targets.map { native.ownerState($0.identity) }
      let recurrence = Verification.recurrence(event: e, observations: observations) { parent in
        guard case .found(let live) = native.probe(parent.identity.pid) else { return false }
        return Member(live) == parent && !live.zombie
      }
      let outcome = Verification.outcome(
        elapsed: elapsed, targets: statuses, recurrence: recurrence, partialScan: state.partial)
      catalog.events[i].outcome = outcome
      if outcome == "unverified" {
        catalog.events[i].detail = "Visibility was lost during verification. No benefit credited."
      }
      if outcome == "partial" {
        catalog.events[i].detail =
          "A helper remained after the 15-second graceful deadline. No escalation and no benefit credited."
      }
      if outcome == "reappeared" {
        catalog.events[i].detail =
          "A new matching helper appeared under the same verified parent after cleanup. Possible recurrence; no benefit credited. Inspect the creator."
      }
      if outcome == "verified" {
        catalog.events[i].outcome = "verified"
        catalog.events[i].verifiedCount = e.targets.count
        catalog.events[i].verificationDate = now
        catalog.events[i].detail =
          "Exact targets exited; no replacement was observed under the same verified parent during the 120-second watch. Reparented or differently owned replacements cannot be attributed. Resident footprint is an upper-bound attribution."
        catalog.lifetimeVerified += e.targets.count
        catalog.lifetimeActions += 1
        catalog.lifetimeResidentReleased =
          (catalog.lifetimeResidentReleased ?? 0) + e.residentBefore
        if let cpu = e.cpuSecondsSavedEstimate {
          catalog.lifetimeCPUSecondsSaved = (catalog.lifetimeCPUSecondsSaved ?? 0) + cpu
        }
        let after = Responsiveness.sample()
        catalog.events[i].responseAfterSamples = after
        catalog.events[i].responseAfterMS = after.flatMap(Responsiveness.median)
      }
    }
  }
  public func updatePreferences(_ preferences: Preferences) throws {
    catalog.preferences = preferences
    try checkpoint()
    state.catalog = catalog
  }
  public func protect(_ finding: Finding) throws {
    for key in finding.members {
      guard let r = catalog.records[key] else { continue }
      catalog.preferences.protectedExecutables.insert(r.latest.executable)
      catalog.records[key]?.protection = true
    }
    try checkpoint()
    _ = refresh()
  }
  public func removeProtection(_ path: String) throws {
    catalog.preferences.protectedExecutables.remove(path)
    for key in Array(catalog.records.keys) where catalog.records[key]?.latest.executable == path {
      catalog.records[key]?.protection = false
    }
    try checkpoint()
    _ = refresh()
  }
  public func snooze(_ finding: Finding) throws {
    for key in finding.members {
      catalog.records[key]?.ignoreUntil = Date().addingTimeInterval(86400)
    }
    try checkpoint()
    _ = refresh()
  }
  public func details(_ finding: Finding) -> [String] {
    finding.members.prefix(10).compactMap { catalog.records[$0] }.map { r in
      "\(r.latest.name) · PID \(r.latest.identity.pid) · start \(r.latest.identity.seconds).\(r.latest.identity.micros)\n\(native.enrich(r.latest))"
    }
  }
  public func notificationSummary() throws -> String? {
    guard catalog.preferences.notifications else { return nil }
    let now = Date()
    let candidates = state.findings.filter {
      $0.disposition == .eligible || $0.disposition == .investigate
    }.filter { f in
      f.members.contains { key in
        guard let r = catalog.records[key], !r.protection,
          !catalog.preferences.protectedExecutables.contains(r.latest.executable),
          !(r.ignoreUntil.map { $0 > now } ?? false)
        else {
          return false
        }
        return r.alertedAt == nil
          || (now.timeIntervalSince(r.alertedAt!) > 86400 && f.rss > max(1, r.alertLevel) * 2)
      }
    }
    guard !candidates.isEmpty else { return nil }
    for f in candidates {
      for key in f.members {
        catalog.records[key]?.alertedAt = now
        catalog.records[key]?.alertLevel = f.rss
      }
    }
    try checkpoint()
    return
      "\(candidates.count) activities are worth a look. Open BurnZombies to review the evidence."
  }
  public func cleanup(_ requested: Finding, automatic: Bool = false) async throws -> String {
    throw StoreError.message("Cleanup is agent-led. Ask your connected harness to tame the horde.")
  }

  public func recordWorkspace(_ request: AgentRequest) throws -> (String?, String, WorkspaceClaim?) {
    guard case .found = native.probe(request.callerPID), let action = request.action,
      let evidence = request.rationale, (20...1200).contains(evidence.count) else {
      throw StoreError.message("Authenticated caller and factual workspace evidence are required.")
    }
    var next = catalog
    var claims = (next.workspaces ?? []).filter { $0.state != "cleaned" }
    if action == "create" {
      guard claims.count < 64, let repository = request.workspacePath, repository.hasPrefix("/"),
        let label = request.label, (1...80).contains(label.count),
        let condition = request.completionCondition, (10...500).contains(condition.count) else {
        throw StoreError.message("Create requires repository, label and completion condition. Maximum 64 tracked workspaces.")
      }
      let repo = WorkspaceSafety.canonical(repository)
      // Git checkout can execute repository-defined filters. Refuse them instead of running arbitrary commands.
      let configuration = try WorkspaceSafety.git(repo, ["config", "--null", "--name-only", "--list"])
      guard !configuration.split(separator: "\0").contains(where: { $0.hasPrefix("filter.") }) else {
        throw StoreError.message("Repositories with checkout filters require their owning harness; no worktree created.")
      }
      let directory = URL(fileURLWithPath: WorkspaceSafety.canonical(store.root.path)).appendingPathComponent("workspaces", isDirectory: true)
      if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
      _ = try WorkspaceSafety.statAt(directory.path)
      let id = UUID().uuidString, path = WorkspaceSafety.canonical(directory.path) + "/" + id
      let head = WorkspaceSafety.line(try WorkspaceSafety.git(repo, ["rev-parse", "--verify", "HEAD^{commit}"]))
      try WorkspaceSafety.git(repo, ["worktree", "add", "--detach", "--", path, head])
      let identity = try WorkspaceSafety.identity(path, root: store.root)
      let token = UUID().uuidString + UUID().uuidString
      let claim = WorkspaceClaim(id: id, tokenHash: WorkEvidence.hash(token), identity: identity,
        label: label, purpose: evidence, completionCondition: condition, state: "active", evidence: evidence,
        head: nil, created: Date(), updated: Date())
      claims.append(claim); next.workspaces = claims
      do { try store.save(next) } catch {
        throw StoreError.message("Workspace created at \(path), but ownership could not be saved. It will not be cleaned automatically. Preserve it.")
      }
      catalog = next; state.catalog = next
      return (token, "Disposable detached worktree created. Work in the returned path, create a branch if needed, and keep workToken private. Release only after outputs are preserved and all consumers finish.", claim)
    }
    guard ["release", "retain"].contains(action), let token = request.workToken, token.count == 72,
      let index = claims.firstIndex(where: { $0.tokenHash == WorkEvidence.hash(token) }),
      try WorkspaceSafety.identity(claims[index].identity.path, root: store.root) == claims[index].identity else {
      throw StoreError.message("Exact workspace and owning task's token required. No claim changed.")
    }
    claims[index].state = action == "release" ? "released" : "active"
    claims[index].head = action == "release" ? WorkspaceSafety.line(try WorkspaceSafety.git(claims[index].identity.path, ["rev-parse", "--verify", "HEAD^{commit}"])) : nil
    claims[index].evidence = evidence; claims[index].updated = Date()
    next.workspaces = claims
    try store.save(next); catalog = next; state.catalog = next
    if action == "release" { try HarnessHook.requestCleanup(root: store.root) }
    return (nil, action == "release" ? "Workspace release saved for independent review. Nothing deleted or credited." : "Workspace retained. Cleanup is blocked before you resume work.", claims[index])
  }

  public func previewWorkspace(_ id: String) throws -> WorkspaceClaim {
    guard let claim = catalog.workspaces?.first(where: { $0.id == id }) else {
      throw StoreError.message("Unknown disposable workspace; existing worktrees cannot be adopted.")
    }
    _ = try WorkspaceSafety.check(claim, root: store.root, visibility: workspaceVisibility)
    return claim
  }

  public func cleanWorkspace(_ preview: WorkspaceClaim) throws -> String {
    guard let current = catalog.workspaces?.first(where: { $0.id == preview.id }),
      current.updated == preview.updated, current.head == preview.head, current.state == "released",
      !(catalog.workspaceReceipts ?? []).contains(where: { $0.workspaceID == current.id }) else {
      throw StoreError.message("Workspace claim changed or a cleanup was already attempted. Preserve it.")
    }
    let check = try WorkspaceSafety.check(current, root: store.root, visibility: workspaceVisibility)
    let id = UUID(), ref = "refs/burnzombies/worktrees/" + id.uuidString.lowercased()
    // Atomic compare-and-create: keep the exact commit reachable even if remote refs or branches later move.
    try WorkspaceSafety.git(check.identity.common, ["update-ref", ref, check.head, String(repeating: "0", count: check.head.count)])
    var receipt = WorkspaceReceipt(id: id, workspaceID: current.id, identity: check.identity,
      label: current.label, head: check.head, recoveryRef: ref, date: Date(), verifiedAt: nil,
      outcome: "prepared", diskReclaimedBytes: 0, detail: "Prepared native removal; recovery ref preserves HEAD. No benefit yet.")
    var next = catalog; next.workspaceReceipts = (next.workspaceReceipts ?? []) + [receipt]
    try store.save(next); catalog = next; state.catalog = next
    do {
      // Recheck after durable preparation, including fresh use and all Git protections. Never --force.
      _ = try WorkspaceSafety.check(current, root: store.root, visibility: workspaceVisibility)
      let before = try WorkspaceSafety.freeBytes(store.root.path)
      try WorkspaceSafety.git(check.identity.common, ["worktree", "remove", "--", check.identity.path])
      guard WorkspaceSafety.removed(receipt) else { throw StoreError.message("Worktree removal was not verified. No benefit credited.") }
      let after = try WorkspaceSafety.freeBytes(store.root.path)
      receipt.diskReclaimedBytes = min(check.allocated, after > before ? after - before : 0)
      receipt.outcome = "verified"; receipt.verifiedAt = Date()
      receipt.detail = "Exact worktree removal verified. HEAD retained at \(ref). Disk credit is observed free-space gain capped by the removed allocated files; APFS sharing and concurrent activity can reduce attribution."
      let receiptIndex = (next.workspaceReceipts?.count ?? 1) - 1
      next.workspaceReceipts?[receiptIndex] = receipt
      next.lifetimeWorktreesCleaned = (next.lifetimeWorktreesCleaned ?? 0) + 1
      next.lifetimeDiskReclaimedBytes = (next.lifetimeDiskReclaimedBytes ?? 0) + receipt.diskReclaimedBytes
      if let index = next.workspaces?.firstIndex(where: { $0.id == current.id }) { next.workspaces?[index].state = "cleaned" }
      try store.save(next); catalog = next; state.catalog = next
      return "One worktree removal verified. \(receipt.diskReclaimedBytes) disk bytes credited; commits preserved at \(ref)."
    } catch {
      // Never turn an uncertain or interrupted removal into a positive benefit.
      var failed = catalog
      if let i = failed.workspaceReceipts?.firstIndex(where: { $0.id == id }) {
        failed.workspaceReceipts?[i].outcome = "unverified"
        failed.workspaceReceipts?[i].detail = "Removal failed or could not be recorded: " + error.localizedDescription
      }
      if (try? store.save(failed)) != nil { catalog = failed; state.catalog = failed }
      throw error
    }
  }

  public func diskPolicy() throws -> DiskPolicy { try DiskPolicy.load(store) }
  public func diskDecision(_ id: String, decision: String, rationale: String) throws -> String {
    guard ["keep", "recommend"].contains(decision), (20...1200).contains(rationale.count),
      let i = diskSnapshot.candidates.firstIndex(where: { $0.id == id && $0.reviewable }) else { throw StoreError.message("Unknown disk candidate or invalid decision.") }
    diskSnapshot.candidates[i].decision = decision; diskSnapshot.candidates[i].rationale = rationale
    try diskSnapshot.save(store)
    catalog.diskCandidates?.removeAll { $0.id == id }
    return "Disk review saved. Nothing removed. Tune exact folder rules in Settings."
  }
  public func previewDisk(_ id: String) throws -> DiskCandidate {
    let policy = try DiskPolicy.load(store)
    guard policy.mode == "automatic", let c = diskSnapshot.candidates.first(where: { $0.id == id && $0.reviewable }),
      policy.revision == diskSnapshot.policyRevision else { throw StoreError.message("Automatic mode, unchanged policy and a current candidate are required.") }
    guard try WorkspaceSafety.freeBytes(c.path) < UInt64(policy.targetFreeGB) * 1_000_000_000 else { throw StoreError.message("Free-space target is already satisfied; no removal.") }
    let today = (catalog.diskReceipts ?? []).filter { Date().timeIntervalSince($0.date) < 86400 }
    let used = today.reduce(UInt64(0)) { $0 + $1.allocatedRemoved }
    guard used + c.bytes <= UInt64(policy.maximumGBPerDay) * 1_000_000_000 else { throw StoreError.message("Daily disk cleanup cap reached; no removal.") }
    _ = try DiskInventory.check(c, policy: policy, visibility: workspaceVisibility)
    return c
  }
  public func cleanDisk(_ preview: DiskCandidate, rationale: String) throws -> String {
    let c = try previewDisk(preview.id)
    guard c.revision == preview.revision else { throw StoreError.message("Disk evidence changed after preview.") }
    let id = UUID(), quarantine = store.root.appendingPathComponent("disk-pending-" + id.uuidString)
    let source = try WorkspaceSafety.statAt(c.path), destination = try WorkspaceSafety.statAt(store.root.path)
    guard source.st_dev == destination.st_dev else { throw StoreError.message("Cross-volume cleanup is unsupported; preserved.") }
    // Persist intent first. Interrupted moves are retained here for recovery, never
    // treated as free space or silently purged on restart.
    var receipt = DiskReceipt(id: id, candidateID: c.id, path: c.path, date: Date(), outcome: "prepared",
      allocatedRemoved: c.bytes, diskReclaimedBytes: 0, rationale: rationale + " Recovery location if interrupted: " + quarantine.path)
    catalog.diskReceipts = (catalog.diskReceipts ?? []) + [receipt]; try checkpoint()
    do {
      let currentPolicy = try DiskPolicy.load(store)
      guard currentPolicy.mode == "automatic", currentPolicy.revision == diskSnapshot.policyRevision else { throw StoreError.message("Disk policy changed.") }
      _ = try DiskInventory.check(c, policy: currentPolicy, visibility: workspaceVisibility)
      let before = try WorkspaceSafety.freeBytes(store.root.path)
      guard rename(c.path, quarantine.path) == 0 else { throw StoreError.message("Could not atomically isolate the exact folder.") }
      let moved = try DiskInventory.manifest(quarantine.path)
      guard moved.complete, !moved.unsafe, moved.fingerprint == c.fingerprint else { throw StoreError.message("Folder changed during isolation. Preserved in recovery location.") }
      try FileManager.default.removeItem(at: quarantine)
      guard !FileManager.default.fileExists(atPath: quarantine.path), !FileManager.default.fileExists(atPath: c.path) else { throw StoreError.message("Removal was not verified.") }
      let after = try WorkspaceSafety.freeBytes(store.root.path)
      receipt.outcome = "verified"; receipt.date = Date(); receipt.diskReclaimedBytes = min(c.bytes, after > before ? after - before : 0)
      var next = catalog
      let receiptIndex = (next.diskReceipts?.count ?? 1) - 1
      next.diskReceipts?[receiptIndex] = receipt
      next.lifetimeDiskReclaimedBytes = (next.lifetimeDiskReclaimedBytes ?? 0) + receipt.diskReclaimedBytes
      diskSnapshot.candidates.removeAll { $0.id == c.id }; try diskSnapshot.save(store)
      next.diskCandidates?.removeAll { $0.id == c.id }
      try store.save(next); catalog = next; state.catalog = next
      return "Exact regenerable output removed and verified. \(receipt.diskReclaimedBytes) disk bytes credited; no worktree deleted."
    } catch {
      if FileManager.default.fileExists(atPath: quarantine.path), !FileManager.default.fileExists(atPath: c.path) { _ = rename(quarantine.path, c.path) }
      let failedIndex = (catalog.diskReceipts?.count ?? 1) - 1
      catalog.diskReceipts?[failedIndex].outcome = "unverified"
      try? checkpoint(); throw error
    }
  }

  public func recordWork(_ request: AgentRequest) throws -> (String?, String) {
    let current = refresh()
    guard current.error == nil, !current.partial,
      let caller = AgentSafety.ancestors(of: request.callerPID),
      let action = request.action, ["register", "release", "retain"].contains(action),
      let evidence = request.rationale, (20...1200).contains(evidence.count) else {
      throw StoreError.message("Complete visibility, authenticated caller, action and 20–1200 characters of factual evidence required.")
    }
    var claims = catalog.workEvidence ?? []
    // Only retired identities are pruned. An old or crashed owner never expires a live claim.
    let atCapacity = claims.count >= 256
    claims.removeAll { claim in
      (atCapacity || Date().timeIntervalSince(claim.updated) > 7 * 86400)
        && claim.members.allSatisfy { native.ownerState($0.identity) == .gone }
    }
    var token: String?
    var message: String
    if action == "register" {
      guard request.workToken == nil, let ids = request.processIDs, !ids.isEmpty, ids.count <= 16,
        Set(ids).count == ids.count, let label = request.label, (1...80).contains(label.count),
        let condition = request.completionCondition, (10...500).contains(condition.count), claims.count < 256 else {
        throw StoreError.message("Register 1–16 exact identities, label, purpose evidence and observable completion_condition. Claim budget: 256.")
      }
      var members = [Member](), anchors = [Member]()
      for id in ids {
        guard let record = catalog.records[id], record.missingSince == nil,
          AgentSafety.refusal(record, preferences: catalog.preferences, protectedPIDs: caller) == nil,
          case .found(let live) = native.probe(record.latest.identity.pid), Member(live) == Member(record.latest) else {
          throw StoreError.message("Registration requires a live, unprotected helper identity from inspect.")
        }
        // Capture a real common owner before a helper is orphaned; never invent lost ancestry.
        var pid = live.parent
        var anchor: Observation?
        var seen = Set<Int32>()
        for _ in 0..<128 {
          guard pid > 1, seen.insert(pid).inserted, case .found(let parent) = native.probe(pid) else { break }
          if caller.contains(pid) { anchor = parent; break }
          pid = parent.parent
        }
        guard let anchor, anchor.uid == getuid() else {
          throw StoreError.message("No live ownership ancestry connects this caller and helper. Preserve it; do not retroactively invent ownership.")
        }
        members.append(Member(record.latest)); anchors.append(Member(anchor))
      }
      let secret = UUID().uuidString + UUID().uuidString
      token = secret
      claims.append(WorkEvidence(id: UUID().uuidString, tokenHash: WorkEvidence.hash(secret),
        members: members, anchors: anchors, label: label, purpose: evidence, completionCondition: condition,
        created: Date(), updated: Date(), state: "active", evidence: evidence))
      message = "Active claim saved. Keep work_token in the owning task. Release only after observing completion and no remaining consumers. This did not stop anything."
    } else {
      guard request.processIDs == nil, request.label == nil, request.completionCondition == nil,
        let secret = request.workToken, secret.count == 72,
        let index = claims.firstIndex(where: { $0.tokenHash == WorkEvidence.hash(secret) }) else {
        throw StoreError.message("The owning task's work_token is required; no claim was changed.")
      }
      claims[index].state = action == "release" ? "released" : "active"
      claims[index].evidence = evidence; claims[index].updated = Date()
      message = action == "release"
        ? "Owner release recorded; queued for independent review. No stop requested and no benefit credited."
        : "Active need recorded. Cleanup is blocked while this claim remains active."
    }
    // Commit before publishing or returning a capability. Failed writes cannot weaken protection.
    var next = catalog; next.workEvidence = claims
    try store.save(next)
    catalog = next; state.catalog = next
    if action == "release" { try HarnessHook.requestCleanup(root: store.root) }
    return (token, message)
  }

  public func workSummaries() -> [WorkSummary] {
    let claims = catalog.workEvidence ?? []
    let owned = claims.sorted { $0.updated > $1.updated }.map { claim in
      let live = claim.members.filter { member in
        guard let r = catalog.records[member.identity.key] else { return false }
        return r.missingSince == nil && Member(r.latest) == member
      }
      return WorkSummary(id: claim.id, processIDs: claim.members.map { $0.identity.key },
        livePIDs: live.map { $0.identity.pid }, label: claim.label, purpose: claim.purpose,
        completionCondition: claim.completionCondition, state: claim.state, evidence: claim.evidence,
        created: claim.created, updated: claim.updated, ownershipAnchors: claim.anchors,
        blockedByActiveClaim: claim.members.contains { WorkEvidence.blocking(claims, identity: $0.identity.key) })
    }
    return owned + (catalog.passiveEvidence ?? []).map(\.workSummary)
  }

  public func previewTargets(_ ids: [String], callerPID: Int32) throws -> [Observation] {
    let before = refresh()
    guard before.error == nil, !before.partial,
      !ids.isEmpty, ids.count <= 64, Set(ids).count == ids.count,
      let callerAncestors = AgentSafety.ancestors(of: callerPID),
      let ownAncestors = AgentSafety.ancestors(of: getpid())
    else { throw StoreError.message("Complete visibility and 1–64 distinct process identities are required.") }
    let protectedPIDs = callerAncestors.union(ownAncestors)
    var targets = [Observation]()
    for id in ids {
      guard let r = catalog.records[id], r.missingSince == nil else {
        throw StoreError.message("Target identity expired. Inspect again.")
      }
      if let reason = AgentSafety.refusal(r, preferences: catalog.preferences, protectedPIDs: protectedPIDs) {
        throw StoreError.message("PID \(r.latest.identity.pid): \(reason)")
      }
      if WorkEvidence.blockingTree(catalog.workEvidence ?? [], record: r, records: catalog.records) {
        throw StoreError.message("PID \(r.latest.identity.pid): an owning task still retains this helper. All claims must be released.")
      }
      if let evidence = catalog.passiveEvidence?.first(where: { $0.member.identity.key == id }), !evidence.canReview() {
        throw StoreError.message("PID \(r.latest.identity.pid): passive owner evidence changed or is incomplete. Preserve this helper.")
      }
      targets.append(r.latest)
    }
    let pids = Set(targets.map { $0.identity.pid })
    guard !catalog.records.values.contains(where: {
      $0.missingSince == nil && pids.contains($0.latest.parent) && !pids.contains($0.latest.identity.pid)
    }) else { throw StoreError.message("A target has unreviewed live children. Inspect the tree or use its owner's teardown.") }
    return targets
  }

  public func burnTargets(_ reviewed: [Observation], label: String, rationale: String,
    callerPID: Int32) throws -> String {
    guard !busy else { throw StoreError.message("A cleanup is already in progress.") }
    busy = true
    defer { busy = false }
    let responseBefore = Responsiveness.sample()
    let targets = try previewTargets(reviewed.map { $0.identity.key }, callerPID: callerPID)
    guard zip(targets, reviewed).allSatisfy({ Member($0.0) == Member($0.1) }) else {
      throw StoreError.message("Process identity or executable changed since preview.")
    }
    // Refresh immediately before each syscall as well; no cached-PID or process-name kills.
    var event = CleanupEvent(leaseID: UUID(), label: label, date: Date(),
      targets: targets.map(Member.init), residentBefore: targets.reduce(0) { $0 + $1.rss },
      outcome: "verifying", detail: "Agent decision: \(rationale). Graceful stop requested; verifying exits.")
    event.recurrenceScopes = targets.compactMap { target in
      guard target.parent > 1, case .found(let parent) = native.probe(target.parent) else { return nil }
      return RecurrenceScope(executable: target.executable, parent: Member(parent))
    }
    event.cpuSavingsRate = ImpactAccounting.cpuRate(targets.compactMap { catalog.records[$0.identity.key] })
    event.cpuObservedSeconds = event.cpuSavingsRate == nil ? nil : 0
    event.cpuSecondsSavedEstimate = event.cpuSavingsRate == nil ? nil : 0
    event.responseBeforeSamples = responseBefore
    event.responseBeforeMS = responseBefore.flatMap(Responsiveness.median)
    catalog.events.append(event)
    try checkpoint()
    var failures = [String]()
    for target in targets {
      let code = native.terminate(target)
      if code != 0 { failures.append("PID \(target.identity.pid): errno \(code)") }
    }
    if !failures.isEmpty {
      catalog.events[catalog.events.count - 1].outcome = "partial"
      catalog.events[catalog.events.count - 1].detail = failures.joined(separator: "; ") + ". No benefit credited."
    }
    try checkpoint()
    _ = refresh()
    return failures.isEmpty ? "Graceful stop requested. Exit receipts are pending; continue your work and check later."
      : "Some targets could not be stopped. No escalation. Inspect the receipt."
  }
}
