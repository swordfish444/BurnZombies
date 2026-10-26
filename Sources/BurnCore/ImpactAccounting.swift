import Foundation

/// Estimated avoided CPU, never historical CPU consumed while useful work was running.
public enum ImpactAccounting {
  // Kept only to interpret receipts written before incremental accounting.
  public static let projectionSeconds: Double = 3600
  public static let maximumObservedSeconds: Double = 24 * 3600
  public static func cpuSecondsSaved(_ records: [Record]) -> Double? {
    cpuRate(records).map { $0 * projectionSeconds }
  }
  public static func cpuRate(_ records: [Record]) -> Double? {
    guard !records.isEmpty else { return nil }
    var total = 0.0
    for record in records {
      let latest = record.latest
      let samples = record.samples.filter {
        $0.identity == latest.identity && $0.monotonic <= latest.monotonic
      }
      guard let first = samples.first, samples.count >= 3,
        latest.metricsValid, samples.allSatisfy({ $0.metricsValid }),
        latest.monotonic - first.monotonic >= 120, latest.cpuNS >= first.cpuNS
      else { return nil }
      let rate = Double(latest.cpuNS - first.cpuNS) / 1e9 / (latest.monotonic - first.monotonic)
      guard rate.isFinite, rate >= 0 else { return nil }
      total += rate
    }
    return total
  }

  /// Preserve old credited estimates, without silently backfilling unobserved runtime.
  public static func migrate(_ catalog: inout Catalog) {
    for i in catalog.events.indices {
      let event = catalog.events[i]
      guard event.outcome == "verified", event.cpuSavingsRate == nil,
        let old = event.cpuSecondsSavedEstimate, old.isFinite, old >= 0 else { continue }
      catalog.events[i].cpuSavingsRate = old / projectionSeconds
      catalog.events[i].cpuObservedSeconds = 0
      catalog.events[i].cpuLegacyFloorSeconds = projectionSeconds
    }
  }

  /// Called only for consecutive complete scans. Awake time excludes sleep; the
  /// interval limit also excludes downtime, suspension and missed observations.
  @discardableResult public static func accrue(_ catalog: inout Catalog,
    awakeSeconds: Double, wallSeconds: Double, boot: UInt64, ended: Set<UUID> = []) -> Double {
    guard awakeSeconds.isFinite, wallSeconds.isFinite, awakeSeconds > 0,
      awakeSeconds <= 75, wallSeconds > 0, wallSeconds <= 75,
      abs(wallSeconds - awakeSeconds) <= 5, boot != 0 else { return 0 }
    var added = 0.0
    for i in catalog.events.indices {
      let event = catalog.events[i]
      guard event.outcome == "verified", event.cpuAccrualEnded != true,
        let rate = event.cpuSavingsRate, rate.isFinite, rate >= 0,
        let observed = event.cpuObservedSeconds, observed.isFinite, observed >= 0 else { continue }
      guard !ended.contains(event.id), !event.targets.isEmpty,
        event.targets.allSatisfy({ $0.identity.boot == boot }) else {
        catalog.events[i].cpuAccrualEnded = true
        continue
      }
      let duration = min(maximumObservedSeconds, observed + awakeSeconds)
      let floor = event.cpuLegacyFloorSeconds ?? 0
      let total = rate * max(floor, duration)
      let delta = max(0, total - (event.cpuSecondsSavedEstimate ?? 0))
      catalog.events[i].cpuObservedSeconds = duration
      catalog.events[i].cpuSecondsSavedEstimate = total
      catalog.events[i].cpuAccrualEnded = duration >= maximumObservedSeconds
      added += delta
    }
    if added > 0 { catalog.lifetimeCPUSecondsSaved = (catalog.lifetimeCPUSecondsSaved ?? 0) + added }
    return added
  }
}
