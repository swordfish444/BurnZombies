import Foundation

public enum ImpactPeriod: String, CaseIterable, Sendable {
  case today = "Today"
  case week = "7 days"
  case all = "All time"

  public var caption: String {
    switch self {
    case .today: return "Finished burns today"
    case .week: return "Finished burns in the last 7 days"
    case .all: return "Finished burns, all time"
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
  public var cpuSeconds: Double? = 0
  public var before: Double?
  public var after: Double?
  public var last: Date?
  public var speedBoostPercent: Double?
  public var lifetimeCount: Int = 0

  public enum Benefit: Equatable, Sendable {
    case firstBurn, ready, speed, memory, helpers, disk, worktrees
  }
  public var benefit: Benefit {
    guard count > 0 || worktrees > 0 else {
      return lifetimeCount + lifetimeWorktrees > 0 ? .ready : .firstBurn
    }
    if boost != "—" { return .speed }
    if memory > 0 { return .memory }
    if count > 0 { return .helpers }
    return disk > 0 ? .disk : .worktrees
  }

  public var boost: String {
    guard let percent = speedBoostPercent, percent.isFinite, percent >= 5 else { return "—" }
    return String(format: "~%.0f%%", percent)
  }

  public static func bytes(_ n: UInt64) -> String {
    if n == 0 { return "0 GB" }
    if n >= 1_000_000_000 { return String(format: "%.1f GB", Double(n) / 1e9) }
    if n >= 1_000_000 { return String(format: "%.0f MB", Double(n) / 1e6) }
    return String(format: "%.0f KB", Double(n) / 1e3)
  }

  public static func make(
    catalog: Catalog, autopilot: AutopilotImpact? = nil, period: ImpactPeriod, now: Date = Date(),
    calendar: Calendar = .current
  ) -> Self {
    let start = period.start(now: now, calendar: calendar)
    let verified = catalog.events.filter {
      let completed = $0.verificationDate ?? $0.date
      return $0.outcome == "verified" && $0.fixture != true && completed >= start
        && completed <= now
    }.sorted { ($0.verificationDate ?? $0.date) < ($1.verificationDate ?? $1.date) }
    let cpu = verified.compactMap(\.cpuSecondsSavedEstimate)
    let latest = verified.last
    let measured = verified.last { $0.responseBeforeMS != nil && $0.responseAfterMS != nil }
    let comparison = Responsiveness.comparison(verified)
    let workspaces = (catalog.workspaceReceipts ?? []).filter {
      $0.outcome == "verified" && $0.fixture != true && $0.verifiedAt != nil
        && $0.verifiedAt! >= start && $0.verifiedAt! <= now
    }.sorted { $0.verifiedAt! < $1.verifiedAt! }
    let diskOutputs = (catalog.diskReceipts ?? []).filter {
      $0.outcome == "verified" && $0.fixture != true && $0.date >= start && $0.date <= now
    }
    let cleanups = (autopilot?.cleanups ?? []).filter { $0.date >= start && $0.date <= now }
    // Autopilot's own cleanups count in every period; kept as small typed steps for the compiler.
    let periodDisk: UInt64 = workspaces.reduce(0) { $0 + $1.diskReclaimedBytes }
    let outputDisk: UInt64 = diskOutputs.reduce(0) { $0 + $1.diskReclaimedBytes }
    let cleanupDisk: UInt64 = cleanups.reduce(0) { $0 + $1.bytes }
    let lifetimeDisk: UInt64 = (catalog.lifetimeDiskReclaimedBytes ?? 0) + (autopilot?.bytes ?? 0)
    let lifetimeWorktrees: Int = (catalog.lifetimeWorktreesCleaned ?? 0) + (autopilot?.worktrees ?? 0)
    let periodWorktrees: Int = workspaces.count + cleanups.filter(\.worktree).count
    let dates: [Date?] = [
      workspaces.last?.verifiedAt, latest?.verificationDate ?? latest?.date,
      cleanups.map(\.date).max(),
    ]
    return Self(
      count: period == .all
        ? catalog.lifetimeVerified : verified.reduce(0) { $0 + $1.verifiedCount },
      memory: period == .all
        ? (catalog.lifetimeResidentReleased ?? verified.reduce(0) { $0 + $1.residentBefore })
        : verified.reduce(0) { $0 + $1.residentBefore },
      disk: period == .all ? lifetimeDisk : periodDisk + outputDisk + cleanupDisk,
      worktrees: period == .all ? lifetimeWorktrees : periodWorktrees,
      lifetimeWorktrees: lifetimeWorktrees,
      cpuSeconds: period == .all
        ? (catalog.lifetimeCPUSecondsSaved ?? (catalog.lifetimeVerified == 0 ? 0 : nil))
        : (cpu.isEmpty && !verified.isEmpty ? nil : cpu.reduce(0, +)),
      before: comparison?.before ?? measured?.responseBeforeMS,
      after: comparison?.after ?? measured?.responseAfterMS,
      last: dates.compactMap { $0 }.max(),
      speedBoostPercent: comparison?.boostPercent,
      lifetimeCount: max(
        catalog.lifetimeVerified,
        catalog.events.filter {
          $0.outcome == "verified" && $0.fixture != true && ($0.verificationDate ?? $0.date) <= now
        }.reduce(0) { $0 + $1.verifiedCount }))
  }
}
