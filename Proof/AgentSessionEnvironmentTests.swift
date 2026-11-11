import BurnCore
import Darwin
import Foundation

/// An agent that installs BZ starts it from inside its own session. The app used to pass that
/// session's variables (its id, the socket and token that reach back into it, "you are inside
/// Claude Code") on to every sweep and review it started. They now start without them, and keep
/// what the person set on purpose.
func agentSessionEnvironmentProof() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("bz-session-env-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  // Invented values standing in for what an agent's session hands the installer.
  let session = [
    "CLAUDECODE": "1",
    "CLAUDE_CODE_SESSION_ID": "fixture-session",
    "CLAUDE_CODE_ENTRYPOINT": "fixture",
    "CLAUDE_CODE_MESSAGING_SOCKET": root.appendingPathComponent("session.sock").path,
    "CLAUDE_CODE_MESSAGING_TOKEN": "fixture-token",
    "CLAUDE_PID": "1",
    "MCP_TIMEOUT": "1",
    "AI_AGENT": "fixture-agent",
    "CODEX_THREAD_ID": "fixture-thread",
    "CODEX_SANDBOX": "seatbelt",
    "CODEX_ESCALATE_SOCKET": root.appendingPathComponent("escalate.sock").path,
    "CURSOR_AGENT": "1",
    "VSCODE_IPC_HOOK_CLI": root.appendingPathComponent("editor.sock").path,
    "ANTIGRAVITY_AGENT": "1",
    "AGY_BROWSER_WS_URL": "ws://127.0.0.1:9",
  ]
  // What a person sets on purpose for their harness stays.
  let chosen = [
    "CLAUDE_CODE_OAUTH_TOKEN": "fixture-oauth",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "ANTHROPIC_BASE_URL": "https://gateway.invalid",
    "CODEX_HOME": root.appendingPathComponent("codex-home").path,
  ]
  let fixture = session.merging(chosen) { first, _ in first }
  let previous = fixture.keys.map { ($0, getenv($0).map { String(cString: $0) }) }
  defer {
    for (name, value) in previous {
      if let value { setenv(name, value, 1) } else { unsetenv(name) }
    }
  }
  for (name, value) in fixture { setenv(name, value, 1) }
  equal(
    ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"], "fixture-session",
    "The fixture session is in this process's environment")

  // A harness that writes down the environment it was started with.
  let dump = root.appendingPathComponent("harness-environment")
  let harness = root.appendingPathComponent("harness")
  try Data("#!/bin/sh\n/usr/bin/env > '\(dump.path)'\n".utf8).write(to: harness)
  try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: harness.path)
  let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("burnzombies").path
  guard fm.isExecutableFile(atPath: cli) else {
    failTest("Build burnzombies beside BurnProof first: \(cli)")
    return
  }
  let config = MachineReviewConfiguration(
    harness: "claude", executable: harness.path, launcher: cli,
    server: URL(fileURLWithPath: cli).deletingLastPathComponent()
      .appendingPathComponent("burnzombies-mcp").path)
  func started(_ label: String, _ run: () throws -> Void) throws -> [String: String] {
    try? fm.removeItem(at: dump)
    try run()
    guard let text = try? String(contentsOf: dump, encoding: .utf8) else {
      failTest("\(label): the harness never started")
      return [:]
    }
    var seen = [String: String]()
    for line in text.split(separator: "\n") {
      guard let equals = line.firstIndex(of: "=") else { continue }
      seen[String(line[..<equals])] = String(line[line.index(after: equals)...])
    }
    for name in session.keys.sorted() {
      checkFalse(seen[name] != nil, "\(label) started inside the installer's session: \(name)")
    }
    for (name, value) in chosen.sorted(by: { $0.key < $1.key }) {
      equal(seen[name], value, "\(label) keeps \(name), set on purpose")
    }
    equal(seen["BURNZOMBIES_HOME"], root.path, "\(label) uses BZ's own home")
    return seen
  }
  let sweep = try started("An Autopilot sweep") {
    _ = try AutopilotHarness.run(config, root: root, timeout: 30)
  }
  // BZ's own settings for the sweep share a session prefix and are set after the cleanup.
  equal(sweep["CLAUDE_CODE_DISABLE_CLAUDE_MDS"], "1", "The sweep still skips CLAUDE.md files")
  equal(sweep["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1", "The sweep still skips auto memory")
  _ = try started("A machine review") {
    try MachineReviewer.execute(
      config, root: root, prompt: "fixture", timeout: 30, accessCheck: fixtureAccess)
  }

  // Where the line falls: a session's own state goes; accounts, providers and config stay.
  for name in ["CLAUDE_CODE_SSE_PORT", "CLAUDE_AGENT_SDK_VERSION", "CODEX_NETWORK_PROXY_ACTIVE"] {
    check(AgentSessionEnvironment.belongsToSession(name), "\(name) belongs to a session")
  }
  for name in [
    "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY", "CURSOR_API_KEY", "CLAUDE_CONFIG_DIR",
    "CODEX_HOME", "CLAUDE_CODE_USE_VERTEX", "BURNZOMBIES_HOME", "PATH", "HTTPS_PROXY",
  ] {
    checkFalse(AgentSessionEnvironment.belongsToSession(name), "\(name) was set on purpose")
  }
  // The app the installer starts gets BZ's own settings and nothing else of the installer's;
  // launchd supplies HOME, PATH and the rest, as at login.
  let installer = fixture.merging([
    "BURNZOMBIES_HOME": root.path, "HOME": root.path, "PATH": root.path,
    "HTTPS_PROXY": "http://127.0.0.1:9",
  ]) { first, _ in first }
  equal(
    AgentSessionEnvironment.login(installer), ["BURNZOMBIES_HOME": root.path],
    "The observer starts with only BZ's own settings")
}
