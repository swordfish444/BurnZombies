import Darwin
import Foundation

/// Live process details Autopilot reads while cataloging. Injectable for proofs.
public struct AutopilotProcessProbe: Sendable {
  public var listening: @Sendable (Int32) -> Bool?
  public var agent: @Sendable (Int32) -> String?
  public var cwd: @Sendable (Int32) -> String?
  public var alive: @Sendable (Int32) -> Bool
  public init(
    listening: @escaping @Sendable (Int32) -> Bool?, agent: @escaping @Sendable (Int32) -> String?,
    cwd: @escaping @Sendable (Int32) -> String?, alive: @escaping @Sendable (Int32) -> Bool
  ) {
    self.listening = listening
    self.agent = agent
    self.cwd = cwd
    self.alive = alive
  }
  public static let live = AutopilotProcessProbe(
    listening: { Native().listening($0) }, agent: { Native().agent($0) },
    cwd: { Native().currentDirectory($0) },
    alive: { pid in
      if case .found = Native().probe(pid) { return true }
      return false
    })
}

/// Zombies: processes reparented to launchd whose job or chat ended. Only these orphan
/// roots become items; their live descendants are burned with them.
public enum AutopilotProcesses {
  static let protectedNames: Set<String> = [
    "launchd", "kernel_task", "login", "WindowServer", "sshd", "ssh-agent", "gpg-agent",
    "security", "op", "codex", "claude", "gemini", "copilot", "cursor-agent", "burnzombies",
    "burnzombies-mcp", "BurnZombiesApp", "tmux", "screen", "mosh-server", "caffeinate",
  ]
  static let systemPrefixes = [
    "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
  ]

  /// Hard rails for one process. A non-nil reason means it is never burned.
  public static func rail(
    _ record: Record, protectedPIDs: Set<Int32>, preferences: Preferences, now: Date = Date(),
    home: String = NSHomeDirectory()
  ) -> String? {
    let o = record.latest
    if o.uid != getuid() || o.identity.pid <= 1 || protectedPIDs.contains(o.identity.pid) {
      return "It belongs to macOS or to BurnZombies itself."
    }
    if record.protection || preferences.protectedExecutables.contains(o.executable)
      || (record.ignoreUntil.map { $0 > now } ?? false)
    {
      return "You asked me to keep it."
    }
    if o.zombie { return "It already exited. macOS cleans it up by itself." }
    if !o.metricsValid || o.executable.isEmpty || record.missingSince != nil {
      return "I can't see it clearly enough to be sure."
    }
    if systemPrefixes.contains(where: o.executable.hasPrefix) { return "It's part of macOS." }
    if protectedNames.contains(o.name) { return "It's an agent or a system helper you rely on." }
    if bundled(o.executable, home: home) { return "It's part of an app you use." }
    return nil
  }

  /// Binaries inside app, XPC or extension bundles are protected unless the bundle lives
  /// in a known automation cache (Playwright/Puppeteer browsers, node_modules, temp).
  static func bundled(_ path: String, home: String) -> Bool {
    guard [".app/Contents/", ".xpc/Contents/", ".appex/Contents/"].contains(where: path.contains)
    else { return false }
    let automation = [
      home + "/Library/Caches/ms-playwright/", home + "/.cache/ms-playwright/",
      home + "/.cache/puppeteer/", home + "/Library/Caches/puppeteer/", "/private/var/folders/",
      "/private/tmp/", "/tmp/",
    ]
    return !(automation.contains(where: path.hasPrefix) || path.contains("/node_modules/"))
  }

  public static func family(_ executable: String) -> String {
    let path = executable.lowercased()
    let name = URL(fileURLWithPath: path).lastPathComponent
    if ["node", "nodejs", "bun", "deno", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node",
      "next-server"].contains(name)
    {
      return "node"
    }
    if name.hasPrefix("python") || ["uvicorn", "gunicorn", "pytest", "uv", "celery"].contains(name)
      || name.hasPrefix("jupyter")
    {
      return "python"
    }
    if ["ruby", "rails", "bundle", "puma", "sidekiq"].contains(name) { return "ruby" }
    if name == "java" || name.hasPrefix("kotlin") || path.contains("/gradle") { return "java" }
    if path.contains("ms-playwright") || path.contains("puppeteer")
      || ["chromium", "chrome", "chrome-headless-shell", "firefox", "msedge"].contains(name)
      || name.contains("google chrome for testing") || name.contains("chromium helper")
    {
      return "browser"
    }
    if ["esbuild", "swc", "tsc", "cargo", "rustc", "clang", "swift-frontend", "swift-build",
      "xcodebuild", "make", "cmake", "ninja", "go", "watchman", "turbo", "sourcekit-lsp",
      "gopls", "rust-analyzer"].contains(name)
    {
      return "build"
    }
    if ["sh", "bash", "zsh", "fish", "dash"].contains(name) { return "shell" }
    return "other"
  }

  static func idle(_ since: TimeInterval) -> String {
    switch since {
    case ..<600: return "active"
    case ..<3600: return "10m"
    case ..<21600: return "1h"
    case ..<86400: return "6h"
    default: return "1d"
    }
  }

  static func memory(_ bytes: UInt64) -> String {
    bytes < 100 << 20 ? "small" : bytes < 1 << 30 ? "medium" : "large"
  }

  /// Folder name of the git checkout containing `path`, or nil.
  public static func repository(_ path: String) -> String? {
    var url = URL(fileURLWithPath: path)
    for _ in 0..<24 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
        return url.lastPathComponent
      }
      let parent = url.deletingLastPathComponent()
      guard parent.path != url.path else { return nil }
      url = parent
    }
    return nil
  }

  /// Every live descendant of `root`, deepest first.
  public static func descendants(of root: Int32, in records: [String: Record]) -> [Record] {
    var children = [Int32: [Record]]()
    for r in records.values where r.missingSince == nil {
      children[r.latest.parent, default: []].append(r)
    }
    var result = [Record]()
    var frontier = [root]
    var seen: Set<Int32> = [root]
    while let next = frontier.popLast() {
      for child in children[next] ?? [] where seen.insert(child.latest.identity.pid).inserted {
        result.append(child)
        frontier.append(child.latest.identity.pid)
      }
    }
    return result.reversed()
  }

  static func idleSince(_ r: Record, now: Date) -> TimeInterval {
    now.timeIntervalSince(r.lastBusy ?? r.firstSeen)
  }

  public static func items(
    _ records: [String: Record], threads: [AgentThread], protectedPIDs: Set<Int32>,
    launchAgents: Set<Int32> = [], preferences: Preferences = Preferences(), now: Date = Date(),
    probe: AutopilotProcessProbe = .live, home: String = NSHomeDirectory()
  ) -> [AutopilotItem] {
    var items = [AutopilotItem]()
    for record in records.values where record.missingSince == nil {
      let o = record.latest
      guard o.parent == 1, o.uid == getuid(), !o.zombie, o.identity.pid != getpid(),
        !launchAgents.contains(o.identity.pid)
      else { continue }
      var reason = rail(
        record, protectedPIDs: protectedPIDs, preferences: preferences, now: now, home: home)
      // macOS services, apps, harnesses and unreadable processes are not leftovers at all.
      if let reason, reason != "You asked me to keep it." { continue }
      let tree = descendants(of: o.identity.pid, in: records)
      let members = [record] + tree
      if reason == nil,
        tree.contains(where: {
          rail($0, protectedPIDs: protectedPIDs, preferences: preferences, now: now, home: home)
            != nil
        })
      {
        reason = "Part of it is something I must not touch."
      }
      let cwd = probe.cwd(o.identity.pid)
      let thread = cwd.map { AgentThreads.state(for: $0, threads: threads).thread } ?? "none"
      if reason == nil, thread == "live" { reason = "A chat is still working in this project." }
      let listening: String = {
        var unknown = false
        for member in members {
          switch probe.listening(member.latest.identity.pid) {
          case true?: return "yes"
          case nil: unknown = true
          default: break
          }
        }
        return unknown ? "unknown" : "no"
      }()
      let leaderGone =
        o.pgid.map { $0 > 1 && $0 != o.identity.pid && !probe.alive($0) } ?? false
      let orphaned = record.orphanSince != nil || leaderGone ? "yes" : "maybe"
      let quiet = members.map { idleSince($0, now: now) }.min() ?? 0
      let bytes = members.reduce(0) { $0 + $1.latest.rss }
      let repo = cwd.flatMap(repository) ?? "none"
      let program = o.name.lowercased()
      let facts = [
        "program": program, "family": family(o.executable), "orphaned": orphaned,
        "thread": thread, "agent": probe.agent(o.identity.pid) ?? "none",
        "idle": idle(quiet), "listening": listening, "memory": memory(bytes), "repo": repo,
      ]
      items.append(
        AutopilotItem(
          id: "process:" + o.identity.key, kind: .process,
          name: repo == "none" ? o.name : o.name + " in " + repo,
          detail: describe(o.name, repo: repo, facts: facts, children: tree.count),
          path: o.executable, bytes: bytes, facts: facts, protectedReason: reason,
          observedAt: o.time, pid: o.identity.pid, processKey: o.identity.key))
    }
    return items.sorted { $0.bytes > $1.bytes }
  }

  static func describe(_ name: String, repo: String, facts: [String: String], children: Int)
    -> String
  {
    let idle =
      [
        "active": "is still doing work", "10m": "has been idle for a few minutes",
        "1h": "has been idle for over an hour", "6h": "has been idle for over 6 hours",
        "1d": "has been idle for over a day",
      ][facts["idle"] ?? ""] ?? "is running"
    var text = "A \(name) program" + (repo == "none" ? "" : " from \(repo)") + " that " + idle + "."
    if facts["orphaned"] == "yes" { text += " The app or chat that started it is gone." }
    if facts["listening"] == "yes" { text += " It's still serving a web page or port." }
    if children > 0 { text += " It has \(children) helper\(children == 1 ? "" : "s") of its own." }
    return text
  }
}
