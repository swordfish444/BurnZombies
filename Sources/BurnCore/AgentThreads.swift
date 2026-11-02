import Foundation

/// One agent chat (Claude Code or Codex session) and the folder it works in. Threads let
/// Autopilot tell a helper or copy whose chat is still alive from one whose chat ended.
public struct AgentThread: Codable, Sendable, Equatable {
  public var id: String
  /// `claude` or `codex`.
  public var agent: String
  public var cwd: String
  public var live: Bool
  public var pid: Int32?
  public var title: String?
  public var lastActive: Date
  public init(
    id: String, agent: String, cwd: String, live: Bool, pid: Int32? = nil, title: String? = nil,
    lastActive: Date
  ) {
    self.id = id
    self.agent = agent
    self.cwd = cwd
    self.live = live
    self.pid = pid
    self.title = title
    self.lastActive = lastActive
  }
}

public enum AgentThreads {
  /// Indexes Claude Code and Codex sessions under `home`. Bounded and read-only.
  public static func index(home: String = NSHomeDirectory(), now: Date = Date()) -> [AgentThread] {
    []
  }

  /// `live` when a live thread works inside `path`, `ended` when only finished threads did,
  /// `none` otherwise. Also returns the newest activity among matching threads.
  public static func state(for path: String, threads: [AgentThread]) -> (
    thread: String, lastActive: Date?
  ) {
    let root = path.hasSuffix("/") ? path : path + "/"
    let matching = threads.filter { $0.cwd == path || $0.cwd.hasPrefix(root) }
    guard !matching.isEmpty else { return ("none", nil) }
    return (matching.contains(where: \.live) ? "live" : "ended", matching.map(\.lastActive).max())
  }
}
