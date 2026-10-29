import Foundation

public enum OwnerWatchTransition: Equatable, Sendable {
  case waiting
  case observedExit
  case verify(elapsedSinceExit: TimeInterval)
  case unverified
}

public extension Verification {
  /// Stop-when-idle may let a raced build finish. The ordinary two-minute
  /// recurrence watch starts only after exact native exit is first observed.
  static func ownerWatch(elapsed: TimeInterval, targets: [OwnerState], partialScan: Bool,
                        elapsedSinceExit: TimeInterval?) -> OwnerWatchTransition {
    guard elapsed >= 0, !targets.isEmpty, !partialScan, !targets.contains(.unknown) else {
      return .unverified
    }
    if targets.contains(.alive) {
      return elapsed >= 900 || elapsedSinceExit != nil ? .unverified : .waiting
    }
    guard let exitElapsed = elapsedSinceExit else { return .observedExit }
    guard exitElapsed >= 0 else { return .unverified }
    return .verify(elapsedSinceExit: exitElapsed)
  }
}
