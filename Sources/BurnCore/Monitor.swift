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
  private var leases = [Lease]()
  private var owners = [UUID: OwnerState]()
  private var state = ViewState()
  private var lastSave = Date.distantPast
  private var receiptNeedsCheckpoint = false
  private var busy = false
  private var lastMonotonic: Double?
  private var lastWall: Date?
  public init(root: URL = Store.defaultRoot) throws {
    store = try Store(root: root)
    lock = try InstanceLock(url: root.appendingPathComponent("monitor.lock"))
    catalog = try store.load()
    if catalog.lifetimeResidentReleased == nil {
      catalog.lifetimeResidentReleased = catalog.events.filter { $0.outcome == "verified" }.reduce(
        0
      ) { $0 + $1.residentBefore }
    }
    if catalog.lifetimeCPUSecondsSaved == nil {
      let measured = catalog.events.filter { $0.outcome == "verified" }.compactMap(
        \.cpuSecondsSavedEstimate)
      if !measured.isEmpty || catalog.lifetimeVerified == 0 {
        catalog.lifetimeCPUSecondsSaved = measured.reduce(0, +)
      }
    }
    catalog.resetContinuity()
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
      leases = try store.leases()
      owners = Dictionary(uniqueKeysWithValues: leases.map { ($0.id, native.ownerState($0.owner)) })
      let owned = Dictionary(
        leases.flatMap { l in l.members.map { ($0.identity.key, l) } },
        uniquingKeysWith: { a, _ in a })
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
        if let l = owned[key], owners[l.id] == .gone {
          if r.orphanSince == nil { r.orphanSince = now }
        } else {
          r.orphanSince = nil
        }
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
      state.findings = DecisionEngine.findings(
        catalog: catalog, leases: leases, owners: owners, uid: getuid(), ownPID: getpid(), now: now)
      if scan.partial {
        state.findings = state.findings.map {
          var f = $0
          if f.disposition == .eligible {
            f.disposition = .protected
            f.reason = "Incomplete scan coverage; cleanup is paused."
          }
          return f
        }
      }
      state.interval =
        state.findings.contains { $0.leaseID != nil && $0.disposition != .protected }
          || catalog.events.contains { $0.outcome == "verifying" } ? 15 : 60
      if receiptNeedsCheckpoint || now.timeIntervalSince(lastSave) >= 300 {
        try store.pruneLeases(now: now, native: native)
        try checkpoint()
      }
    } catch {
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
      let paths = Set(e.targets.map(\.executable))
      let recurrence = observations.contains(where: {
        paths.contains($0.executable) && !e.targets.contains(Member($0))
          && Double($0.identity.seconds) >= e.date.timeIntervalSince1970 - 1 && !$0.zombie
      })
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
          "A matching executable appeared during verification. Recurrence is inferred; no benefit credited. Inspect the creator."
      }
      if outcome == "verified" {
        catalog.events[i].outcome = "verified"
        catalog.events[i].verifiedCount = e.targets.count
        catalog.events[i].verificationDate = now
        catalog.events[i].detail =
          "Exact targets exited; no matching executable was observed at samples during the 120-second watch. Resident footprint is an upper-bound attribution, not physical RAM reclaimed or speed gained."
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
    guard !busy else { throw StoreError.message("A cleanup is already in progress.") }
    busy = true
    defer { busy = false }
    let responseBefore = Responsiveness.sample()
    let before = refresh()
    guard !before.partial, before.error == nil,
      let f = before.findings.first(where: { $0.id == requested.id }), f.disposition == .eligible,
      let id = f.leaseID, let index = leases.firstIndex(where: { $0.id == id }),
      Set(f.members) == Set(requested.members),
      !automatic || catalog.preferences.automaticCleanup
    else { throw StoreError.message("Eligibility changed. Refresh and review the finding again.") }
    let records = f.members.compactMap { catalog.records[$0] }
    let reviewedLease = leases[index]
    // Unknown live descendants make whole-activity teardown unsafe.
    let pids = Set(records.map { $0.latest.identity.pid })
    guard
      !catalog.records.values.contains(where: {
        $0.missingSince == nil && pids.contains($0.latest.parent) && !f.members.contains($0.id)
      })
    else {
      throw StoreError.message(
        "An unregistered descendant is active. Use the owning tool's teardown.")
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    guard !automatic || catalog.preferences.automaticCleanup else {
      throw StoreError.message("Automatic cleanup was disabled.")
    }
    guard let currentIndex = leases.firstIndex(where: { $0.id == id }),
      !leases[currentIndex].disarmed,
      Set(leases[currentIndex].members) == Set(reviewedLease.members)
    else {
      throw StoreError.message("Ownership changed during revalidation.")
    }
    for r in records {
      guard let currentRecord = catalog.records[r.id],
        DecisionEngine.eligibility(
          currentRecord, lease: leases[currentIndex], owner: native.ownerState(reviewedLease.owner),
          preferences: catalog.preferences, uid: getuid(), ownPID: getpid(), now: Date()
        ).0
      else {
        throw StoreError.message("Protection, snooze, or observation continuity changed.")
      }
      guard case .found(let o) = native.probe(r.latest.identity.pid),
        o.metricsValid, !o.zombie,
        o.identity == r.latest.identity, o.executable == r.latest.executable,
        o.readBytes == r.latest.readBytes, o.writeBytes == r.latest.writeBytes,
        o.cpuNS >= r.latest.cpuNS,
        Double(o.cpuNS - r.latest.cpuNS) / 1e9 / max(0.001, o.monotonic - r.latest.monotonic)
          < 0.01,
        !catalog.preferences.protectedExecutables.contains(o.executable),
        native.ownerState(reviewedLease.owner) == .gone
      else {
        throw StoreError.message(
          "Identity, ownership, protection, or activity changed. Nothing was stopped.")
      }
    }
    leases[currentIndex].disarmed = true
    try store.saveLease(leases[currentIndex])
    var event = CleanupEvent(
      leaseID: id, label: f.title, date: Date(), targets: records.map { Member($0.latest) },
      residentBefore: records.reduce(0) { $0 + $1.latest.rss }, outcome: "verifying",
      detail: "Graceful stop requested. Waiting 15 seconds for exit and 120 seconds for recurrence."
    )
    event.cpuSecondsSavedEstimate = ImpactAccounting.cpuSecondsSaved(records)
    event.responseBeforeMS = responseBefore
    catalog.events.append(event)
    try checkpoint()  // Write intent before the irreversible syscall. Failure means no signal.
    var failures = [String]()
    for r in records {
      let code = native.terminate(r.latest)
      if code != 0 { failures.append("PID \(r.latest.identity.pid): errno \(code)") }
    }
    if !failures.isEmpty {
      catalog.events[catalog.events.count - 1].outcome = "partial"
      catalog.events[catalog.events.count - 1].detail =
        failures.joined(separator: "; ") + ". No benefit credited."
    }
    try checkpoint()
    _ = refresh()
    return failures.isEmpty
      ? "Stop requested. Verifying exit and watching for reappearance…"
      : "Some helpers could not be stopped. See History."
  }
}
