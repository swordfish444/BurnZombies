import CBurn
import CryptoKit
import Darwin
import Foundation

public struct ViewState: Sendable {
  public var worktrees: WorktreeReply?
  public var worktreeError: String?
  public var fullDiskAccess = FullDiskAccessStatus()
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
  private let accessCheck: @Sendable () -> FullDiskAccessStatus
  private let store: Store
  private var worktreeService: WorktreeService?
  private let lock: InstanceLock
  private let native = Native()
  private let passive: PassiveCollector?
  private let discovery: DiskDiscovery?
  private let ownerMaintenance: OwnerMaintenance?
  private var diskScanRunning = false
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
  public init(
    root: URL = Store.defaultRoot, passiveHome: URL? = nil, discoveryRoots: [String]? = nil,
    workspaceVisibility: (@Sendable (String) -> Int32)? = nil,
    accessCheck: (@Sendable () -> FullDiskAccessStatus)? = nil,
    discoveryWalker: DiskWalkRunner? = nil,
    worktreeRecoveryKey: (@Sendable () throws -> SymmetricKey)? = nil
  ) throws {
    self.workspaceVisibility = workspaceVisibility ?? { bz_path_in_use($0) }
    self.accessCheck = accessCheck ?? { FullDiskAccess.status(root: root) }
    store = try Store(root: root)
    ownerMaintenance =
      root.standardizedFileURL == Store.defaultRoot.standardizedFileURL
        && ProcessInfo.processInfo.environment["BURNZOMBIES_HOME"] == nil
      ? OwnerMaintenance(store: store, accessCheck: self.accessCheck) : nil
    discovery =
      discoveryRoots != nil
        || (root.standardizedFileURL == Store.defaultRoot.standardizedFileURL
          && ProcessInfo.processInfo.environment["BURNZOMBIES_HOME"] == nil)
      ? try DiskDiscovery(
        store: store, roots: discoveryRoots, walker: discoveryWalker, accessCheck: self.accessCheck)
      : nil
    passive =
      root.standardizedFileURL == Store.defaultRoot.standardizedFileURL || passiveHome != nil
      ? try PassiveCollector(
        store: store, home: passiveHome ?? FileManager.default.homeDirectoryForCurrentUser) : nil
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
        receipts[i].detail =
          "Workspace operation interrupted. Preserve the recovery ref; no disk or worktree credit without the completed receipt."
      }
      loaded.workspaceReceipts = receipts
    }
    if var attempts = loaded.managedCacheAttempts {
      for i in attempts.indices where attempts[i].outcome == "prepared" {
        attempts[i].outcome = "uncertain"
        attempts[i].detail =
          "Interrupted owner operation; preserve exact record IDs until reconciliation. Never retry automatically."
      }
      loaded.managedCacheAttempts = attempts
    }
    for i in loaded.events.indices where loaded.events[i].outcome == "prepared" {
      loaded.events[i].outcome = "unverified"
    }
    ImpactAccounting.migrate(&loaded)
    loaded.resetContinuity()
    do {
      let service = try WorktreeService(
        root: root, visibility: workspaceVisibility, access: self.accessCheck,
        recoveryKey: worktreeRecoveryKey, legacy: loaded.workspaces ?? [])
      if !(loaded.workspaces ?? []).isEmpty {
        loaded.workspaces = []
        try store.save(loaded)
      }
      try service.finishMigration()
      worktreeService = service
    } catch { state.worktreeError = "Worktree management paused: " + error.localizedDescription }
    catalog = loaded
    state.catalog = loaded
    state.fullDiskAccess = self.accessCheck()
  }
  public func snapshot() async -> ViewState {
    var projected = state
    if let service = worktreeService {
      do {
        projected.worktrees = try await service.snapshot()
        let added = try await service.projectedReceipts()
        projected.catalog.workspaces = try await service.legacyClaims()
        projected.catalog.workspaceReceipts = (catalog.workspaceReceipts ?? []) + added
        projected.catalog.lifetimeWorktreesCleaned =
          (catalog.lifetimeWorktreesCleaned ?? 0) + added.count
        projected.catalog.lifetimeDiskReclaimedBytes =
          (catalog.lifetimeDiskReclaimedBytes ?? 0) + added.reduce(0) { $0 + $1.diskReclaimedBytes }
      } catch {
        projected.worktreeError = "Worktree evidence unavailable: " + error.localizedDescription
      }
    }
    return projected
  }
  public func workspaceClaims() async throws -> [WorkspaceClaim] {
    guard let service = worktreeService else {
      throw StoreError.message("Worktree store unavailable.")
    }
    return try await service.legacyClaims()
  }
  public func worktreeTick() async {
    guard !busy, accessCheck().canScan, let service = worktreeService else { return }
    do {
      let roots = (try? DiskPolicy.load(store).roots) ?? []
      try await service.suggestRoots(roots + (catalog.diskCandidates ?? []).map(\.repository))
      catalog.worktreeEvidence = try await service.tick()
      state.worktreeError = nil
    } catch {
      catalog.worktreeEvidence = []
      state.worktreeError = "Worktree observation: " + error.localizedDescription
    }
  }
  public func shutdownWorktrees() async { await worktreeService?.shutdown() }
  public func worktreeRequest(_ request: WorktreeRequest, caller: String, management: Bool = true)
    async throws -> WorktreeReply
  {
    try requireFullDiskAccess()
    let destructive = [
      "retire", "retire_dirty", "quarantine", "finish_quarantine", "batch_retire", "repair",
      "reconcile", "rescue", "restore", "purge",
    ].contains(request.action)
    guard let service = worktreeService,
      !busy || ["list", "operations", "keep", "retain"].contains(request.action)
    else { throw StoreError.message("Cleanup is busy or worktree store unavailable.") }
    if destructive { busy = true }
    defer { if destructive { busy = false } }
    return try await service.request(request, caller: caller, management: management)
  }
  public func recheckFullDiskAccess() throws -> ViewState {
    state.fullDiskAccess = try FullDiskAccess.confirmSetup(root: store.root)
    return state
  }
  public func requireFullDiskAccess() throws {
    state.fullDiskAccess = accessCheck()
    guard state.fullDiskAccess.canScan else {
      throw StoreError.message(state.fullDiskAccess.detail)
    }
  }
  public func resetContinuity() {
    receiptNeedsCheckpoint =
      receiptNeedsCheckpoint || catalog.events.contains { $0.outcome == "verifying" }
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
    state.fullDiskAccess = accessCheck()
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
        let ended = Set(
          catalog.events.filter { event in
            event.outcome == "verified" && event.cpuAccrualEnded != true
              && Verification.recurrence(event: event, observations: scan.observations) { parent in
                guard case .found(let live) = native.probe(parent.identity.pid) else {
                  return false
                }
                return Member(live) == parent && !live.zombie
              }
          }.map(\.id))
        let added = ImpactAccounting.accrue(
          &catalog, awakeSeconds: awake - previousAwake,
          wallSeconds: now.timeIntervalSince(previousWall), boot: native.boot, ended: ended)
        receiptNeedsCheckpoint = receiptNeedsCheckpoint || added > 0
      }
      verifyPending(now: now, observations: scan.observations)
      receiptNeedsCheckpoint =
        receiptNeedsCheckpoint || priorOutcomes != catalog.events.map(\.outcome)
      catalog.lastSample = now
      catalog.prune(now: now)
      if state.fullDiskAccess.canScan, let passive {
        catalog.passiveEvidence = try passive.poll(
          records: catalog.records, claims: catalog.workEvidence ?? [], now: now,
          partial: scan.partial)
      }
      catalog.diskDiscovery = nil
      if let discovery {
        discovery.setAccessAllowed(state.fullDiskAccess.canScan)
      }
      if state.fullDiskAccess.canScan, let discovery {
        let policy = try DiskPolicy.load(store)
        discovery.tick(policy: policy)
        catalog.diskDiscovery = policy.mode == "off" ? [] : discovery.snapshot().pending
      }
      if state.fullDiskAccess.canScan
        && (store.root.standardizedFileURL == Store.defaultRoot.standardizedFileURL
          || FileManager.default.fileExists(
            atPath: store.root.appendingPathComponent("disk-policy.json").path))
      {
        let policy = try DiskPolicy.load(store)
        if !diskScanLoaded {
          diskSnapshot = try DiskSnapshot.load(store)
          diskScanLoaded = true
        }
        if !diskScanRunning
          && (diskSnapshot.recommendationVersion != 2
            || now.timeIntervalSince(diskSnapshot.date) >= Double(policy.scanHours * 3600)
            || diskSnapshot.policyRevision != policy.revision)
        {
          diskScanRunning = true
          let previous = diskSnapshot
          let visibility = workspaceVisibility
          Task.detached(priority: .utility) { [self] in
            guard self.accessCheck().canScan else {
              await self.cancelDiskScan()
              return
            }
            let result = DiskInventory.scan(
              policy: policy, previous: previous, visibility: visibility)
            await self.acceptDiskScan(result)
          }
        }
        if let ownerMaintenance {
          ownerMaintenance.tick(
            records: catalog.records, policy: policy,
            complete: !scan.partial && scan.observations.count <= 4096, now: now)
          let owners = ownerMaintenance.snapshot()
          catalog.ownerDaemons = owners.daemons
          catalog.managedCache = owners.cache
          let free = try? WorkspaceSafety.freeBytes(store.root.path)
          catalog.managedCacheAllowanceBytes =
            policy.mode == "automatic" ? try managedAvailableBytes() : nil
          catalog.managedCacheReviewAllowed =
            policy.mode == "recommend"
            || (policy.mode == "automatic"
              && free.map { $0 < UInt64(policy.targetFreeGB) * 1_000_000_000 } == true)
          catalog.ownerEvidenceGaps = owners.gaps
        }
        catalog.diskCandidates = diskSnapshot.candidates.filter {
          $0.pendingReview && diskSnapshot.freeBytes < UInt64(policy.targetFreeGB) * 1_000_000_000
        }
      }
      // Observation is factual. The connected harness owns diagnosis and target selection.
      state.findings = []
      state.interval = catalog.events.contains { $0.outcome == "verifying" } ? 15 : 60
      if receiptNeedsCheckpoint || now.timeIntervalSince(lastSave) >= 300 {
        try checkpoint()
      }
      if !scan.partial && state.fullDiskAccess.canScan {
        try HarnessHook.publish(
          .init(
            observedAt: now, processCount: scan.observations.count,
            residentBytes: scan.observations.reduce(0) { $0 + $1.rss },
            pressure: native.memoryPressure(),
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
  private func cancelDiskScan() { diskScanRunning = false }
  private func acceptDiskScan(_ result: DiskSnapshot) {
    defer { diskScanRunning = false }
    do {
      guard accessCheck().canScan, try DiskPolicy.load(store).revision == result.policyRevision
      else { return }
      try result.save(store)
      diskSnapshot = result
    } catch { state.error = "Disk inventory could not be saved: " + error.localizedDescription }
  }

  private func verifyPending(now: Date, observations: [Observation]) {
    for i in catalog.events.indices where catalog.events[i].outcome == "verifying" {
      let e = catalog.events[i]
      var elapsed = now.timeIntervalSince(e.date)
      guard elapsed >= 15 else { continue }
      let statuses = e.targets.map { native.ownerState($0.identity) }
      if e.ownerProtocol == true {
        switch Verification.ownerWatch(
          elapsed: elapsed, targets: statuses, partialScan: state.partial,
          elapsedSinceExit: e.ownerExitObservedAt.map { now.timeIntervalSince($0) })
        {
        case .waiting: continue
        case .observedExit:
          catalog.events[i].ownerExitObservedAt = now
          receiptNeedsCheckpoint = true
          continue
        case .unverified:
          catalog.events[i].outcome = "unverified"
          catalog.events[i].detail =
            "Owner watch lost continuity or exceeded its bounded wait; no escalation or credit."
          continue
        case .verify(let elapsedSinceExit): elapsed = elapsedSinceExit
        }
      }
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

  public func recordWorkspace(_ request: AgentRequest) async throws -> (
    String?, String, WorkspaceClaim?
  ) {
    try requireFullDiskAccess()
    guard case .found = native.probe(request.callerPID), let service = worktreeService,
      !busy || request.action == "retain"
    else {
      throw StoreError.message("Authenticated caller and available worktree service required.")
    }
    return try await service.legacyRequest(request)
  }
  public func previewWorkspace(_ id: String) async throws -> WorkspaceClaim {
    try requireFullDiskAccess()
    guard let service = worktreeService else {
      throw StoreError.message("Worktree service unavailable.")
    }
    return try await service.legacyPreview(id)
  }
  public func cleanWorkspace(_ preview: WorkspaceClaim) async throws -> String {
    try requireFullDiskAccess()
    guard !busy, let service = worktreeService else {
      throw StoreError.message("Cleanup is already in progress or unavailable.")
    }
    busy = true
    defer { busy = false }
    return try await service.legacyClean(preview).detail
  }

  public func diskPolicy() throws -> DiskPolicy { try DiskPolicy.load(store) }
  public func diskDiscoveryRequest(_ request: AgentRequest) async throws -> AgentReply {
    try requireFullDiskAccess()
    guard let discovery, try DiskPolicy.load(store).mode != "off" else {
      throw StoreError.message("Storage discovery is unavailable or disabled.")
    }
    let id = request.findingID ?? ""
    var reply = AgentReply(message: "Read-only storage evidence; no removal authority.")
    switch request.operation {
    case "disk_explore": reply.message = try discovery.explore(id, allowed: request.reviewIDs)
    case "disk_inspect":
      reply.diskInspection = try await Task.detached {
        try discovery.inspect(id, allowed: request.reviewIDs)
      }.value
    case "disk_evidence":
      reply.diskEvidence = try discovery.readEvidence(
        id, relativePath: request.workspacePath ?? "", allowed: request.reviewIDs)
    case "disk_recommend":
      reply.message = try discovery.recommend(
        id, disposition: request.action ?? "", title: request.label ?? "",
        summary: request.rationale ?? "", nextStep: request.completionCondition ?? "",
        allowed: request.reviewIDs)
    default: throw StoreError.message("Unknown discovery operation.")
    }
    catalog.diskDiscovery = discovery.snapshot().pending
    state.catalog = catalog
    return reply
  }
  public func diskDecision(_ id: String, decision: String, rationale: String) throws -> String {
    try requireFullDiskAccess()
    guard ["keep", "recommend"].contains(decision), (20...1200).contains(rationale.count),
      let i = diskSnapshot.candidates.firstIndex(where: { $0.id == id && $0.pendingReview }),
      try DiskPolicy.load(store).revision == diskSnapshot.policyRevision
    else { throw StoreError.message("Unknown disk candidate, changed policy or invalid decision.") }
    diskSnapshot.candidates[i].decisionRevision = diskSnapshot.candidates[i].queueRevision
    diskSnapshot.candidates[i].decision = decision
    diskSnapshot.candidates[i].rationale = rationale
    try diskSnapshot.save(store)
    catalog.diskCandidates?.removeAll { $0.id == id }
    state.catalog = catalog
    return
      "AI recommendation saved in Settings. Nothing removed; removal permission and safety checks are separate."
  }
  public func previewDisk(_ id: String) throws -> DiskCandidate {
    try requireFullDiskAccess()
    let policy = try DiskPolicy.load(store)
    guard policy.mode == "automatic",
      let c = diskSnapshot.candidates.first(where: { $0.id == id && $0.reviewable }),
      policy.revision == diskSnapshot.policyRevision
    else {
      throw StoreError.message(
        "Automatic mode, unchanged policy and a current candidate are required.")
    }
    guard try WorkspaceSafety.freeBytes(c.path) < UInt64(policy.targetFreeGB) * 1_000_000_000 else {
      throw StoreError.message("Free-space target is already satisfied; no removal.")
    }
    let used = managedUsedToday()
    guard used + c.bytes <= UInt64(policy.maximumGBPerDay) * 1_000_000_000 else {
      throw StoreError.message("Daily disk cleanup cap reached; no removal.")
    }
    _ = try DiskInventory.check(c, policy: policy, visibility: workspaceVisibility)
    return c
  }
  public func cleanDisk(_ preview: DiskCandidate, rationale: String) throws -> String {
    try requireFullDiskAccess()
    guard !busy else { throw StoreError.message("A cleanup is already in progress.") }
    busy = true
    defer { busy = false }
    let c = try previewDisk(preview.id)
    guard c.revision == preview.revision else {
      throw StoreError.message("Disk evidence changed after preview.")
    }
    let id = UUID()
    let quarantine = store.root.appendingPathComponent("disk-pending-" + id.uuidString)
    let source = try WorkspaceSafety.statAt(c.path)
    let destination = try WorkspaceSafety.statAt(store.root.path)
    guard source.st_dev == destination.st_dev else {
      throw StoreError.message("Cross-volume cleanup is unsupported; preserved.")
    }
    // Persist intent first. Interrupted moves are retained here for recovery, never
    // treated as free space or silently purged on restart.
    var receipt = DiskReceipt(
      id: id, candidateID: c.id, path: c.path, date: Date(), outcome: "prepared",
      allocatedRemoved: c.bytes, diskReclaimedBytes: 0,
      rationale: rationale + " Recovery location if interrupted: " + quarantine.path)
    catalog.diskReceipts = (catalog.diskReceipts ?? []) + [receipt]
    try checkpoint()
    do {
      let currentPolicy = try DiskPolicy.load(store)
      guard currentPolicy.mode == "automatic", currentPolicy.revision == diskSnapshot.policyRevision
      else { throw StoreError.message("Disk policy changed.") }
      _ = try DiskInventory.check(c, policy: currentPolicy, visibility: workspaceVisibility)
      let before = try WorkspaceSafety.freeBytes(store.root.path)
      guard rename(c.path, quarantine.path) == 0 else {
        throw StoreError.message("Could not atomically isolate the exact folder.")
      }
      let moved = try DiskInventory.manifest(quarantine.path)
      guard moved.complete, !moved.unsafe, moved.fingerprint == c.fingerprint else {
        throw StoreError.message("Folder changed during isolation. Preserved in recovery location.")
      }
      try FileManager.default.removeItem(at: quarantine)
      guard !FileManager.default.fileExists(atPath: quarantine.path),
        !FileManager.default.fileExists(atPath: c.path)
      else { throw StoreError.message("Removal was not verified.") }
      let after = try WorkspaceSafety.freeBytes(store.root.path)
      receipt.outcome = "verified"
      receipt.date = Date()
      receipt.diskReclaimedBytes = min(c.bytes, after > before ? after - before : 0)
      var next = catalog
      let receiptIndex = (next.diskReceipts?.count ?? 1) - 1
      next.diskReceipts?[receiptIndex] = receipt
      next.lifetimeDiskReclaimedBytes =
        (next.lifetimeDiskReclaimedBytes ?? 0) + receipt.diskReclaimedBytes
      diskSnapshot.candidates.removeAll { $0.id == c.id }
      try diskSnapshot.save(store)
      next.diskCandidates?.removeAll { $0.id == c.id }
      try store.save(next)
      catalog = next
      state.catalog = next
      return
        "Exact regenerable output removed and verified. \(receipt.diskReclaimedBytes) disk bytes credited; no worktree deleted."
    } catch {
      if FileManager.default.fileExists(atPath: quarantine.path),
        !FileManager.default.fileExists(atPath: c.path)
      {
        _ = rename(quarantine.path, c.path)
      }
      let failedIndex = (catalog.diskReceipts?.count ?? 1) - 1
      catalog.diskReceipts?[failedIndex].outcome = "unverified"
      try? checkpoint()
      throw error
    }
  }

  public func recordWork(_ request: AgentRequest) throws -> (String?, String) {
    try requireFullDiskAccess()
    let current = refresh()
    guard current.error == nil, !current.partial,
      let caller = AgentSafety.ancestors(of: request.callerPID),
      let action = request.action, ["register", "release", "retain"].contains(action),
      let evidence = request.rationale, (20...1200).contains(evidence.count)
    else {
      throw StoreError.message(
        "Complete visibility, authenticated caller, action and 20–1200 characters of factual evidence required."
      )
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
        let condition = request.completionCondition, (10...500).contains(condition.count),
        claims.count < 256
      else {
        throw StoreError.message(
          "Register 1–16 exact identities, label, purpose evidence and observable completion_condition. Claim budget: 256."
        )
      }
      var members = [Member]()
      var anchors = [Member]()
      for id in ids {
        guard let record = catalog.records[id], record.missingSince == nil,
          AgentSafety.refusal(record, preferences: catalog.preferences, protectedPIDs: caller)
            == nil,
          case .found(let live) = native.probe(record.latest.identity.pid),
          Member(live) == Member(record.latest)
        else {
          throw StoreError.message(
            "Registration requires a live, unprotected helper identity from inspect.")
        }
        // Capture a real common owner before a helper is orphaned; never invent lost ancestry.
        var pid = live.parent
        var anchor: Observation?
        var seen = Set<Int32>()
        for _ in 0..<128 {
          guard pid > 1, seen.insert(pid).inserted, case .found(let parent) = native.probe(pid)
          else { break }
          if caller.contains(pid) {
            anchor = parent
            break
          }
          pid = parent.parent
        }
        guard let anchor, anchor.uid == getuid() else {
          throw StoreError.message(
            "No live ownership ancestry connects this caller and helper. Preserve it; do not retroactively invent ownership."
          )
        }
        members.append(Member(record.latest))
        anchors.append(Member(anchor))
      }
      let secret = UUID().uuidString + UUID().uuidString
      token = secret
      claims.append(
        WorkEvidence(
          id: UUID().uuidString, tokenHash: WorkEvidence.hash(secret),
          members: members, anchors: anchors, label: label, purpose: evidence,
          completionCondition: condition,
          created: Date(), updated: Date(), state: "active", evidence: evidence))
      message =
        "Active claim saved. Keep work_token in the owning task. Release only after observing completion and no remaining consumers. This did not stop anything."
    } else {
      guard request.processIDs == nil, request.label == nil, request.completionCondition == nil,
        let secret = request.workToken, secret.count == 72,
        let index = claims.firstIndex(where: { $0.tokenHash == WorkEvidence.hash(secret) })
      else {
        throw StoreError.message("The owning task's work_token is required; no claim was changed.")
      }
      claims[index].state = action == "release" ? "released" : "active"
      claims[index].evidence = evidence
      claims[index].updated = Date()
      message =
        action == "release"
        ? "Owner release recorded; queued for independent review. No stop requested and no benefit credited."
        : "Active need recorded. Cleanup is blocked while this claim remains active."
    }
    // Commit before publishing or returning a capability. Failed writes cannot weaken protection.
    var next = catalog
    next.workEvidence = claims
    try store.save(next)
    catalog = next
    state.catalog = next
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
      return WorkSummary(
        id: claim.id, processIDs: claim.members.map { $0.identity.key },
        livePIDs: live.map { $0.identity.pid }, label: claim.label, purpose: claim.purpose,
        completionCondition: claim.completionCondition, state: claim.state,
        evidence: claim.evidence,
        created: claim.created, updated: claim.updated, ownershipAnchors: claim.anchors,
        blockedByActiveClaim: claim.members.contains {
          WorkEvidence.blocking(claims, identity: $0.identity.key)
        })
    }
    return owned + (catalog.passiveEvidence ?? []).map(\.workSummary)
  }

  private func ownerGuard(_ evidence: GradleDaemonEvidence, callerPID: Int32) throws -> Record {
    guard !state.partial, let record = catalog.records[evidence.member.identity.key],
      record.missingSince == nil, Member(record.latest) == evidence.member,
      let ancestors = AgentSafety.ancestors(of: callerPID),
      let own = AgentSafety.ancestors(of: getpid()),
      AgentSafety.refusal(
        record, preferences: catalog.preferences, protectedPIDs: ancestors.union(own)) == nil,
      !WorkEvidence.blockingTree(
        catalog.workEvidence ?? [], record: record, records: catalog.records),
      !catalog.records.values.contains(where: {
        $0.missingSince == nil && $0.latest.parent == record.latest.identity.pid
      }),
      !catalog.events.contains(where: {
        ["prepared", "verifying", "unverified"].contains($0.outcome)
          && $0.targets.contains(evidence.member)
      })
    else {
      throw StoreError.message(
        "Owner identity, active use, visibility or an earlier uncertain stop prevents this action.")
    }
    return record
  }
  public func previewOwnerProcess(_ id: String, callerPID: Int32) throws -> GradleDaemonEvidence {
    try requireFullDiskAccess()
    _ = refresh()
    guard let evidence = catalog.ownerDaemons?.first(where: { $0.id == id }), evidence.eligible
    else {
      throw StoreError.message(
        "Supported cached owner evidence required; exact producer facts must be revalidated before dispatch."
      )
    }
    _ = try ownerGuard(evidence, callerPID: callerPID)
    return evidence
  }
  public func startOwnerStop(_ evidence: GradleDaemonEvidence, rationale: String, callerPID: Int32)
    throws -> String
  {
    try requireFullDiskAccess()
    guard !busy else { throw StoreError.message("A cleanup is already in progress.") }
    _ = refresh()
    let target = try ownerGuard(evidence, callerPID: callerPID)
    var event = CleanupEvent(
      leaseID: UUID(), label: "Idle Gradle daemon", date: Date(),
      targets: [evidence.member], residentBefore: target.latest.rss, outcome: "prepared",
      detail: "Owner-protocol decision: " + rationale
        + ". Revalidating exact daemon; no benefit credited.")
    event.ownerProtocol = true
    event.cpuSavingsRate = ImpactAccounting.cpuRate([target])
    event.cpuObservedSeconds = event.cpuSavingsRate == nil ? nil : 0
    event.cpuSecondsSavedEstimate = event.cpuSavingsRate == nil ? nil : 0
    catalog.events.append(event)
    try checkpoint()
    state.catalog = catalog
    busy = true
    let eventID = event.id
    Task.detached(priority: .utility) { [self] in
      let result = Result { () throws -> String in
        let (fresh, records) = try OwnerStopFailure.preflight {
          () -> (GradleDaemonEvidence, [String: Record]) in
          guard self.accessCheck().canScan else {
            throw StoreError.message(FullDiskAccess.instructions)
          }
          let scan = Native().scan()
          guard !scan.partial,
            let live = scan.observations.first(where: { Member($0) == evidence.member })
          else {
            throw StoreError.message(
              "Fresh complete process visibility unavailable; owner stop refused.")
          }
          let records = Dictionary(
            uniqueKeysWithValues: scan.observations.map { ($0.identity.key, Record($0)) })
          guard let fresh = try GradleDaemon.inspect(live, records: records, complete: true),
            fresh.eligible,
            fresh.daemonUID == evidence.daemonUID, fresh.lastBusy == evidence.lastBusy,
            fresh.evidenceFingerprint == evidence.evidenceFingerprint,
            fresh.gradleHome == evidence.gradleHome
          else {
            throw StoreError.message(
              "Daemon activity or ownership changed since preview; preserved.")
          }
          return (fresh, records)
        }
        return try GradleDaemon.requestGracefulStop(
          fresh, records: records,
          authorize: {
            guard self.accessCheck().canScan else {
              throw StoreError.message(FullDiskAccess.instructions)
            }
            let saved = try self.store.load()
            guard let current = saved.records[fresh.member.identity.key],
              AgentSafety.refusal(current, preferences: saved.preferences, protectedPIDs: [])
                == nil,
              !WorkEvidence.blockingTree(
                saved.workEvidence ?? [], record: current, records: saved.records)
            else {
              throw StoreError.message("Owner protections or active claims changed; preserved.")
            }
          })
      }
      await self.finishOwnerStop(eventID, result: result)
    }
    return
      "Exact owner stop queued with a durable receipt. It will recheck activity, allow any raced build to finish, and verify exit independently. Do not poll or retry."
  }
  private func finishOwnerStop(_ id: UUID, result: Result<String, Error>) {
    defer { busy = false }
    guard let index = catalog.events.firstIndex(where: { $0.id == id }) else { return }
    switch result {
    case .success(let message):
      catalog.events[index].date = Date()
      catalog.events[index].outcome = "verifying"
      catalog.events[index].detail = message
    case .failure(let error):
      catalog.events[index].outcome = OwnerStopFailure.receiptOutcome(for: error)
      catalog.events[index].detail =
        (catalog.events[index].outcome == "refused" ? "No owner stop was dispatched. " : "")
        + error.localizedDescription
    }
    do { try checkpoint() } catch { state.error = error.localizedDescription }
    state.catalog = catalog
  }
  public func managedAvailableBytes() throws -> UInt64 {
    let limit = UInt64(try DiskPolicy.load(store).maximumGBPerDay) * 1_000_000_000
    let used = managedUsedToday()
    return used < limit ? limit - used : 0
  }
  private func managedUsedToday() -> UInt64 {
    let since = Date().addingTimeInterval(-86400)
    let files = (catalog.diskReceipts ?? []).filter { $0.date > since }.reduce(UInt64(0)) {
      $0 + $1.allocatedRemoved
    }
    return (catalog.managedCacheAttempts ?? []).filter { $0.date > since }.reduce(files) {
      $0
        + (["prepared", "uncertain"].contains($1.outcome)
          ? $1.plan.cacheBytes : ($1.receipt?.cacheReleasedBytes ?? 0))
    }
  }
  public func previewManagedCache(_ id: String, recordIDs: [String]) throws -> BuildKitCache.Plan {
    try requireFullDiskAccess()
    let policy = try DiskPolicy.load(store)
    guard
      (catalog.managedCacheAttempts ?? []).filter({
        ["prepared", "uncertain"].contains($0.outcome)
      }).count < 128
    else {
      throw StoreError.message(
        "Unresolved cache operations require reconciliation before another cleanup.")
    }
    guard let inventory = catalog.managedCache, ManagedCacheSummary(inventory).id == id,
      try WorkspaceSafety.freeBytes(store.root.path) < UInt64(policy.targetFreeGB) * 1_000_000_000,
      ManagedCacheAttempt.blockedIDs(catalog.managedCacheAttempts ?? [], inventory: inventory)
        .isDisjoint(with: recordIDs)
    else {
      throw StoreError.message(
        "Cache inventory expired, free-space target met, or an exact record was already attempted. Preserve it."
      )
    }
    return try BuildKitCache.preview(
      inventory: inventory, recordIDs: recordIDs, policy: policy, usedTodayBytes: managedUsedToday()
    )
  }
  public func startManagedCache(_ plan: BuildKitCache.Plan, rationale: String) throws -> String {
    try requireFullDiskAccess()
    guard !busy else { throw StoreError.message("A cleanup is already in progress.") }
    let fresh = try previewManagedCache(
      ManagedCacheSummary(plan.inventory).id, recordIDs: plan.recordIDs)
    guard fresh.inventory.revision == plan.inventory.revision, Date() <= plan.expires else {
      throw StoreError.message("Cache plan changed or expired; preserved.")
    }
    let policy = try DiskPolicy.load(store)
    let used = managedUsedToday()
    var durablePlan = plan
    durablePlan.inventory.records = plan.inventory.records.filter { plan.recordIDs.contains($0.id) }
    durablePlan.inventory.eligibleIDs = plan.recordIDs
    durablePlan.inventory.eligibleBytes = plan.cacheBytes
    catalog.managedCacheAttempts =
      (catalog.managedCacheAttempts ?? []) + [
        ManagedCacheAttempt(
          plan: durablePlan, date: Date(),
          outcome: "prepared", receipt: nil,
          detail: "Owner cache decision: " + rationale
            + ". Prepared exact IDs; no recovery credited.")
      ]
    try checkpoint()
    state.catalog = catalog
    busy = true
    let operationStore = store
    Task.detached(priority: .utility) { [self] in
      let result = Result { () throws -> BuildKitCache.Receipt in
        guard self.accessCheck().canScan,
          try DiskPolicy.load(operationStore).revision == policy.revision
        else { throw StoreError.message("Disk policy changed; preserved.") }
        return try BuildKitCache.live(store: operationStore).clean(
          plan: plan, policy: policy, usedTodayBytes: used,
          authorize: {
            guard self.accessCheck().canScan,
              try DiskPolicy.load(operationStore).revision == policy.revision,
              try WorkspaceSafety.freeBytes(operationStore.root.path) < UInt64(policy.targetFreeGB)
                * 1_000_000_000
            else {
              throw StoreError.message(
                "Disk authorization or free-space target changed; preserved.")
            }
          })
      }
      await self.finishManagedCache(plan.id, result: result)
    }
    return
      "Exact owner cache cleanup queued. The durable receipt will distinguish verified owner cache bytes from physical host recovery. Do not poll or retry."
  }
  private func finishManagedCache(_ id: UUID, result: Result<BuildKitCache.Receipt, Error>) {
    defer {
      busy = false
      ownerMaintenance?.invalidateCache()
    }
    guard let index = catalog.managedCacheAttempts?.firstIndex(where: { $0.plan.id == id }) else {
      return
    }
    switch result {
    case .success(let receipt):
      catalog.managedCacheAttempts?[index].receipt = receipt
      catalog.managedCacheAttempts?[index].outcome = receipt.outcome
      catalog.managedCacheAttempts?[index].detail = receipt.detail
    case .failure(let error):
      catalog.managedCacheAttempts?[index].outcome = "refused"
      catalog.managedCacheAttempts?[index].detail = error.localizedDescription
    }
    catalog.managedCache = nil
    do { try checkpoint() } catch { state.error = error.localizedDescription }
    state.catalog = catalog
  }

  public func previewTargets(_ ids: [String], callerPID: Int32) throws -> [Observation] {
    try requireFullDiskAccess()
    let before = refresh()
    guard before.error == nil, !before.partial,
      !ids.isEmpty, ids.count <= 64, Set(ids).count == ids.count,
      let callerAncestors = AgentSafety.ancestors(of: callerPID),
      let ownAncestors = AgentSafety.ancestors(of: getpid())
    else {
      throw StoreError.message(
        "Complete visibility and 1–64 distinct process identities are required.")
    }
    let protectedPIDs = callerAncestors.union(ownAncestors)
    let leases = try store.leases()
    var targets = [Observation]()
    for id in ids {
      guard let r = catalog.records[id], r.missingSince == nil else {
        throw StoreError.message("Target identity expired. Inspect again.")
      }
      if let reason = AgentSafety.refusal(
        r, preferences: catalog.preferences, protectedPIDs: protectedPIDs)
      {
        throw StoreError.message("PID \(r.latest.identity.pid): \(reason)")
      }
      if WorkEvidence.blockingTree(catalog.workEvidence ?? [], record: r, records: catalog.records)
      {
        throw StoreError.message(
          "PID \(r.latest.identity.pid): an owning task still retains this helper. All claims must be released."
        )
      }
      if let evidence = catalog.passiveEvidence?.first(where: { $0.member.identity.key == id }),
        !evidence.canReview()
      {
        throw StoreError.message(
          "PID \(r.latest.identity.pid): passive owner evidence changed or is incomplete. Preserve this helper."
        )
      }
      let released = (catalog.workEvidence ?? []).contains { claim in
        claim.state == "released" && claim.members.contains { $0 == Member(r.latest) }
      }
      let passiveReady =
        catalog.passiveEvidence?.contains { $0.member == Member(r.latest) && $0.canReview() }
        == true
      let explicitLifetime = leases.contains { lease in
        lease.allowCleanup && !lease.disarmed && lease.ended != nil
          && lease.members.contains(Member(r.latest))
          && native.ownerState(lease.owner) == .gone
      }
      guard released || passiveReady || explicitLifetime else {
        throw StoreError.message(
          "PID \(r.latest.identity.pid): no positive completion evidence. Use a supported owner protocol; generic signaling is blocked."
        )
      }
      var sockets: Int32 = 0
      var files: Int32 = 0
      guard bz_fd_summary(r.latest.identity.pid, &sockets, &files) >= 0, sockets == 0 else {
        throw StoreError.message(
          "PID \(r.latest.identity.pid): socket consumers or incomplete descriptor visibility; preserved."
        )
      }
      targets.append(r.latest)
    }
    let pids = Set(targets.map { $0.identity.pid })
    guard
      !catalog.records.values.contains(where: {
        $0.missingSince == nil && pids.contains($0.latest.parent)
          && !pids.contains($0.latest.identity.pid)
      })
    else {
      throw StoreError.message(
        "A target has unreviewed live children. Inspect the tree or use its owner's teardown.")
    }
    return targets
  }

  public func burnTargets(
    _ reviewed: [Observation], label: String, rationale: String,
    callerPID: Int32
  ) throws -> String {
    try requireFullDiskAccess()
    guard !busy else { throw StoreError.message("A cleanup is already in progress.") }
    busy = true
    defer { busy = false }
    let responseBefore = Responsiveness.sample()
    let targets = try previewTargets(reviewed.map { $0.identity.key }, callerPID: callerPID)
    guard zip(targets, reviewed).allSatisfy({ Member($0.0) == Member($0.1) }) else {
      throw StoreError.message("Process identity or executable changed since preview.")
    }
    // Refresh immediately before each syscall as well; no cached-PID or process-name kills.
    var event = CleanupEvent(
      leaseID: UUID(), label: label, date: Date(),
      targets: targets.map(Member.init), residentBefore: targets.reduce(0) { $0 + $1.rss },
      outcome: "verifying",
      detail: "Agent decision: \(rationale). Graceful stop requested; verifying exits.")
    event.recurrenceScopes = targets.compactMap { target in
      guard target.parent > 1, case .found(let parent) = native.probe(target.parent) else {
        return nil
      }
      return RecurrenceScope(executable: target.executable, parent: Member(parent))
    }
    event.cpuSavingsRate = ImpactAccounting.cpuRate(
      targets.compactMap { catalog.records[$0.identity.key] })
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
      catalog.events[catalog.events.count - 1].detail =
        failures.joined(separator: "; ") + ". No benefit credited."
    }
    try checkpoint()
    _ = refresh()
    return failures.isEmpty
      ? "Graceful stop requested. Exit receipts are pending; continue your work and check later."
      : "Some targets could not be stopped. No escalation. Inspect the receipt."
  }
}
