import BurnCore
import Foundation
import MCP

/// The tool surface for an Autopilot sweep. Every call goes to the running app, which
/// re-checks authority and hard rails; the model never touches processes or files itself.
enum AutopilotTools {
  static func string(_ max: Int) -> Value { .object(["type": "string", "maxLength": .int(max)]) }
  static let kinds: Value = .object(["type": "string", "enum": ["process", "worktree", "disk"]])
  static let tools: [Tool] = [
    Tool(
      name: "autopilot_catalog", title: "Read the cleanup catalog",
      description:
        "Items (zombie programs, old copies, junk folders) with their facts and current status, plus the owner's rules and open questions. Unsure items come first.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "status": .object([
            "type": "string",
            "enum": ["unsure", "burn", "keep", "protected", "burned", "failed", "all"],
          ]),
          "kind": kinds,
          "offset": .object(["type": "integer", "minimum": 0]),
          "limit": .object(["type": "integer", "minimum": 1, "maximum": 200]),
        ]), "additionalProperties": false,
      ]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)),
    Tool(
      name: "autopilot_inspect", title: "Look closely at one item",
      description:
        "Live detail for one item: a program's command line, folder, parent and ports; a copy's git status, branch and recent commits; a folder's contents and producer files.",
      inputSchema: .object([
        "type": "object", "properties": .object(["id": string(200)]), "required": ["id"],
        "additionalProperties": false,
      ]),
      annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)),
    Tool(
      name: "autopilot_decide", title: "Record verdicts",
      description:
        "Record burn, keep or unsure for items with an honest confidence (0-1), a friendly label of at most 6 words and one plain sentence of why. Returns the ids now authorized to burn.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "judgments": .object([
            "type": "array", "minItems": 1, "maxItems": 50,
            "items": .object([
              "type": "object",
              "properties": .object([
                "id": string(200),
                "verdict": .object(["type": "string", "enum": ["burn", "keep", "unsure"]]),
                "confidence": .object(["type": "number", "minimum": 0, "maximum": 1]),
                "label": string(120), "why": string(400),
              ]), "required": ["id", "verdict", "confidence", "label", "why"],
              "additionalProperties": false,
            ]),
          ])
        ]), "required": ["judgments"], "additionalProperties": false,
      ]),
      annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)),
    Tool(
      name: "autopilot_burn", title: "Burn authorized items",
      description:
        "Burn items the policy authorizes (owner rules, starter rules, or your confident verdict for eligible items). Programs get a graceful stop; old copies are saved in a restore point first; junk folders are deleted. Unauthorized items are refused with a reason. An item refused earlier for the same facts waits a few hours, and burning it again returns that reason at once.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "ids": .object([
            "type": "array", "minItems": 1, "maxItems": 50, "uniqueItems": true,
            "items": string(200),
          ])
        ]), "required": ["ids"], "additionalProperties": false,
      ]),
      annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)),
    Tool(
      name: "autopilot_ask", title: "Ask the owner one yes/no question",
      description:
        "Open a training question about a fact pattern (fact name to allowed values) that covers unsure items. One short sentence a 10-year-old understands, ending with ?. One open question per subject (old copies, each kind of program, each kind of folder); use replace to improve the open one. Say how long things sat unused (stale or idle) and never ask about things used today.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "kind": kinds,
          "match": .object([
            "type": "object",
            "additionalProperties": .object([
              "type": "array", "minItems": 1, "maxItems": 6, "items": string(60),
            ]),
          ]),
          "question": string(200), "why": string(200),
          "examples": .object(["type": "array", "maxItems": 3, "items": string(120)]),
          "replace": string(100),
        ]), "required": ["kind", "match", "question"], "additionalProperties": false,
      ]),
      annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)),
    Tool(
      name: "autopilot_report", title: "Summarize this sweep",
      description: "Two plain sentences for the owner's activity log.",
      inputSchema: .object([
        "type": "object", "properties": .object(["text": string(500)]), "required": ["text"],
        "additionalProperties": false,
      ]),
      annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)),
  ]

  static func request(_ name: String, _ arguments: [String: Value]) throws -> AutopilotRequest {
    func json(_ value: Value) throws -> Data { try JSONEncoder().encode(value) }
    switch name {
    case "autopilot_catalog":
      var r = AutopilotRequest(tool: "catalog")
      r.status = arguments["status"]?.stringValue
      r.kind = arguments["kind"]?.stringValue
      r.offset = arguments["offset"]?.intValue
      r.limit = arguments["limit"]?.intValue
      return r
    case "autopilot_inspect":
      var r = AutopilotRequest(tool: "inspect")
      r.id = arguments["id"]?.stringValue
      return r
    case "autopilot_decide":
      var r = AutopilotRequest(tool: "decide")
      guard let judgments = arguments["judgments"] else {
        throw MCPError.invalidParams("Pass judgments.")
      }
      r.judgments = try JSONDecoder().decode(
        [AutopilotJudgmentInput].self, from: json(judgments))
      return r
    case "autopilot_burn":
      var r = AutopilotRequest(tool: "burn")
      r.ids = arguments["ids"]?.arrayValue?.compactMap(\.stringValue)
      return r
    case "autopilot_ask":
      var r = AutopilotRequest(tool: "ask")
      guard let kind = arguments["kind"]?.stringValue.flatMap(AutopilotKind.init(rawValue:)),
        let question = arguments["question"]?.stringValue, let match = arguments["match"]
      else { throw MCPError.invalidParams("Pass kind, match and question.") }
      var input = AutopilotQuestionInput(
        kind: kind, match: try JSONDecoder().decode([String: [String]].self, from: json(match)),
        question: question)
      input.why = arguments["why"]?.stringValue
      input.examples = arguments["examples"]?.arrayValue?.compactMap(\.stringValue)
      r.question = input
      r.replace = arguments["replace"]?.stringValue
      return r
    case "autopilot_report":
      var r = AutopilotRequest(tool: "report")
      r.text = arguments["text"]?.stringValue
      return r
    default:
      throw MCPError.invalidParams("Unknown tool.")
    }
  }

  static func serve() async throws {
    let server = Server(
      name: "BurnZombies Autopilot", version: BuildIdentity.version,
      instructions:
        "Autopilot sweep tools. Read the catalog, inspect what is unclear, record honest verdicts, burn what is authorized, ask at most a few yes/no questions, then report. The app enforces every safety rail.",
      capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
    await server.withMethodHandler(CallTool.self) { params in
      guard tools.contains(where: { $0.name == params.name }) else {
        throw MCPError.invalidParams("Tool unavailable for this connection.")
      }
      let body = try JSONEncoder().encode(request(params.name, params.arguments ?? [:]))
      let raw = try await AgentConnection.callAsync(
        AgentRequest("autopilot", payload: String(decoding: body, as: UTF8.self)))
      let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
      let text = (object?["payload"] as? String) ?? (object?["message"] as? String) ?? raw
      return .init(
        content: [.text(text: text, annotations: nil, _meta: nil)],
        isError: object?["ok"] as? Bool != true)
    }
    try await server.start(transport: CompatibleTransport())
    await server.waitUntilCompleted()
  }
}
