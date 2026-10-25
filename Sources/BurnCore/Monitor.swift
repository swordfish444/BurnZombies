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
  private var catalog: Catalog
  private var state = ViewState()
  private var lastSave = Date.distantPast
  private var receiptNeedsCheckpoint = false
  private var busy = false
  private var lastMonotonic: Double?
  private var lastWall: Date?
  public init(root: URL = Store.defaultRoot) throws {
    store = try Store(root: root)
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
    loaded.resetContinuity()
    catalog = loaded
  }
  public func snapshot() -> ViewState { state }
  public func resetContinuity() {
    receiptNeedsCheckpoint = receiptNeedsCheckpoint || catalog.events.contains { $0.outcome == "verifying" }
    catalog.resetContinuity()
    lastMonotonic = nil
    lastWall = nil
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
      verifyPending(now: now, observations: scan.observations)
      receiptNeedsCheckpoint = receiptNeedsCheckpoint || priorOutcomes != catalog.events.map(\.outcome)
      catalog.lastSample = now
      catalog.prune(now: now)
      // Observation is factual. The connected harness owns diagnosis and target selection.
      state.findings = []
      state.interval = catalog.events.contains { $0.outcome == "verifying" } ? 15 : 60
      if receiptNeedsCheckpoint || now.timeIntervalSince(lastSave) >= 300 {
        try checkpoint()
      }
      if !scan.partial {
        try HarnessHook.publish(.init(observedAt: now, processCount: scan.observations.count,
          residentBytes: scan.observations.reduce(0) { $0 + $1.rss }, pressure: native.memoryPressure()), store: store)
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
        catalog.events[i].responseAfterMS = Responsiveness.sample()
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
    event.cpuSecondsSavedEstimate = ImpactAccounting.cpuSecondsSaved(
      targets.compactMap { catalog.records[$0.identity.key] })
    event.responseBeforeMS = responseBefore
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
