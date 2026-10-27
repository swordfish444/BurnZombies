import CryptoKit
import Foundation

/// Dispatch facts only. The model still decides whether released work is disposable.
public struct ReviewEvidence: Codable, Equatable, Sendable {
  public var id: String
  public var revision: String
  public var processCount: Int
  public init(id: String, revision: String, processCount: Int = 1) {
    self.id = id; self.revision = revision; self.processCount = processCount
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
    for workspace in catalog.workspaces ?? [] where workspace.state == "released" {
      result.append(.init(id: workspace.id, revision: digest(workspace.id + "|" + String(workspace.updated.timeIntervalSinceReferenceDate)), processCount: 0))
    }
    return result.sorted { $0.id < $1.id }
  }
  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct ReviewUsage: Codable, Sendable {
  public var inputTokens: Int
  public var cachedInputTokens: Int
  public var outputTokens: Int
  public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens; self.outputTokens = outputTokens
  }
  public static func parse(_ data: Data) -> Self? {
    var total = Self(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0)
    var found = false
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let usage = object["usage"] as? [String: Any],
        let input = usage["input_tokens"] as? Int, let output = usage["output_tokens"] as? Int,
        input >= 0, output >= 0 else { continue }
      found = true
      let cacheRead = (usage["cached_input_tokens"] as? Int) ?? (usage["cache_read_input_tokens"] as? Int) ?? 0
      let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
      // Codex input includes cached input; Claude reports cache input separately.
      total.inputTokens += input + (object["type"] as? String == "result" ? cacheRead + cacheWrite : 0)
      total.cachedInputTokens += max(0, cacheRead)
      total.outputTokens += output
    }
    return found ? total : nil
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
    public var evidenceCount: Int
  }
  public var entries: [Entry] = []
  public init() {}
  public static let maximumReviews = 8
  public static let inputTokenLimit = 200_000
  public func limitReason(now: Date) -> String? {
    let recent = entries.filter { now.timeIntervalSince($0.started) < 86400 }
    if recent.count >= Self.maximumReviews { return "Daily review limit reached (8 per rolling 24 hours). Observation continues." }
    if recent.reduce(0, { $0 + ($1.usage?.inputTokens ?? 0) }) >= Self.inputTokenLimit {
      return "Daily review token threshold reached. Observation continues; no further reviews today."
    }
    return nil
  }
  public mutating func reserve(harness: String, evidenceCount: Int, now: Date) -> UUID {
    entries.removeAll { now.timeIntervalSince($0.started) > 7 * 86400 }
    let id = UUID()
    entries.append(.init(id: id, started: now, harness: harness, outcome: "started", evidenceCount: evidenceCount))
    return id
  }
  public static func load(store: Store) throws -> Self {
    let path = store.root.appendingPathComponent("review-usage.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return Self() }
    return try JSONDecoder().decode(Self.self, from: store.read(path, limit: 131072))
  }
  public func save(store: Store) throws {
    try store.write(JSONEncoder().encode(self), to: store.root.appendingPathComponent("review-usage.json"), limit: 131072)
  }
}
