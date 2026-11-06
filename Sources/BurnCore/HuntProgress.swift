import Foundation

public struct HuntLogEntry: Codable, Sendable, Identifiable {
  public var id: String
  public var date: Date
  public var kind: String
  public var message: String
  public init(id: String = UUID().uuidString, date: Date = Date(), kind: String, message: String) {
    self.id = id
    self.date = date
    self.kind = kind
    self.message = String(message.prefix(600))
  }
}

/// One area an Autopilot hunt works through: programs, old copies or junk folders. Every number
/// is a count of real things: what BZ looked at, what the AI judged and what burned.
public struct HuntLane: Codable, Sendable, Equatable, Identifiable {
  /// An `AutopilotKind` raw value: `process`, `worktree` or `disk`.
  public var kind: String
  /// What BZ looked at on its own: programs running, copies and junk folders found.
  public var seen = 0
  /// What was waiting for the AI's judgment when the hunt began.
  public var toJudge = 0
  /// What the AI judged during this hunt, those or others.
  public var judged = 0
  public var burned = 0
  public var bytes: UInt64 = 0
  public var id: String { kind }
  public init(kind: String) { self.kind = kind }
}

/// Presentation evidence only. This file never authorizes a scan or cleanup.
public struct HuntSnapshot: Codable, Sendable, Identifiable {
  public var id = UUID()
  /// `hunting`, `completed`, `stopped` (by the owner or the spending limit) or `paused`.
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
  public var discoveredWorktrees: Int?
  public var worktreeStates: [String: Int]?
  /// A deep hunt: the owner started it by hand, the AI reads everything and it stops at
  /// `limitUSD`.
  public var deep: Bool?
  /// Autopilot hunts only: programs, old copies and junk folders, in that order.
  public var lanes: [HuntLane]?
  /// What the hunt is looking at right now: a program, copy or folder name, never a command line.
  public var focus: String?
  /// What the AI cost so far, estimated from its tokens until the run reports its own total.
  public var spentUSD: Double?
  public var limitUSD: Double?
  public var tokens: Int?
  /// Why a hunt ended early: `stopped` (the owner pressed Stop) or `limit` (it reached the
  /// spending limit). What it burned stays burned either way.
  public var stopReason: String?
  public var isRunning: Bool { phase == "hunting" }
  /// Autopilot hunts count their own receipts as they burn.
  public var isAutopilot: Bool { lane == "autopilot" }
  public init(startedAt: Date = Date()) { self.startedAt = startedAt }
  /// Changes one lane, adding it when the hunt has none of that kind yet.
  public mutating func update(lane kind: String, _ change: (inout HuntLane) -> Void) {
    var all = lanes ?? []
    if let i = all.firstIndex(where: { $0.kind == kind }) {
      change(&all[i])
    } else {
      var lane = HuntLane(kind: kind)
      change(&lane)
      all.append(lane)
    }
    lanes = all
  }
  /// `id` names a line that must appear only once, such as a burn's receipt.
  public mutating func append(
    _ kind: String, _ message: String, date: Date = Date(), id: String? = nil
  ) {
    log.append(.init(id: id ?? UUID().uuidString, date: date, kind: kind, message: message))
    log = Array(log.suffix(128))
  }
  public mutating func include(_ progress: ReviewProgress) {
    for (index, item) in (progress.activity ?? []).enumerated() {
      let id = "tool-\(progress.attempt)-\(item.id ?? String(index))"
      guard !log.contains(where: { $0.id == id }) else { continue }
      let detected =
        item.succeeded
        && (["preview", "workspace_preview", "disk_preview", "owner_preview", "cache_preview"]
          .contains(item.tool)
          || (["worktrees", "worktrees_read"].contains(item.tool) && item.action == "preview"))
      let fallback =
        detected
        ? "Potential zombie detected. Safety preview passed; awaiting verified cleanup."
        : item.tool.replacingOccurrences(of: "_", with: " ")
          + (item.succeeded ? " completed." : " refused or failed; no verified cleanup credited.")
      log.append(
        .init(
          id: id, date: item.date,
          kind: detected ? "detected" : item.succeeded ? "scanning" : "warning",
          message: item.detail ?? fallback))
    }
    log = Array(log.suffix(128))
  }
  public func save(_ store: Store) throws {
    try store.write(
      JSONEncoder().encode(self), to: store.root.appendingPathComponent("hunt-state.json"),
      limit: 131072)
  }
  public static func load(root: URL = Store.defaultRoot) throws -> Self {
    let store = try Store(root: root)
    var value = try JSONDecoder().decode(
      Self.self, from: store.read(root.appendingPathComponent("hunt-state.json"), limit: 131072))
    if let progress = try? ReviewProgress.load(store), progress.attempt == value.activeAttempt {
      value.include(progress)
    }
    if value.isAutopilot {
      value.receiptEvidenceAvailable = true
    } else if let catalog = try? store.load() {
      value.includeReceipts(catalog)
    } else {
      value.receiptEvidenceAvailable = false
      value.log.append(
        .init(
          id: "receipt-unavailable", date: value.startedAt, kind: "warning",
          message: "Cleanup receipt evidence is currently unavailable. Totals are unknown."))
    }
    return value
  }
  public mutating func includeReceipts(_ catalog: Catalog) {
    // Autopilot burns are counted from its own receipts as they happen; the monitor's evidence
    // would count its programs twice and its copies not at all.
    if isAutopilot {
      receiptEvidenceAvailable = true
      return
    }
    let nativeWorktrees = (catalog.worktreeEvidence ?? []).count
    let nativeDisk = (catalog.diskCandidates ?? []).count + (catalog.diskDiscovery ?? []).count
    if isRunning, nativeWorktrees + nativeDisk > 0,
      !log.contains(where: { $0.id == "native-discovery" })
    {
      log.append(
        .init(
          id: "native-discovery", date: Date(), kind: "detected",
          message:
            "Found \(nativeWorktrees) worktree review candidates and \(nativeDisk) storage findings. Discovery is not cleanup permission; active and blocked items remain protected."
        ))
    }
    receiptEvidenceAvailable = true
    let end = finishedAt ?? .distantFuture
    let events = catalog.events.filter {
      $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" && $0.fixture != true
        && $0.verifiedCount > 0
    }
    let worktrees = (catalog.workspaceReceipts ?? []).filter {
      $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" && $0.fixture != true
    }
    let caches = (catalog.managedCacheAttempts ?? []).filter { $0.fixture != true }.compactMap(
      \.receipt
    ).filter {
      $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" && !$0.removedIDs.isEmpty
    }
    let disks = (catalog.diskReceipts ?? []).filter {
      $0.date >= startedAt && $0.date <= end && $0.outcome == "verified" && $0.fixture != true
    }
    burned = events.reduce(0) { $0 + $1.verifiedCount }
    worktreesCleaned = worktrees.count
    memoryReclaimed = events.reduce(0) { $0 + $1.residentBefore }
    diskReclaimed =
      worktrees.reduce(0) { $0 + $1.diskReclaimedBytes }
      + disks.reduce(0) { $0 + $1.diskReclaimedBytes }
    func receipt(_ id: UUID, date: Date, message: String) -> HuntLogEntry {
      .init(id: "receipt-" + id.uuidString, date: date, kind: "burn", message: message)
    }
    let receipts =
      events.map {
        receipt(
          $0.id, date: $0.verificationDate ?? $0.date,
          message:
            "\($0.verifiedCount) zombie process\($0.verifiedCount == 1 ? "" : "es") eradicated. Exit verified."
        )
      }
      + worktrees.map {
        receipt(
          $0.id, date: $0.verifiedAt ?? $0.date, message: "Worktree cleaned. Removal verified.")
      }
      + disks.map {
        receipt(
          $0.id, date: $0.date,
          message: String(
            format: "Disk cleanup verified. %.2f GB reclaimed.", Double($0.diskReclaimedBytes) / 1e9
          ))
      }
    let cacheReceipts = caches.map {
      receipt(
        $0.planID, date: $0.date,
        message: String(
          format:
            "Owner-managed cache cleanup verified. %.2f GB of cache capacity released; host disk recovery remains unmeasured.",
          Double($0.cacheReleasedBytes) / 1e9))
    }
    for item in receipts + cacheReceipts where !log.contains(where: { $0.id == item.id }) {
      log.append(item)
    }
    log = Array(log.sorted { $0.date < $1.date }.suffix(128))
  }
  public mutating func includeMonitorReceipts(_ state: ViewState) {
    if isRunning {
      discoveredWorktrees =
        state.worktreeError == nil
        ? state.worktrees?.totalRecords ?? state.worktrees?.records.count : nil
      worktreeStates = state.worktreeError == nil ? state.worktrees?.stateCounts : nil
    }
    guard state.worktreeError == nil else {
      receiptEvidenceAvailable = false
      let id = "worktree-receipts-unavailable-" + self.id.uuidString
      if !log.contains(where: { $0.id == id }) {
        log.append(
          .init(
            id: id, kind: "warning",
            message: "Worktree receipt evidence is unavailable. Cleanup totals are unknown."))
        log = Array(log.suffix(128))
      }
      return
    }
    includeReceipts(state.catalog)
  }
  public func newCelebrations(since seen: Set<String>) -> [HuntLogEntry] {
    log.filter {
      !seen.contains($0.id)
        && ($0.kind == "detected" || ($0.kind == "burn" && receiptEvidenceAvailable != false))
    }
  }
}
