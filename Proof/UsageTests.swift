import BurnCore
import Foundation

func usageProof() throws {
  let codex = Data("""
  {"type":"bz.model","model":"gpt-6.1-sol"}
  {"type":"bz.usage","event_id":"one","model":"gpt-6.1-sol","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100}}
  {"type":"bz.usage","event_id":"one","model":"gpt-6.1-sol","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100}}
  {"type":"bz.usage","event_id":"two","model":"gpt-6.1-terra","usage":{"input_tokens":2000,"cached_input_tokens":1000,"output_tokens":200}}
  """.utf8)
  let usage = ReviewUsage.parse(codex)!
  equal(usage.inputTokens, 3000); equal(usage.cachedInputTokens, 1800); equal(usage.outputTokens, 300)
  equal(usage.byModel?.count, 2)
  check(abs((usage.byModel?.first?.estimatedUSD ?? -1) - 0.00148) < 0.0000001, "Model-specific input/cache/output pricing")
  let claude = ReviewUsage.parse(Data("""
  {"type":"result","usage":{"input_tokens":99999,"output_tokens":99999},"modelUsage":{"claude-opus-5-5":{"inputTokens":100,"cacheReadInputTokens":200,"cacheCreationInputTokens":300,"outputTokens":10},"future-model":{"inputTokens":50,"outputTokens":2}}}
  """.utf8))!
  equal(claude.inputTokens, 650); equal(claude.cachedInputTokens, 200); equal(claude.outputTokens, 12)
  equal(claude.byModel?.first?.cacheWrite, 300)
  check(claude.byModel?.last?.estimatedUSD == nil, "Unknown model cost cannot become zero")
  check(ReviewUsage.parse(Data("{\"type\":\"result\",\"modelUsage\":{\"gpt-6.1-sol\":{}}}".utf8)) == nil)
  for invalid in [-1, 100_000_001] {
    check(ReviewUsage.parse(Data("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":\(invalid),\"output_tokens\":0}}".utf8)) == nil)
  }
  let fast = ModelUsage(model: "gpt-5.5", input: 1_000_000, cached: 0, output: 0, tier: "fast")
  equal(ModelPricing.estimate(fast), 12.5)
  let large = ModelUsage(model: "gpt-6.1-sol", input: 1_000_000, cached: 0, output: 0, maximumContext: 300_000)
  equal(ModelPricing.estimate(large), 4)
  check(ModelPricing.estimate(.init(model: "claude-sonnet-5-5", input: 1, cached: 0, output: 1, tier: "fast")) == nil)
  var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Denver")!
  let now = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
  var ledger = ReviewLedger()
  _ = ledger.reserve(harness: "codex", evidenceCount: 1, now: now.addingTimeInterval(-3600)); ledger.entries[0].usage = usage
  _ = ledger.reserve(harness: "claude", evidenceCount: 1, now: now.addingTimeInterval(-3*86400)); ledger.entries[1].usage = claude
  _ = ledger.reserve(harness: "codex", evidenceCount: 1, now: now.addingTimeInterval(-2*3600))
  let one = UsageReport.make(ledger, days: 1, hourly: true, now: now, calendar: calendar)
  equal(one.total.reviews, 2); equal(one.total.unknown, 1); equal(one.total.input, 3000)
  equal(one.buckets.reduce(0) { $0 + $1.totals.input }, one.total.input)
  let all = UsageReport.make(ledger, days: 30, hourly: false, now: now, calendar: calendar)
  equal(all.total.input, 3650); equal(all.models.count, 4); equal(all.total.unpriced, 1)
  equal(Set(all.buckets.map(\.date)).count, all.buckets.count, "DST buckets are distinct")
  let model = UsageReport.make(ledger, days: 30, hourly: true, model: "gpt-6.1-sol", now: now, calendar: calendar)
  equal(model.total.input, 1000); equal(model.total.reviews, 1); equal(model.models.count, 4)
  let empty = UsageReport.make(ReviewLedger(), days: 30, hourly: true, now: now, calendar: calendar)
  equal(empty.total.reviews, 0); check(empty.buckets.count <= 746)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-usage-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try Store(root: root); try ledger.save(store: store)
  let restored = try ReviewLedger.load(store: store)
  equal(restored.entries[0].usage?.byModel?.first?.estimatedUSD, usage.byModel?.first?.estimatedUSD)
  _ = ledger.reserve(harness: "codex", evidenceCount: 0, now: now.addingTimeInterval(31*86400))
  check(ledger.entries.contains { $0.id == restored.entries[0].id }, "Keep at least thirty days across restarts")
  let old = try JSONDecoder().decode(ReviewUsage.self, from: Data("{\"inputTokens\":10,\"cachedInputTokens\":8,\"outputTokens\":1}".utf8))
  check(old.byModel == nil, "Legacy counters remain readable without inventing a model")
  print("PASS per-model cache-aware pricing, duplicate events, unknown usage, DST/time/model filters and thirty-day persistence")
}
