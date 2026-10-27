import Foundation

public enum ImpactPeriod: String, CaseIterable, Sendable {
  case today = "Today"
  case week = "7 days"
  case all = "All time"

  public var caption: String {
    switch self {
    case .today: return "Totals from completed cleanups today"
    case .week: return "Totals from completed cleanups in the last 7 days"
    case .all: return "Totals from completed cleanups across all time"
    }
  }

  public func start(now: Date, calendar: Calendar) -> Date {
    switch self {
    case .today: return calendar.startOfDay(for: now)
    case .week:
      // Today plus six preceding local dates, including across daylight-saving changes.
      return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
    case .all: return .distantPast
    }
  }
}

public struct ImpactNumbers: Sendable {
  public var count: Int = 0
  public var memory: UInt64 = 0
  public var disk: UInt64 = 0
  public var worktrees: Int = 0
  public var lifetimeWorktrees: Int = 0
  public var latestIsWorkspace: Bool = false
  public var latestDisk: UInt64 = 0
  public var cpuSeconds: Double? = 0
  public var before: Double?
  public var after: Double?
  public var last: Date?
  public var latestCount: Int = 0
  public var latestMemory: UInt64 = 0
  public var latestLabel: String?
  public var speedBoostPercent: Double?
  public var lifetimeCount: Int = 0

  public enum Benefit: Equatable, Sendable { case firstBurn, ready, speed, memory, helpers, disk, worktrees }
  public var benefit: Benefit {
    guard count > 0 || worktrees > 0 else { return lifetimeCount + lifetimeWorktrees > 0 ? .ready : .firstBurn }
    if boost != "—" { return .speed }
    if memory > 0 { return .memory }
    if count > 0 { return .helpers }
    return disk > 0 ? .disk : .worktrees
  }

  public var boost: String {
    guard let percent = speedBoostPercent, percent.isFinite, percent >= 5 else { return "—" }
    return String(format: "~%.0f%%", percent)
  }

  public static func make(
    catalog: Catalog, period: ImpactPeriod, now: Date = Date(), calendar: Calendar = .current
  ) -> Self {
    let start = period.start(now: now, calendar: calendar)
    let verified = catalog.events.filter {
      let completed = $0.verificationDate ?? $0.date
      return $0.outcome == "verified" && completed >= start && completed <= now
    }.sorted { ($0.verificationDate ?? $0.date) < ($1.verificationDate ?? $1.date) }
    let cpu = verified.compactMap(\.cpuSecondsSavedEstimate)
    let latest = verified.last
    let measured = verified.last { $0.responseBeforeMS != nil && $0.responseAfterMS != nil }
    let comparison = Responsiveness.comparison(verified)
    let workspaces = (catalog.workspaceReceipts ?? []).filter {
      $0.outcome == "verified" && $0.verifiedAt != nil && $0.verifiedAt! >= start && $0.verifiedAt! <= now
    }.sorted { $0.verifiedAt! < $1.verifiedAt! }
    let workspace = workspaces.last
    let latestIsWorkspace = (workspace?.verifiedAt ?? .distantPast) > (latest?.verificationDate ?? latest?.date ?? .distantPast)
    return Self(
      count: period == .all
        ? catalog.lifetimeVerified : verified.reduce(0) { $0 + $1.verifiedCount },
      memory: period == .all
        ? (catalog.lifetimeResidentReleased ?? verified.reduce(0) { $0 + $1.residentBefore })
        : verified.reduce(0) { $0 + $1.residentBefore },
      disk: period == .all ? (catalog.lifetimeDiskReclaimedBytes ?? 0) : workspaces.reduce(0) { $0 + $1.diskReclaimedBytes },
      worktrees: period == .all ? (catalog.lifetimeWorktreesCleaned ?? 0) : workspaces.count,
      lifetimeWorktrees: catalog.lifetimeWorktreesCleaned ?? 0,
      latestIsWorkspace: latestIsWorkspace, latestDisk: latestIsWorkspace ? (workspace?.diskReclaimedBytes ?? 0) : 0,
      cpuSeconds: period == .all
        ? (catalog.lifetimeCPUSecondsSaved ?? (catalog.lifetimeVerified == 0 ? 0 : nil))
        : (cpu.isEmpty && !verified.isEmpty ? nil : cpu.reduce(0, +)),
      before: comparison?.before ?? measured?.responseBeforeMS,
      after: comparison?.after ?? measured?.responseAfterMS,
      last: latestIsWorkspace ? workspace?.verifiedAt : latest?.verificationDate ?? latest?.date, latestCount: latest?.verifiedCount ?? 0,
      latestMemory: latest?.residentBefore ?? 0,
      latestLabel: latestIsWorkspace ? "Worktree cleaned" : latest.map {
        "\($0.verifiedCount) \($0.verifiedCount == 1 ? "helper" : "helpers") burned"
      }, speedBoostPercent: comparison?.boostPercent,
      lifetimeCount: max(catalog.lifetimeVerified, catalog.events.filter {
        $0.outcome == "verified" && ($0.verificationDate ?? $0.date) <= now
      }.reduce(0) { $0 + $1.verifiedCount }))
  }
}
