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
  public var cpuSeconds: Double? = 0
  public var before: Double?
  public var after: Double?
  public var last: Date?
  public var latestCount: Int = 0
  public var latestMemory: UInt64 = 0
  public var latestLabel: String?

  public var boost: String {
    guard let before, let after, before > 0, after > 0 else { return "—" }
    return String(format: "~%.0f%%", (before / after - 1) * 100)
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
    return Self(
      count: period == .all
        ? catalog.lifetimeVerified : verified.reduce(0) { $0 + $1.verifiedCount },
      memory: period == .all
        ? (catalog.lifetimeResidentReleased ?? verified.reduce(0) { $0 + $1.residentBefore })
        : verified.reduce(0) { $0 + $1.residentBefore },
      cpuSeconds: period == .all
        ? (catalog.lifetimeCPUSecondsSaved ?? (catalog.lifetimeVerified == 0 ? 0 : nil))
        : (cpu.isEmpty && !verified.isEmpty ? nil : cpu.reduce(0, +)),
      before: measured?.responseBeforeMS, after: measured?.responseAfterMS,
      last: latest?.verificationDate ?? latest?.date, latestCount: latest?.verifiedCount ?? 0,
      latestMemory: latest?.residentBefore ?? 0,
      latestLabel: latest.map {
        "\($0.verifiedCount) \($0.verifiedCount == 1 ? "helper" : "helpers") burned"
      })
  }
}
