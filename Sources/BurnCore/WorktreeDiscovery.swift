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

extension ProtectedLocations {
  /// The protected place one of a repository's registered checkouts is in. Git looks at every
  /// one before it adds, moves, removes or lists a checkout.
  func registryPlace(_ common: String) -> String? {
    guard !unrestricted else { return nil }
    if let place = resolution(common).place { return place }
    guard let copies = try? WorktreeDiscovery.registered(common) else {
      return "a place macOS protects"
    }
    for copy in copies where resolve(copy.path) == nil {
      return resolution(copy.path).place ?? "a place macOS protects"
    }
    return nil
  }
}

public enum WorktreeDiscovery {
  static func roundRobinRepositories(_ rows: [WorktreeRecord], after: String? = nil)
    -> [WorktreeRecord]
  {
    let groups = Dictionary(grouping: rows, by: \.repository)
    var active = groups.keys.sorted()
    if let after, let index = active.firstIndex(where: { $0 > after }) {
      active = Array(active[index...]) + Array(active[..<index])
    }
    var offset = 0
    var result: [WorktreeRecord] = []
    while !active.isEmpty {
      var next: [String] = []
      for key in active {
        let group = groups[key]!
        result.append(group[offset])
        if group.count > offset + 1 { next.append(key) }
      }
      active = next
      offset += 1
    }
    return result
  }
  public static func ownerManaged(_ path: String) -> Bool {
    ["/.codex/worktrees/", "/.claude/worktrees/", "/.cursor/worktrees/"].contains {
      path.contains($0)
    }
  }
  public static func parse(
    _ data: Data, repository: String, protected: ProtectedLocations? = nil
  ) throws -> [WorktreeRecord] {
    var result: [WorktreeRecord] = []
    var fields: [String: String] = [:]
    func append() {
      guard let rawPath = fields["worktree"] else { return }
      let (path, place) = located(rawPath, protected: protected)
      var r = WorktreeRecord(
        id: WorkEvidence.hash(repository + "|" + path), path: path, repository: repository)
      r.branch = fields["branch"]
      r.head = fields["HEAD"]
      r.main = result.isEmpty
      r.bare = fields["bare"] != nil
      r.locked = fields["locked"] != nil
      r.protectedPlace = place
      r.missing = place == nil && !FileManager.default.fileExists(atPath: path)
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
  /// A registered checkout's canonical path, or its spelling and the protected place it is in
  /// when it may not be looked at.
  static func located(_ path: String, protected: ProtectedLocations?) -> (String, String?) {
    guard let protected else { return (WorkspaceSafety.canonical(path), nil) }
    let found = protected.resolution(path)
    if let place = found.place { return (ProtectedLocations.lexical(path), place) }
    return (found.real ?? WorkspaceSafety.canonical(path), nil)
  }
  /// Linked checkouts as Git recorded them, read from the repository without asking Git.
  static func registered(_ common: String) throws -> [(name: String, path: String)] {
    let parent = common + "/worktrees"
    var info = stat()
    guard lstat(parent, &info) == 0 else {
      guard errno == ENOENT else { throw StoreError.message("Worktree registry unreadable.") }
      return []
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw StoreError.message("Worktree registry is not a directory.")
    }
    return try FileManager.default.contentsOfDirectory(atPath: parent).sorted().compactMap {
      name in
      // Git skips an entry without a readable checkout pointer, so this does too.
      guard let pointer = ProtectedLocations.text(parent + "/" + name + "/gitdir") else {
        return nil
      }
      var path = ProtectedLocations.lexical(
        pointer.hasPrefix("/") ? pointer : parent + "/" + name + "/" + pointer)
      if path.hasSuffix("/.git") { path.removeLast(5) }
      return (name, path)
    }
  }
  /// The rows `git worktree list` gives. Listing makes Git look inside every registered
  /// checkout, so a repository with one in a protected place is read directly instead.
  static func listing(_ seed: String, common: String, protected: ProtectedLocations) throws
    -> [WorktreeRecord]
  {
    guard !protected.unrestricted,
      try registered(common).contains(where: { protected.resolution($0.path).real == nil })
    else {
      return try parse(
        WorktreeGit.run(seed, ["worktree", "list", "--porcelain", "-z"]), repository: common,
        protected: protected)
    }
    var tips: [String: String] = [:]
    for line in try WorktreeGit.text(
      common,
      ["--git-dir=" + common, "for-each-ref", "--format=%(refname)%00%(objectname)", "refs/heads"]
    ).split(separator: "\n") {
      let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
      if parts.count == 2 { tips[String(parts[0])] = String(parts[1]) }
    }
    func head(_ administration: String) -> (branch: String?, head: String?) {
      guard let text = ProtectedLocations.text(administration + "/HEAD") else { return (nil, nil) }
      guard text.hasPrefix("ref: ") else { return (nil, text) }
      let ref = String(text.dropFirst(5))
      return (ref, tips[ref])
    }
    let bare = !common.hasSuffix("/.git")
    let anchor = bare ? common : String(common.dropLast(5))
    var main = WorktreeRecord(
      id: WorkEvidence.hash(common + "|" + anchor), path: anchor, repository: common)
    if !bare { (main.branch, main.head) = head(common) }
    main.main = true
    main.bare = bare
    main.missing = !FileManager.default.fileExists(atPath: anchor)
    main.ownerManaged = ownerManaged(anchor)
    var rows = [main]
    for (name, raw) in try registered(common) {
      let administration = common + "/worktrees/" + name
      let (path, place) = located(raw, protected: protected)
      var row = WorktreeRecord(
        id: WorkEvidence.hash(common + "|" + path), path: path, repository: common)
      (row.branch, row.head) = head(administration)
      row.locked = FileManager.default.fileExists(atPath: administration + "/locked")
      row.protectedPlace = place
      row.missing = place == nil && !FileManager.default.fileExists(atPath: path)
      row.ownerManaged = ownerManaged(path)
      rows.append(row)
    }
    return rows
  }
  public static func scan(
    roots: [String], limit: Int = 20_000, seconds: Double = 30,
    visibility: (String) -> Int32 = { _ in -1 }, inspectOffset: Int = 0,
    publish: (WorktreeRecord) -> Void = { _ in }, progress: () -> Void = {}, checkpoint: URL? = nil,
    protected: ProtectedLocations = .limited()
  ) -> WorktreeDiscoveryResult {
    var result = WorktreeDiscoveryResult()
    var repositories = Set<String>()
    var registeredPaths = Set<String>()
    var seeds = Set<String>()
    // A place macOS protects is skipped by its name, before anything inside it is read.
    func skip(_ path: String, _ place: String) {
      result.gaps.append("Skipped " + path + ". " + ProtectedLocations.reason(place))
    }
    let configured = roots
    let roots = roots.compactMap { root -> String? in
      let found = protected.resolution(root)
      if let place = found.place {
        skip(root, place)
        return nil
      }
      return found.real ?? WorkspaceSafety.canonical(root)
    }.sorted()
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
      // A saved frontier can predate the current access.
      if let place = protected.place(path) {
        skip(path, place)
        continue
      }
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
        if let place = protected.place(child.path) {
          skip(child.path, place)
          continue
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
    if configured.isEmpty { result.gaps.append("No discovery folders configured.") }
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
      // Git follows a checkout's pointer to its repository, so check where it leads first.
      if let place = protected.pointerPlace(seed) {
        result.gaps.append(
          "Skipped " + seed + ": its repository is in " + place
            + ", which macOS protects. Turn on Full Disk Access so BurnZombies can check it.")
        continue
      }
      do {
        let common = WorkspaceSafety.canonical(
          try WorktreeGit.line(seed, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
        guard repositories.insert(common).inserted else { continue }
        let rows = try listing(seed, common: common, protected: protected)
        registeredPaths.formUnion(rows.map(\.path))
        for var row in rows {
          if let place = row.protectedPlace {
            row.gaps = ["Not checked. " + ProtectedLocations.reason(place)]
          } else if row.main || row.bare || row.ownerManaged {
            row.blockers = [
              row.ownerManaged
                ? "Use the owning application's supported archive/restore workflow."
                : "Main and bare repository anchors are protected."
            ]
            row.gaps = [
              "Protected inventory: file and consumer details are not measured automatically. Use Inspect for current details."
            ]
          } else if !roots.contains(where: { WorkspaceSafety.contains($0, row.path) }) {
            row.gaps = [
              "Registered location is outside discovery permission; add its exact folder to inspect."
            ]
          } else {
            row.gaps = ["Detailed inspection pending."]
          }
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
    let detailed = roundRobinRepositories(
      result.records.filter { row in
        !row.main && !row.bare && !row.ownerManaged && row.protectedPlace == nil
          && roots.contains(where: { WorkspaceSafety.contains($0, row.path) })
      })
    let positions = Dictionary(
      uniqueKeysWithValues: result.records.enumerated().map { ($0.element.id, $0.offset) })
    let recordCount = detailed.count
    if recordCount > 0 {
      let start = max(0, inspectOffset) % recordCount
      for step in 0..<recordCount {
        let position = (start + step) % recordCount
        let index = positions[detailed[position].id]!
        if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline {
          result.nextInspection = position
          result.gaps.append(
            "Detailed inspection deferred for \(recordCount - step) worktree(s); next scan resumes from its saved cursor."
          )
          return result
        }
        var row = result.records[index]
        if roots.contains(where: { WorkspaceSafety.contains($0, row.path) }) {
          row = WorktreeInspection.inspect(row, visibility: visibility, protected: protected)
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
