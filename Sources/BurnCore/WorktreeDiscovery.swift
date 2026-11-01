import Foundation

public struct WorktreeDiscoveryResult: Sendable {
  public var records: [WorktreeRecord] = []
  public var gaps: [String] = []
  public var nextInspection: Int = 0
  public var unavailablePaths: [String: String] = [:]
  public var workerCompleted = false
  public var inspectionInProgress: String?
  public var inspectionStartedAt: Date?
  public var inspectionElapsed: TimeInterval?
  public var deferred = false
}

private struct WorktreeDiscoveryFrontier: Codable {
  var roots: [String]
  var directories: [String]
  var seeds: [String] = []
}

public enum WorktreeDiscovery {
  public static func ownerManaged(_ path: String) -> Bool {
    ["/.codex/worktrees/", "/.claude/worktrees/", "/.cursor/worktrees/"].contains {
      path.contains($0)
    }
  }
  public static func parse(_ data: Data, repository: String) throws -> [WorktreeRecord] {
    var result: [WorktreeRecord] = []
    var fields: [String: String] = [:]
    func append() {
      guard let rawPath = fields["worktree"] else { return }
      let path = WorkspaceSafety.canonical(rawPath)
      var r = WorktreeRecord(
        id: WorkEvidence.hash(repository + "|" + path), path: path, repository: repository)
      r.branch = fields["branch"]
      r.head = fields["HEAD"]
      r.main = result.isEmpty
      r.bare = fields["bare"] != nil
      r.locked = fields["locked"] != nil
      r.missing = !FileManager.default.fileExists(atPath: path)
      r.ownerManaged = ownerManaged(path)
      result.append(r)
      fields = [:]
    }
    for token in data.split(separator: 0, omittingEmptySubsequences: false) {
      if token.isEmpty {
        append()
        continue
      }
      guard let s = String(data: Data(token), encoding: .utf8) else {
        throw StoreError.message(
          "Worktree registration contains unsupported byte paths; no lossy inventory accepted.")
      }
      let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
      fields[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
    }
    append()
    return result
  }
  public static func scan(
    roots: [String], limit: Int = 20_000, seconds: Double = 30,
    visibility: (String) -> Int32 = { _ in -1 }, inspectOffset: Int = 0,
    publish: (WorktreeRecord) -> Void = { _ in }, progress: () -> Void = {}, checkpoint: URL? = nil
  ) -> WorktreeDiscoveryResult {
    var result = WorktreeDiscoveryResult()
    var repositories = Set<String>()
    var registeredPaths = Set<String>()
    var seeds = Set<String>()
    let roots = roots.map(WorkspaceSafety.canonical).sorted()
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    let discoveryDeadline = ProcessInfo.processInfo.systemUptime + max(0, seconds / 3)
    var frontier = WorktreeDiscoveryFrontier(roots: roots, directories: roots)
    if let checkpoint, let store = try? Store(root: checkpoint.deletingLastPathComponent()),
      let data = try? store.read(checkpoint, limit: 2_097_152),
      let saved = try? JSONDecoder().decode(WorktreeDiscoveryFrontier.self, from: data),
      saved.roots == roots, !saved.directories.isEmpty,
      saved.directories.count + saved.seeds.count <= 40_000
    {
      frontier = saved
    }
    seeds.formUnion(frontier.seeds)
    var visited = 0
    // Repositories are discovery leaves. Git enumerates their linked checkouts;
    // walking every generated file first used to exhaust the discovery budget.
    while !frontier.directories.isEmpty, visited < limit,
      ProcessInfo.processInfo.systemUptime < discoveryDeadline, !Task.isCancelled
    {
      let path = frontier.directories.removeFirst()
      visited += 1
      if visited % 64 == 0 { progress() }
      let url = URL(fileURLWithPath: path)
      guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true, values.isSymbolicLink != true
      else {
        let gap = "Discovery directory unavailable or linked: " + path
        result.gaps.append(gap)
        result.unavailablePaths[path] = gap
        continue
      }
      if FileManager.default.fileExists(atPath: path + "/.git")
        || (FileManager.default.fileExists(atPath: path + "/HEAD")
          && FileManager.default.fileExists(atPath: path + "/objects")
          && FileManager.default.fileExists(atPath: path + "/config"))
      {
        seeds.insert(path)
        continue
      }
      guard
        let walk = FileManager.default.enumerator(
          at: url,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey],
          options: [.skipsSubdirectoryDescendants],
          errorHandler: { failed, _ in
            result.gaps.append("Directory visibility incomplete: " + failed.path)
            return false
          })
      else {
        result.gaps.append("Cannot enumerate root: " + path)
        continue
      }
      let volume = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
      var children = [String]()
      var entries = 0
      for case let child as URL in walk {
        entries += 1
        if entries > 20_000 || children.count + frontier.directories.count >= 20_000 {
          result.gaps.append(
            "Discovery directory exceeds the entry bound; add a more specific folder: " + path)
          break
        }
        guard
          !["node_modules", ".build", "vendor", "Pods", "DerivedData"].contains(
            child.lastPathComponent),
          let metadata = try? child.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .volumeIdentifierKey,
          ]),
          metadata.isDirectory == true, metadata.isSymbolicLink != true
        else { continue }
        if let volume, let other = metadata.volumeIdentifier, !volume.isEqual(other) { continue }
        children.append(child.path)
      }
      frontier.directories.append(contentsOf: children.sorted())
    }
    if roots.isEmpty { result.gaps.append("No discovery folders configured.") }
    if !frontier.directories.isEmpty {
      result.gaps.append(
        "Discovery is incomplete; remaining directories are saved for the next scan.")
    }
    frontier.seeds = Array(seeds.sorted().prefix(20_000))
    if let checkpoint, let store = try? Store(root: checkpoint.deletingLastPathComponent()),
      let data = try? JSONEncoder().encode(frontier)
    {
      do { try store.write(data, to: checkpoint, limit: 2_097_152) } catch {
        result.gaps.append("Discovery progress could not be saved; remaining coverage is unknown.")
      }
    }
    for seed in seeds.sorted() {
      progress()
      if registeredPaths.contains(seed) { continue }
      if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline {
        result.gaps.append("Repository reconciliation incomplete.")
        break
      }
      do {
        let common = WorkspaceSafety.canonical(
          try WorktreeGit.line(seed, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
        guard repositories.insert(common).inserted else { continue }
        let rows = try parse(
          WorktreeGit.run(seed, ["worktree", "list", "--porcelain", "-z"]), repository: common)
        registeredPaths.formUnion(rows.map(\.path))
        for var row in rows {
          row.gaps = ["Detailed inspection pending."]
          result.records.append(row)
          publish(row)
        }
      } catch {
        // Ordinary non-repository root seeds are expected; discovered .git seeds are not.
        if FileManager.default.fileExists(atPath: seed + "/.git") {
          let gap = "Repository inspection unavailable: " + seed
          result.gaps.append(gap)
          result.unavailablePaths[seed] = gap
        }
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
          result.gaps.append(
            "Detailed inspection deferred for \(recordCount - step) worktree(s); next scan resumes from its saved cursor."
          )
          return result
        }
        var row = result.records[index]
        if roots.contains(where: { WorkspaceSafety.contains($0, row.path) }) {
          row = WorktreeInspection.inspect(row, visibility: visibility)
        } else {
          row.gaps = [
            "Registered location is outside discovery permission; add its exact folder to inspect."
          ]
        }
        result.records[index] = row
        publish(row)
      }
    }
    result.nextInspection = 0
    return result
  }
}
