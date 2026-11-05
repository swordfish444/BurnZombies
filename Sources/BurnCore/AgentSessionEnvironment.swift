import Foundation

/// The variables an agent session hands its own children: which session and client is running,
/// and the sockets and tokens that reach back into it. BZ is part of no session. An agent that
/// installs BZ starts the app from inside its own, and LaunchServices gives the app the
/// starter's environment, so without this the app and every sweep or review it starts would carry
/// that session's variables long after it ended.
public enum AgentSessionEnvironment {
  /// Set by a running Claude Code, Codex or Cursor session (or the app that hosts it) for its
  /// children.
  static let names: Set<String> = [
    "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_PROJECT_DIR", "CLAUDE_PLUGIN_ROOT",
    "AI_AGENT",
    "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_PERMISSION_PROFILE", "CODEX_SANDBOX",
    "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_ESCALATE_SOCKET", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
    "CURSOR_AGENT", "CURSOR_TRACE_ID",
  ]
  /// Families only a session or its host sets. `VSCODE_` holds the editor's IPC handles in a
  /// Cursor or VS Code terminal.
  static let prefixes = [
    "CLAUDE_CODE_", "CLAUDE_AGENT_SDK_", "MCP_", "CODEX_NETWORK_PROXY_", "VSCODE_",
  ]
  /// Set on purpose to pick an account, a cloud provider or a certificate. They share a
  /// session's prefix but stay.
  static let chosen: Set<String> = [
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH", "CLAUDE_CODE_SKIP_VERTEX_AUTH",
    "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
    "CLAUDE_CODE_CLIENT_CERT", "CLAUDE_CODE_CLIENT_KEY", "CLAUDE_CODE_CLIENT_KEY_PASSPHRASE",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
  ]

  public static func belongsToSession(_ name: String) -> Bool {
    !chosen.contains(name)
      && (names.contains(name) || prefixes.contains { name.hasPrefix($0) })
  }

  /// For a harness BZ starts: the app's environment without any session's variables. API keys,
  /// endpoints, proxies and the rest of what the person set stay.
  public static func harness(_ environment: [String: String]) -> [String: String] {
    environment.filter { !belongsToSession($0.key) }
  }

  /// For the app the CLI starts: only BZ's own settings. LaunchServices lays the starter's
  /// environment over launchd's, which supplies what a login launch has (HOME, USER, PATH,
  /// TMPDIR, SSH_AUTH_SOCK), so the app starts as it would after a restart.
  public static func login(_ environment: [String: String]) -> [String: String] {
    environment.filter { $0.key.hasPrefix("BURNZOMBIES_") || $0.key == "__CF_USER_TEXT_ENCODING" }
  }
}
