import Darwin
import Foundation

/// Live process details Autopilot reads while cataloging. Injectable for proofs.
public struct AutopilotProcessProbe: Sendable {
  public var listening: @Sendable (Int32) -> Bool?
  public var agent: @Sendable (Int32) -> String?
  public var cwd: @Sendable (Int32) -> String?
  public var alive: @Sendable (Int32) -> Bool
  /// The live command line, one entry per argument. Read only to recognize robot browsers.
  public var arguments: @Sendable (Int32) -> [String]?
  /// How many clients are connected to the ports the process listens on; nil when unknown.
  public var clients: @Sendable (Int32) -> Int?
  public init(
    listening: @escaping @Sendable (Int32) -> Bool?, agent: @escaping @Sendable (Int32) -> String?,
    cwd: @escaping @Sendable (Int32) -> String?, alive: @escaping @Sendable (Int32) -> Bool,
    arguments: @escaping @Sendable (Int32) -> [String]? = { _ in nil },
    clients: @escaping @Sendable (Int32) -> Int? = { _ in nil }
  ) {
    self.listening = listening
    self.agent = agent
    self.cwd = cwd
    self.alive = alive
    self.arguments = arguments
    self.clients = clients
  }
  public static let live = AutopilotProcessProbe(
    listening: { Native().listening($0) }, agent: { Native().agent($0) },
    cwd: { Native().currentDirectory($0) },
    alive: { pid in
      if case .found = Native().probe(pid) { return true }
      return false
    }, arguments: { Native().arguments($0) }, clients: { Native().clients($0) })
}

/// Zombies: processes reparented to launchd whose job or chat ended. Only these orphan
/// roots become items; their live descendants are burned with them.
public enum AutopilotProcesses {
  static let protectedNames: Set<String> = [
    "launchd", "kernel_task", "login", "WindowServer", "sshd", "ssh-agent", "gpg-agent",
    "security", "op", "codex", "claude", "gemini", "agy", "copilot", "cursor-agent", "burnzombies",
    "burnzombies-mcp", "BurnZombiesApp", "tmux", "screen", "mosh-server", "caffeinate",
  ]
  static let systemPrefixes = [
    "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
  ]

  /// Hard rails for one process. A non-nil reason means it is never burned.
  public static func rail(
    _ record: Record, protectedPIDs: Set<Int32>, preferences: Preferences, now: Date = Date(),
    home: String = NSHomeDirectory(), robot: Bool = false
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
    // A robot browser, and its own helpers, run from a browser the owner may also use; the
    // owner's own copy never carries a robot's flags, so it stays protected here.
    if !robot, bundled(o.executable, home: home) { return "It's part of an app you use." }
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

  /// The robot browsers among `members`, by PID, and every process that belongs to one: its
  /// main process and its own helpers, the descendants inside the same app bundle.
  public static func robots(in members: [Record], arguments: (Int32) -> [String]?) -> (
    browsers: [Int32: RobotBrowser], members: Set<Int32>
  ) {
    var browsers: [Int32: RobotBrowser] = [:]
    var children: [Int32: [Record]] = [:]
    for member in members {
      children[member.latest.parent, default: []].append(member)
      let pid = member.latest.identity.pid
      guard RobotBrowser.isBrowser(member.latest.executable), let argv = arguments(pid),
        let robot = RobotBrowser.fingerprint(executable: member.latest.executable, arguments: argv)
      else { continue }
      browsers[pid] = robot
    }
    var owned = Set(browsers.keys)
    for member in members where browsers[member.latest.identity.pid] != nil {
      guard let bundle = RobotBrowser.bundle(member.latest.executable) else { continue }
      var frontier = [member.latest.identity.pid]
      while let next = frontier.popLast() {
        for child in children[next] ?? [] where child.latest.executable.hasPrefix(bundle) {
          if owned.insert(child.latest.identity.pid).inserted {
            frontier.append(child.latest.identity.pid)
          }
        }
      }
    }
    return (browsers, owned)
  }

  /// Whether nothing can drive a robot browser whose launcher is gone: it was driven over a pipe
  /// only, or it has a throwaway profile and no client is connected to it (`clients` nil, unknown,
  /// counts as connected).
  public static func abandoned(
    _ robot: RobotBrowser, members: Set<Int32>, clients: (Int32) -> Int?
  ) -> Bool {
    if robot.control == .pipe { return true }
    return robot.throwawayProfile && !members.contains { clients($0).map { $0 > 0 } ?? true }
  }

  public static func family(_ executable: String) -> String {
    let path = executable.lowercased()
    let name = (path as NSString).lastPathComponent
    if [
      "node", "nodejs", "bun", "deno", "npm", "npx", "pnpm", "yarn", "tsx", "ts-node",
      "next-server",
    ].contains(name) {
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
      || RobotBrowser.isBrowser(executable) || name.contains("chromium helper")
    {
      return "browser"
    }
    if [
      "esbuild", "swc", "tsc", "cargo", "rustc", "clang", "swift-frontend", "swift-build",
      "xcodebuild", "make", "cmake", "ninja", "go", "watchman", "turbo", "sourcekit-lsp",
      "gopls", "rust-analyzer",
    ].contains(name) {
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

  /// Folder name of the git checkout containing `path`, or nil. Nothing in a place macOS
  /// protects is looked at without Full Disk Access.
  public static func repository(_ path: String, protected: ProtectedLocations = .limited())
    -> String?
  {
    var directory = path
    for _ in 0..<24 {
      guard directory.hasPrefix("/"), protected.allows(directory) else { return nil }
      if FileManager.default.fileExists(atPath: directory + "/.git") {
        return (directory as NSString).lastPathComponent
      }
      let parent = (directory as NSString).deletingLastPathComponent
      guard parent != directory else { return nil }
      directory = parent
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

  /// When it was last seen busy, or first seen. A program never seen busy that has used under a
  /// second of CPU in its whole life has been idle since it started, so a new install need not
  /// watch it for hours first.
  static func lastActive(_ r: Record) -> Date {
    if r.lastBusy == nil, r.latest.cpuNS < 1_000_000_000 {
      let started = Date(timeIntervalSince1970: Double(r.latest.identity.seconds))
      return min(started, r.firstSeen)
    }
    return r.lastBusy ?? r.firstSeen
  }

  static func idleSince(_ r: Record, now: Date) -> TimeInterval {
    now.timeIntervalSince(lastActive(r))
  }

  public static func items(
    _ records: [String: Record], threads: [AgentThread], protectedPIDs: Set<Int32>,
    launchAgents: Set<Int32> = [], claimed: Set<String> = [],
    preferences: Preferences = Preferences(), now: Date = Date(),
    probe: AutopilotProcessProbe = .live, home: String = NSHomeDirectory(),
    protected: ProtectedLocations = .limited()
  ) -> [AutopilotItem] {
    var items = [AutopilotItem]()
    for record in records.values where record.missingSince == nil {
      let o = record.latest
      guard o.parent == 1, o.uid == getuid(), !o.zombie, o.identity.pid != getpid(),
        !launchAgents.contains(o.identity.pid)
      else { continue }
      // A robot browser is the one program inside an app that may be a leftover, and only once
      // nothing can drive it. Its tree is needed first to tell.
      let robotRoot =
        RobotBrowser.isBrowser(o.executable)
        ? probe.arguments(o.identity.pid).flatMap {
          RobotBrowser.fingerprint(executable: o.executable, arguments: $0)
        } : nil
      var tree: [Record] = []
      var robots: (browsers: [Int32: RobotBrowser], members: Set<Int32>) = ([:], [])
      if robotRoot != nil {
        tree = descendants(of: o.identity.pid, in: records)
        robots = Self.robots(in: [record] + tree, arguments: probe.arguments)
      }
      let abandoned =
        robotRoot.map {
          Self.abandoned($0, members: robots.members, clients: probe.clients)
        } ?? false
      var reason = rail(
        record, protectedPIDs: protectedPIDs, preferences: preferences, now: now, home: home,
        robot: abandoned)
      // macOS services, apps, harnesses and unreadable processes are not leftovers at all.
      if let reason, reason != "You asked me to keep it." { continue }
      if robotRoot == nil {
        tree = descendants(of: o.identity.pid, in: records)
        robots = Self.robots(in: [record] + tree, arguments: probe.arguments)
      }
      let members = [record] + tree
      // A driver's own robot browser goes with it; a robot browser at the root lends its helpers
      // that exemption only once nothing can drive it.
      let exempt = robotRoot == nil || abandoned ? robots.members : []
      if reason == nil,
        tree.contains(where: {
          rail(
            $0, protectedPIDs: protectedPIDs, preferences: preferences, now: now, home: home,
            robot: exempt.contains($0.latest.identity.pid)) != nil
        })
      {
        reason = "Part of it is something I must not touch."
      }
      let robot =
        abandoned ? "abandoned" : robotRoot != nil || !robots.browsers.isEmpty ? "driven" : "no"
      let cwd = probe.cwd(o.identity.pid)
      let thread = cwd.map { AgentThreads.state(for: $0, threads: threads).thread } ?? "none"
      // No chat can reach a pipe browser whose launcher is gone, and it holds the profile that
      // chat's next browser needs.
      if reason == nil, thread == "live", !(abandoned && robotRoot?.control == .pipe) {
        reason = "A chat is still working in this project."
      }
      if reason == nil, members.contains(where: { claimed.contains($0.id) }) {
        reason = "A chat said it still needs this."
      }
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
      let orphaned =
        robot == "abandoned" || record.orphanSince != nil || leaderGone ? "yes" : "maybe"
      let quiet = members.map { idleSince($0, now: now) }.min() ?? 0
      // The whole tree was last used when its busiest member was; the same moment `quiet` counts
      // from, kept as a date so it doesn't move with `now`.
      let lastUsed: Date? = members.map { lastActive($0) }.max()
      let bytes = members.reduce(0) { $0 + $1.latest.rss }
      // A quarter of a core or more over the last minute, across the whole tree.
      let cpu = members.compactMap(\.cpuPercent).reduce(0, +) >= 25 ? "busy" : "calm"
      let repo = cwd.flatMap { repository($0, protected: protected) } ?? "none"
      let program = o.name.lowercased()
      var facts = [
        "program": program, "family": family(o.executable), "orphaned": orphaned,
        "thread": thread, "agent": probe.agent(o.identity.pid) ?? "none",
        "idle": idle(quiet), "listening": listening, "memory": memory(bytes), "cpu": cpu,
        "repo": repo,
      ]
      // Only where a robot browser is involved, so nothing else is judged anew.
      if robot != "no" { facts["robot"] = robot }
      let shown = robotRoot != nil ? o.name + " (robot)" : o.name
      // When it started, for its card's "running for": unlike its idle time, that only grows.
      let started: Date? =
        o.identity.seconds > 0 ? Date(timeIntervalSince1970: Double(o.identity.seconds)) : nil
      items.append(
        AutopilotItem(
          id: "process:" + o.identity.key, kind: .process,
          name: repo == "none" ? shown : shown + " in " + repo,
          detail: describe(
            o.name, repo: repo, facts: facts, children: tree.count, robot: robotRoot != nil),
          path: o.executable, bytes: bytes, facts: facts, protectedReason: reason,
          observedAt: o.time, pid: o.identity.pid, processKey: o.identity.key,
          lastUsed: lastUsed, started: started))
    }
    return items.sorted { $0.bytes > $1.bytes }
  }

  static func describe(
    _ name: String, repo: String, facts: [String: String], children: Int, robot: Bool = false
  ) -> String {
    let idle =
      [
        "active": "is still doing work", "10m": "has been idle for a few minutes",
        "1h": "has been idle for over an hour", "6h": "has been idle for over 6 hours",
        "1d": "has been idle for over a day",
      ][facts["idle"] ?? ""] ?? "is running"
    let kind = robot ? "A robot \(name) browser" : "A \(name) program"
    var text = kind + (repo == "none" ? "" : " from \(repo)") + " that " + idle + "."
    switch facts["robot"] {
    case "abandoned":
      text += " Nothing can drive it anymore: the program that started it is gone."
    case "driven" where robot:
      text += " Something can still drive it."
    case "driven":
      text += " It is still driving a robot browser."
    default:
      if facts["orphaned"] == "yes" { text += " The app or chat that started it is gone." }
    }
    if facts["listening"] == "yes" { text += " It's still serving a web page or port." }
    if children > 0 { text += " It has \(children) helper\(children == 1 ? "" : "s") of its own." }
    return text
  }
}
