import Foundation

/// A finite projection, not a counter of CPU already consumed by the helper.
public enum ImpactAccounting {
  public static let projectionSeconds: Double = 3600
  public static func cpuSecondsSaved(_ records: [Record]) -> Double? {
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
      total += rate * projectionSeconds
    }
    return total
  }
}
