import CBurn
import Foundation

/// Where a worktree's commits are saved. Cached per HEAD; recomputed at retire time.
public struct AutopilotDelivery: Codable, Sendable, Equatable {
  public var head: String
  /// `merged`, `pushed`, `local` or `unknown`.
  public var saved: String
  public var checked: Date
  public init(head: String, saved: String, checked: Date = Date()) {
    self.head = head
    self.saved = saved
    self.checked = checked
  }
}

/// Old copies: facts from the worktree inventory plus Git delivery state, and a
/// restorable retirement that keeps every local change in a safety ref.
public enum AutopilotWorktrees {
  /// Folders that tools rebuild by themselves. Ignored files inside them are never backed up.
  private static let rebuildable: Set<String> = [
    "node_modules", ".build", "build", "dist", "target", ".next", ".turbo", ".gradle",
    "DerivedData", ".venv", "venv", "__pycache__", "Pods", ".cache",
  ]
  private static let ignoredFileLimit: UInt64 = 5 << 20
  private static let ignoredTotalLimit: UInt64 = 100 << 20
  private static let walkLimit = 100_000
  /// Untracked, unignored content larger than this is never copied into a safety commit.
  static let maximumUnsavedBytes: UInt64 = 512 << 20
  private static let refPrefix = "refs/burnzombies/retired/"
  private static let stateFiles = [
    "locked", "index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
    "BISECT_START", "rebase-merge", "rebase-apply", "sequencer",
  ]

  private struct Refusal: Error {
    var reason: String
    init(_ reason: String) { self.reason = reason }
  }
  private struct Candidate {
    var path: String
    var size: UInt64
    var depth: Int
  }

  // MARK: Catalog

  /// `delivery` caches Git delivery state by worktree record id; `budget` bounds how many
  /// fresh Git lookups one call may spend.
  public static func items(
    _ records: [WorktreeRecord], threads: [AgentThread],
    delivery cache: inout [String: AutopilotDelivery], now: Date = Date(), budget: Int = 100
  ) -> [AutopilotItem] {
    var remaining = budget
    var result: [AutopilotItem] = []
    for record in records where !record.missing && !record.retired && !record.bare {
      let chat = AgentThreads.state(for: record.path, threads: threads)
      let saved = savedFact(record, cache: &cache, now: now, budget: &remaining)
      let changes = record.status.isEmpty ? "unknown" : changesBucket(record.changes)
      let dates: [Date?] = [record.lastFileChange, record.lastCommitAt, chat.lastActive]
      let newest = dates.compactMap { $0 }.max()
      let repo = repoName(record)
      let facts: [String: String] = [
        "place": placeFact(record), "repo": repo, "saved": saved, "changes": changes,
        "stale": newest.map { AutopilotPolicy.stale(since: $0, now: now) } ?? "unknown",
        "thread": chat.thread, "inUse": inUseFact(record), "size": sizeFact(record.allocated),
      ]
      let sentence = detail(
        repo: repo, branch: branchName(record), saved: saved, changes: changes, newest: newest,
        now: now)
      result.append(
        AutopilotItem(
          id: "worktree:" + record.id, kind: .worktree,
          name: (record.path as NSString).lastPathComponent, detail: sentence, path: record.path,
          bytes: record.allocated, facts: facts,
          protectedReason: protectedReason(record, thread: chat.thread),
          observedAt: record.observedAt))
    }
    return result
  }

  private static func savedFact(
    _ record: WorktreeRecord, cache: inout [String: AutopilotDelivery], now: Date,
    budget: inout Int
  ) -> String {
    if let cached = cache[record.id], cached.head == record.head,
      now.timeIntervalSince(cached.checked) < 86_400
    {
      return cached.saved
    }
    guard budget > 0 else { return "unknown" }
    budget -= 1
    guard let fresh = try? delivery(path: record.path) else { return "unknown" }
    cache[record.id] = fresh
    return fresh.saved
  }

  private static func changesBucket(_ count: Int) -> String {
    count <= 0 ? "none" : count <= 20 ? "small" : "large"
  }

  private static func sizeFact(_ bytes: UInt64) -> String {
    bytes < 100_000_000 ? "small" : bytes < 1_000_000_000 ? "medium" : "large"
  }

  private static func inUseFact(_ record: WorktreeRecord) -> String {
    switch record.consumer {
    case "in use": return "yes"
    case "none observed": return "no"
    default: return "unknown"
    }
  }

  /// The folder of the repository's main checkout (its `.git` directory's parent).
  private static func mainCheckout(_ record: WorktreeRecord) -> String {
    record.repository.hasSuffix("/.git")
      ? (record.repository as NSString).deletingLastPathComponent : record.repository
  }

  private static func repoName(_ record: WorktreeRecord) -> String {
    var name = (mainCheckout(record) as NSString).lastPathComponent
    if name.count > 4, name.hasSuffix(".git") { name = String(name.dropLast(4)) }
    return name.isEmpty ? "unknown" : name
  }

  private static func placeFact(_ record: WorktreeRecord) -> String {
    let path = record.path.lowercased()
    if path.contains("/.patrol6/worktrees/") { return "patrol6" }
    if path.contains("/.codex/worktrees/") { return "codex" }
    if path.contains("/.claude/worktrees/") || path.contains("/.claude-worktrees/") {
      return "claude"
    }
    if path.contains("/conductor/") { return "conductor" }
    let parent = (record.path as NSString).deletingLastPathComponent
    let mainParent = (mainCheckout(record) as NSString).deletingLastPathComponent
    return parent == mainParent ? "sibling" : "other"
  }

  private static func branchName(_ record: WorktreeRecord) -> String? {
    guard let branch = record.branch, !branch.isEmpty else { return nil }
    return branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
  }

  /// Hard rails that keep an item out of every rule. Owner-managed copies are not protected.
  private static func protectedReason(_ record: WorktreeRecord, thread: String) -> String? {
    if record.main { return "This is your main project folder." }
    if record.locked || record.blockers.contains("Git worktree lock is set.") {
      return "It is locked, so I will leave it alone."
    }
    if record.consumer == "in use" { return "Something is using it right now." }
    if thread == "live" { return "A chat is still working in it." }
    if record.blockers.contains(where: { $0.hasPrefix("Git state requires completion") }) {
      return "Git is in the middle of something in it."
    }
    return nil
  }

  private static func detail(
    repo: String, branch: String?, saved: String, changes: String, newest: Date?, now: Date
  ) -> String {
    var parts: [String]
    switch saved {
    case "merged": parts = ["merged"]
    case "pushed": parts = ["pushed but not merged"]
    case "local": parts = ["saved only on this Mac"]
    default: parts = ["not checked yet"]
    }
    if changes == "small" { parts.append("a few unsaved changes") }
    if changes == "large" { parts.append("lots of unsaved changes") }
    if let newest { parts.append(untouched(since: newest, now: now)) }
    let place = branch.map { " on " + $0 } ?? ""
    return "Copy of \(repo)\(place) — " + parts.joined(separator: ", ") + "."
  }

  private static func untouched(since date: Date, now: Date) -> String {
    let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
    func count(_ number: Int, _ unit: String) -> String {
      "untouched for \(number) \(unit)" + (number == 1 ? "" : "s")
    }
    switch days {
    case 0: return "used today"
    case 1..<14: return count(days, "day")
    case 14..<60: return count(days / 7, "week")
    case 60..<365: return count(days / 30, "month")
    default: return count(days / 365, "year")
    }
  }

  // MARK: Delivery

  /// `merged` when HEAD is part of the default branch, `pushed` when any remote branch has it,
  /// otherwise `local`. Only reads refs; never touches the network.
  public static func delivery(path: String) throws -> AutopilotDelivery {
    let head = try line(path, ["rev-parse", "--verify", "HEAD^{commit}"])
    var candidates: [String] = []
    if let target = try? line(path, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]),
      target.hasPrefix("refs/remotes/")
    {
      candidates.append(target)
    }
    candidates += [
      "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main",
      "refs/heads/master",
    ]
    let listed = try lines(path, ["for-each-ref", "--format=%(refname)"] + candidates)
    let existing = Set(listed)
    var merged = false
    if let base = candidates.first(where: { existing.contains($0) }) {
      let containing = try lines(
        path, ["for-each-ref", "--contains=" + head, "--format=%(refname)", base])
      merged = containing.contains(base)
    }
    var saved = "merged"
    if !merged {
      let remotes = try lines(
        path, ["for-each-ref", "--contains=" + head, "--format=%(refname)", "refs/remotes"])
      saved = remotes.isEmpty ? "local" : "pushed"
    }
    return AutopilotDelivery(head: head, saved: saved, checked: Date())
  }

  // MARK: Retire

  /// Removes an old copy only after everything in it is safe: committed work is recorded at
  /// HEAD, local changes go into a snapshot commit, and either way a safety ref in the
  /// repository keeps it restorable. `root` is a private folder for scratch files; nothing in it
  /// outlives the call. Refusals leave the copy untouched.
  public static func retire(
    _ item: AutopilotItem, authority: String, root: URL,
    inUse: (String) -> Int32 = { bz_path_in_use($0) }, protected: ProtectedLocations? = nil
  ) -> AutopilotReceipt {
    guard item.kind == .worktree, item.id.hasPrefix("worktree:"), let path = item.path else {
      return .refused(item, authority: authority, "This is not an old copy I can retire.")
    }
    if let reason = item.protectedReason { return .refused(item, authority: authority, reason) }
    if let reason = refusal(path, protected ?? .current(root: root)) {
      return .refused(item, authority: authority, reason)
    }
    do {
      return try perform(item, path: path, authority: authority, root: root, inUse: inUse)
    } catch let refusal as Refusal {
      return .refused(item, authority: authority, refusal.reason)
    } catch {
      return .refused(
        item, authority: authority, "I could not check it safely, so I left it alone.")
    }
  }

  /// Why Autopilot may not touch a copy without Full Disk Access: it, the project it belongs
  /// to, or another copy of that project is in a place macOS protects, and Git looks at all
  /// of them when it removes one.
  static func refusal(_ path: String, _ protected: ProtectedLocations) -> String? {
    guard !protected.unrestricted else { return nil }
    let repository = protected.repository(of: path)
    if let place = protected.resolution(path).place ?? repository.place {
      return AutopilotDisk.protectedRefusal(place)
    }
    if let place = repository.common.flatMap(protected.registryPlace) {
      return "Another copy of this project is in " + place
        + ", which macOS protects, and Git checks every copy, so I left it alone. Turn on Full Disk Access to let me clean it up."
    }
    return nil
  }

  private static func perform(
    _ item: AutopilotItem, path: String, authority: String, root: URL, inUse: (String) -> Int32
  ) throws -> AutopilotReceipt {
    let fm = FileManager.default

    // A real, linked worktree that is not locked, mid-operation or in use.
    var folder = stat()
    guard lstat(path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR else {
      throw Refusal("The folder is already gone.")
    }
    let gitDir = WorkspaceSafety.canonical(try line(path, ["rev-parse", "--absolute-git-dir"]))
    let common = WorkspaceSafety.canonical(
      try line(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
    guard gitDir != common else { throw Refusal("This is your main project folder.") }
    let top = WorkspaceSafety.canonical(try line(path, ["rev-parse", "--show-toplevel"]))
    guard gitDir.hasPrefix(common + "/worktrees/"), top == WorkspaceSafety.canonical(path) else {
      throw Refusal("I can't tell how this copy is connected to its project, so I left it alone.")
    }
    for name in stateFiles {
      var marker = stat()
      if lstat(gitDir + "/" + name, &marker) == 0 {
        throw Refusal(
          name == "locked"
            ? "It is locked, so I left it alone."
            : "Git is in the middle of something in it, so I left it alone.")
      }
      guard errno == ENOENT else {
        throw Refusal("I could not check it safely, so I left it alone.")
      }
    }
    switch inUse(path) {
    case 0: break
    case 1: throw Refusal("Something is using it right now.")
    default:
      throw Refusal("I could not check whether something is using it, so I left it alone.")
    }

    // What the catalog said must still be true, recomputed from the current HEAD. A fact it
    // had not checked yet may only turn out safe; anything riskier is judged again.
    let head = try line(path, ["rev-parse", "--verify", "HEAD^{commit}"])
    let current = try delivery(path: path)
    let changes = try currentChanges(path)
    let checks = [("saved", current.saved, ["merged", "pushed"]), ("changes", changes, ["none"])]
    for (fact, live, safe) in checks where item.facts[fact] != live {
      guard item.facts[fact] == "unknown" else {
        throw Refusal("This copy changed since I last looked.")
      }
      guard safe.contains(live) else {
        throw Refusal("I hadn't finished checking this copy, so I'll judge it again.")
      }
    }

    // Submodule content lives inside the worktree's own Git folder and goes with it.
    let links = try gitlinks(path, environment: [:])
    if let reason = try submoduleRefusal(path, links: links, depth: 0) {
      throw Refusal(reason)
    }

    // Big unsaved files would be copied into the repository's own storage; ask instead.
    var unsaved: UInt64 = 0
    let untracked = try WorktreeGit.run(
      path, ["ls-files", "-z", "--others", "--exclude-standard"], seconds: 60)
    for name in untracked.split(separator: 0) {
      var info = stat()
      if lstat(path + "/" + String(decoding: name, as: UTF8.self), &info) == 0,
        info.st_mode & S_IFMT == S_IFREG
      {
        unsaved += UInt64(max(0, info.st_size))
      }
      if unsaved > maximumUnsavedBytes {
        throw Refusal(
          "It has big files that aren't saved anywhere else, so I'll ask you before touching it.")
      }
    }

    // Snapshot with a throwaway copy of the index so the real one is never touched.
    let work = root.appendingPathComponent(
      "worktree-scratch-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(
      at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: work) }
    let index = work.appendingPathComponent("index").path
    let indexEnvironment = ["GIT_INDEX_FILE": index]
    if fm.fileExists(atPath: gitDir + "/index") {
      try fm.copyItem(atPath: gitDir + "/index", toPath: index)
    }
    _ = try WorktreeGit.run(path, ["add", "-A"], seconds: 150, environment: indexEnvironment)
    let added = try gitlinks(path, environment: indexEnvironment)
    guard Set(added).isSubset(of: Set(links)) else {
      throw Refusal(
        "There is another project folder inside it that I can't back up, so I left it alone.")
    }
    let keepers = try ignoredFilesToSave(path, environment: indexEnvironment)
    if !keepers.isEmpty {
      let list = work.appendingPathComponent("ignored-files")
      var bytes = Data()
      for name in keepers {
        bytes.append(Data(name.utf8))
        bytes.append(0)
      }
      try bytes.write(to: list)
      _ = try WorktreeGit.run(
        path, ["add", "-f", "--pathspec-from-file=" + list.path, "--pathspec-file-nul"],
        seconds: 150, environment: ["GIT_INDEX_FILE": index, "GIT_LITERAL_PATHSPECS": "1"])
    }
    let tree = try line(path, ["write-tree"], environment: indexEnvironment)
    let headTree = try line(path, ["rev-parse", "--verify", "HEAD^{tree}"])
    let snapshot = !keepers.isEmpty || tree != headTree
    var target = head
    if snapshot {
      target = try line(
        path,
        [
          "-c", "user.name=BurnZombies", "-c", "user.email=burnzombies@localhost", "-c",
          "commit.gpgsign=false", "commit-tree", tree, "-p", head, "-m",
          "BurnZombies safety copy of " + item.name,
        ])
    }
    let ref = refPrefix + refSuffix(item.id)
    _ = try WorktreeGit.run(common, ["update-ref", ref, target])
    let stored = try line(common, ["rev-parse", "--verify", ref + "^{commit}"])
    guard stored == target else {
      throw Refusal("I could not make a backup, so I left it alone.")
    }

    // Nothing may have moved while the backup was being written.
    _ = try WorktreeGit.run(path, ["add", "-A"], seconds: 150, environment: indexEnvironment)
    let again = try line(path, ["write-tree"], environment: indexEnvironment)
    let headAgain = try line(path, ["rev-parse", "--verify", "HEAD^{commit}"])
    guard again == tree, headAgain == head else {
      throw Refusal("It changed while I was backing it up, so I left it alone.")
    }
    guard inUse(path) == 0 else {
      throw Refusal("Something started using it, so I left it alone.")
    }
    var branch: String?
    if let symbolic = try? line(path, ["symbolic-ref", "-q", "HEAD"]),
      symbolic.hasPrefix("refs/heads/")
    {
      branch = String(symbolic.dropFirst("refs/heads/".count))
    }

    // Point of no return: the backup exists and is verified.
    _ = try? WorktreeGit.run(common, ["worktree", "remove", "--force", "--", path], seconds: 120)
    let folderGone = !entryExists(path)
    let registrationGone = !entryExists(gitDir) && !registered(common, path)
    let recovery = AutopilotRestore(
      repository: common, path: path, ref: ref, head: head, branch: branch, snapshot: snapshot)
    guard folderGone, registrationGone else {
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: authority,
        outcome: "failed",
        detail: "I made a backup but could not finish removing the copy.",
        restore: folderGone ? recovery : nil)
    }
    return AutopilotReceipt(
      itemID: item.id, kind: .worktree, name: item.name, authority: authority, outcome: "burned",
      detail: snapshot
        ? "Removed. Your unsaved changes are backed up, so you can restore it."
        : "Removed. Everything in it was already saved, so you can restore it.",
      bytes: item.bytes, restore: recovery)
  }

  /// Same buckets as the catalog, from a fresh `git status`.
  private static func currentChanges(_ path: String) throws -> String {
    let status = try WorktreeGit.run(
      path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], seconds: 60)
    return changesBucket(status.split(separator: 0).count)
  }

  /// Paths of submodules (gitlinks) in the index selected by `environment`.
  private static func gitlinks(_ path: String, environment: [String: String]) throws -> [String] {
    let listing = try git(
      path, ["ls-files", "--stage", "-z"], seconds: 60, environment: environment)
    var result: [String] = []
    for entry in listing.split(separator: "\0") where entry.hasPrefix("160000 ") {
      if let tab = entry.firstIndex(of: "\t") {
        result.append(String(entry[entry.index(after: tab)...]))
      }
    }
    return result
  }

  /// A reason to keep the copy when a checked-out submodule has work that exists only here.
  private static func submoduleRefusal(_ worktree: String, links: [String], depth: Int) throws
    -> String?
  {
    if depth > 3 { return "It has projects inside projects inside projects, so I left it alone." }
    for link in links {
      let directory = worktree + "/" + link
      var marker = stat()
      guard lstat(directory + "/.git", &marker) == 0 else { continue }
      let dirty = try git(
        directory, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], seconds: 60)
      if !dirty.isEmpty {
        return "A project inside it has changes that are not saved, so I left it alone."
      }
      let sub = try line(directory, ["rev-parse", "--verify", "HEAD^{commit}"])
      let remote = try lines(
        directory, ["for-each-ref", "--contains=" + sub, "--format=%(refname)", "refs/remotes"])
      if remote.isEmpty {
        return "A project inside it has work that only exists here, so I left it alone."
      }
      let nested = try gitlinks(directory, environment: [:])
      if let reason = try submoduleRefusal(directory, links: nested, depth: depth + 1) {
        return reason
      }
    }
    return nil
  }

  /// Ignored files worth keeping: small, and outside rebuildable folders. Shallow files come
  /// first so configuration such as `.env` wins over a pile of cache files.
  private static func ignoredFilesToSave(_ path: String, environment: [String: String]) throws
    -> [String]
  {
    let listing = try git(
      path, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
      seconds: 60, environment: environment)
    var candidates: [Candidate] = []
    var visited = 0
    for entry in listing.split(separator: "\0").map(String.init) {
      let isDirectory = entry.hasSuffix("/")
      let relative = isDirectory ? String(entry.dropLast()) : entry
      let parts = relative.split(separator: "/").map(String.init)
      if parts.contains(where: { rebuildable.contains($0) }) { continue }
      if parts.contains(where: { $0.lowercased() == ".git" }) { continue }
      if isDirectory {
        try walk(path, relative, candidates: &candidates, visited: &visited)
      } else {
        var info = stat()
        if lstat(path + "/" + relative, &info) == 0, let found = describe(info, relative) {
          candidates.append(found)
        }
      }
    }
    var chosen: [String] = []
    var total: UInt64 = 0
    for candidate in candidates.sorted(by: order) {
      guard candidate.size <= ignoredFileLimit, total + candidate.size <= ignoredTotalLimit else {
        continue
      }
      total += candidate.size
      chosen.append(candidate.path)
    }
    return chosen
  }

  private static func walk(
    _ root: String, _ relative: String, candidates: inout [Candidate], visited: inout Int
  ) throws {
    var pending = [relative]
    while let current = pending.popLast() {
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: root + "/" + current)
      } catch {
        throw Refusal("I could not look inside every folder, so I left it alone.")
      }
      for name in names.sorted() {
        visited += 1
        guard visited <= walkLimit else {
          throw Refusal("It has too many extra files for me to back up, so I left it alone.")
        }
        if name.lowercased() == ".git" {
          throw Refusal(
            "There is another project folder inside it that I can't back up, so I left it alone.")
        }
        if rebuildable.contains(name) { continue }
        let child = current + "/" + name
        var info = stat()
        guard lstat(root + "/" + child, &info) == 0 else {
          throw Refusal("I could not look inside every folder, so I left it alone.")
        }
        if info.st_mode & S_IFMT == S_IFDIR {
          pending.append(child)
        } else if let found = describe(info, child) {
          candidates.append(found)
        }
      }
    }
  }

  /// Regular files and links can be backed up; sockets and the like cannot.
  private static func describe(_ info: stat, _ relative: String) -> Candidate? {
    let type = info.st_mode & S_IFMT
    guard type == S_IFREG || type == S_IFLNK else { return nil }
    return Candidate(
      path: relative, size: type == S_IFREG ? UInt64(max(0, info.st_size)) : 0,
      depth: relative.split(separator: "/").count)
  }

  private static func order(_ a: Candidate, _ b: Candidate) -> Bool {
    (a.depth, a.size, a.path) < (b.depth, b.size, b.path)
  }

  private static func refSuffix(_ id: String) -> String {
    let raw = id.hasPrefix("worktree:") ? String(id.dropFirst("worktree:".count)) : id
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    let clean = String(raw.prefix(16).map { allowed.contains($0) ? $0 : "-" })
    return clean.isEmpty ? "unnamed" : clean
  }

  private static func entryExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  /// True while Git still lists a worktree at `path`. An unreadable list counts as not listed;
  /// the removed administration folder is the decisive check.
  private static func registered(_ common: String, _ path: String) -> Bool {
    guard let text = try? git(common, ["worktree", "list", "--porcelain", "-z"]) else {
      return false
    }
    let wanted: Set<String> = [path, WorkspaceSafety.canonical(path)]
    return text.split(separator: "\0").contains { entry in
      entry.hasPrefix("worktree ") && wanted.contains(String(entry.dropFirst("worktree ".count)))
    }
  }

  // MARK: Restore

  /// Recreates the copy at its original path from the safety ref. Local changes come back
  /// uncommitted. Refuses to touch anything that already exists at that path. The ref stays.
  public static func restore(_ receipt: AutopilotReceipt, protected: ProtectedLocations? = nil)
    throws
  {
    guard let info = receipt.restore else {
      throw StoreError.message("Nothing was saved for this copy, so there is nothing to restore.")
    }
    let protected = protected ?? .limited()
    if let place = protected.resolution(info.path).place ?? protected.registryPlace(info.repository) {
      throw StoreError.message(AutopilotDisk.protectedRefusal(place))
    }
    guard info.path.hasPrefix("/"), info.ref.hasPrefix(refPrefix) else {
      throw StoreError.message("This backup is not one I made, so I did not restore it.")
    }
    var existing = stat()
    if lstat(info.path, &existing) == 0 {
      throw StoreError.message(
        "Something is already at \(info.path), so I did not restore over it.")
    }
    guard errno == ENOENT else {
      throw StoreError.message(
        "I could not tell whether the folder is free, so I did not restore it.")
    }
    let tip = try line(info.repository, ["rev-parse", "--verify", info.ref + "^{commit}"])
    let base = try info.snapshot
      ? line(info.repository, ["rev-parse", "--verify", info.ref + "^1"]) : tip
    guard base == info.head else {
      throw StoreError.message("The backup does not match this copy, so I did not restore it.")
    }

    // Reuse the branch only when it still points at the saved commit and is free.
    var attach: String?
    if let name = info.branch, !name.isEmpty {
      let full = "refs/heads/" + name
      if let current = try? line(
        info.repository, ["rev-parse", "--verify", "--quiet", full + "^{commit}"]),
        current == info.head, !checkedOut(info.repository, full)
      {
        attach = name
      }
    }
    if let name = attach, !info.snapshot {
      _ = try WorktreeGit.run(
        info.repository, ["worktree", "add", "--", info.path, name], seconds: 120)
    } else {
      // A snapshot is checked out as it is, then HEAD moves back to the saved commit so the
      // difference becomes uncommitted changes (including deleted and untracked files).
      _ = try WorktreeGit.run(
        info.repository,
        ["worktree", "add", "--detach", "--", info.path, info.snapshot ? info.ref : info.head],
        seconds: 120)
    }
    do {
      if info.snapshot {
        _ = try WorktreeGit.run(
          info.path, ["reset", "--quiet", "--mixed", info.head], seconds: 120)
        if let name = attach {
          _ = try WorktreeGit.run(info.path, ["symbolic-ref", "HEAD", "refs/heads/" + name])
        }
      }
      let restored = try line(info.path, ["rev-parse", "--verify", "HEAD^{commit}"])
      guard restored == info.head else {
        throw StoreError.message("The restored copy does not match what I saved.")
      }
    } catch {
      // Everything in the half-restored copy came from the ref, so it is safe to retry later.
      _ = try? WorktreeGit.run(
        info.repository, ["worktree", "remove", "--force", "--", info.path], seconds: 120)
      throw error
    }
  }

  /// True when another worktree has `ref` checked out, or when that cannot be told.
  private static func checkedOut(_ repository: String, _ ref: String) -> Bool {
    guard let text = try? git(repository, ["worktree", "list", "--porcelain", "-z"]) else {
      return true
    }
    return text.split(separator: "\0").contains { String($0) == "branch " + ref }
  }

  // MARK: Git

  private static func git(
    _ path: String, _ args: [String], seconds: Double = 30, environment: [String: String] = [:]
  ) throws -> String {
    let data = try WorktreeGit.run(path, args, seconds: seconds, environment: environment)
    guard let text = String(data: data, encoding: .utf8) else {
      throw StoreError.message("Git returned bytes I cannot read; preserved without guessing.")
    }
    return text
  }

  private static func line(
    _ path: String, _ args: [String], seconds: Double = 30, environment: [String: String] = [:]
  ) throws -> String {
    let text = try git(path, args, seconds: seconds, environment: environment)
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
  }

  private static func lines(_ path: String, _ args: [String]) throws -> [String] {
    try git(path, args).split(separator: "\n").map(String.init)
  }
}

/// Sizes old copies the worktree inventory never measured, a bounded amount of time per tick,
/// and remembers each size for a day. Until measured a copy counts as 0 bytes, so it waits
/// outside the assessment; one too big to finish in time gets what was counted, a lower bound.
public final class AutopilotSizes: @unchecked Sendable {
  private let lock = NSLock()
  private var known: [String: (bytes: UInt64, measured: Date)] = [:]
  private let sizer: (String, TimeInterval) -> UInt64?
  public init(
    sizer: @escaping (String, TimeInterval) -> UInt64? = {
      AutopilotDisk.countedSize($0, deadline: $1)
    }
  ) {
    self.sizer = sizer
  }

  public func fill(_ records: [WorktreeRecord], budget: TimeInterval = 20, now: Date = Date())
    -> [WorktreeRecord]
  {
    let limit = ProcessInfo.processInfo.systemUptime + budget
    return records.map { record in
      guard record.allocated == 0, !record.missing, !record.retired, !record.bare,
        record.protectedPlace == nil
      else {
        return record
      }
      var sized = record
      if let size = lock.withLock({ known[record.id] }),
        now.timeIntervalSince(size.measured) < 86_400
      {
        sized.allocated = size.bytes
        return sized
      }
      let left = limit - ProcessInfo.processInfo.systemUptime
      guard left > 0, let bytes = sizer(record.path, min(30, left)) else { return sized }
      lock.withLock { known[record.id] = (bytes, now) }
      sized.allocated = bytes
      return sized
    }
  }
}
