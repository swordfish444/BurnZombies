import BurnCore
import Foundation

/// Owns the running app's Autopilot engine and its sweep coordinator.
final class AutopilotRuntime: Sendable {
  let engine: Autopilot
  let coordinator: AutopilotCoordinator
  init(monitor: Monitor) throws {
    final class WakeBox: @unchecked Sendable {
      let lock = NSLock()
      var wake: (@Sendable () -> Void)?
      func fire() { lock.withLock { wake }?() }
    }
    let wakeBox = WakeBox()
    let junk = AutopilotJunkCache(slicePause: 1.5) { wakeBox.fire() }
    engine = try Autopilot(sources: .live(monitor: monitor, junk: junk, docker: .live()))
    coordinator = AutopilotCoordinator(engine: engine)
    // A hunt asked for from the command line, or a cold-start disk scan finishing its first round,
    // wakes Autopilot right away instead of waiting for the next 15-minute timer.
    let engine = engine
    let coordinator = coordinator
    wakeBox.lock.withLock { wakeBox.wake = { Task { _ = await engine.tick() } } }
    Task { await engine.onRequest { Task { await coordinator.tick() } } }
  }
  /// Native tick when due, plus an AI sweep when there is something new to judge. A hunt the owner
  /// asks for, deep or not, starts at once.
  func tick(manual: Bool = false, options: HuntOptions? = nil) async -> AutopilotSnapshot {
    await coordinator.tick(manual: manual, options: options)
  }
  /// Ends the hunt under way; what it burned stays burned.
  func stop() async { await coordinator.stop() }
  /// Applies an operator command. "Hunt now" and a deep hunt start an AI sweep immediately.
  func run(_ command: AutopilotCommand) async throws -> AutopilotSnapshot {
    switch command {
    case .sweepNow:
      return await coordinator.tick(manual: true)
    case .deepHunt(let limit):
      return await coordinator.tick(
        manual: true, options: HuntOptions(deep: true, limitUSD: limit))
    case .stopHunt:
      await coordinator.stop()
      return await engine.snapshot()
    default:
      return try await engine.apply(command)
    }
  }
}
