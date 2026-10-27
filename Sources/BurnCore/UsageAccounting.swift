import Foundation

/// Recorded per-model usage for BurnZombies-owned reviews only. Cache reads and writes
/// are disjoint parts of input; reasoning tokens are already included in output.
public struct ModelUsage: Codable, Sendable, Identifiable {
  public var model: String
  public var input: Int
  public var cached: Int
  public var output: Int
  public var cacheWrite: Int = 0
  public var cacheWriteLong: Int = 0
  public var maximumContext: Int?
  public var tier: String?
  public var estimatedUSD: Double?
  public var rateDate: String?
  public var id: String { model }
  public var uncached: Int { max(0, input - cached - cacheWrite) }
  public init(model: String, input: Int, cached: Int, output: Int, cacheWrite: Int = 0,
    cacheWriteLong: Int = 0, maximumContext: Int? = nil, tier: String? = nil) {
    self.model = model; self.input = input; self.cached = cached; self.output = output
    self.cacheWrite = cacheWrite; self.cacheWriteLong = cacheWriteLong
    self.maximumContext = maximumContext; self.tier = tier
  }
  public mutating func price() {
    estimatedUSD = ModelPricing.estimate(self)
    rateDate = estimatedUSD == nil ? nil : ModelPricing.date
  }
}

public enum ModelPricing {
  public static let date = "2026-10-27"
  public static let openAI = "https://developers.openai.com/api/docs/pricing"
  public static let anthropic = "https://platform.claude.com/docs/en/about-claude/pricing"
  // USD / million tokens, standard global API-equivalent rates. No subscription-credit conversion.
  public static func estimate(_ usage: ModelUsage) -> Double? {
    var model = usage.model
    if let range = model.range(of: #"-\d{4}-\d{2}-\d{2}$|-\d{8}$"#, options: .regularExpression) { model.removeSubrange(range) }
    let rates: [String: [Double]] = [
      "gpt-6-astra": [10, 1, 50], "gpt-6.1-sol": [2, 0.1, 10], "gpt-6.1-terra": [1, 0.05, 5],
      "gpt-6-sol": [2, 0.2, 10], "gpt-6-luna": [0.1, 0.01, 0.5],
      "gpt-5.6-sol": [4, 0.4, 20], "gpt-5.6-terra": [2, 0.2, 12], "gpt-5.6-luna": [0.2, 0.02, 1.2],
      "gpt-5.5": [5, 0.5, 30], "gpt-5.4": [2.5, 0.25, 15], "gpt-5.4-mini": [0.75, 0.075, 4.5],
      "gpt-5.4-nano": [0.2, 0.02, 1.25], "gpt-5.2": [1.75, 0.175, 14],
      "claude-opus-5-5": [4, 0.2, 20], "claude-sonnet-5-5": [2, 0.1, 10], "claude-haiku-5-5": [0.1, 0.01, 0.5],
      "claude-fable-5-1": [10, 0.25, 50], "claude-mythos-5-1": [10, 0.25, 50],
      "claude-opus-5": [5, 0.5, 25], "claude-opus-4-8": [5, 0.5, 25], "claude-opus-4-7": [5, 0.5, 25],
      "claude-opus-4-6": [5, 0.5, 25], "claude-opus-4-5": [5, 0.5, 25],
      "claude-sonnet-5": [2, 0.2, 10], "claude-sonnet-4-6": [3, 0.3, 15], "claude-sonnet-4-5": [3, 0.3, 15],
      "claude-haiku-4-5": [1, 0.1, 5]
    ]
    guard var rate = rates[model], usage.input >= 0, usage.cached >= 0, usage.output >= 0,
      usage.cacheWrite >= 0, usage.cacheWriteLong >= 0,
      usage.cached + usage.cacheWrite <= usage.input, usage.cacheWriteLong <= usage.cacheWrite else { return nil }
    if let context = usage.maximumContext {
      if (model.hasPrefix("gpt-6") || ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"].contains(model)) && context > 272_000 {
        rate[0] *= 2; rate[1] *= 2; rate[2] *= 1.5
      }
      if model == "claude-haiku-5-5" && context > 100_000 { rate = rate.map { $0 * 5 } }
    }
    let multiplier: Double
    switch usage.tier ?? "standard" {
    case "standard", "default", "auto": multiplier = 1
    case "fast" where model.hasPrefix("gpt-"), "priority" where model.hasPrefix("gpt-"): multiplier = model == "gpt-5.5" ? 2.5 : 2
    case "fast" where ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"].contains(model): multiplier = 2
    case "ultrafast" where ["gpt-6-astra", "gpt-6.1-sol"].contains(model): multiplier = 6
    case "batch", "flex": multiplier = 0.5
    default: return nil
    }
    let writeLongMultiplier = model.hasPrefix("claude-") ? 2.0 : 2.5
    let cost = Double(usage.uncached) * rate[0] + Double(usage.cached) * rate[1]
      + Double(usage.output) * rate[2] + Double(usage.cacheWrite - usage.cacheWriteLong) * rate[0] * 1.25
      + Double(usage.cacheWriteLong) * rate[0] * writeLongMultiplier
    return cost * multiplier / 1_000_000
  }
}

public struct UsageTotals: Sendable {
  public var input = 0, cached = 0, output = 0, cacheWrite = 0
  public var estimatedUSD: Double = 0
  public var unpriced = 0, unknown = 0, reviews = 0
  public var uncached: Int { max(0, input - cached - cacheWrite) }
  public mutating func add(_ value: ModelUsage) {
    input += value.input; cached += value.cached; output += value.output; cacheWrite += value.cacheWrite
    if let cost = value.estimatedUSD { estimatedUSD += cost } else { unpriced += 1 }
  }
}
public struct UsageBucket: Identifiable, Sendable {
  public var date: Date
  public var totals: UsageTotals
  public var id: Date { date }
}
public struct UsageModelRow: Identifiable, Sendable {
  public var model: String
  public var totals: UsageTotals
  public var id: String { model }
}
public struct UsageReport: Sendable {
  public var total = UsageTotals()
  public var buckets: [UsageBucket] = []
  public var models: [UsageModelRow] = []
  public static func make(_ ledger: ReviewLedger, days: Int, hourly: Bool, model: String? = nil,
    now: Date = Date(), calendar: Calendar = .current) -> Self {
    let days = min(30, max(1, days))
    let start = calendar.date(byAdding: .day, value: -days, to: now)!
    let component: Calendar.Component = hourly ? .hour : .day
    var report = Self(), cursor = calendar.dateInterval(of: component, for: start)!.start
    while cursor <= now {
      report.buckets.append(.init(date: cursor, totals: .init()))
      guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
      cursor = next
    }
    var byModel: [String: UsageTotals] = [:]
    let indices = Dictionary(uniqueKeysWithValues: report.buckets.enumerated().map { ($0.element.date, $0.offset) })
    for entry in ledger.entries where entry.started >= start && entry.started <= now {
      let slices = entry.usage?.byModel ?? entry.usage.map {
        [ModelUsage(model: entry.requestedModel ?? "Unreported model", input: $0.inputTokens, cached: $0.cachedInputTokens, output: $0.outputTokens)]
      } ?? []
      let bucket = calendar.dateInterval(of: component, for: entry.started)!.start
      guard let index = indices[bucket] else { continue }
      if model == nil || slices.contains(where: { $0.model == model }) {
        report.total.reviews += 1; report.buckets[index].totals.reviews += 1
        if entry.usage == nil { report.total.unknown += 1; report.buckets[index].totals.unknown += 1 }
      }
      for slice in slices {
        byModel[slice.model, default: .init()].add(slice)
        byModel[slice.model, default: .init()].reviews += 1
        if model == nil || slice.model == model {
          report.total.add(slice); report.buckets[index].totals.add(slice)
        }
      }
    }
    report.models = byModel.map { .init(model: $0.key, totals: $0.value) }.sorted { $0.totals.input + $0.totals.output > $1.totals.input + $1.totals.output }
    return report
  }
}
