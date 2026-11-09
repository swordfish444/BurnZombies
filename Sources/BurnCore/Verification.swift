import Foundation

/// Finite, conservative receipt states. Resource absence is not a speed measurement.
public enum Verification {
  /// Compare clocks sampled together at successive observation boundaries. A scan's first
  /// process timestamp is not paired with its completion wall time: changing scan cost would
  /// otherwise look like a clock jump. Thresholds retain the conservative no-credit guard.
  public static func observationInterrupted(wallSeconds: Double, monotonicSeconds: Double) -> Bool {
    monotonicSeconds > 75 || abs(wallSeconds - monotonicSeconds) > 5
  }

  public static func recurrence(event: CleanupEvent, observations: [Observation], parentAlive: (Member) -> Bool) -> Bool {
    observations.contains { observation in
      let started = Double(observation.identity.seconds) + Double(observation.identity.micros) / 1e6
      guard !observation.zombie, started > event.date.timeIntervalSince1970,
        !event.targets.contains(Member(observation)) else { return false }
      return (event.recurrenceScopes ?? []).contains { scope in
        scope.parent.identity.pid > 1 && scope.executable == observation.executable
          && scope.parent.identity.pid == observation.parent && parentAlive(scope.parent)
      }
    }
  }
  public static func outcome(
    elapsed: TimeInterval, targets: [OwnerState], recurrence: Bool, partialScan: Bool
  ) -> String {
    guard !targets.isEmpty else { return "unverified" }
    guard !partialScan else { return "unverified" }
    guard elapsed >= 15 else { return "verifying" }
    if targets.contains(.unknown) { return "unverified" }
    if targets.contains(.alive) { return "partial" }
    if recurrence { return "reappeared" }
    return elapsed >= 120 ? "verified" : "verifying"
  }
}
