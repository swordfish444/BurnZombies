import Darwin
import Foundation

public struct ExecutionBaton: Codable, Sendable, Equatable {
  public var sessionID: String
  public var sourceAgent: String
  public var cwd: String
  public var branch: String?
  public var headCommit: String?
  public var gitStatusSummary: [String]
  public var lastUserObjective: String?
  public var recentTouchedFiles: [String]
  public var negativeMemory: [String]
  public var generatedAt: Date
  public var markdown: String

  public init(
    sessionID: String, sourceAgent: String, cwd: String, branch: String?, headCommit: String?,
    gitStatusSummary: [String], lastUserObjective: String?, recentTouchedFiles: [String],
    negativeMemory: [String], generatedAt: Date, markdown: String
  ) {
    self.sessionID = sessionID
    self.sourceAgent = sourceAgent
    self.cwd = cwd
    self.branch = branch
    self.headCommit = headCommit
    self.gitStatusSummary = gitStatusSummary
    self.lastUserObjective = lastUserObjective
    self.recentTouchedFiles = recentTouchedFiles
    self.negativeMemory = negativeMemory
    self.generatedAt = generatedAt
    self.markdown = markdown
  }
}

/// Compiles a < 2.4 KB (< ~550 token) Cross-Harness `<execution_baton>` capsule from any Claude
/// Code, Codex, or Antigravity session + Git worktree—including Negative Memory of failed commands
/// so the receiving harness never burns tens of millions of tokens repeating dead ends.
public enum AgentBaton {
  public static let maxCapsuleBytes = 2_400
  private static let tailLimit = 262_144

  public static func compile(
    target: String? = nil, home: String = NSHomeDirectory(), now: Date = Date()
  ) throws -> ExecutionBaton {
    let base = WorkspaceSafety.canonical(home)
    let threads = AgentThreads.index(home: base, now: now).sorted { $0.lastActive > $1.lastActive }
    let resolved = try resolveTarget(target: target, home: base, threads: threads)

    let branch = gitLine(resolved.cwd, ["rev-parse", "--abbrev-ref", "HEAD"])
    let head = gitLine(resolved.cwd, ["log", "-1", "--oneline", "--no-decorate"])
    let statusLines = gitStatusLines(resolved.cwd, limit: 14)

    var objective = resolved.thread?.title
    var touched: [String] = []
    var failures: [String] = []

    if let transcript = resolved.transcriptPath, let tail = readTail(transcript, limit: tailLimit) {
      let parsed = parseTranscriptTail(tail, agent: resolved.agent)
      if let lastGoal = parsed.lastObjective, !lastGoal.isEmpty {
        objective = lastGoal
      }
      touched = parsed.touchedFiles
      failures = parsed.negativeMemory
    }
    if touched.isEmpty {
      touched = statusLines.prefix(8).map { line in
        line.count > 3 ? String(line.dropFirst(3)) : line
      }
    }

    let capsule = formatMarkdown(
      sessionID: resolved.sessionID,
      agent: resolved.agent,
      cwd: resolved.cwd,
      branch: branch,
      head: head,
      statusLines: statusLines,
      objective: objective,
      touched: touched,
      negativeMemory: failures)

    return ExecutionBaton(
      sessionID: resolved.sessionID,
      sourceAgent: resolved.agent,
      cwd: resolved.cwd,
      branch: branch,
      headCommit: head,
      gitStatusSummary: statusLines,
      lastUserObjective: objective,
      recentTouchedFiles: touched,
      negativeMemory: failures,
      generatedAt: now,
      markdown: capsule)
  }

  // MARK: - Target Resolution

  private struct ResolvedTarget {
    var sessionID: String
    var agent: String
    var cwd: String
    var thread: AgentThread?
    var transcriptPath: String?
  }

  private static func resolveTarget(
    target: String?, home: String, threads: [AgentThread]
  ) throws -> ResolvedTarget {
    let trimmed = target?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let query = trimmed, !query.isEmpty {
      // 1. Check if `query` is an existing directory path
      let expanded = query.hasPrefix("~/") ? home + String(query.dropFirst(1)) : query
      var info = stat()
      if lstat(expanded, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
        let canonicalDir = WorkspaceSafety.canonical(expanded)
        let matching = threads.first {
          $0.cwd == canonicalDir || $0.cwd.hasPrefix(canonicalDir + "/")
            || canonicalDir.hasPrefix($0.cwd + "/")
        }
        let sid = matching?.id ?? "worktree:" + URL(fileURLWithPath: canonicalDir).lastPathComponent
        let agent = matching?.agent ?? "worktree"
        let transcript = matching.flatMap { locateTranscript(for: $0, home: home) }
        return ResolvedTarget(
          sessionID: sid, agent: agent, cwd: canonicalDir, thread: matching,
          transcriptPath: transcript)
      }

      // 2. Match against indexed session IDs (`claude:...`, `codex:...`, `antigravity:...`, or bare UUID/prefix)
      if let match = threads.first(where: { thread in
        thread.id == query || thread.id.hasSuffix(":" + query) || thread.id.contains(query)
      }) {
        return ResolvedTarget(
          sessionID: match.id, agent: match.agent, cwd: match.cwd, thread: match,
          transcriptPath: locateTranscript(for: match, home: home))
      }
      throw StoreError.message("No session or folder matched '\(query)'.")
    }

    // Default: newest session in current directory, else newest session overall, else current directory
    let currentDir = WorkspaceSafety.canonical(FileManager.default.currentDirectoryPath)
    if let local = threads.first(where: {
      $0.cwd == currentDir || currentDir.hasPrefix($0.cwd + "/")
    }) {
      return ResolvedTarget(
        sessionID: local.id, agent: local.agent, cwd: local.cwd, thread: local,
        transcriptPath: locateTranscript(for: local, home: home))
    }
    if let newest = threads.first {
      return ResolvedTarget(
        sessionID: newest.id, agent: newest.agent, cwd: newest.cwd, thread: newest,
        transcriptPath: locateTranscript(for: newest, home: home))
    }
    return ResolvedTarget(
      sessionID: "worktree:" + URL(fileURLWithPath: currentDir).lastPathComponent,
      agent: "worktree", cwd: currentDir, thread: nil, transcriptPath: nil)
  }

  private static func locateTranscript(for thread: AgentThread, home: String) -> String? {
    let rawID: String = {
      if let colon = thread.id.firstIndex(of: ":") {
        return String(thread.id[thread.id.index(after: colon)...])
      }
      return thread.id
    }()
    switch thread.agent {
    case "claude":
      let root = home + "/.claude/projects"
      guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else {
        return nil
      }
      for project in projects.prefix(256) {
        let candidate = root + "/" + project + "/" + rawID + ".jsonl"
        if isRegular(candidate) { return candidate }
      }
      return nil
    case "antigravity":
      let candidate =
        home + "/.gemini/antigravity/brain/" + rawID + "/.system_generated/logs/transcript.jsonl"
      return isRegular(candidate) ? candidate : nil
    case "codex":
      let root = home + "/.codex/sessions"
      guard let years = try? FileManager.default.contentsOfDirectory(atPath: root) else {
        return nil
      }
      for year in years.sorted(by: >).prefix(2) {
        let ydir = root + "/" + year
        for month in ((try? FileManager.default.contentsOfDirectory(atPath: ydir)) ?? []).sorted(
          by: >
        ).prefix(3) {
          let mdir = ydir + "/" + month
          for day in ((try? FileManager.default.contentsOfDirectory(atPath: mdir)) ?? []).sorted(
            by: >
          ).prefix(10) {
            let ddir = mdir + "/" + day
            for file in ((try? FileManager.default.contentsOfDirectory(atPath: ddir)) ?? [])
            where file.contains(rawID) && file.hasSuffix(".jsonl") {
              let candidate = ddir + "/" + file
              if isRegular(candidate) { return candidate }
            }
          }
        }
      }
      return nil
    default:
      return nil
    }
  }

  // MARK: - Transcript Extraction

  private static func parseTranscriptTail(_ data: Data, agent: String) -> (
    lastObjective: String?, touchedFiles: [String], negativeMemory: [String]
  ) {
    let lines = String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: true)
    var lastObjective: String?
    var touched: [String] = []
    var touchedSeen = Set<String>()
    var negative: [String] = []
    var negativeSeen = Set<String>()

    func addTouched(_ raw: String) {
      let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty, clean.count <= 180, !clean.contains("\n") else { return }
      if touchedSeen.insert(clean).inserted { touched.append(clean) }
    }
    func addNegative(_ raw: String) {
      let collapsed =
        raw
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard collapsed.count >= 8 else { return }
      let clipped = collapsed.count > 140 ? String(collapsed.prefix(137)) + "..." : collapsed
      if negativeSeen.insert(clipped).inserted { negative.append(clipped) }
    }

    for line in lines {
      guard line.first == "{",
        let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
      else { continue }

      // Antigravity USER_INPUT or PLANNER_RESPONSE
      if let type = obj["type"] as? String {
        if type == "USER_INPUT", let content = obj["content"] as? String {
          let cleaned = stripTags(content)
          if cleaned.count >= 6 { lastObjective = cleaned }
        }
        if type == "user", let msg = obj["message"] as? [String: Any] {
          if let text = extractMessageText(msg), text.count >= 6 {
            lastObjective = text
          }
        }
        if type == "rate_limit_event" {
          addNegative("Primary harness hit usage/rate limit; switch harness instead of retrying.")
        }
      }

      // Codex response_item / event_msg
      if let payload = obj["payload"] as? [String: Any] {
        if payload["role"] as? String == "user", let text = extractMessageText(payload),
          text.count >= 6
        {
          lastObjective = text
        }
        if let argsStr = payload["arguments"] as? String,
          let argsObj = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)))
            as? [String: Any]
        {
          for key in ["file_path", "path", "Path"] {
            if let p = argsObj[key] as? String { addTouched(p) }
          }
        }
        if let output = payload["output"] as? String,
          output.contains("Exit code ") && !output.contains("Exit code 0")
        {
          addNegative(firstErrorLine(in: output))
        }
      }

      // Claude tool_use / tool_result inside message.content
      if let msg = obj["message"] as? [String: Any],
        let blocks = msg["content"] as? [[String: Any]]
      {
        for block in blocks {
          if block["type"] as? String == "tool_use",
            let input = block["input"] as? [String: Any]
          {
            for key in ["file_path", "path", "Path"] {
              if let p = input[key] as? String { addTouched(p) }
            }
          }
          if block["type"] as? String == "tool_result", block["is_error"] as? Bool == true {
            if let text = block["content"] as? String {
              addNegative(firstErrorLine(in: text))
            }
          }
        }
      }

      // Antigravity tool_calls
      if let calls = obj["tool_calls"] as? [[String: Any]] {
        for call in calls {
          if let args = call["arguments"] as? [String: Any] ?? call["args"] as? [String: Any] {
            for key in ["Path", "file_path", "path"] {
              if let p = args[key] as? String { addTouched(p) }
            }
          }
        }
      }
      if obj["status"] as? String == "ERROR", let content = obj["content"] as? String {
        addNegative(firstErrorLine(in: content))
      }
    }

    let trimmedObjective = lastObjective.map { text in
      text.count > 260 ? String(text.prefix(257)) + "..." : text
    }
    return (
      lastObjective: trimmedObjective,
      touchedFiles: Array(touched.suffix(8)),
      negativeMemory: Array(negative.suffix(5))
    )
  }

  private static func formatMarkdown(
    sessionID: String, agent: String, cwd: String, branch: String?, head: String?,
    statusLines: [String], objective: String?, touched: [String], negativeMemory: [String]
  ) -> String {
    var lines: [String] = []
    lines.append("<execution_baton>")
    lines.append("source_session: \(sessionID) (\(agent))")
    lines.append("workspace: \(cwd)")
    if let branch {
      lines.append("git_branch: \(branch)\(head.map { " @ \($0)" } ?? "")")
    }
    if let objective, !objective.isEmpty {
      lines.append("")
      lines.append("## Active Objective")
      lines.append(objective)
    }
    if !statusLines.isEmpty {
      lines.append("")
      lines.append("## Uncommitted Git State")
      for s in statusLines.prefix(10) { lines.append("- \(s)") }
    }
    if !touched.isEmpty {
      lines.append("")
      lines.append("## Recently Touched Files")
      for f in touched.prefix(6) { lines.append("- \(f)") }
    }
    if !negativeMemory.isEmpty {
      lines.append("")
      lines.append("## Negative Memory (Do NOT Repeat These Dead Ends)")
      for err in negativeMemory.prefix(5) { lines.append("- \(err)") }
    }
    lines.append("")
    lines.append(
      "Resume directly from the workspace state above without re-scanning unrelated directories.")
    lines.append("</execution_baton>")

    var joined = lines.joined(separator: "\n")
    if joined.utf8.count > maxCapsuleBytes {
      let clipped = String(decoding: joined.utf8.prefix(maxCapsuleBytes - 36), as: UTF8.self)
      joined = clipped + "\n...</execution_baton>"
    }
    return joined
  }

  // MARK: - Low-level Helpers

  private static func gitLine(_ cwd: String, _ args: [String]) -> String? {
    guard let data = try? WorktreeGit.run(cwd, args, seconds: 5) else { return nil }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func gitStatusLines(_ cwd: String, limit: Int) -> [String] {
    guard let data = try? WorktreeGit.run(cwd, ["status", "--short"], seconds: 5) else {
      return []
    }
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .prefix(limit)
      .map(String.init)
  }

  private static func extractMessageText(_ dict: [String: Any]) -> String? {
    if let s = dict["content"] as? String {
      let clean = stripTags(s)
      return clean.isEmpty ? nil : clean
    }
    if let arr = dict["content"] as? [[String: Any]] {
      for item in arr {
        if let text = item["text"] as? String {
          let clean = stripTags(text)
          if !clean.isEmpty, !clean.hasPrefix("<environment_context>") { return clean }
        }
      }
    }
    return nil
  }

  private static func stripTags(_ raw: String) -> String {
    var s = raw
    if let open = s.range(of: "<USER_REQUEST>"), let close = s.range(of: "</USER_REQUEST>"),
      open.upperBound <= close.lowerBound
    {
      s = String(s[open.upperBound..<close.lowerBound])
    }
    return
      s
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func firstErrorLine(in text: String) -> String {
    let parts = text.split(separator: "\n", omittingEmptySubsequences: true)
    for part in parts {
      let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func readTail(_ path: String, limit: Int) -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let size = Int(info.st_size)
    guard size > 0 else { return nil }
    _ = lseek(fd, off_t(max(0, size - limit)), SEEK_SET)
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

  private static func isRegular(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
  }
}
