import Foundation

/// Private JSON documents under `<root>/autopilot/`, written atomically with bounded reads.
public final class AutopilotStore: @unchecked Sendable {
  public static let maximumReceipts = 500
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
    try lock.withLock { try load("memory.json", limit: 8 << 20, empty: AutopilotMemory()) }
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
      var memory = try load("memory.json", limit: 8 << 20, empty: AutopilotMemory())
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
      // Refusals go first, so a stream of them never pushes out a burn the owner may restore.
      var excess = all.count - Self.maximumReceipts
      all.removeAll { receipt in
        guard excess > 0, receipt.outcome == "refused" else { return false }
        excess -= 1
        return true
      }
      if excess > 0 { all.removeFirst(excess) }
      try save(all, "receipts.json", limit: 8 << 20)
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
