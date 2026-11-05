import Foundation

/// Private JSON documents under `<root>/autopilot/`, written atomically with bounded reads.
public final class AutopilotStore: @unchecked Sendable {
  public static let maximumReceipts = 500
  /// Refusals are kept apart from `maximumReceipts`: they only stop a copy from being tried again
  /// on every tick.
  public static let maximumRefusals = 500
  public static let maximumJudgments = 5000
  private let store: Store
  private let lock = NSLock()
  public let directory: URL
  public init(root: URL = Store.defaultRoot) throws {
    directory = root.appendingPathComponent("autopilot", isDirectory: true)
    store = try Store(root: directory)
  }

  private func load<T: Decodable>(_ name: String, limit: Int, empty: T) throws -> T {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return empty }
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
    guard memory.version < 2 else { return (memory, false) }
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
      // pushes out a burn the owner may restore, and a full history of burns never erases the
      // refusal that keeps a copy from being tried again on every tick.
      Self.trim(&all, refusals: true, to: Self.maximumRefusals)
      Self.trim(&all, refusals: false, to: Self.maximumReceipts)
      impact.prune(keeping: all, now: Date())
      try save(all, "receipts.json", limit: 8 << 20)
      if impact != counted { try save(impact, "impact.json", limit: 4 << 20) }
    }
  }

  public func impact() throws -> AutopilotImpact {
    try lock.withLock { try load("impact.json", limit: 4 << 20, empty: AutopilotImpact()) }
  }
  /// Counts burns made before the tally existed; later ones are counted as they are written.
  public func refreshImpact() throws {
    try lock.withLock {
      let all = try load("receipts.json", limit: 8 << 20, empty: [AutopilotReceipt]())
      var impact = try load("impact.json", limit: 4 << 20, empty: AutopilotImpact())
      let counted = impact
      impact.count(all)
      impact.prune(keeping: all, now: Date())
      if impact != counted { try save(impact, "impact.json", limit: 4 << 20) }
    }
  }

  private static func trim(_ all: inout [AutopilotReceipt], refusals: Bool, to limit: Int) {
    var excess = all.count { ($0.outcome == "refused") == refusals } - limit
    all.removeAll { receipt in
      guard excess > 0, (receipt.outcome == "refused") == refusals else { return false }
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
