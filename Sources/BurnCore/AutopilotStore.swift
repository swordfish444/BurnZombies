import Darwin
import Foundation

/// Private JSON documents under `<root>/autopilot/`, written atomically with bounded reads.
public final class AutopilotStore: @unchecked Sendable {
  public static let maximumReceipts = 500
  /// Refusals are kept apart from `maximumReceipts`: they only stop a copy from being tried again
  /// on every tick.
  public static let maximumRefusals = 500
  public static let maximumJudgments = 5000
  public static let restorableWindow: TimeInterval =
    TimeInterval(AutopilotSweepState.defaultBackupRetentionDays) * 86_400

  public static func restorableWindow(for sweep: AutopilotSweepState?) -> TimeInterval {
    let days = sweep?.effectiveBackupRetentionDays ?? AutopilotSweepState.defaultBackupRetentionDays
    // When backups are disabled (`0`), keep any previously captured backups restorable for the
    // default 7-day window until they expire or the owner explicitly purges them.
    let effective = days == 0 ? AutopilotSweepState.defaultBackupRetentionDays : days
    return TimeInterval(effective) * 86_400
  }
  private let root: URL
  private let store: Store
  private let lock = NSLock()
  private var lastRecoveryPrune: Date?
  public let directory: URL
  public init(root: URL = Store.defaultRoot) throws {
    self.root = root
    directory = root.appendingPathComponent("autopilot", isDirectory: true)
    store = try Store(root: directory)
    let eraStore = try Store(root: root)
    let marker = root.appendingPathComponent("autopilot-authority-era-v1")
    var identity = stat()
    if lstat(marker.path, &identity) != 0 {
      guard errno == ENOENT else {
        throw StoreError.message("Autopilot authority visibility is unavailable.")
      }
      // Only a completely new store gets defaults. An upgrade with any previous state must
      // preserve missing permissions/receipts as an error rather than recreate a grant.
      let names = [
        "memory.json", "sweep.json", "receipts.json", "memory.v1.json", "catalog.json",
        "impact.json",
      ]
      let prior = names.contains { name in
        var value = stat()
        return lstat(directory.appendingPathComponent(name).path, &value) == 0 || errno != ENOENT
      }
      if !prior {
        try store.write(
          JSONEncoder().encode(AutopilotMemory()),
          to: directory.appendingPathComponent("memory.json"), limit: 8 << 20)
        try store.write(
          JSONEncoder().encode(AutopilotSweepState()),
          to: directory.appendingPathComponent("sweep.json"), limit: 1 << 20)
        try store.write(
          JSONEncoder().encode([AutopilotReceipt]()),
          to: directory.appendingPathComponent("receipts.json"), limit: 8 << 20)
      }
      try eraStore.write(Data("1".utf8), to: marker, limit: 16)
    } else {
      _ = try eraStore.read(marker, limit: 16)
    }

  }

  private func load<T: Decodable>(_ name: String, limit: Int, empty: T) throws -> T {
    let url = directory.appendingPathComponent(name)
    var info = stat()
    if lstat(url.path, &info) != 0 {
      guard errno == ENOENT else { throw StoreError.message("State visibility is unavailable.") }
      guard !["memory.json", "sweep.json", "receipts.json"].contains(name) else {
        throw StoreError.message(
          "Required Autopilot permissions or receipts are missing; cleanup is paused.")
      }
      return empty
    }
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: store.read(url, limit: limit))
  }
  private func save<T: Encodable>(_ value: T, _ name: String, limit: Int) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try store.write(encoder.encode(value), to: directory.appendingPathComponent(name), limit: limit)
  }

  public func memory() throws -> AutopilotMemory {
    try lock.withLock { try loadMemory().memory }
  }

  /// Memory as saved, migrated to version 2 the first time memory from before lessons is read.
  /// Migrating needs the receipts (a missing receipts.json is none; one that can't be read is
  /// waited for) and a copy of the version-1 file as `memory.v1.json`, made once: an existing copy
  /// is never replaced. Without either, the memory is used as it is and the next read tries again.
  /// A failed save doesn't fail the read, since the engine treats unreadable memory as empty and
  /// would lose the owner's keeps; the next read migrates again. `seeded` says this read migrated,
  /// so the tallies were just counted from receipts.json. Call with `lock` held.
  private func loadMemory() throws -> (memory: AutopilotMemory, seeded: Bool) {
    let memory = try load("memory.json", limit: 8 << 20, empty: AutopilotMemory())
    if memory.version >= 2 {
      let normalized = AutopilotPolicy.normalizePlaces(memory)
      if normalized != memory { try? save(normalized, "memory.json", limit: 8 << 20) }
      return (normalized, false)
    }
    let receipts: [AutopilotReceipt]
    do {
      receipts = try load("receipts.json", limit: 8 << 20, empty: [AutopilotReceipt]())
    } catch {
      return (memory, false)
    }
    let backup = directory.appendingPathComponent("memory.v1.json")
    if !FileManager.default.fileExists(atPath: backup.path) {
      let file = directory.appendingPathComponent("memory.json")
      do {
        try store.write(store.read(file, limit: 8 << 20), to: backup, limit: 8 << 20)
      } catch {
        return (memory, false)
      }
    }
    let migrated = AutopilotPolicy.migrate(memory, receipts: receipts)
    try? save(migrated, "memory.json", limit: 8 << 20)
    return (migrated, true)
  }
  public func save(memory: AutopilotMemory) throws {
    var bounded = memory
    if bounded.judgments.count > Self.maximumJudgments {
      let keep = bounded.judgments.values.sorted { $0.date > $1.date }.prefix(
        Self.maximumJudgments)
      bounded.judgments = Dictionary(uniqueKeysWithValues: keep.map { ($0.itemID, $0) })
    }
    try lock.withLock { try save(bounded, "memory.json", limit: 8 << 20) }
  }
  /// Read-modify-write under one lock so an answer and a sweep never overwrite each other.
  @discardableResult public func updateMemory<T>(_ change: (inout AutopilotMemory) throws -> T)
    throws -> T
  {
    try updateMemoryAfterReceipts { memory, _ in try change(&memory) }
  }

  /// `updateMemory` for receipts already saved to receipts.json. `change` learns whether this read
  /// migrated version-1 memory: the migration then seeded the tallies from receipts.json, so those
  /// receipts are counted already and counting them again would count them twice.
  @discardableResult func updateMemoryAfterReceipts<T>(
    _ change: (inout AutopilotMemory, _ seeded: Bool) throws -> T
  ) throws -> T {
    try lock.withLock {
      let loaded = try loadMemory()
      var memory = loaded.memory
      let result = try change(&memory, loaded.seeded)
      if memory.judgments.count > Self.maximumJudgments {
        let keep = memory.judgments.values.sorted { $0.date > $1.date }.prefix(
          Self.maximumJudgments)
        memory.judgments = Dictionary(uniqueKeysWithValues: keep.map { ($0.itemID, $0) })
      }
      try save(memory, "memory.json", limit: 8 << 20)
      return result
    }
  }

  public func catalog() throws -> AutopilotCatalog? {
    try lock.withLock {
      try load("catalog.json", limit: 32 << 20, empty: AutopilotCatalog?.none)
    }
  }
  public func save(catalog: AutopilotCatalog) throws {
    try lock.withLock { try save(catalog, "catalog.json", limit: 32 << 20) }
  }

  public func receipts() throws -> [AutopilotReceipt] {
    try lock.withLock { try load("receipts.json", limit: 8 << 20, empty: [AutopilotReceipt]()) }
  }
  public func append(_ receipt: AutopilotReceipt) throws {
    try updateReceipts { $0.append(receipt) }
  }
  public func updateReceipts(_ change: (inout [AutopilotReceipt]) throws -> Void) throws {
    try lock.withLock {
      var all = try load("receipts.json", limit: 8 << 20, empty: [AutopilotReceipt]())
      try change(&all)
      // Counted before trimming, so no burn is trimmed away uncounted.
      var impact = try load("impact.json", limit: 4 << 20, empty: AutopilotImpact())
      let counted = impact
      impact.count(all)
      // Refusals and everything else are bounded apart, oldest first: a stream of refusals never
      // pushes out a burn the owner may restore, and non-restorable stops (`process`, regenerable
      // `disk`, already-restored or >30d expired receipts) yield before live restorable backups.
      let now = Date()
      let currentSweep = try? load("sweep.json", limit: 1 << 20, empty: AutopilotSweepState())
      let window = Self.restorableWindow(for: currentSweep)
      let beforeRecoveryIDs = Set(
        all.filter { Self.isLiveRestorable($0, window: window, now: now) }
          .compactMap { $0.restore?.recovery?.id })
      Self.trim(&all, refusals: true, to: Self.maximumRefusals, window: window, now: now)
      Self.trim(&all, refusals: false, to: Self.maximumReceipts, window: window, now: now)
      let keepingIDs = Set(
        all.filter { Self.isLiveRestorable($0, window: window, now: now) }
          .compactMap { $0.restore?.recovery?.id })
      let evictedRecovery = !beforeRecoveryIDs.subtracting(keepingIDs).isEmpty
      impact.prune(keeping: all, now: now)
      try save(all, "receipts.json", limit: 8 << 20)
      if impact != counted { try save(impact, "impact.json", limit: 4 << 20) }
      pruneRecoveryIfNeeded(keepingIDs: keepingIDs, force: evictedRecovery, now: now)
    }
  }

  public func impact() throws -> AutopilotImpact {
    try lock.withLock { try load("impact.json", limit: 4 << 20, empty: AutopilotImpact()) }
  }
  /// Counts burns made before the tally existed; later ones are counted as they are written.
  public func refreshImpact(forcePrune: Bool = false, now: Date = Date()) throws {
    try lock.withLock {
      let all = try load("receipts.json", limit: 8 << 20, empty: [AutopilotReceipt]())
      let currentSweep = try? load("sweep.json", limit: 1 << 20, empty: AutopilotSweepState())
      let window = Self.restorableWindow(for: currentSweep)
      var impact = try load("impact.json", limit: 4 << 20, empty: AutopilotImpact())
      let counted = impact
      impact.count(all)
      impact.prune(keeping: all, now: now)
      if impact != counted { try save(impact, "impact.json", limit: 4 << 20) }
      let keepingIDs = Set(
        all.filter { Self.isLiveRestorable($0, window: window, now: now) }
          .compactMap { $0.restore?.recovery?.id })
      pruneRecoveryIfNeeded(keepingIDs: keepingIDs, force: forcePrune, now: now)
    }
  }

  /// Explicitly deletes all restorable private-recovery archives and retired Git refs while
  /// preserving unresolved `failed` recoveries and Burn Log history.
  @discardableResult
  public func purgeBackups(now: Date = Date()) throws -> (removed: Int, bytes: UInt64) {
    try lock.withLock {
      var all = try load("receipts.json", limit: 8 << 20, empty: [AutopilotReceipt]())
      var keepingIDs = Set<String>()
      var changed = false
      for i in all.indices {
        if all[i].outcome == "failed", let id = all[i].restore?.recovery?.id {
          keepingIDs.insert(id)
          continue
        }
        if let restore = all[i].restore {
          if !restore.repository.isEmpty, restore.ref.hasPrefix("refs/burnzombies/retired/"),
            FileManager.default.fileExists(atPath: restore.repository)
          {
            _ = try? WorktreeGit.run(
              restore.repository, ["update-ref", "-d", restore.ref], seconds: 5)
          }
          all[i].restore = nil
          changed = true
        }
      }
      if changed { try save(all, "receipts.json", limit: 8 << 20) }
      lastRecoveryPrune = now
      return PrivateRecovery.prune(root: root, keepingIDs: keepingIDs, graceAge: 0, now: now)
    }
  }

  /// Called with `lock` held; fast-exits when `<root>/private-recovery` does not exist.
  private func pruneRecoveryIfNeeded(keepingIDs: Set<String>, force: Bool, now: Date) {
    if !force, let last = lastRecoveryPrune, now.timeIntervalSince(last) < 600 { return }
    var info = stat()
    let hasRecovery = lstat(root.appendingPathComponent("private-recovery").path, &info) == 0
    let isDefaultRoot =
      WorkspaceSafety.canonical(root.path) == WorkspaceSafety.canonical(Store.defaultRoot.path)
    guard hasRecovery || isDefaultRoot else { return }
    lastRecoveryPrune = now
    if hasRecovery { _ = PrivateRecovery.prune(root: root, keepingIDs: keepingIDs, now: now) }
    if isDefaultRoot { _ = AutopilotHarness.pruneClaudeRunCaches(root: root, now: now) }
  }

  private static func isLiveRestorable(
    _ receipt: AutopilotReceipt, window: TimeInterval = restorableWindow, now: Date
  ) -> Bool {
    guard receipt.restore != nil else { return false }
    if receipt.outcome == "failed" && receipt.restore?.recovery != nil { return true }
    guard receipt.outcome == "burned" else { return false }
    return now.timeIntervalSince(receipt.date) <= window
  }

  private static func trim(
    _ all: inout [AutopilotReceipt], refusals: Bool, to limit: Int,
    window: TimeInterval = restorableWindow, now: Date = Date()
  ) {
    var excess = all.count { ($0.outcome == "refused") == refusals } - limit
    guard excess > 0 else { return }
    if refusals {
      all.removeAll { receipt in
        guard excess > 0, receipt.outcome == "refused" else { return false }
        excess -= 1
        return true
      }
      return
    }
    // Pass 1: trim non-restorable, restored, or expired receipts first so frequent process
    // and cache cleanups never evict live restorable worktree backups.
    all.removeAll { receipt in
      guard excess > 0, receipt.outcome != "refused",
        !isLiveRestorable(receipt, window: window, now: now)
      else {
        return false
      }
      excess -= 1
      return true
    }
    guard excess > 0 else { return }
    // Pass 2: if live restorable receipts alone exceed `limit`, trim oldest non-failed ones.
    all.removeAll { receipt in
      guard excess > 0, receipt.outcome != "refused",
        !(receipt.outcome == "failed" && receipt.restore?.recovery != nil)
      else { return false }
      excess -= 1
      return true
    }
  }

  /// Sizes and ages of old copies the worktree inventory couldn't measure, by worktree record id.
  /// They outlive a restart: measuring every copy again takes many ticks.
  public func sizes() throws -> [String: AutopilotSize] {
    try lock.withLock { try load("sizes.json", limit: 4 << 20, empty: [String: AutopilotSize]()) }
  }
  public func save(sizes: [String: AutopilotSize]) throws {
    try lock.withLock { try save(sizes, "sizes.json", limit: 4 << 20) }
  }
  public func ages() throws -> [String: AutopilotLook] {
    try lock.withLock { try load("ages.json", limit: 4 << 20, empty: [String: AutopilotLook]()) }
  }
  public func save(ages: [String: AutopilotLook]) throws {
    try lock.withLock { try save(ages, "ages.json", limit: 4 << 20) }
  }

  public func sweep() throws -> AutopilotSweepState {
    try lock.withLock { try load("sweep.json", limit: 1 << 20, empty: AutopilotSweepState()) }
  }
  public func save(sweep: AutopilotSweepState) throws {
    try lock.withLock { try save(sweep, "sweep.json", limit: 1 << 20) }
  }
  @discardableResult public func updateSweep<T>(_ change: (inout AutopilotSweepState) throws -> T)
    throws -> T
  {
    try lock.withLock {
      var sweep = try load("sweep.json", limit: 1 << 20, empty: AutopilotSweepState())
      let result = try change(&sweep)
      try save(sweep, "sweep.json", limit: 1 << 20)
      return result
    }
  }
}
