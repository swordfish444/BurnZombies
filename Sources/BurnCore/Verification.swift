import Foundation

/// Finite, conservative receipt states. Resource absence is not a speed measurement.
public enum Verification {
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
