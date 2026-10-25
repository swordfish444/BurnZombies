import Foundation

/// Lifecycle transport only: coalesces reminders. It never scans, classifies or stops processes.
public enum HarnessHook {
  public struct Signal: Codable {
    public var observedAt: Date
    public var processCount: Int
    public var residentBytes: UInt64
    public var pressure: String
    public init(observedAt: Date, processCount: Int, residentBytes: UInt64, pressure: String) {
      self.observedAt = observedAt; self.processCount = processCount
      self.residentBytes = residentBytes; self.pressure = pressure
    }
  }
  private struct Delivery: Codable { var signal: Signal; var deliveredAt: Date }
  /// Publish facts already gathered by the monitor. This is a notification gate,
  /// never a process classifier or permission to stop anything.
  public static func publish(_ signal: Signal, store: Store) throws {
    try store.write(JSONEncoder().encode(signal), to: store.root.appendingPathComponent("review-signal"), limit: 1024)
  }
  public static let context = """
    BurnZombies has a pending cleanup request or changed resource pressure/buildup.
    At a convenient boundary, use the burnzombies skill for one bounded review within existing cleanup authorization.
    The signal is not an abandonment verdict. Preserve active and uncertain work; prefer owner-native teardown.
    Continue the user's task while receipts verify. No reboot, blanket kill, forced continuation or UI activation.
    If tools or authorization are unavailable, keep working. A no-op is quiet.
    """

  public static func requestCleanup(root: URL = Store.defaultRoot) throws {
    let store = try Store(root: root)
    try store.write(Data("requested".utf8), to: root.appendingPathComponent("review-request"), limit: 128)
  }

  public static func response(client: String, event: String, input: [String: Any],
    root: URL = Store.defaultRoot, now: Date = Date()) throws -> [String: Any] {
    guard ["codex", "claude", "cursor", "copilot", "gemini"].contains(client) else { return [:] }
    guard ["PostToolUse", "postToolUse", "AfterTool"].contains(event) else { return [:] }
    let tool = (input["tool_name"] as? String ?? input["toolName"] as? String ?? "").lowercased()
    if tool.contains("burnzombies") { return [:] }
    let store = try Store(root: root)
    guard let data = try? store.read(root.appendingPathComponent("review-signal"), limit: 1024),
      let signal = try? JSONDecoder().decode(Signal.self, from: data),
      (0...180).contains(now.timeIntervalSince(signal.observedAt)) else { return [:] }
    let lock = try InstanceLock(url: root.appendingPathComponent("hook.lock"))
    defer { withExtendedLifetime(lock) {} }
    let stamp = root.appendingPathComponent("review-delivery")
    let pending = root.appendingPathComponent("review-request")
    let requested = FileManager.default.fileExists(atPath: pending.path)
    let previous = (try? store.read(stamp, limit: 2048)).flatMap { try? JSONDecoder().decode(Delivery.self, from: $0) }
    let elapsed = previous.map { now.timeIntervalSince($0.deliveredAt) } ?? 600
    guard requested || elapsed >= 600 || elapsed < 0 else { return [:] }
    let grew = previous.map { signal.processCount >= $0.signal.processCount + 20
      || (signal.residentBytes > $0.signal.residentBytes && signal.residentBytes - $0.signal.residentBytes >= 512 * 1024 * 1024) } ?? false
    let pressured = ["Elevated", "High"].contains(signal.pressure) && signal.pressure != previous?.signal.pressure
    let needsReview = requested || grew || pressured
    // Save a baseline once. Unchanged checkpoints do no writes and emit no context.
    guard needsReview || previous == nil else { return [:] }
    try store.write(JSONEncoder().encode(Delivery(signal: signal, deliveredAt: now)), to: stamp, limit: 2048)
    guard needsReview else { return [:] }
    if requested { try FileManager.default.removeItem(at: pending) }
    if client == "cursor" { return ["additional_context": context] }
    if client == "copilot" { return ["additionalContext": context] }
    return ["hookSpecificOutput": ["hookEventName": event, "additionalContext": context]]
  }
}
