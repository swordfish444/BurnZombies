import CryptoKit
import Foundation

/// Dispatch facts only. The model still decides whether released work is disposable.
public struct ReviewEvidence: Codable, Equatable, Sendable {
  public var id: String
  public var revision: String
  public var processCount: Int
  public var recommendationOnly: Bool?
  public init(id: String, revision: String, processCount: Int = 1, recommendationOnly: Bool? = nil) {
    self.id = id; self.revision = revision; self.processCount = processCount; self.recommendationOnly = recommendationOnly
  }
  public static func pending(in catalog: Catalog) -> [Self] {
    let claims = catalog.workEvidence ?? []
    var result = [Self]()
    for claim in claims where claim.state == "released" {
      let live = claim.members.compactMap { member -> Record? in
        guard let r = catalog.records[member.identity.key], r.missingSince == nil,
          Member(r.latest) == member, !WorkEvidence.blockingTree(claims, record: r, records: catalog.records) else { return nil }
        return r
      }
      guard !live.isEmpty else { continue }
      let pids = Set(live.map { $0.latest.identity.pid })
      let children = catalog.records.values.filter { $0.missingSince == nil && pids.contains($0.latest.parent) }.map(\.id).sorted()
      // CPU, memory, time and unrelated process churn must never invalidate a reviewed decision.
      let revision = claim.id + "|" + String(claim.updated.timeIntervalSinceReferenceDate)
        + "|" + live.map(\.id).sorted().joined(separator: ",") + "|" + children.joined(separator: ",")
      result.append(.init(id: claim.id, revision: digest(revision), processCount: live.count))
    }
    let releasedIDs = Set(claims.filter { $0.state == "released" }.flatMap { $0.members.map { $0.identity.key } })
    for evidence in catalog.passiveEvidence ?? [] where evidence.canReview() && !releasedIDs.contains(evidence.member.identity.key) {
      guard let record = catalog.records[evidence.member.identity.key], record.missingSince == nil,
        Member(record.latest) == evidence.member, !WorkEvidence.blockingTree(claims, record: record, records: catalog.records) else { continue }
      result.append(.init(id: evidence.id, revision: evidence.revision))
    }
    for candidate in catalog.diskCandidates ?? [] where candidate.pendingReview {
      result.append(.init(id: candidate.id, revision: candidate.queueRevision, processCount: 0, recommendationOnly: !candidate.reviewable))
    }
    for node in catalog.diskDiscovery ?? [] {
      result.append(.init(id: node.id, revision: node.revision, processCount: 0, recommendationOnly: true))
    }
    for workspace in catalog.workspaces ?? [] where workspace.state == "released" {
      result.append(.init(id: workspace.id, revision: digest(workspace.id + "|" + String(workspace.updated.timeIntervalSinceReferenceDate)), processCount: 0))
    }
    // Preserve the producer's measured opportunity order instead of sorting opaque hashes.
    return result
  }
  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct ReviewUsage: Codable, Sendable {
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public var byModel: [ModelUsage]?
  public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens; self.outputTokens = outputTokens
  }
  public static func parse(_ data: Data, requestedModel: String? = nil) -> Self? {
    var models = [String: ModelUsage](), seen = Set<String>()
    var fallback = requestedModel ?? "Unreported model"
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let type = object["type"] as? String else { continue }
      if type == "bz.model", let model = object["model"] as? String { fallback = model }
      if let key = object["event_id"] as? String, !seen.insert(key).inserted { continue }
      func number(_ u: [String: Any], _ names: [String]) -> Int { names.compactMap { u[$0] as? Int }.first ?? 0 }
      func add(_ u: [String: Any], model: String, claude: Bool) {
        guard (u["input_tokens"] as? Int ?? u["inputTokens"] as? Int) != nil,
          (u["output_tokens"] as? Int ?? u["outputTokens"] as? Int) != nil else { return }
        let input = number(u, ["input_tokens", "inputTokens"]), output = number(u, ["output_tokens", "outputTokens"])
        let cache = number(u, ["cached_input_tokens", "cache_read_input_tokens", "cacheReadInputTokens"])
        let write = number(u, ["cache_creation_input_tokens", "cacheCreationInputTokens"])
        let long = (u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0
        guard [input, output, cache, write, long].allSatisfy({ (0...100_000_000).contains($0) }) else { return }
        let total = input + (claude ? cache + write : 0)
        guard [input, output, cache, write, long].allSatisfy({ (0...100_000_000).contains($0) }), cache + write <= total, long <= write else { return }
        var value = ModelUsage(model: model, input: total, cached: cache, output: output, cacheWrite: write,
          cacheWriteLong: long, maximumContext: u["context_tokens"] as? Int, tier: u["service_tier"] as? String)
        value.price()
        if var prior = models[model] {
          prior.input += value.input; prior.cached += value.cached; prior.output += value.output
          prior.cacheWrite += value.cacheWrite; prior.cacheWriteLong += value.cacheWriteLong
          prior.estimatedUSD = prior.estimatedUSD.flatMap { a in value.estimatedUSD.map { a + $0 } }
          models[model] = prior
        } else { models[model] = value }
      }
      if type == "result", let perModel = object["modelUsage"] as? [String: [String: Any]], !perModel.isEmpty {
        for (model, usage) in perModel { add(usage, model: model, claude: true) }
      } else if ["turn.completed", "result", "bz.usage"].contains(type), let usage = object["usage"] as? [String: Any],
        usage["input_tokens"] != nil && usage["output_tokens"] != nil {
        add(usage, model: object["model"] as? String ?? fallback, claude: type == "result")
      }
    }
    guard !models.isEmpty else { return nil }
    let values = models.values.sorted { $0.model < $1.model }
    var result = Self(inputTokens: values.reduce(0) { $0 + $1.input }, cachedInputTokens: values.reduce(0) { $0 + $1.cached }, outputTokens: values.reduce(0) { $0 + $1.output })
    result.byModel = values
    return result
  }
}

public struct ReviewLedger: Codable, Sendable {
  public struct Entry: Codable, Sendable {
    public var id: UUID
    public var started: Date
    public var finished: Date?
    public var harness: String
    public var outcome: String
    public var usage: ReviewUsage?
    public var requestedModel: String?
    public var evidenceCount: Int
  }
  public var entries: [Entry] = []
  public init() {}
  public mutating func reserve(harness: String, evidenceCount: Int, now: Date, model: String? = nil) -> UUID {
    entries.removeAll { now.timeIntervalSince($0.started) > 32 * 86400 }
    let id = UUID()
    entries.append(.init(id: id, started: now, harness: harness, outcome: "started", requestedModel: model, evidenceCount: evidenceCount))
    return id
  }
  public static func load(store: Store) throws -> Self {
    let path = store.root.appendingPathComponent("review-usage.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return Self() }
    return try JSONDecoder().decode(Self.self, from: store.read(path, limit: 1_048_576))
  }
  public func save(store: Store) throws {
    try store.write(JSONEncoder().encode(self), to: store.root.appendingPathComponent("review-usage.json"), limit: 1_048_576)
  }
}
