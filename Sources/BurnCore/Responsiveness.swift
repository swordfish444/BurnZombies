import Foundation

/// Small local command-launch probe. It never reads user files or contacts a service.
/// Seven launches with a discarded warm-up; median elapsed time is saved in the receipt.
public enum Responsiveness {
  public static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
    return values.sorted()[(values.count - 1) / 2]
  }
  public struct Comparison {
    public let before: Double
    public let after: Double
    public let boostPercent: Double?
  }
  /// Keep slower pairs in the distribution: selecting only improvements would
  /// manufacture a benefit. Legacy medians have no dispersion evidence.
  public static func comparison(_ events: [CleanupEvent]) -> Comparison? {
    let pairs = events.compactMap { event -> Comparison? in
      guard let a = event.responseBeforeSamples, let b = event.responseAfterSamples,
        a.count >= 7, b.count >= 7, let before = median(a), let after = median(b) else { return nil }
      let x = a.sorted(), y = b.sorted()
      let xLow = x[x.count / 4], xHigh = x[3 * x.count / 4]
      let yLow = y[y.count / 4], yHigh = y[3 * y.count / 4]
      guard (xHigh - xLow) / before <= 0.2, (yHigh - yLow) / after <= 0.2 else { return nil }
      let percent = (before / after - 1) * 100
      let clear = percent.isFinite && percent >= 5 && before - after >= 1 && xLow > yHigh
      return Comparison(before: before, after: after, boostPercent: clear ? percent : nil)
    }.sorted { $0.before / $0.after < $1.before / $1.after }
    guard !pairs.isEmpty else { return nil }
    return pairs[(pairs.count - 1) / 2]
  }
  public static func sample() -> [Double]? {
    var samples = [Double]()
    for i in 0..<8 {
      let command = Process()
      command.executableURL = URL(fileURLWithPath: "/usr/bin/true")
      command.environment = [:]
      command.standardInput = FileHandle.nullDevice
      command.standardOutput = FileHandle.nullDevice
      command.standardError = FileHandle.nullDevice
      let exited = DispatchSemaphore(value: 0)
      command.terminationHandler = { _ in exited.signal() }
      let start = ProcessInfo.processInfo.systemUptime
      do { try command.run() } catch { return nil }
      guard exited.wait(timeout: .now() + 1) == .success else {
        if command.isRunning { command.terminate() }
        return nil
      }
      guard command.terminationStatus == 0 else { return nil }
      if i > 0 { samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
    }
    return samples
  }
}
