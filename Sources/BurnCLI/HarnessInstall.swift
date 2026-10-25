import Foundation

enum HarnessInstall {
  static let clients = ["codex", "claude", "cursor", "copilot", "gemini"]
  static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  static func run(_ args: [String]) throws {
    func option(_ name: String, fallback: String) throws -> String {
      guard let i = args.firstIndex(of: name) else { return fallback }
      guard i + 1 < args.count else { throw NSError(domain: "Missing \(name)", code: 1) }
      return args[i + 1]
    }
    let home = URL(fileURLWithPath: try option("--home", fallback: NSHomeDirectory()), isDirectory: true)
    let selected = try option("--harness", fallback: "auto")
    let checkpoints = try option("--checkpoints", fallback: "on")
    guard ["on", "off"].contains(checkpoints) else { throw NSError(domain: "Use --checkpoints on or off", code: 1) }
    if !args.contains("--home") {
      for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "GEMINI_CLI_HOME", "COPILOT_HOME"] {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
          throw NSError(domain: "Custom harness root \(key) is set. Configuration preserved; install into that root explicitly.", code: 1)
        }
      }
    }
    guard clients.contains(selected) || ["auto", "all", "none"].contains(selected) else {
      throw NSError(domain: "Choose auto, all, codex, claude, cursor, copilot, gemini or none", code: 1)
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let server = executable.deletingLastPathComponent().appendingPathComponent("burnzombies-mcp").path
    let bundledSkill = executable.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/burnzombies/SKILL.md").path
    let skill = try String(contentsOfFile: option("--skill-file", fallback: bundledSkill), encoding: .utf8)
    let fm = FileManager.default
    let directories = ["codex": ".codex", "claude": ".claude", "cursor": ".cursor", "copilot": ".copilot", "gemini": ".gemini"]
    let applications = ["codex": "Codex.app", "claude": "Claude.app", "cursor": "Cursor.app"]
    let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let chosen = clients.filter { client in
      if selected == "all" || selected == client { return true }
      if selected != "auto" { return false }
      if fm.fileExists(atPath: home.appendingPathComponent(directories[client]!).path) { return true }
      if let app = applications[client], fm.fileExists(atPath: "/Applications/" + app) { return true }
      return pathEntries.contains { fm.isExecutableFile(atPath: $0 + "/" + (client == "cursor" ? "agent" : client)) }
    }
    if chosen.isEmpty { print("App installed. No local harness detected."); return }

    // Prepare every edit first. Invalid/conflicting input leaves all configurations unchanged.
    var writes: [URL: Data] = [:]
    func read(_ relative: String) throws -> Data? {
      let url = home.appendingPathComponent(relative)
      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
      guard values?.isSymbolicLink != true else { throw NSError(domain: "Refusing config symlink: \(relative)", code: 1) }
      if !fm.fileExists(atPath: url.path) { return nil }
      guard (values?.fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw NSError(domain: "Oversized config: \(relative)", code: 1) }
      return try Data(contentsOf: url)
    }
    func editJSON(_ relative: String, _ transform: (inout [String: Any]) throws -> Void) throws {
      let url = home.appendingPathComponent(relative)
      let data = try writes[url] ?? read(relative)
      var object: [String: Any] = [:]
      if let data {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw NSError(domain: "Expected JSON object in \(relative)", code: 1)
        }
        object = decoded
      }
      try transform(&object)
      writes[url] = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
    }
    func addServer(_ relative: String, key: String = "mcpServers", extra: [String: Any] = [:]) throws {
      try editJSON(relative) { object in
        if object[key] != nil && !(object[key] is [String: Any]) { throw NSError(domain: "Invalid \(key) in \(relative)", code: 1) }
        var servers = object[key] as? [String: Any] ?? [:]
        if let existing = servers["burnzombies"] {
          guard let config = existing as? [String: Any], config["command"] as? String == server else {
            throw NSError(domain: "Existing burnzombies entry uses a different command in \(relative); preserved", code: 1)
          }
        } else {
          var config = extra; config["command"] = server; config["args"] = [String]()
          servers["burnzombies"] = config; object[key] = servers
        }
      }
    }
    func addHooks(_ relative: String, client: String, event: String, flat: Bool = false) throws {
      try editJSON(relative) { object in
        if client == "cursor" || client == "copilot" { object["version"] = object["version"] ?? 1 }
        if object["hooks"] != nil && !(object["hooks"] is [String: Any]) { throw NSError(domain: "Invalid hooks in \(relative)", code: 1) }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        func owned(_ handler: [String: Any]) -> Bool {
          if handler["type"] as? String == "mcp_tool", handler["server"] as? String == "burnzombies",
            handler["tool"] as? String == "burnzombies_checkpoint" { return true }
          guard let command = handler["command"] as? String else { return false }
          let prefix = quoted(executable.path) + " hook --client \(client) --event "
          return ["SessionStart", "sessionStart", "PostToolUse", "postToolUse", "Stop", "AfterTool"].contains { oldEvent in
            command == prefix + oldEvent
          }
        }
        // Upgrade only our exact handlers. Keep unrelated hooks, matchers and permissions.
        for key in Array(hooks.keys) {
          guard let entries = hooks[key] as? [[String: Any]] else { throw NSError(domain: "Invalid \(key) hooks", code: 1) }
          var kept = [[String: Any]]()
          for var entry in entries {
            if let handlers = entry["hooks"] as? [[String: Any]] {
              let remaining = handlers.filter { !owned($0) }
              if !remaining.isEmpty { entry["hooks"] = remaining; kept.append(entry) }
            } else if !owned(entry) { kept.append(entry) }
          }
          if kept.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = kept }
        }
        if checkpoints == "on" {
          let handler: [String: Any]
          if client == "codex" || client == "claude" {
            handler = ["type": "mcp_tool", "server": "burnzombies", "tool": "burnzombies_checkpoint",
              "input": ["client": client, "tool_name": "${tool_name}"], "timeout": 1]
          } else {
            handler = ["type": "command", "command": quoted(executable.path) + " hook --client " + client + " --event " + event, "timeout": 1]
          }
          var entries = hooks[event] as? [[String: Any]] ?? []
          entries.append(flat ? handler : ["hooks": [handler]])
          hooks[event] = entries
        }
        object["hooks"] = hooks
      }
    }
    for client in chosen {
      let skillRoot = client == "codex" ? ".agents" : directories[client]!
      let skillPath = skillRoot + "/skills/burnzombies/SKILL.md"
      if let old = try read(skillPath), !String(decoding: old, as: UTF8.self).contains("name: burnzombies") {
        throw NSError(domain: "Unrelated skill already occupies \(skillPath)", code: 1)
      }
      writes[home.appendingPathComponent(skillPath)] = Data(skill.utf8)
      switch client {
      case "codex":
        let relative = ".codex/config.toml"
        let previous = String(decoding: try read(relative) ?? Data(), as: UTF8.self)
        if previous.range(of: #"(?m)^\s*\[mcp_servers\.(?:burnzombies|"burnzombies"|'burnzombies')\]"#, options: .regularExpression) != nil {
          // Never rewrite a user's TOML. The existing installed command is stable across upgrades.
          let section = previous.components(separatedBy: .newlines).drop(while: { !$0.contains("[mcp_servers.") || !$0.contains("burnzombies") }).dropFirst().prefix(while: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }).joined(separator: "\n")
          let encodedCommand = String(decoding: try JSONSerialization.data(withJSONObject: [server], options: .withoutEscapingSlashes), as: UTF8.self).dropFirst().dropLast()
          let expectedCommand = "command = " + encodedCommand
          guard section.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces) == expectedCommand }) else { throw NSError(domain: "Existing Codex BurnZombies config uses a different path; preserved", code: 1) }
        } else {
          guard !previous.contains("mcp_servers.burnzombies") else { throw NSError(domain: "Nonstandard Codex BurnZombies config; preserved", code: 1) }
          let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [server], options: .withoutEscapingSlashes), as: UTF8.self).dropFirst().dropLast()
          writes[home.appendingPathComponent(relative)] = Data((previous + "\n[mcp_servers.burnzombies]\ncommand = \(encoded)\nargs = []\n").utf8)
        }
        try addHooks(".codex/hooks.json", client: client, event: "PostToolUse")
      case "claude":
        try addServer(".claude.json", extra: ["type": "stdio"])
        try addHooks(".claude/settings.json", client: client, event: "PostToolUse")
      case "cursor":
        try addServer(".cursor/mcp.json")
        try addHooks(".cursor/hooks.json", client: client, event: "postToolUse", flat: true)
      case "copilot":
        try addServer(".copilot/mcp-config.json", extra: ["type": "local", "tools": ["*"]])
        try addHooks(".copilot/hooks/burnzombies.json", client: client, event: "postToolUse", flat: true)
      case "gemini":
        try addServer(".gemini/settings.json")
        try addHooks(".gemini/settings.json", client: client, event: "AfterTool")
      default: break
      }
    }
    var originals: [URL: Data] = [:]
    var created = [URL]()
    do {
      for (url, data) in writes.sorted(by: { $0.key.path < $1.key.path }) {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
          let old = try Data(contentsOf: url)
          if old == data { continue }
          originals[url] = old
          let backup = url.appendingPathExtension("burnzombies-backup-" + UUID().uuidString)
          try old.write(to: backup, options: .atomic)
          try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } else { created.append(url) }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    } catch {
      for (url, data) in originals { try? data.write(to: url, options: .atomic) }
      for url in created { try? fm.removeItem(at: url) }
      throw error
    }
    print("Installed MCP and skill for: " + chosen.joined(separator: ", "))
    print("No computer restart. Existing sessions may need their harness's MCP/skill reload. New sessions discover the integration.")
    if checkpoints == "on" { print("One quiet checkpoint per harness. Codex/Claude reuse MCP; no startup hooks or Stop hooks. First-use hook trust remains with the harness.") }
    else { print("Checkpoints disabled. Your agent can use the skill and MCP tools on demand.") }
    print("Ask your agent: Tame the horde with BurnZombies and keep this session healthy.")
  }
}
