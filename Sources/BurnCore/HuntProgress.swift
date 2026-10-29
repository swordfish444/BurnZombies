import Foundation

public struct HuntLogEntry: Codable, Sendable, Identifiable {
  public var id: String
  public var date: Date
  public var kind: String
  public var message: String
  public init(id: String = UUID().uuidString, date: Date = Date(), kind: String, message: String) {
    self.id = id; self.date = date; self.kind = kind; self.message = String(message.prefix(600))
  }
}

/// Presentation evidence only. This file never authorizes a scan or cleanup.
public struct HuntSnapshot: Codable, Sendable, Identifiable {
  public var id = UUID()
  public var phase = "hunting"
  public var startedAt: Date
  public var finishedAt: Date?
  public var lane: String?
  public var detail = "Measuring this Mac and preparing the hunt."
  public var log: [HuntLogEntry] = []
  public var attempts = 0
  public var evidenceReviewed = 0
  public var processCount = 0
  public var burned = 0
  public var worktreesCleaned = 0
  public var memoryReclaimed: UInt64 = 0
  public var diskReclaimed: UInt64 = 0
  public var activeAttempt: UUID?
  public var receiptEvidenceAvailable: Bool?
  public var isRunning: Bool { phase == "hunting" }
  public init(startedAt: Date = Date()) { self.startedAt = startedAt }
  public mutating func append(_ kind: String, _ message: String, date: Date = Date()) {
    log.append(.init(date: date, kind: kind, message: message)); log = Array(log.suffix(128))
  }
  public mutating func include(_ progress: ReviewProgress) {
    for (index, item) in (progress.activity ?? []).enumerated() {
      let id = "tool-\(progress.attempt)-\(item.id ?? String(index))"
      guard !log.contains(where: { $0.id == id }) else { continue }
      let detected = item.succeeded && ["preview", "workspace_preview", "disk_preview", "owner_preview", "cache_preview"].contains(item.tool)
      let fallback = detected ? "Potential zombie detected. Safety preview passed; awaiting verified cleanup."
        : item.tool.replacingOccurrences(of: "_", with: " ") + (item.succeeded ? " completed." : " refused or failed; no verified cleanup credited.")
      log.append(.init(id: id, date: item.date, kind: detected ? "detected" : item.succeeded ? "scanning" : "warning",
        message: item.detail ?? fallback))
    }
    log = Array(log.suffix(128))
  }
  public func save(_ store: Store) throws {
    try store.write(JSONEncoder().encode(self), to: store.root.appendingPathComponent("hunt-state.json"), limit: 131072)
  }
  public static func load(root: URL = Store.defaultRoot) throws -> Self {
    let store = try Store(root: root)
    var value = try JSONDecoder().decode(Self.self, from: store.read(root.appendingPathComponent("hunt-state.json"), limit: 131072))
    if let progress = try? ReviewProgress.load(store), progress.attempt == value.activeAttempt { value.include(progress) }
    if let catalog = try? store.load() { value.includeReceipts(catalog) }
    else {
      value.receiptEvidenceAvailable = false
      value.log.append(.init(id: "receipt-unavailable", date: value.startedAt, kind: "warning", message: "Cleanup receipt evidence is currently unavailable. Totals are unknown."))
    }
    return value
  }
  public mutating func includeReceipts(_ catalog: Catalog) {
    receiptEvidenceAvailable = true
    let end = finishedAt ?? .distantFuture
    let events = catalog.events.filter { $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" && $0.verifiedCount > 0 }
    let worktrees = (catalog.workspaceReceipts ?? []).filter { $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" }
    let caches = (catalog.managedCacheAttempts ?? []).compactMap(\.receipt).filter { $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" && !$0.removedIDs.isEmpty }
    let disks = (catalog.diskReceipts ?? []).filter { $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" }
    burned = events.reduce(0) { $0 + $1.verifiedCount }
    worktreesCleaned = worktrees.count
    memoryReclaimed = events.reduce(0) { $0 + $1.residentBefore }
    diskReclaimed = worktrees.reduce(0) { $0 + $1.diskReclaimedBytes } + disks.reduce(0) { $0 + $1.diskReclaimedBytes }
    func receipt(_ id: UUID, date: Date, message: String) -> HuntLogEntry { .init(id: "receipt-" + id.uuidString, date: date, kind: "burn", message: message) }
    let receipts = events.map { receipt($0.id, date: $0.verificationDate ?? $0.date, message: "\($0.verifiedCount) zombie process\($0.verifiedCount == 1 ? "" : "es") eradicated. Exit verified.") }
      + worktrees.map { receipt($0.id, date: $0.verifiedAt ?? $0.date, message: "Worktree cleaned. Removal verified.") }
      + disks.map { receipt($0.id, date: $0.date, message: String(format: "Disk cleanup verified. %.2f GB reclaimed.", Double($0.diskReclaimedBytes) / 1e9)) }
    let cacheReceipts = caches.map { receipt($0.planID, date: $0.date, message: String(format: "Owner-managed cache cleanup verified. %.2f GB of cache capacity released; host disk recovery remains unmeasured.", Double($0.cacheReleasedBytes) / 1e9)) }
    for item in receipts + cacheReceipts where !log.contains(where: { $0.id == item.id }) { log.append(item) }
    log = Array(log.sorted { $0.date < $1.date }.suffix(128))
  }
}
