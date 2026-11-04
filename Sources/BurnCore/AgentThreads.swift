import Darwin
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
  /// Nothing is read past these bounds, whatever the folders hold.
  private static let readLimit = 65_536
  private static let liveWindow: TimeInterval = 600
  private static let rolloutWindow: TimeInterval = 30 * 86_400
  private static let rolloutLimit = 2_000
  private static let entryLimit = 2_000
  private static let examineLimit = 20_000

  /// Indexes Claude Code and Codex sessions under `home`. Bounded and read-only.
  public static func index(home: String = NSHomeDirectory(), now: Date = Date()) -> [AgentThread] {
    let sessions = claudeSessions(home: home)
    let live = Set(sessions.filter { $0.live }.map { $0.id })
    let all =
      sessions + claudeTranscripts(home: home, now: now, live: live)
      + codexRollouts(home: home, now: now)
    var seen = Set<String>()
    var threads: [AgentThread] = []
    for thread in all {
      if seen.insert(thread.id).inserted { threads.append(thread) }
    }
    return threads
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

  /// The title of the newest chat that worked inside `path` and has one, which is how people
  /// remember the work. Reads only the threads already indexed.
  public static func chatTitle(for path: String, threads: [AgentThread]) -> String? {
    let root = path.hasSuffix("/") ? path : path + "/"
    let named = threads.filter { ($0.cwd == path || $0.cwd.hasPrefix(root)) && $0.title != nil }
    return named.max { $0.lastActive < $1.lastActive }?.title
  }

  /// Running chats: Claude Code keeps one small file per process, live while its pid exists.
  private static func claudeSessions(home: String) -> [AgentThread] {
    let folder = home + "/.claude/sessions"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
      return []
    }
    var threads: [AgentThread] = []
    for name in names.sorted().prefix(entryLimit) where name.hasSuffix(".json") {
      let path = folder + "/" + name
      guard let file = regularFile(path), let data = readHead(path, limit: readLimit),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let session = object["sessionId"] as? String, !session.isEmpty,
        let cwd = object["cwd"] as? String, !cwd.isEmpty
      else { continue }
      let pid = number(object["pid"]).flatMap { Int32(exactly: $0) }
      let alive = pid.map { isAlive($0) } ?? false
      var title = object["name"] as? String
      if title?.isEmpty == true { title = nil }
      let updated = number(object["updatedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
      threads.append(
        AgentThread(
          id: "claude:" + session, agent: "claude", cwd: cwd, live: alive,
          pid: alive ? pid : nil, title: title, lastActive: updated ?? file.modified))
    }
    return threads
  }

  /// Past chats: the newest transcript of each project folder and where it ran.
  private static func claudeTranscripts(home: String, now: Date, live: Set<String>)
    -> [AgentThread]
  {
    let root = home + "/.claude/projects"
    guard let folders = try? FileManager.default.contentsOfDirectory(atPath: root) else {
      return []
    }
    var threads: [AgentThread] = []
    for folder in folders.sorted().prefix(entryLimit) {
      let directory = root + "/" + folder
      guard isDirectory(directory), let latest = newestTranscript(in: directory),
        let data = readHead(directory + "/" + latest.name, limit: readLimit),
        let cwd = firstCwd(data)
      else { continue }
      let id = "claude:" + String(latest.name.dropLast(".jsonl".count))
      let recent = abs(now.timeIntervalSince(latest.modified)) <= liveWindow
      threads.append(
        AgentThread(
          id: id, agent: "claude", cwd: cwd, live: live.contains(id) || recent,
          lastActive: latest.modified))
    }
    return threads
  }

  /// Codex chats: rollouts changed in the last 30 days, newest first, first line only.
  private static func codexRollouts(home: String, now: Date) -> [AgentThread] {
    let root = home + "/.codex/sessions"
    var files: [(path: String, modified: Date)] = []
    var examined = 0
    scan: for year in numericFolders(root, digits: 4) {
      for month in numericFolders(root + "/" + year, digits: 2) {
        for day in numericFolders(root + "/" + year + "/" + month, digits: 2) {
          let directory = root + "/" + year + "/" + month + "/" + day
          let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
          for name in names.sorted() where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
            examined += 1
            if examined > examineLimit { break scan }
            guard let file = regularFile(directory + "/" + name),
              now.timeIntervalSince(file.modified) <= rolloutWindow
            else { continue }
            files.append((path: directory + "/" + name, modified: file.modified))
          }
        }
      }
    }
    files.sort { $0.modified > $1.modified }
    var threads: [AgentThread] = []
    for file in files.prefix(rolloutLimit) {
      guard let meta = codexMeta(file.path) else { continue }
      let recent = abs(now.timeIntervalSince(file.modified)) <= liveWindow
      threads.append(
        AgentThread(
          id: "codex:" + meta.id, agent: "codex", cwd: meta.cwd, live: recent,
          lastActive: file.modified))
    }
    return threads
  }

  /// `session_meta` on the first line holds the chat id and folder; later lines are messages
  /// and are never read.
  private static func codexMeta(_ path: String) -> (id: String, cwd: String)? {
    guard let data = readHead(path, limit: readLimit, line: true) else { return nil }
    let first = data.prefix(while: { $0 != 10 })
    if let object = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any] {
      guard object["type"] as? String == "session_meta",
        let payload = object["payload"] as? [String: Any],
        let id = payload["id"] as? String, !id.isEmpty,
        let cwd = payload["cwd"] as? String, !cwd.isEmpty
      else { return nil }
      return (id, cwd)
    }
    // A first line cut by the read limit still opens with the two values we need.
    guard data.count >= readLimit, !data.contains(10),
      first.range(of: Data("\"session_meta\"".utf8)) != nil,
      let id = looseString("id", in: first), let cwd = looseString("cwd", in: first)
    else { return nil }
    return (id, cwd)
  }

  /// First top-level `cwd` in the leading JSON lines. A last line cut by the read limit is
  /// scanned for the key instead of parsed.
  private static func firstCwd(_ data: Data) -> String? {
    let lines = data.split(separator: 10, omittingEmptySubsequences: true)
    let cut = data.count >= readLimit && data.last != 10
    for (index, line) in lines.enumerated() {
      if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { return cwd }
      } else if cut && index == lines.count - 1 {
        return looseString("cwd", in: line)
      }
    }
    return nil
  }

  /// The first `"key":"value"` pair in text that may be cut off mid-line.
  private static func looseString(_ key: String, in data: Data) -> String? {
    let text = String(decoding: data, as: UTF8.self)
    let pattern = "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    let quoted = Data(("[\"" + String(text[range]) + "\"]").utf8)
    guard let values = try? JSONDecoder().decode([String].self, from: quoted),
      let value = values.first, !value.isEmpty
    else { return nil }
    return value
  }

  private static func newestTranscript(in directory: String) -> (name: String, modified: Date)? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
      return nil
    }
    var best: (name: String, modified: Date)?
    for name in names.sorted().prefix(entryLimit) where name.hasSuffix(".jsonl") {
      guard let file = regularFile(directory + "/" + name) else { continue }
      if file.modified > (best?.modified ?? Date.distantPast) {
        best = (name: name, modified: file.modified)
      }
    }
    return best
  }

  /// Year, month or day folders (all digits), newest first. Links are skipped.
  private static func numericFolders(_ directory: String, digits: Int) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.filter { name in
      name.utf8.count == digits && name.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        && isDirectory(directory + "/" + name)
    }.sorted(by: >)
  }

  /// Reads at most `limit` bytes from the start of a regular file, never through a link.
  /// With `line`, stops after the chunk that holds the first newline.
  private static func readHead(_ path: String, limit: Int, line: Bool = false) -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while data.count < limit {
      let wanted = min(buffer.count, limit - data.count)
      let count = read(fd, &buffer, wanted)
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { break }
      data.append(contentsOf: buffer[0..<count])
      if line && buffer[0..<count].contains(10) { break }
    }
    return data
  }

  /// Modification time and size of a regular file; nil for links, folders and missing paths.
  private static func regularFile(_ path: String) -> (modified: Date, size: Int64)? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let seconds =
      TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    return (Date(timeIntervalSince1970: seconds), Int64(info.st_size))
  }

  private static func isDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
  }

  private static func isAlive(_ pid: Int32) -> Bool {
    pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
  }

  /// A JSON number, or a string holding one.
  private static func number(_ value: Any?) -> Double? {
    if let n = value as? NSNumber, n.doubleValue.isFinite { return n.doubleValue }
    if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespaces)),
      parsed.isFinite
    {
      return parsed
    }
    return nil
  }
}
