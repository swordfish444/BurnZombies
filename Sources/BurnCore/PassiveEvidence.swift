import CBurn
import Darwin
import Foundation

public struct PassiveSession: Codable, Sendable {
  public var provider: String
  public var id: String
  public var turnID: String?
  public var started: Date?
  public var completed: Date?
  public var active = true
  public var summary = ""
  public var purpose = ""
  public var observedAt: Date?
  public var completeRead = false
  public init(provider: String, id: String) { self.provider = provider; self.id = id }
  public mutating func ingest(_ object: [String: Any]) {
    let time = Self.date(object["timestamp"])
    if provider == "codex", object["type"] as? String == "event_msg", let p = object["payload"] as? [String: Any] {
      let kind = p["type"] as? String
      if kind == "task_started" {
        turnID = p["turn_id"] as? String; started = time; completed = nil; active = true; summary = ""; purpose = ""
      } else if kind == "task_complete", p["turn_id"] as? String == turnID, started != nil {
        completed = time; active = false; summary = Self.excerpt(p["last_agent_message"] as? String ?? "")
      } else if ["turn_aborted", "task_failed"].contains(kind ?? "") {
        active = true; completed = nil // Interrupted work may still be flushing or have ongoing consumers.
      }
    } else if provider == "claude" {
      let message = object["message"] as? [String: Any] ?? [:]
      let content = message["content"]
      if object["type"] as? String == "user", object["toolUseResult"] == nil,
        (content is String || (content as? [[String: Any]])?.contains(where: { $0["type"] as? String == "tool_result" }) == false) {
        turnID = object["promptId"] as? String ?? object["uuid"] as? String
        started = time; completed = nil; active = true; summary = ""; purpose = ""
      }
      if object["type"] as? String == "assistant", let parts = content as? [[String: Any]] {
        for part in parts where part["type"] as? String == "tool_use" && part["name"] as? String == "Bash" {
          if let input = part["input"] as? [String: Any], let description = input["description"] as? String { purpose = Self.excerpt(description) }
        }
        if message["stop_reason"] as? String == "end_turn", started != nil {
          summary = Self.excerpt(parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " "))
          completed = time; active = false
        }
      }
    }
  }
  public static func date(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
  public static func excerpt(_ text: String) -> String {
    // Keep a bounded owner completion statement, never prompts, tool output, reasoning,
    // command arguments or credentials. Common token/key-shaped strings are redacted.
    let clean = text.replacingOccurrences(of: #"(?i)(?:sk-|ghp_|github_pat_|AKIA)[A-Za-z0-9_\-]{12,}|(?:bearer\s+)[A-Za-z0-9._\-]+|(?:password|secret|api[_-]?key|token)\s*[:=]\s*\S+"#, with: "[redacted]", options: .regularExpression)
    return String(clean.prefix(1200))
  }
}

public struct PassiveEvidence: Codable, Sendable {
  public var member: Member
  public var owner: Member
  public var provider: String
  public var sessionID: String
  public var turnID: String
  public var started: Date
  public var observed: Date
  public var checked: Date
  public var completed: Date?
  public var summary: String
  public var purpose: String
  public var eligible: Bool
  public var id: String { "passive:" + member.identity.key }
  public var revision: String { WorkEvidence.hash(turnID + "|" + String(completed?.timeIntervalSinceReferenceDate ?? 0) + "|" + summary) }
  public func canReview(now: Date = Date()) -> Bool {
    eligible && completed != nil && !summary.isEmpty && (0...90).contains(now.timeIntervalSince(checked))
  }
  public var workSummary: WorkSummary {
    WorkSummary(id: id, processIDs: [member.identity.key], livePIDs: [member.identity.pid],
      label: "Observed \(provider) helper", purpose: purpose.isEmpty ? "Helper observed under the owning harness during this turn; exact purpose must be corroborated." : purpose,
      completionCondition: "The helper's actual purpose has ended and it has no remaining consumer. Turn completion alone is insufficient.",
      state: "candidate", evidence: "Passive native ancestry and session identity captured while the owner was alive. Owner completion statement (untrusted): " + summary,
      created: observed, updated: completed ?? checked, ownershipAnchors: [owner], blockedByActiveClaim: !eligible)
  }
}

/// Passive file reader: bounded deltas from known session IDs, no model and no hooks.
/// Session completion is evidence for review, never an instruction to signal a process.
public final class PassiveCollector {
  private struct Cursor: Codable { var inode: UInt64; var offset: UInt64; var session: PassiveSession }
  private struct Saved: Codable { var cursors: [String: Cursor] = [:]; var bindings: [String: PassiveEvidence] = [:] }
  private let store: Store
  private let home: URL
  private var saved: Saved
  private var paths: [String: URL] = [:]
  private var lastDiscovery = Date.distantPast
  private var lastPoll = Date.distantPast
  // A missing ancestor/session is temporary evidence, not a lifetime exclusion.
  // Oldest-first retries are bounded and do not reread unrelated chat contents.
  private var checkedProcesses: [String: Date] = [:]
  public private(set) var coverage = "Waiting for passive harness evidence."
  public init(store: Store, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
    self.store = store; self.home = home
    let file = store.root.appendingPathComponent("passive-evidence.json")
    saved = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode(Saved.self, from: store.read(file, limit: 2_097_152)) : Saved()
  }
  private func discover(now: Date) {
    guard now.timeIntervalSince(lastDiscovery) >= 300 else { return }
    lastDiscovery = now; paths = [:]
    let roots = [("codex", home.appendingPathComponent(".codex/sessions")), ("claude", home.appendingPathComponent(".claude/projects"))]
    for (provider, root) in roots {
      guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
      var visited = 0
      var ambiguous = Set<String>()
      while let url = files.nextObject() as? URL, visited < 50_000 {
        visited += 1
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { files.skipDescendants(); continue }
        guard url.pathExtension == "jsonl" else { continue }
        let suffix = String(url.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
        guard UUID(uuidString: suffix) != nil else { continue }
        let key = provider + ":" + suffix
        if paths[key] != nil { ambiguous.insert(key) }
        if !ambiguous.contains(key) { paths[key] = url } else { paths.removeValue(forKey: key) }
      }
    }
  }
  private func read(_ key: String, now: Date) -> PassiveSession? {
    guard let path = paths[key] else { return nil }
    let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }; defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFREG else { return nil }
    let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
    let size = UInt64(status.st_size)
    var cursor = saved.cursors[key] ?? Cursor(inode: UInt64(status.st_ino), offset: 0, session: .init(provider: parts[0], id: parts[1]))
    if cursor.inode != UInt64(status.st_ino) || cursor.offset > size {
      cursor = Cursor(inode: UInt64(status.st_ino), offset: 0, session: .init(provider: parts[0], id: parts[1]))
    }
    let maximum = 262_144
    var skipFirst = false
    if size - cursor.offset > UInt64(maximum) {
      cursor.offset = size - UInt64(maximum); skipFirst = true
      cursor.session = .init(provider: parts[0], id: parts[1]) // A gap invalidates prior completion.
    }
    var buffer = [UInt8](repeating: 0, count: Int(size - cursor.offset))
    let count = buffer.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, $0.count, off_t(cursor.offset)) }
    guard count >= 0 else { return nil }
    let data = Data(buffer.prefix(count))
    var consumed = 0
    for index in data.indices where data[index] == 10 {
      let line = data[consumed..<index]; consumed = index + 1
      if skipFirst { skipFirst = false; continue }
      guard line.count <= 196_608, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
      cursor.session.ingest(object)
    }
    cursor.offset += UInt64(consumed)
    cursor.session.completeRead = cursor.offset == size
    cursor.session.observedAt = now
    saved.cursors[key] = cursor
    return cursor.session
  }
  private func claudeOwners() -> [Int32: String] {
    let root = home.appendingPathComponent(".claude/sessions")
    guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
    let native = Native(); var result: [Int32: String] = [:]
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    for path in files.prefix(128) where path.pathExtension == "json" {
      guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
        let handle = try? FileHandle(forReadingFrom: path) else { continue }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384,
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["pidDomain"] as? String == "darwin", let pid = value["pid"] as? Int32,
        let id = value["sessionId"] as? String, UUID(uuidString: id) != nil,
        let start = value["procStart"] as? String, let date = formatter.date(from: start),
        case .found(let live) = native.probe(pid), live.uid == getuid(),
        abs(date.timeIntervalSince1970 - Double(live.identity.seconds)) < 1 else { continue }
      result[pid] = id.lowercased()
    }
    return result
  }
  public func poll(records: [String: Record], claims: [WorkEvidence], now: Date = Date(), partial: Bool = false) throws -> [PassiveEvidence] {
    guard !partial else { return [] }
    // Agent preview/burn refreshes may happen within a second. Always refresh session
    // state for existing bindings; native discovery is bounded to once per minute.
    discover(now: now)
    let live = records.values.filter { $0.missingSince == nil }.map(\.latest)
    let byPID = Dictionary(uniqueKeysWithValues: live.map { ($0.identity.pid, $0) })
    saved.bindings = saved.bindings.filter { records[$0.key]?.missingSince == nil && records[$0.key] != nil }
    var pending: [(Observation, Observation, String, String)] = []
    if now.timeIntervalSince(lastPoll) >= 55 {
      lastPoll = now
      checkedProcesses = checkedProcesses.filter { records[$0.key]?.missingSince == nil && records[$0.key] != nil }
      let owners = claudeOwners()
      let unchecked = live.filter { saved.bindings[$0.identity.key] == nil &&
        now.timeIntervalSince(checkedProcesses[$0.identity.key] ?? .distantPast) >= 300 }
        .sorted {
          let left = checkedProcesses[$0.identity.key] ?? .distantPast, right = checkedProcesses[$1.identity.key] ?? .distantPast
          return left == right ? $0.identity.key < $1.identity.key : left < right
        }
      for process in unchecked.prefix(256) {
        guard pending.count < 64 else { break }
        checkedProcesses[process.identity.key] = now
        // Bundled runtimes are valid evidence subjects. Application protection is
        // enforced separately at action time; observing one grants no stop authority.
        guard !["codex", "claude", "burnzombies", "burnzombies-mcp"].contains(process.name) else { continue }
        var parent = process.parent, seen = Set<Int32>()
        for _ in 0..<64 {
          guard parent > 1, seen.insert(parent).inserted, let owner = byPID[parent] else { break }
          if owner.name == "codex", let id = Native().codexSessionID(process) {
            pending.append((process, owner, "codex", id)); break
          }
          if let id = owners[parent] { pending.append((process, owner, "claude", id)); break }
          parent = owner.parent
        }
      }
    }
    let wanted = Set(pending.map { $0.2 + ":" + $0.3 } + saved.bindings.values.map { $0.provider + ":" + $0.sessionID })
    var sessions: [String: PassiveSession] = [:]
    for key in wanted.sorted().prefix(64) { sessions[key] = read(key, now: now) }
    for (process, owner, provider, id) in pending {
      guard saved.bindings[process.identity.key] == nil, saved.bindings.count < 256,
        let session = sessions[provider + ":" + id], session.completeRead, let turn = session.turnID, let started = session.started,
        Double(process.identity.seconds) + Double(process.identity.micros) / 1_000_000 >= started.timeIntervalSince1970 else {
        checkedProcesses.removeValue(forKey: process.identity.key); continue
      }
      saved.bindings[process.identity.key] = PassiveEvidence(member: Member(process), owner: Member(owner), provider: provider,
        sessionID: id, turnID: turn, started: started, observed: now, checked: now, completed: nil,
        summary: "", purpose: session.purpose, eligible: false)
    }
    for key in Array(saved.bindings.keys) {
      guard var binding = saved.bindings[key] else { continue }
      binding.checked = now; binding.eligible = false
      if let session = sessions[binding.provider + ":" + binding.sessionID], let record = records[key],
        session.completeRead, !session.active, session.turnID == binding.turnID, let completed = session.completed,
        completed >= binding.started, Member(record.latest) == binding.member,
        !WorkEvidence.blockingTree(claims, record: record, records: records),
        !live.contains(where: { $0.parent == binding.member.identity.pid }),
        !session.summary.isEmpty {
        var sockets: Int32 = 0, files: Int32 = 0
        // Persistent listeners, outstanding socket consumers, hidden descriptors and
        // children stay protected. Low CPU or a finished chat is never a kill rule.
        if bz_fd_summary(binding.member.identity.pid, &sockets, &files) >= 0 && sockets == 0 {
          binding.completed = completed; binding.summary = session.summary; binding.eligible = true
        }
      }
      saved.bindings[key] = binding
    }
    saved.cursors = saved.cursors.filter { wanted.contains($0.key) }
    coverage = "Passive evidence: \(saved.bindings.count) helpers, \(sessions.count)/\(wanted.count) readable sessions."
    try store.write(JSONEncoder().encode(saved), to: store.root.appendingPathComponent("passive-evidence.json"), limit: 2_097_152)
    return Array(saved.bindings.values)
  }
}
