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
    try lock.withLock { try loadMemory() }
  }

  /// Memory as saved, migrated to version 2 the first time memory from before lessons is read.
  /// The version-1 file is kept as `memory.v1.json`, once: an existing copy is never replaced.
  /// Without that copy nothing is migrated, and the memory is used as it is until the next read.
  /// A failed save doesn't fail the read, since the engine treats unreadable memory as empty and
  /// would lose the owner's keeps; the next read migrates again. Call with `lock` held.
  private func loadMemory() throws -> AutopilotMemory {
    let memory = try load("memory.json", limit: 8 << 20, empty: AutopilotMemory())
    guard memory.version < 2 else { return memory }
    let backup = directory.appendingPathComponent("memory.v1.json")
    if !FileManager.default.fileExists(atPath: backup.path) {
      let file = directory.appendingPathComponent("memory.json")
      do {
        try store.write(store.read(file, limit: 8 << 20), to: backup, limit: 8 << 20)
      } catch {
        return memory
      }
    }
    // Unreadable receipts leave the tallies empty rather than the lessons unmigrated.
    let receipts = (try? load("receipts.json", limit: 8 << 20, empty: [AutopilotReceipt]())) ?? []
    let migrated = AutopilotPolicy.migrate(memory, receipts: receipts)
    try? save(migrated, "memory.json", limit: 8 << 20)
    return migrated
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
    try lock.withLock {
      var memory = try loadMemory()
      let result = try change(&memory)
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
