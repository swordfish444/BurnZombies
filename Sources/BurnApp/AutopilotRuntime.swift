import BurnCore
import Foundation

/// Owns the running app's Autopilot engine and its sweep coordinator.
final class AutopilotRuntime: Sendable {
  let engine: Autopilot
  let coordinator: AutopilotCoordinator
  init(monitor: Monitor) throws {
    engine = try Autopilot(sources: .live(monitor: monitor))
    coordinator = AutopilotCoordinator(engine: engine)
  }
  /// Native tick when due, plus an AI sweep when there is something new to judge.
  func tick(manual: Bool = false) async -> AutopilotSnapshot {
    await coordinator.tick(manual: manual)
  }
  /// Applies an operator command. "Hunt now" starts an AI sweep immediately.
  func run(_ command: AutopilotCommand) async throws -> AutopilotSnapshot {
    if command == .sweepNow { return await coordinator.tick(manual: true) }
    return try await engine.apply(command)
  }
}
