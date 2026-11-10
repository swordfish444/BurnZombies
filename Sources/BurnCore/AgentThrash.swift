import CSQLite
import Darwin
import Foundation

public enum AgentThrashKind: String, Codable, Sendable, CaseIterable {
  case loopZombie = "loop-zombie"
  case tokenVampire = "token-vampire"
  case focusThief = "focus-thief"

  public var badge: String {
    switch self {
    case .loopZombie: return "LOOP ZOMBIE"
    case .tokenVampire: return "TOKEN VAMPIRE"
    case .focusThief: return "FOCUS THIEF"
    }
  }
}

public struct AgentThrashFinding: Codable, Sendable, Equatable {
  public var id: String
  public var kind: AgentThrashKind
  public var agent: String
  public var sessionID: String
  public var cwd: String?
  public var live: Bool
  public var pid: Int32?
  public var tokensUsed: UInt64?
  public var subagentCount: Int?
  public var transcriptBytes: UInt64?
  public var errorStreak: Int
  public var summary: String
  public var lastActive: Date

  public init(
    id: String, kind: AgentThrashKind, agent: String, sessionID: String, cwd: String? = nil,
    live: Bool, pid: Int32? = nil, tokensUsed: UInt64? = nil, subagentCount: Int? = nil,
    transcriptBytes: UInt64? = nil, errorStreak: Int = 0, summary: String, lastActive: Date
  ) {
    self.id = id
    self.kind = kind
    self.agent = agent
    self.sessionID = sessionID
    self.cwd = cwd
    self.live = live
    self.pid = pid
    self.tokensUsed = tokensUsed
    self.subagentCount = subagentCount
    self.transcriptBytes = transcriptBytes
    self.errorStreak = errorStreak
    self.summary = summary
    self.lastActive = lastActive
  }
}

/// Fast, bounded detector for "Living Zombies": active or recent agent sessions spinning in error
/// loops, spawning runaway subagent/token storms, or launching `--headed` focus-stealing browsers.
public enum AgentThrashScanner {
  public static let tailByteLimit = 262_144
  public static let vampireTokenThreshold: UInt64 = 50_000_000
  public static let vampireSubagentThreshold = 25
  public static let vampireTranscriptBytes: UInt64 = 40_000_000
  private static let recentTranscriptLimit = 48
  private static let liveWindow: TimeInterval = 900

  public struct ProcessCommandSample: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var commandLine: String
    public init(pid: Int32, name: String, commandLine: String) {
      self.pid = pid
      self.name = name
      self.commandLine = commandLine
    }
  }

  public static func scan(
    home: String = NSHomeDirectory(), now: Date = Date(),
    threads: [AgentThread]? = nil,
    processSamples: [ProcessCommandSample]? = nil,
    limit: Int = 24
  ) -> [AgentThrashFinding] {
    let base = WorkspaceSafety.canonical(home)
    let indexed = threads ?? AgentThreads.index(home: base, now: now)
    let byID = Dictionary(indexed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var findings: [String: AgentThrashFinding] = [:]

    // 1. Focus Thieves (live processes running `--headed` / `headless: false` browser automation)
    let samples = processSamples ?? liveProcessSamples(home: base)
    for sample in samples {
      let lower = sample.commandLine.lowercased()
      let isBrowserAutomation =
        lower.contains("playwright") || lower.contains("puppeteer")
        || lower.contains("chromedriver") || lower.contains("chrome-devtools")
        || lower.contains("--remote-debugging") || lower.contains("chromium")
      let stealsFocus =
        lower.contains("--headed") || lower.contains("headless=false")
        || lower.contains("headless:false") || lower.contains("headless: false")
      guard isBrowserAutomation && stealsFocus else { continue }
      let fid = "thrash:focus:\(sample.pid)"
      findings[fid] = AgentThrashFinding(
        id: fid, kind: .focusThief, agent: "browser", sessionID: "pid-\(sample.pid)",
        cwd: nil, live: true, pid: sample.pid, errorStreak: 0,
        summary:
          "PID \(sample.pid) (\(sample.name)) launched with --headed browser flags that can steal macOS focus.",
        lastActive: now)
    }

    // 2. Codex SQLite telemetry (`~/.codex/state_5.sqlite`) for Token Vampires & Subagent Storms
    for row in codexTopThreads(home: base, limit: 24) {
      let fullID = "codex:" + row.id
      let thread = byID[fullID]
      let isLive = thread?.live ?? (abs(now.timeIntervalSince(row.updatedAt)) <= liveWindow)
      if row.tokensUsed >= vampireTokenThreshold || row.subagentCount >= vampireSubagentThreshold {
        let tokText = formatTokens(row.tokensUsed)
        let stormText =
          row.subagentCount >= vampireSubagentThreshold
          ? " across \(row.subagentCount) spawned subagents" : ""
        let fid = "thrash:vampire:\(fullID)"
        findings[fid] = AgentThrashFinding(
          id: fid, kind: .tokenVampire, agent: "codex", sessionID: row.id,
          cwd: row.cwd ?? thread?.cwd, live: isLive, pid: thread?.pid,
          tokensUsed: row.tokensUsed, subagentCount: row.subagentCount,
          summary:
            "Codex session burned \(tokText) tokens\(stormText)\(row.title.map { " (\($0.prefix(48)))" } ?? "").",
          lastActive: row.updatedAt)
      }
    }

    // 3. Bounded tail scan across recent Claude, Codex, and Antigravity JSONL transcripts
    for candidate in recentTranscripts(home: base, now: now) {
      let fullID = candidate.agent + ":" + candidate.sessionID
      let thread = byID[fullID]
      let isLive = thread?.live ?? (abs(now.timeIntervalSince(candidate.modified)) <= liveWindow)
      if candidate.bytes >= vampireTranscriptBytes, findings["thrash:vampire:\(fullID)"] == nil {
        let mb = String(format: "%.0f MB", Double(candidate.bytes) / 1_000_000)
        findings["thrash:vampire:\(fullID)"] = AgentThrashFinding(
          id: "thrash:vampire:\(fullID)", kind: .tokenVampire, agent: candidate.agent,
          sessionID: candidate.sessionID, cwd: thread?.cwd, live: isLive, pid: thread?.pid,
          transcriptBytes: candidate.bytes,
          summary:
            "\(candidate.agent.capitalized) transcript swelled to \(mb) in one session.",
          lastActive: candidate.modified)
      }
      guard let tail = readTail(candidate.path, limit: tailByteLimit),
        let loop = analyzeTail(tail)
      else { continue }
      let fid = "thrash:loop:\(fullID)"
      findings[fid] = AgentThrashFinding(
        id: fid, kind: .loopZombie, agent: candidate.agent, sessionID: candidate.sessionID,
        cwd: thread?.cwd, live: isLive, pid: thread?.pid, transcriptBytes: candidate.bytes,
        errorStreak: loop.count, summary: loop.summary, lastActive: candidate.modified)
    }

    return Array(
      findings.values.sorted { a, b in
        if a.live != b.live { return a.live && !b.live }
        let pa = severityRank(a), pb = severityRank(b)
        if pa != pb { return pa > pb }
        return a.lastActive > b.lastActive
      }.prefix(limit))
  }

  /// Enriches Autopilot process items with `facts["thrash"]` when a process matches a live Loop
  /// Zombie or Focus Thief, enabling native starter rules and UI callouts.
  public static func annotateProcesses(
    _ items: [AutopilotItem], findings: [AgentThrashFinding]
  ) -> [AutopilotItem] {
    guard !findings.isEmpty else { return items }
    let liveByPID = Dictionary(
      findings.compactMap { f in f.pid.map { ($0, f) } },
      uniquingKeysWith: { first, _ in first })
    let loopPaths = findings.filter { $0.live && $0.kind == .loopZombie }.compactMap(\.cwd)
    return items.map { item in
      guard item.kind == .process else { return item }
      var updated = item
      if let pid = item.pid, let hit = liveByPID[pid] {
        updated.facts["thrash"] = hit.kind.rawValue
        return updated
      }
      if let path = item.path,
        loopPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
      {
        updated.facts["thrash"] = AgentThrashKind.loopZombie.rawValue
      }
      return updated
    }
  }

  // MARK: - Tail & SQLite Inspection

  public static func analyzeTail(_ data: Data) -> (count: Int, summary: String)? {
    let text = String(decoding: data, as: UTF8.self)
    // Check whether the tail made real file mutations recently (last ~64 KB of tail)
    let recentSlice = String(text.suffix(65_536))
    let madeEdits =
      recentSlice.contains("\"name\":\"Edit\"")
      || recentSlice.contains("\"name\":\"Write\"")
      || recentSlice.contains("\"name\":\"MultiEdit\"")
      || recentSlice.contains("\"name\":\"edit_file\"")
      || recentSlice.contains("\"name\":\"write_file\"")
      || recentSlice.contains("apply_patch")

    let lockHits =
      countOccurrences(of: "index.lock", in: text)
      + countOccurrences(of: "already checked out", in: text)
      + countOccurrences(of: "cannot lock ref", in: text)
      + countOccurrences(of: "worktree lock", in: text)
    if lockHits >= 3 && !madeEdits {
      return (
        lockHits,
        "Hit \(lockHits) git worktree / index.lock collisions with zero file progress."
      )
    }

    let sleepHits =
      countOccurrences(of: "sleep 5", in: text)
      + countOccurrences(of: "sleep 10", in: text)
      + countOccurrences(of: "sleep 15", in: text)
      + countOccurrences(of: "sleep 30", in: text)
      + countOccurrences(of: "sleep 60", in: text)
    if sleepHits >= 4 && !madeEdits {
      return (
        sleepHits,
        "Spinning in \(sleepHits) shell sleep-polling calls with no file edits."
      )
    }

    let errorHits =
      countOccurrences(of: "\"is_error\":true", in: recentSlice)
      + countOccurrences(of: "\"is_error\": true", in: recentSlice)
      + countOccurrences(of: "\"status\":\"ERROR\"", in: recentSlice)
      + countOccurrences(of: "Command exited with code ", in: recentSlice)
      + countOccurrences(of: "Exit code ", in: recentSlice)
    if errorHits >= 4 && !madeEdits {
      return (
        errorHits,
        "Stuck in \(errorHits) consecutive tool/command errors with zero file edits."
      )
    }
    return nil
  }

  private struct CodexThreadTelemetry {
    var id: String
    var cwd: String?
    var title: String?
    var tokensUsed: UInt64
    var subagentCount: Int
    var updatedAt: Date
  }

  private static func codexTopThreads(home: String, limit: Int) -> [CodexThreadTelemetry] {
    let dbPath = home + "/.codex/state_5.sqlite"
    var info = stat()
    guard lstat(dbPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
      let db
    else {
      if let db { sqlite3_close(db) }
      return []
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 250)

    var spawnCounts: [String: Int] = [:]
    var edgeStmt: OpaquePointer?
    let edgeSQL =
      "SELECT parent_thread_id, COUNT(*) as cnt FROM thread_spawn_edges GROUP BY parent_thread_id HAVING cnt >= 10 ORDER BY cnt DESC LIMIT 64;"
    if sqlite3_prepare_v2(db, edgeSQL, -1, &edgeStmt, nil) == SQLITE_OK, let edgeStmt {
      defer { sqlite3_finalize(edgeStmt) }
      while sqlite3_step(edgeStmt) == SQLITE_ROW {
        if let raw = sqlite3_column_text(edgeStmt, 0) {
          spawnCounts[String(cString: raw)] = Int(sqlite3_column_int64(edgeStmt, 1))
        }
      }
    }

    var results: [CodexThreadTelemetry] = []
    var stmt: OpaquePointer?
    let sql = """
      SELECT id, cwd, title, tokens_used, updated_at
      FROM threads
      WHERE tokens_used >= 25000000
      ORDER BY tokens_used DESC
      LIMIT ?;
      """
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
      defer { sqlite3_finalize(stmt) }
      sqlite3_bind_int(stmt, 1, Int32(limit))
      while sqlite3_step(stmt) == SQLITE_ROW {
        guard let rawID = sqlite3_column_text(stmt, 0) else { continue }
        let id = String(cString: rawID)
        let cwd = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let tokens = max(0, sqlite3_column_int64(stmt, 3))
        let rawUpdated = sqlite3_column_int64(stmt, 4)
        let seconds =
          rawUpdated > 10_000_000_000 ? Double(rawUpdated) / 1000.0 : Double(rawUpdated)
        results.append(
          CodexThreadTelemetry(
            id: id, cwd: cwd, title: title, tokensUsed: UInt64(tokens),
            subagentCount: spawnCounts[id] ?? 0,
            updatedAt: Date(timeIntervalSince1970: max(0, seconds))))
      }
    }

    // Also include high-spawn storms whose tokens_used was < 25M
    let seenIDs = Set(results.map(\.id))
    for (parentID, cnt) in spawnCounts where cnt >= vampireSubagentThreshold && !seenIDs.contains(parentID) {
      var oneStmt: OpaquePointer?
      if sqlite3_prepare_v2(
        db, "SELECT cwd, title, tokens_used, updated_at FROM threads WHERE id = ? LIMIT 1;", -1,
        &oneStmt, nil) == SQLITE_OK, let oneStmt
      {
        defer { sqlite3_finalize(oneStmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(oneStmt, 1, parentID, -1, transient)
        if sqlite3_step(oneStmt) == SQLITE_ROW {
          let cwd = sqlite3_column_text(oneStmt, 0).map { String(cString: $0) }
          let title = sqlite3_column_text(oneStmt, 1).map { String(cString: $0) }
          let tokens = max(0, sqlite3_column_int64(oneStmt, 2))
          let rawUpdated = sqlite3_column_int64(oneStmt, 3)
          let seconds =
            rawUpdated > 10_000_000_000 ? Double(rawUpdated) / 1000.0 : Double(rawUpdated)
          results.append(
            CodexThreadTelemetry(
              id: parentID, cwd: cwd, title: title, tokensUsed: UInt64(tokens),
              subagentCount: cnt, updatedAt: Date(timeIntervalSince1970: max(0, seconds))))
        }
      }
    }
    return results
  }

  private struct TranscriptCandidate {
    var agent: String
    var sessionID: String
    var path: String
    var modified: Date
    var bytes: UInt64
  }

  private static func recentTranscripts(home: String, now: Date) -> [TranscriptCandidate] {
    var all: [TranscriptCandidate] = []
    let window: TimeInterval = 14 * 86_400

    // Claude projects (`~/.claude/projects/*/*.jsonl`)
    let claudeRoot = home + "/.claude/projects"
    if let projects = try? FileManager.default.contentsOfDirectory(atPath: claudeRoot) {
      for project in projects.sorted().prefix(128) {
        let pdir = claudeRoot + "/" + project
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: pdir) else {
          continue
        }
        for file in files.prefix(128) where file.hasSuffix(".jsonl") {
          let path = pdir + "/" + file
          guard let meta = regularFileMeta(path),
            now.timeIntervalSince(meta.modified) <= window || meta.bytes >= vampireTranscriptBytes
          else { continue }
          all.append(
            TranscriptCandidate(
              agent: "claude", sessionID: String(file.dropLast(6)), path: path,
              modified: meta.modified, bytes: meta.bytes))
        }
      }
    }

    // Antigravity (`~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl`)
    let agyRoot = home + "/.gemini/antigravity/brain"
    if let brains = try? FileManager.default.contentsOfDirectory(atPath: agyRoot) {
      for brain in brains.sorted().prefix(128) {
        let path = agyRoot + "/" + brain + "/.system_generated/logs/transcript.jsonl"
        guard let meta = regularFileMeta(path),
          now.timeIntervalSince(meta.modified) <= window || meta.bytes >= vampireTranscriptBytes
        else { continue }
        all.append(
          TranscriptCandidate(
            agent: "antigravity", sessionID: brain, path: path,
            modified: meta.modified, bytes: meta.bytes))
      }
    }

    // Codex recent rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
    let codexRoot = home + "/.codex/sessions"
    if let years = try? FileManager.default.contentsOfDirectory(atPath: codexRoot) {
      for year in years.sorted(by: >).prefix(2) {
        let ydir = codexRoot + "/" + year
        for month in ((try? FileManager.default.contentsOfDirectory(atPath: ydir)) ?? []).sorted(
          by: >
        ).prefix(2) {
          let mdir = ydir + "/" + month
          for day in ((try? FileManager.default.contentsOfDirectory(atPath: mdir)) ?? []).sorted(
            by: >
          ).prefix(5) {
            let ddir = mdir + "/" + day
            for file in ((try? FileManager.default.contentsOfDirectory(atPath: ddir)) ?? [])
              .prefix(64)
            where file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") {
              let path = ddir + "/" + file
              guard let meta = regularFileMeta(path),
                now.timeIntervalSince(meta.modified) <= window
                  || meta.bytes >= vampireTranscriptBytes
              else { continue }
              let idPart = String(file.dropFirst(8).dropLast(6))
              all.append(
                TranscriptCandidate(
                  agent: "codex", sessionID: idPart, path: path,
                  modified: meta.modified, bytes: meta.bytes))
            }
          }
        }
      }
    }

    let newest = all.sorted { $0.modified > $1.modified }.prefix(recentTranscriptLimit)
    let biggest = all.filter { $0.bytes >= vampireTranscriptBytes }
      .sorted { $0.bytes > $1.bytes }.prefix(12)
    var merged: [String: TranscriptCandidate] = [:]
    for item in Array(newest) + Array(biggest) { merged[item.path] = item }
    return Array(merged.values)
  }

  private static func liveProcessSamples(home: String) -> [ProcessCommandSample] {
    guard WorkspaceSafety.canonical(home) == WorkspaceSafety.canonical(NSHomeDirectory()) else {
      return []
    }
    let native = Native()
    let scan = native.scan()
    var samples: [ProcessCommandSample] = []
    for obs in scan.observations {
      let lowerName = obs.name.lowercased()
      guard
        lowerName.contains("node") || lowerName.contains("chrom") || lowerName.contains("playwright")
          || lowerName.contains("python") || lowerName.contains("deno") || lowerName.contains("bun")
      else { continue }
      guard let cmd = native.commandLine(obs.identity.pid, limit: 600) else { continue }
      samples.append(ProcessCommandSample(pid: obs.identity.pid, name: obs.name, commandLine: cmd))
    }
    return samples
  }

  private static func readTail(_ path: String, limit: Int) -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let size = Int(info.st_size)
    guard size > 0 else { return nil }
    let start = max(0, size - limit)
    _ = lseek(fd, off_t(start), SEEK_SET)
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 16_384)
    while out.count < limit {
      let n = read(fd, &buf, min(buf.count, limit - out.count))
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { break }
      out.append(contentsOf: buf[0..<n])
    }
    return out
  }

  private static func regularFileMeta(_ path: String) -> (modified: Date, bytes: UInt64)? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
      return nil
    }
    let sec = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    return (Date(timeIntervalSince1970: sec), UInt64(max(0, info.st_size)))
  }

  private static func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
      count += 1
      searchRange = found.upperBound..<haystack.endIndex
    }
    return count
  }

  private static func severityRank(_ f: AgentThrashFinding) -> Double {
    switch f.kind {
    case .focusThief: return 1_000_000
    case .loopZombie: return 500_000 + Double(f.errorStreak * 1_000)
    case .tokenVampire:
      let tokScore = Double(f.tokensUsed ?? 0) / 1_000_000.0
      let byteScore = Double(f.transcriptBytes ?? 0) / 1_000_000.0
      let subScore = Double(f.subagentCount ?? 0) * 5.0
      return max(tokScore, max(byteScore, subScore))
    }
  }

  public static func formatTokens(_ tokens: UInt64) -> String {
    if tokens >= 1_000_000_000 {
      return String(format: "%.2fB", Double(tokens) / 1_000_000_000.0)
    } else if tokens >= 1_000_000 {
      return String(format: "%.1fM", Double(tokens) / 1_000_000.0)
    } else if tokens >= 1_000 {
      return String(format: "%.1fK", Double(tokens) / 1_000.0)
    }
    return "\(tokens)"
  }
}
