import BurnCore
import Foundation
import Darwin

/// One supervised, ephemeral Codex turn. Native protocol events expose the resolved
/// model and token counters without saving or rereading a user's conversations.
enum CodexReview {
  static func run(_ planURL: URL, probeOnly: Bool = false) throws {
    let plan = try JSONDecoder().decode(CodexReviewPlan.self, from: Data(contentsOf: planURL))
    // Replace the entire optional MCP table before configuration validation;
    // disabled legacy entries can still use transports unsupported by this CLI.
    // The sole per-review server is then added by the plan. Live config is untouched.
    let config = ["mcp_servers={}"] + plan.overrides
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: plan.executable)
    process.arguments = ["app-server", "--stdio"] + config.flatMap { ["-c", $0] }
    var environment = ProcessInfo.processInfo.environment
    environment["RUST_LOG"] = "error"
    process.environment = environment
    process.currentDirectoryURL = planURL.deletingLastPathComponent()
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
    try process.run()
    defer {
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      // The outer native supervisor also reaps this entire owned group.
    }
    var buffer = Data(), nextID = 0, model = "Unreported model", tier: String?
    var threadID: String?, total = [String: Int]()
    func send(_ object: [String: Any]) throws {
      try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    func emit(_ object: [String: Any]) throws {
      FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10]))
    }
    func next() throws -> [String: Any] {
      while true {
        if let newline = buffer.firstIndex(of: 10) {
          let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
          guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
          return object
        }
        let chunk = output.fileHandleForReading.availableData
        guard !chunk.isEmpty else { throw StoreError.message("Codex review transport closed before completion.") }
        buffer.append(chunk)
        guard buffer.count <= 1_048_576 else { throw StoreError.message("Codex review transport exceeded its output bound.") }
      }
    }
    func event(_ object: [String: Any]) throws {
      guard let method = object["method"] as? String else { return }
      let p = object["params"] as? [String: Any] ?? [:]
      if let id = object["id"] {
        // No interactive approval, elicitation, shell or file permission is granted by this client.
        try send(["id": id, "error": ["code": -32601, "message": "Unattended BurnZombies review cannot answer interactive requests."]])
        throw StoreError.message("Codex requested interactive input. Review paused.")
      }
      if method == "model/rerouted" {
        throw StoreError.message("Codex proposed a model reroute. Review paused without switching models.")
      }
      if method == "thread/tokenUsage/updated", p["threadId"] as? String == threadID,
        let usage = p["tokenUsage"] as? [String: Any], let values = usage["total"] as? [String: Any] {
        let fields = ["inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens"]
        var delta = [String: Int]()
        for field in fields {
          let value = values[field] as? Int ?? 0
          guard value >= (total[field] ?? 0), value <= 100_000_000 else { throw StoreError.message("Codex usage counters reset or exceeded their bound.") }
          delta[field] = value - (total[field] ?? 0)
        }
        total = fields.reduce(into: [:]) { $0[$1] = values[$1] as? Int ?? 0 }
        if delta.values.contains(where: { $0 > 0 }) {
          var normalized: [String: Any] = ["input_tokens": delta["inputTokens"]!, "cached_input_tokens": delta["cachedInputTokens"]!,
            "cache_creation_input_tokens": delta["cacheWriteInputTokens"]!, "output_tokens": delta["outputTokens"]!]
          if let last = usage["last"] as? [String: Any], let context = last["inputTokens"] as? Int { normalized["context_tokens"] = context }
          if let tier { normalized["service_tier"] = tier }
          try emit(["type": "bz.usage", "model": model, "event_id": UUID().uuidString, "usage": normalized])
        }
      }
      if method == "item/completed", let item = p["item"] as? [String: Any] {
        if item["type"] as? String == "mcpToolCall" {
          try emit(["type": "bz.tool", "name": item["tool"] as? String ?? "unknown", "status": item["status"] as? String ?? "unknown"])
        } else if item["type"] as? String == "agentMessage", let message = item["text"] as? String {
          try emit(["type": "bz.result", "text": PassiveSession.excerpt(message)])
        }
      }
      if method == "error" { throw StoreError.message("Codex reported a review error; no automatic retry.") }
    }
    func rpc(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
      nextID += 1; let id = nextID
      try send(["id": id, "method": method, "params": params])
      while true {
        let object = try next()
        if object["id"] as? Int == id {
          guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
            throw StoreError.message("Codex rejected \(method): \(String(describing: object["error"]).prefix(800))")
          }
          return result
        }
        try event(object)
      }
    }
    _ = try rpc("initialize", ["clientInfo": ["name": "burnzombies", "version": "0.9.0"], "capabilities": ["experimentalApi": true]])
    try send(["method": "initialized"])
    var start: [String: Any] = ["cwd": planURL.deletingLastPathComponent().path, "ephemeral": true,
      "approvalPolicy": "on-request", "approvalsReviewer": "auto_review", "sandbox": "workspace-write",
      "baseInstructions": MachineReviewer.prompt]
    if let selected = plan.model { start["model"] = selected }
    let response = try rpc("thread/start", start)
    guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String,
      let resolved = response["model"] as? String else { throw StoreError.message("Codex did not report its review model.") }
    threadID = id; model = resolved; tier = response["serviceTier"] as? String
    try emit(["type": "bz.model", "model": resolved, "reasoning": plan.effort ?? response["reasoningEffort"] as? String ?? "default"])
    if probeOnly { return }
    var turn: [String: Any] = ["threadId": id, "input": [["type": "text", "text": plan.prompt]]]
    if let effort = plan.effort { turn["effort"] = effort }
    _ = try rpc("turn/start", turn)
    while true {
      let object = try next(); try event(object)
      if object["method"] as? String == "turn/completed", let p = object["params"] as? [String: Any], p["threadId"] as? String == id {
        guard let completed = p["turn"] as? [String: Any], completed["status"] as? String == "completed" else {
          throw StoreError.message("Codex review did not complete. Recorded partial usage is retained.")
        }
        return
      }
    }
  }
  private static func quote(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self).dropFirst().dropLast().description
  }
}
