import Foundation

public struct WorktreeDiscoveryResult: Sendable {
  public var records: [WorktreeRecord] = []
  public var gaps: [String] = []
  public var nextInspection: Int = 0
}

public enum WorktreeDiscovery {
  public static func parse(_ data: Data, repository: String) throws -> [WorktreeRecord] {
    var result: [WorktreeRecord] = [], fields: [String: String] = [:]
    func append() {
      guard let rawPath = fields["worktree"] else { return }
      let path = WorkspaceSafety.canonical(rawPath)
      var r = WorktreeRecord(id: WorkEvidence.hash(repository + "|" + path), path: path, repository: repository)
      r.branch = fields["branch"]; r.head = fields["HEAD"]; r.main = result.isEmpty
      r.bare = fields["bare"] != nil; r.locked = fields["locked"] != nil
      r.missing = !FileManager.default.fileExists(atPath: path)
      r.ownerManaged = ["/.codex/worktrees/", "/.claude/worktrees/", "/.cursor/worktrees/"].contains { path.contains($0) }
      result.append(r); fields = [:]
    }
    for token in data.split(separator: 0, omittingEmptySubsequences: false) {
      if token.isEmpty { append(); continue }
      guard let s = String(data: Data(token), encoding: .utf8) else { throw StoreError.message("Worktree registration contains unsupported byte paths; no lossy inventory accepted.") }
      let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
      fields[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
    }
    append(); return result
  }
  public static func scan(roots: [String], limit: Int = 20_000, seconds: Double = 30,
    visibility: (String) -> Int32 = { _ in -1 }, inspectOffset: Int = 0, publish: (WorktreeRecord) -> Void = { _ in }, progress: () -> Void = {}) -> WorktreeDiscoveryResult {
    var result = WorktreeDiscoveryResult(), repositories = Set<String>(), registeredPaths = Set<String>(), seeds = Set<String>(), count = 0
    let roots = roots.map(WorkspaceSafety.canonical), deadline = ProcessInfo.processInfo.systemUptime + seconds
    for root in roots {
      guard FileManager.default.fileExists(atPath: root) else { result.gaps.append("Discovery root missing or unavailable: " + root); continue }
      seeds.insert(root)
      guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey],
        errorHandler: { url, _ in result.gaps.append("Directory visibility incomplete: " + url.path); return false }) else { result.gaps.append("Cannot enumerate root: " + root); continue }
      let volume = try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
      for case let url as URL in walk {
        count += 1
        if count % 128 == 0 { progress() }
        if Task.isCancelled || count > limit || ProcessInfo.processInfo.systemUptime > deadline {
          result.gaps.append("Discovery budget reached; remaining directories are uninspected."); break
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey])
        if values?.isSymbolicLink == true { walk.skipDescendants(); continue }
        if values == nil { result.gaps.append("Directory entry metadata unavailable: " + url.path); walk.skipDescendants(); continue }
        if let volume, let other = values?.volumeIdentifier, !volume.isEqual(other) { walk.skipDescendants(); continue }
        if url.lastPathComponent == ".git" {
          seeds.insert(url.deletingLastPathComponent().path); walk.skipDescendants()
        } else if values?.isDirectory == true && FileManager.default.fileExists(atPath: url.path + "/HEAD") && FileManager.default.fileExists(atPath: url.path + "/objects") && FileManager.default.fileExists(atPath: url.path + "/config") {
          seeds.insert(url.path); walk.skipDescendants()
        } else if ["node_modules", ".build", "vendor", "Pods", "DerivedData"].contains(url.lastPathComponent) { walk.skipDescendants() }
      }
    }
    for seed in seeds.sorted() {
      progress()
      if registeredPaths.contains(seed) { continue }
      if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline { result.gaps.append("Repository reconciliation incomplete."); break }
      do {
        let common = WorkspaceSafety.canonical(try WorktreeGit.line(seed, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
        guard repositories.insert(common).inserted else { continue }
        let rows = try parse(WorktreeGit.run(seed, ["worktree", "list", "--porcelain", "-z"]), repository: common)
        registeredPaths.formUnion(rows.map(\.path))
        for var row in rows {
          row.gaps = ["Detailed inspection pending."]
          result.records.append(row); publish(row)
        }
      } catch {
        // Ordinary non-repository root seeds are expected; discovered .git seeds are not.
        if FileManager.default.fileExists(atPath: seed + "/.git") { result.gaps.append("Repository inspection unavailable: " + seed) }
      }
    }
    // Inventory is complete before expensive status/files/consumer inspection.
    // Deferred details remain explicit and the next round starts at the cursor.
    let recordCount = result.records.count
    if recordCount > 0 {
      let start = max(0, inspectOffset) % recordCount
      for step in 0..<recordCount {
        let index = (start + step) % recordCount
        if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline {
          result.nextInspection = index
          result.gaps.append("Detailed inspection deferred for \(recordCount - step) worktree(s); next scan resumes from its saved cursor.")
          return result
        }
        var row = result.records[index]
        if roots.contains(where: { WorkspaceSafety.contains($0, row.path) }) {
          row = WorktreeInspection.inspect(row, visibility: visibility)
        } else { row.gaps = ["Registered location is outside discovery permission; add its exact folder to inspect."] }
        result.records[index] = row; publish(row)
      }
    }
    result.nextInspection = 0
    return result
  }
}
