import Foundation

/// How a hunt runs: a regular one, or a deep one the owner started with a spending limit.
public struct HuntOptions: Sendable, Equatable {
  /// The AI reads everything, small programs included, and burns as it goes.
  public var deep: Bool
  /// What this run may spend, in US dollars at API rates. Claude stops itself there too.
  public var limitUSD: Double?
  /// "Keep hunting": the stopped hunt goes on, and what it spent and freed still counts.
  public var continuing: Bool
  public init(deep: Bool = false, limitUSD: Double? = nil, continuing: Bool = false) {
    self.deep = deep
    self.limitUSD = limitUSD
    self.continuing = continuing
  }
  /// The limits the owner picks from.
  public static let limits: [Double] = [2, 5, 15]
  public static let defaultLimit: Double = 5
  /// Less than this left under the limit isn't worth starting a run for.
  public static let smallestRun: Double = 0.25
}

/// What a streamed Claude run says while it works.
public enum AutopilotStreamEvent: Sendable, Equatable {
  /// The model's own words between tool calls.
  case text(String)
  /// What the run used so far: every token it read or wrote, and the cost at API rates when BZ
  /// knows the model's prices.
  case spend(tokens: Int, usd: Double?)
  /// The run ended: its own total cost, and whether its spending limit stopped it.
  case result(usd: Double?, limitReached: Bool, isError: Bool)
}

/// Reads Claude Code's `--output-format stream-json` one line at a time. A message's usage comes
/// with each of its content blocks as running totals, so each message counts once, at its latest.
public struct AutopilotStreamReader: Sendable {
  var pending = Data()
  var messages: [String: ModelUsage] = [:]
  public init() {}

  public var tokens: Int {
    messages.values.reduce(0) { $0 + $1.input + $1.output }
  }
  /// Nil while any message is from a model BZ has no prices for.
  public var estimatedUSD: Double? {
    var total = 0.0
    for usage in messages.values {
      guard let usd = ModelPricing.estimate(usage) else { return nil }
      total += usd
    }
    return total
  }

  public mutating func read(_ data: Data) -> [AutopilotStreamEvent] {
    pending.append(data)
    var events = [AutopilotStreamEvent]()
    while let newline = pending.firstIndex(of: 0x0A) {
      let line = Data(pending[pending.startIndex..<newline])
      pending.removeSubrange(pending.startIndex...newline)
      events += parse(line)
    }
    // Only a tool result is ever this long, and none is needed: drop it instead of holding it.
    if pending.count > 4 << 20 { pending.removeAll() }
    return events
  }

  /// Whatever is left once the run's output has ended.
  public mutating func finish() -> [AutopilotStreamEvent] {
    let line = pending
    pending.removeAll()
    return parse(line)
  }

  mutating func parse(_ line: Data) -> [AutopilotStreamEvent] {
    guard line.first == UInt8(ascii: "{"),
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = object["type"] as? String
    else { return [] }
    switch type {
    case "assistant":
      guard let message = object["message"] as? [String: Any] else { return [] }
      var events = [AutopilotStreamEvent]()
      for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "text" {
        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { events.append(.text(text)) }
      }
      if let id = message["id"] as? String, let usage = message["usage"] as? [String: Any],
        let counted = Self.usage(usage, model: message["model"] as? String ?? "unknown")
      {
        messages[id] = counted
        events.append(.spend(tokens: tokens, usd: estimatedUSD))
      }
      return events
    case "result":
      let limit =
        object["subtype"] as? String == "error_max_budget_usd"
        || object["terminal_reason"] as? String == "budget_exhausted"
      return [
        .result(
          usd: object["total_cost_usd"] as? Double, limitReached: limit,
          isError: object["is_error"] as? Bool == true)
      ]
    default:
      return []
    }
  }

  /// One message's usage the way the ledger counts Claude's: input includes cache reads and writes.
  static func usage(_ u: [String: Any], model: String) -> ModelUsage? {
    func number(_ key: String) -> Int? { u[key] as? Int }
    guard let input = number("input_tokens"), let output = number("output_tokens") else {
      return nil
    }
    let cached = number("cache_read_input_tokens") ?? 0
    let write = number("cache_creation_input_tokens") ?? 0
    let durations = u["cache_creation"] as? [String: Any]
    let long = durations?["ephemeral_1h_input_tokens"] as? Int ?? 0
    guard [input, output, cached, write, long].allSatisfy({ (0...100_000_000).contains($0) }),
      long <= write
    else { return nil }
    return ModelUsage(
      model: model, input: input + cached + write, cached: cached, output: output,
      cacheWrite: write, cacheWriteLong: long, tier: u["service_tier"] as? String)
  }
}

/// One AI run of a hunt: what kind it is, where its live events go, and how to stop it. Stopping
/// ends the harness's whole process group; what the run burned stays burned.
public final class AutopilotRun: @unchecked Sendable {
  public let options: HuntOptions
  public let events: @Sendable (AutopilotStreamEvent) -> Void
  private let lock = NSLock()
  private var process: Process?
  private var reason: String?

  public init(
    options: HuntOptions = HuntOptions(),
    events: @escaping @Sendable (AutopilotStreamEvent) -> Void = { _ in }
  ) {
    self.options = options
    self.events = events
  }

  /// `stopped` when the owner pressed Stop, `limit` when the run reached its spending limit.
  public var stopReason: String? { lock.withLock { reason } }

  /// Ends the run. The first reason given is the one that stands.
  public func stop(_ why: String = "stopped") {
    let running: Process? = lock.withLock {
      if reason == nil { reason = why }
      return process
    }
    if let running, running.isRunning { running.terminate() }
  }

  /// The harness process, once started; a run stopped before it started ends it at once.
  func attach(_ started: Process) {
    let stopped: Bool = lock.withLock {
      process = started
      return reason != nil
    }
    if stopped, started.isRunning { started.terminate() }
  }
}
