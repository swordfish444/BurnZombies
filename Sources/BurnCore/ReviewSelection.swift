import Foundation

extension MachineReviewConfiguration {
  public var harnessName: String {
    ["codex": "Codex", "claude": "Claude Code", "cursor": "Cursor", "copilot": "GitHub Copilot", "gemini": "Gemini"][harness] ?? harness
  }
  public var thinkingLevels: [String] {
    switch harness {
    case "codex": return ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    case "claude", "copilot": return ["low", "medium", "high", "xhigh", "max"]
    default: return [] // These adapters expose model selection, not a separate effort flag.
    }
  }
  public static func selectionValue(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == "default" ? nil : trimmed
  }
  public func validateSelection() throws {
    if let model {
      let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:@+")
      guard !model.isEmpty, model.count <= 160, !model.hasPrefix("-"), model.unicodeScalars.allSatisfy(allowed.contains) else {
        throw StoreError.message("Use a model ID or leave Model empty for the harness default.")
      }
    }
    if let reasoningEffort, !thinkingLevels.contains(reasoningEffort) {
      throw StoreError.message("This thinking level is not supported by the \(harnessName) adapter.")
    }
  }
  public var selectionArguments: [String] {
    var args = model.map { ["--model", $0] } ?? []
    if let reasoningEffort {
      switch harness {
      case "codex": args += ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""]
      case "claude": args += ["--effort", reasoningEffort]
      case "copilot": args += ["--reasoning-effort", reasoningEffort]
      default: break
      }
    }
    return args
  }
  /// Reload at Save so a draft never overwrites a changed provider or enabled state.
  public static func saveSelection(root: URL, expectedHarness: String, model: String, thinking: String) throws -> Self {
    guard var current = try load(root: root), current.harness == expectedHarness else {
      throw StoreError.message("The review harness changed. Reopen Settings before saving.")
    }
    current.model = selectionValue(model)
    current.reasoningEffort = selectionValue(thinking)
    try current.save(root: root)
    return current
  }
}

/// Suggestions from Codex's local catalog; no model invocation or global config writes.
/// Custom IDs remain possible when the catalog is missing or a new model is available.
public struct ReviewModelOption: Decodable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let efforts: [String]
  private let priority: Int
  private let visibility: String
  enum CodingKeys: String, CodingKey {
    case id = "slug", name = "display_name", levels = "supported_reasoning_levels", priority, visibility
  }
  private struct Level: Decodable { let effort: String }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
    efforts = try c.decodeIfPresent([Level].self, forKey: .levels)?.map(\.effort) ?? []
    priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 999
    visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "list"
  }
  public static func decode(_ data: Data) throws -> [Self] {
    struct Catalog: Decodable { let models: [ReviewModelOption] }
    guard data.count <= 8 * 1024 * 1024 else { throw StoreError.message("Model catalog is oversized.") }
    var seen = Set<String>()
    return try JSONDecoder().decode(Catalog.self, from: data).models
      .filter { $0.visibility == "list" && $0.id.count <= 160 && $0.name.count <= 160 && seen.insert($0.id).inserted }
      .sorted { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
  }
  public static func localCodexCatalog() -> [Self] {
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let url = home.appendingPathComponent("models_cache.json")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 8 * 1024 * 1024 + 1) else { return [] }
    return (try? decode(data)) ?? []
  }
}
