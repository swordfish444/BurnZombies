import CBurn
import CryptoKit
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
/// restorable retirement that keeps committed work in Git and local changes encrypted.
public enum AutopilotWorktrees {
  /// Untracked, unignored content larger than this is never copied into a safety commit.
  public static let maximumUnsavedBytes: UInt64 = 512 << 20
  private static let refPrefix = "refs/burnzombies/retired/"
  private static let stateFiles = [
    "locked", "index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
    "BISECT_START", "rebase-merge", "rebase-apply", "sequencer",
  ]

  private struct Refusal: Error {
    var reason: String
    /// The unsaved files too big to back up that kept the copy, named for the owner's card.
    var bigFiles: [AutopilotBigFiles]?
    init(_ reason: String, bigFiles: [AutopilotBigFiles]? = nil) {
      self.reason = reason
      self.bigFiles = bigFiles
    }
  }
  /// Why a copy is left alone when a project inside it holds work that can't be backed up.
  private static let nestedProject =
    "There is another project folder inside it that I can't back up, so I left it alone."

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
      // Only the file walk tells when a copy was last worked in; without it, an old commit could
      // hide newer edits.
      let dates: [Date?] = [record.lastFileChange, record.lastCommitAt, chat.lastActive]
      let newest = record.lastFileChange == nil ? nil : dates.compactMap { $0 }.max()
      let repo = repoName(record)
      // What the card calls it: the chat that worked in it, else the task its branch names.
      let branch: String? = branchName(record)
      let task: String? =
        AgentThreads.chatTitle(for: record.path, threads: threads)
        ?? branch.flatMap { AutopilotPolicy.humanize(branch: $0) }
      let facts: [String: String] = [
        "place": placeFact(record), "repo": repo, "saved": saved, "changes": changes,
        "stale": newest.map { AutopilotPolicy.stale(since: $0, now: now) } ?? "unknown",
        "thread": chat.thread, "inUse": inUseFact(record), "size": sizeFact(record.allocated),
      ]
      let sentence = detail(
        repo: repo, branch: branch, saved: saved, changes: changes, newest: newest, now: now)
      result.append(
        AutopilotItem(
          id: "worktree:" + record.id, kind: .worktree,
          name: (record.path as NSString).lastPathComponent, detail: sentence, path: record.path,
          bytes: record.allocated, facts: facts,
          protectedReason: protectedReason(record, thread: chat.thread),
          observedAt: record.observedAt, lastUsed: newest, title: task, branch: branch,
          unsaved: record.status.isEmpty ? nil : record.changes))
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

  // MARK: Age

  /// When a copy the inventory couldn't walk was last worked in: the newest of its HEAD commit,
  /// its index (Git rewrites it on add, commit, checkout and reset) and everything in it but
  /// Git's own data and what is inside its junk folders, whose own times count. Unlike the
  /// inventory's walk, this one doesn't stop at hard links, projects inside or special files.
  /// Nil when Git can't say, or the walk can't see everything within `seconds` or `stop` says so
  /// first: anything partial could only make a copy look older than it is.
  public static func lastWorked(
    path: String, seconds: TimeInterval, stop: () -> Bool = { false }
  ) -> Date? {
    let deadline = Date().addingTimeInterval(seconds)
    func ask(_ args: [String]) -> String? {
      let wait = min(deadline.timeIntervalSinceNow, 180)
      guard wait > 0.001 else { return nil }
      return try? line(path, args, seconds: wait)
    }
    guard let committed = ask(["log", "-1", "--format=%ct"]), let stamp = TimeInterval(committed),
      let index = ask(["rev-parse", "--path-format=absolute", "--git-path", "index"]),
      let files = AutopilotDisk.newestChange(in: path, until: deadline, stop: stop)
    else { return nil }
    var newest = max(files, Date(timeIntervalSince1970: stamp))
    var info = stat()
    if lstat(index, &info) == 0 { newest = max(newest, AutopilotDisk.changed(info)) }
    return newest
  }

  // MARK: Retire

  /// Removes an old copy only after everything in it is safe: committed work is recorded at
  /// HEAD, local changes go into a snapshot commit, and either way a safety ref in the
  /// repository keeps it restorable. `root` is a private folder for scratch files; nothing in it
  /// outlives the call. Refusals leave the copy untouched.
  public static func retire(
    _ item: AutopilotItem, authority: String, root: URL,
    inUse: (String) -> Int32 = { bz_path_in_use($0) }, protected: ProtectedLocations? = nil,
    recoveryKey: SymmetricKey? = nil, authorize: () -> Bool = { true },
    keys: AutopilotRecoveryKey = .shared
  ) -> AutopilotReceipt {
    guard item.kind == .worktree, item.id.hasPrefix("worktree:"), let path = item.path else {
      return .refused(item, authority: authority, "This is not an old copy I can retire.")
    }
    if let reason = item.protectedReason { return .refused(item, authority: authority, reason) }
    // `root` is scratch space, not a store, so no access record is read from it.
    if let reason = refusal(path, protected ?? .limited()) {
      return .refused(item, authority: authority, reason)
    }
    do {
      return try perform(
        item, path: path, authority: authority, root: root, inUse: inUse, recoveryKey: recoveryKey,
        authorize: authorize, keys: keys)
    } catch let refusal as Refusal {
      if let big = refusal.bigFiles {
        return .refused(item, authority: authority, bigFiles: big)
      }
      return .refused(item, authority: authority, refusal.reason)
    } catch {
      return .refused(item, authority: authority, plainReason(error))
    }
  }

  /// Why the backup walk, the backup or Git stopped a retire, in the owner's words. Anything
  /// without plain words still says what stopped it, so a copy is never kept for no stated reason.
  static func plainReason(_ error: Error) -> String {
    let stopped = "I stopped before I finished checking it, so I left it alone."
    if Task.isCancelled || error is CancellationError { return stopped }
    guard case StoreError.message(let message) = error else {
      let failure = error as NSError
      if (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOSPC))
        || (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError)
      {
        return noRoom
      }
      return "I could not check it safely, so I left it alone. What stopped me: "
        + failure.localizedDescription
    }
    if let plain = plainReasons[message] { return plain }
    if message.hasPrefix(WorktreeGit.refusedPrefix) {
      // The bounded runner's own codes: out of time, more output than it reads, stopped.
      let status = message.components(separatedBy: "(status ").last ?? ""
      switch String(status.prefix(while: \.isNumber)) {
      case "124": return "Git took too long to answer about it, so I left it alone."
      case "125": return tooManyFiles
      case "130": return stopped
      default: return "Git gave an error when I checked it, so I left it alone."
      }
    }
    return "I could not check it safely, so I left it alone. What stopped me: " + message
  }

  private static let tooManyFiles = "It has too many files for me to back up, so I left it alone."
  private static let noRoom =
    "There isn't enough free space to back it up first, so I left it alone."

  /// The walk's and the backup's own reasons (`WorktreeInspection.files`, `PrivateRecovery`), word
  /// for word, with what the owner reads instead.
  private static let plainReasons: [String: String] = {
    let changed = "It changed while I was backing it up, so I left it alone."
    let unseen = "I could not look inside every folder, so I left it alone."
    let permissions =
      "Some files in it have special permissions I can't back up, so I left it alone."
    let extra = "Some files in it carry extra macOS data I can't back up, so I left it alone."
    let names = "Git listed file names I can't read, so I left it alone."
    var reasons: [String: String] = [
      "Nested repository is protected.": nestedProject,
      "Nested bare repository is protected.": nestedProject,
      "Checkout inspection limit reached; coverage incomplete.": tooManyFiles,
      "Recovery metadata exceeds its bound; nothing removed.": tooManyFiles,
      "Links or special files require supported recovery.":
        "It holds a special file, like a socket or a pipe, that I can't back up, so I left it alone.",
      "File identity, ownership or same-volume coverage unavailable.":
        "Some files in it belong to another user or sit on another disk, so I left it alone.",
      "Native file flags or online-only content require owner recovery.":
        "Some files in it are locked, hidden, compressed or only in iCloud, which I can't back up, so I left it alone.",
      "Special permission bits require owner handling.": permissions,
      "Extended ACLs require owner recovery.": permissions,
      "ACL visibility is unavailable.": permissions,
      "Extended attribute visibility is unavailable or exceeds inspection bounds.": extra,
      "Extended attributes exceed bounded recovery support.": extra,
      "Unsupported attribute name.": extra,
      "Incomplete file visibility.": unseen,
      "Cannot enumerate checkout.": unseen,
      "Insufficient private recovery capacity; preserve the original without truncation.": noRoom,
      "Private recovery capacity is unknown; preserve the original.": noRoom,
      "Git returned bytes I cannot read; preserved without guessing.": names,
      "Non-UTF-8 Git evidence requires owner handling; preserved without lossy parsing.": names,
    ]
    for message in [
      "Generated folder changed during recovery.",
      "A big file the owner let go changed during recovery.",
      "Submodule pointer changed; preserved.", "Attribute names changed during inspection.",
      "Attribute changed during inspection.", "Recovery source changed; nothing removed.",
      "Recovery source unavailable; nothing removed.", "Recovery source changed.",
      "Contents changed after recovery; nothing removed.",
      "File contents changed after recovery; nothing removed.",
    ] {
      reasons[message] = changed
    }
    return reasons
  }()

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
    _ item: AutopilotItem, path: String, authority: String, root: URL, inUse: (String) -> Int32,
    recoveryKey: SymmetricKey?, authorize: () -> Bool, keys: AutopilotRecoveryKey
  ) throws -> AutopilotReceipt {
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
    try unused(path, inUse, else: "Something is using it right now.")

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

    // Unsaved files too big for the backup would only move into BZ's own storage instead of
    // freeing the disk, so they keep the copy, named so the owner can be asked about them. Under an
    // owner's Yes to that kind of them they go with the copy instead (`dropsBigFiles`). Browser
    // profiles don't count: they aren't kept.
    let untracked = try WorktreeGit.run(
      path, ["ls-files", "-z", "--others", "--exclude-standard"], seconds: 60
    ).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    let generated = AutopilotDisk.recoveryExclusions(path)
    let profiles = try browserProfiles(path, untracked: untracked, skipping: generated)
    let dropped = try profileBytes(path, profiles)
    var files: [AutopilotUnsavedFile] = []
    for name in untracked where !profiles.contains(where: { name.hasPrefix($0 + "/") }) {
      var info = stat()
      guard lstat(path + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        continue
      }
      files.append(
        AutopilotUnsavedFile(
          path: name, bytes: UInt64(max(0, info.st_size)), changed: AutopilotDisk.changed(info)))
    }
    var big: [AutopilotBigFiles] = []
    if files.reduce(0, { $0 + $1.bytes }) > maximumUnsavedBytes {
      let entries = try WorktreeGit.run(
        path, ["ls-files", "-z", "--others", "--exclude-standard", "--directory"], seconds: 60
      ).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
      big = bigFiles(files, entries: entries)
      guard dropsBigFiles(item, authority: authority, files: big) else {
        throw Refusal(bigFilesRefusal, bigFiles: big)
      }
      // A project inside them, ignored or not, would go with them unseen. It keeps the copy, as it
      // does when Git would back it up or the walk of ignored files finds it.
      for file in big where try holdsProject(path + "/" + file.path) {
        throw Refusal(nestedProject)
      }
    }

    // Existing commits stay in Git. Every unsaved/ignored byte outside proven generated caches
    // lives only in authenticated encrypted recovery, never in a temporary Git index or blob.
    // Big unsaved files a Yes let go are left out too: they go with the copy, for good. A file
    // with other names (pnpm links an injected workspace package's files into its install) is
    // kept by its contents: removing the copy deletes only the copy's own names for it.
    let excluded = generated.union(profiles)
    // The key, read without a keychain question and within a bound: a dialog nobody answered
    // refuses this copy instead of holding up the burn pass. One read serves capture and check.
    let key: SymmetricKey
    do { key = try recoveryKey ?? keys.forBurn() } catch {
      throw Refusal(AutopilotRecoveryKey.refusal)
    }
    let archive = try PrivateRecovery.capture(
      path, root: root, excluding: excluded, leavingOut: Set(big.map(\.path)),
      gitPointers: try submodulePointers(path, links: links), repository: common, head: head,
      key: key, hardLinks: true)
    let snapshot = changes != "none"
    let ref = refPrefix + archive.id.lowercased()
    _ = try WorktreeGit.run(common, ["update-ref", ref, head])
    guard try line(common, ["rev-parse", "--verify", ref + "^{commit}"]) == head else {
      throw Refusal("I could not preserve the commit, so I left it alone.")
    }
    try PrivateRecovery.validate(archive, key: key)
    guard try line(path, ["rev-parse", "--verify", "HEAD^{commit}"]) == head else {
      throw Refusal("It changed while I was backing it up, so I left it alone.")
    }
    try unused(path, inUse, else: "Something started using it, so I left it alone.")
    var branch: String?
    if let symbolic = try? line(path, ["symbolic-ref", "-q", "HEAD"]),
      symbolic.hasPrefix("refs/heads/")
    {
      branch = String(symbolic.dropFirst("refs/heads/".count))
    }

    var recovery = AutopilotRestore(
      repository: common, path: path, ref: ref, head: head, branch: branch, snapshot: snapshot)
    recovery.recovery = archive
    let journal = try Store(root: root)
    try journal.write(
      JSONEncoder().encode(recovery),
      to: URL(fileURLWithPath: archive.directory).appendingPathComponent("restore.json"),
      limit: 65536)
    var finalFolder = stat()
    guard lstat(path, &finalFolder) == 0, finalFolder.st_ino == folder.st_ino,
      finalFolder.st_dev == folder.st_dev,
      WorkspaceSafety.canonical(try line(path, ["rev-parse", "--absolute-git-dir"])) == gitDir
    else {
      throw Refusal("This copy changed while preserving it, so I left it alone.")
    }
    for name in stateFiles {
      var state = stat()
      if lstat(gitDir + "/" + name, &state) == 0 || errno != ENOENT {
        throw Refusal("Git started using this copy while preserving it, so I left it alone.")
      }
    }
    guard authorize() else {
      throw Refusal("Permissions changed while preserving it, so I left it alone.")
    }
    // Point of no return: the encrypted backup is restored, verified and durably discoverable.
    _ = try? WorktreeGit.run(common, ["worktree", "remove", "--force", "--", path], seconds: 120)
    let folderGone = !entryExists(path)
    let registrationGone = !entryExists(gitDir) && !registered(common, path)
    guard folderGone, registrationGone else {
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: authority,
        outcome: "failed",
        detail: "I made a backup but could not finish removing the copy.",
        restore: recovery)
    }
    var detail = "Removed. Your unsaved changes are backed up, so you can restore it."
    if !snapshot {
      let saved = dropped > 0 || !big.isEmpty ? "Everything else" : "Everything"
      detail = "Removed. " + saved + " in it was already saved, so you can restore it."
    }
    if dropped > 0 {
      detail += " Its browser profiles (\(AutopilotPolicy.format(dropped))) weren't kept."
    }
    if !big.isEmpty { detail += " " + AutopilotPolicy.bigFilesGone(big) }
    let retained = AutopilotDisk.allocatedSize(archive.directory) ?? archive.allocated
    var receipt = AutopilotReceipt(
      itemID: item.id, kind: .worktree, name: item.name, authority: authority, outcome: "burned",
      detail: detail, bytes: item.bytes > retained ? item.bytes - retained : 0,
      restore: recovery)
    receipt.bigFiles = big.isEmpty ? nil : big
    return receipt
  }

  /// Whether a project folder (a `.git`) is anywhere inside `folder`, outside rebuildable folders,
  /// as recovery would find one anywhere else in the copy. A file is no folder. Refuses when it
  /// can't look everywhere.
  private static func holdsProject(_ folder: String) throws -> Bool {
    var info = stat()
    guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
    var pending: [String] = [folder]
    var visited = 0
    while let current = pending.popLast() {
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: current)
      } catch {
        throw Refusal("I could not look inside every folder, so I left it alone.")
      }
      for name in names {
        visited += 1
        guard visited <= 1_000_000 else {
          throw Refusal("It has too many files for me to check, so I left it alone.")
        }
        if name.lowercased() == ".git" { return true }
        if AutopilotDisk.rebuildable[name] != nil { continue }
        var child = stat()
        guard lstat(current + "/" + name, &child) == 0 else {
          throw Refusal("I could not look inside every folder, so I left it alone.")
        }
        if child.st_mode & S_IFMT == S_IFDIR { pending.append(current + "/" + name) }
      }
    }
    return false
  }

  /// Browser profiles test runs leave in a copy, by path inside it: a Chrome-style profile folder,
  /// with `Local State` beside `Default/Preferences`, among the unsaved files or in a folder Git
  /// ignores. Test state, not work, so they are neither backed up nor counted as unsaved. A folder
  /// holding a file Git tracks is somebody's fixture. `generated` folders aren't kept anyway.
  private static func browserProfiles(
    _ path: String, untracked: [String], skipping generated: Set<String>
  ) throws -> [String] {
    func profile(_ folder: String) -> Bool {
      ["/Local State", "/Default/Preferences"].allSatisfy { name in
        var info = stat()
        return lstat(path + "/" + folder + name, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
      }
    }
    var found = untracked.filter { $0.hasSuffix("/Local State") }
      .map { String($0.dropLast("/Local State".count)) }.filter(profile)
    // Git names a folder it ignores as one entry, so those are searched on disk. The search only
    // finds profiles; one it can't reach is backed up with the rest of the folder.
    let ignored = (try? WorktreeGit.run(
      path, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"],
      seconds: 60)) ?? Data()
    let skipped = generated.union(found)
    var pending = ignored.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
      .filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }
      .filter { folder in !skipped.contains { folder == $0 || folder.hasPrefix($0 + "/") } }
    var listed = 0
    while let folder = pending.popLast(), listed < 100_000 {
      if profile(folder) {
        found.append(folder)
        continue
      }
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: path + "/" + folder)
      else { continue }
      listed += names.count
      for name in names where name.lowercased() != ".git" {
        let child = folder + "/" + name
        var info = stat()
        if !generated.contains(child), lstat(path + "/" + child, &info) == 0,
          info.st_mode & S_IFMT == S_IFDIR
        {
          pending.append(child)
        }
      }
    }
    // One inside another goes with it.
    found = found.filter { inner in !found.contains { inner.hasPrefix($0 + "/") } }
    guard !found.isEmpty else { return [] }
    let tracked = try git(path, ["--literal-pathspecs", "ls-files", "-z", "--"] + found)
      .split(separator: "\0").map(String.init)
    return found.filter { folder in !tracked.contains { $0.hasPrefix(folder + "/") } }
  }

  /// The bytes in the browser profiles. They go with the copy and nothing else looks inside them,
  /// so a project in one keeps the copy, as does a folder in them that can't be read.
  private static func profileBytes(_ path: String, _ profiles: [String]) throws -> UInt64 {
    var bytes: UInt64 = 0
    var pending = profiles.map { path + "/" + $0 }
    var visited = 0
    while let current = pending.popLast() {
      let names: [String]
      do {
        names = try FileManager.default.contentsOfDirectory(atPath: current)
      } catch {
        throw Refusal("I could not look inside every folder, so I left it alone.")
      }
      for name in names {
        visited += 1
        guard visited <= 1_000_000 else {
          throw Refusal("It has too many files for me to check, so I left it alone.")
        }
        if name.lowercased() == ".git" { throw Refusal(nestedProject) }
        var info = stat()
        guard lstat(current + "/" + name, &info) == 0 else {
          throw Refusal("I could not look inside every folder, so I left it alone.")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: pending.append(current + "/" + name)
        case S_IFREG: bytes += UInt64(max(0, info.st_size))
        default: break
        }
      }
    }
    return bytes
  }

  /// Why a copy was left when the check for programs using it couldn't finish.
  static let uncheckedUse = "I could not check whether something is using it, so I left it alone."

  /// Refuses with `busy` when a program uses the copy, and says so when the check couldn't tell.
  private static func unused(_ path: String, _ inUse: (String) -> Int32, else busy: String) throws {
    switch inUse(path) {
    case 0: return
    case 1: throw Refusal(busy)
    default: throw Refusal(uncheckedUse)
    }
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

  /// These exact initialized gitlinks were independently checked above. Preserve all their raw
  /// contents (including ignored files), while omitting only obsolete administration pointers.
  private static func submodulePointers(_ root: String, links: [String], depth: Int = 0) throws
    -> Set<String>
  {
    guard depth <= 3 else { throw Refusal("Submodule recovery depth exceeded.") }
    var result = Set<String>()
    for link in links where entryExists(root + "/" + link + "/.git") {
      result.insert(link + "/.git")
      let nested = try gitlinks(root + "/" + link, environment: [:])
      result.formUnion(
        try submodulePointers(root + "/" + link, links: nested, depth: depth + 1).map {
          link + "/" + $0
        })
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
  /// The owner asked for it, so reading the backup key may show macOS's question.
  public static func restore(
    _ receipt: AutopilotReceipt, protected: ProtectedLocations? = nil,
    recoveryKey: SymmetricKey? = nil, keys: AutopilotRecoveryKey = .shared
  )
    throws
  {
    guard let info = receipt.restore else {
      throw StoreError.message("Nothing was saved for this copy, so there is nothing to restore.")
    }
    let protected = protected ?? .limited()
    if let place = protected.resolution(info.path).place ?? protected.registryPlace(info.repository)
    {
      throw StoreError.message(AutopilotDisk.protectedRefusal(place))
    }
    if let archive = info.recovery {
      guard archive.source == info.path else {
        throw StoreError.message("Recovery path binding changed.")
      }
      let key = try recoveryKey ?? keys.forOwner(create: false)
      if receipt.kind == .disk {
        try PrivateRecovery.restore(archive, to: info.path, key: key)
        return
      }
      guard info.ref.hasPrefix(refPrefix),
        try line(info.repository, ["rev-parse", "--verify", info.ref + "^{commit}"]) == info.head
      else {
        throw StoreError.message("Recovery commit binding changed.")
      }
      _ = try WorktreeGit.run(
        info.repository,
        ["worktree", "add", "--no-checkout", "--detach", "--", info.path, info.head], seconds: 120)
      // On failure preserve the authenticated archive and partial checkout for explicit recovery.
      try PrivateRecovery.restore(archive, to: info.path, key: key, emptyWorktree: true)
      _ = try WorktreeGit.run(info.path, ["reset", "--quiet", "--mixed", info.head], seconds: 120)
      if let branch = info.branch, !checkedOut(info.repository, "refs/heads/" + branch),
        (try? line(info.repository, ["rev-parse", "--verify", "refs/heads/" + branch])) == info.head
      {
        _ = try WorktreeGit.run(info.path, ["symbolic-ref", "HEAD", "refs/heads/" + branch])
      }
      return
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
    let base =
      try info.snapshot
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
    let target = info.snapshot ? info.ref : info.head
    _ = try WorktreeGit.run(
      info.repository,
      ["worktree", "add", "--no-checkout", "--detach", "--", info.path, target], seconds: 120)
    try WorktreeGit.checkout(info.repository, revision: target, to: info.path)
    _ = try WorktreeGit.run(info.path, ["reset", "--quiet", "--mixed", target], seconds: 120)
    if let name = attach, !info.snapshot {
      _ = try WorktreeGit.run(info.path, ["symbolic-ref", "HEAD", "refs/heads/" + name])
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

/// A copy's size as `AutopilotSizes` measured it.
public struct AutopilotSize: Codable, Sendable, Equatable {
  public var bytes: UInt64
  public var measured: Date
  public init(bytes: UInt64, measured: Date) {
    self.bytes = bytes
    self.measured = measured
  }
}

/// Sizes old copies the worktree inventory never measured, a bounded amount of time per tick,
/// and remembers each size for a day. Until measured a copy counts as 0 bytes, so it waits
/// outside the assessment; one too big to finish in time gets what was counted, a lower bound.
public final class AutopilotSizes: @unchecked Sendable {
  private let lock = NSLock()
  private var known: [String: AutopilotSize]
  private let store: AutopilotStore?
  private let sizer: (String, TimeInterval) -> UInt64?
  /// With `store`, sizes outlive a restart: sizing every copy again takes many ticks, and each
  /// one is out of the catalog until then.
  public init(
    store: AutopilotStore? = nil,
    sizer: @escaping (String, TimeInterval) -> UInt64? = {
      AutopilotDisk.countedSize($0, deadline: $1)
    }
  ) {
    self.store = store
    self.sizer = sizer
    known = (try? store?.sizes()) ?? [:]
  }

  public func fill(_ records: [WorktreeRecord], budget: TimeInterval = 20, now: Date = Date())
    -> [WorktreeRecord]
  {
    let limit = ProcessInfo.processInfo.systemUptime + budget
    var measured = false
    let result: [WorktreeRecord] = records.map { record in
      guard record.allocated == 0, !record.missing, !record.retired, !record.bare,
        record.protectedPlace == nil
      else {
        return record
      }
      var sized = record
      if let size = lock.withLock({ known[record.id] }), Self.good(size, now: now) {
        sized.allocated = size.bytes
        return sized
      }
      let left = limit - ProcessInfo.processInfo.systemUptime
      guard left > 0, let bytes = sizer(record.path, min(30, left)) else { return sized }
      lock.withLock { known[record.id] = AutopilotSize(bytes: bytes, measured: now) }
      measured = true
      sized.allocated = bytes
      return sized
    }
    // Sizes no longer good go; a store that can't be written leaves them in memory only.
    if measured {
      lock.withLock {
        known = known.filter { Self.good($0.value, now: now) }
        try? store?.save(sizes: known)
      }
    }
    return result
  }

  private static func good(_ size: AutopilotSize, now: Date) -> Bool {
    now.timeIntervalSince(size.measured) < 86_400
  }
}

/// What one look of `AutopilotAges` found: when the copy was last worked in, nil when the look
/// found no date, and the HEAD and changes the inventory saw when it looked.
public struct AutopilotLook: Codable, Sendable, Equatable {
  public var date: Date?
  public var at: Date
  public var head: String?
  public var status: String
  public init(date: Date?, at: Date, head: String?, status: String) {
    self.date = date
    self.at = at
    self.head = head
    self.status = status
  }
}

/// Dates old copies the worktree inventory looked into but couldn't walk (a hard-linked file, a
/// project inside it or a special file stops its walk), a few per tick, with a look of its own.
/// Until dated a copy's age is unknown, so no lesson or question reaches it. A date holds for an
/// hour, or until the inventory sees the copy's HEAD or changes move.
public final class AutopilotAges: @unchecked Sendable {
  private let lock = NSLock()
  private var known: [String: AutopilotLook]
  private let store: AutopilotStore?
  private let walks: AutopilotWalks?
  private let prober: (String, TimeInterval, () -> Bool) -> Date?
  /// With `store`, looks outlive a restart, each for the rest of its hour. With `walks`, the junk
  /// walk's, a burn of a copy waits for its look and stops it: the check for programs using a
  /// copy would otherwise find BZ itself inside. `prober` is told to stop through its last
  /// argument.
  public init(
    store: AutopilotStore? = nil, walks: AutopilotWalks? = nil,
    prober: @escaping (String, TimeInterval, () -> Bool) -> Date? = {
      AutopilotWorktrees.lastWorked(path: $0, seconds: $1, stop: $2)
    }
  ) {
    self.store = store
    self.walks = walks
    self.prober = prober
    known = (try? store?.ages()) ?? [:]
  }

  /// Starts no more than `limit` looks, and none once `budget` seconds have passed; each look
  /// gets 10 seconds, since a cut-short one says nothing. A look that found no date is
  /// remembered too, so a copy that can't be dated doesn't take every tick's turn; a copy being
  /// burned isn't looked into, and a look a burn stopped isn't remembered.
  public func fill(
    _ records: [WorktreeRecord], limit: Int = 8, budget: TimeInterval = 10, now: Date = Date()
  ) -> [WorktreeRecord] {
    let end = ProcessInfo.processInfo.systemUptime + budget
    let walks = self.walks
    var looked = 0
    var remembered = false
    let result: [WorktreeRecord] = records.map { record in
      // Without a status the inventory never read Git there: it may not look into that folder.
      guard record.lastFileChange == nil, !record.status.isEmpty, !record.main, !record.missing,
        !record.retired, !record.bare, record.protectedPlace == nil
      else {
        return record
      }
      var dated = record
      if let look = lock.withLock({ known[record.id] }), look.head == record.head,
        look.status == record.status, Self.good(look, now: now)
      {
        dated.lastFileChange = look.date
        return dated
      }
      guard looked < limit, ProcessInfo.processInfo.systemUptime < end else { return record }
      let real = WorkspaceSafety.canonical(record.path)
      guard walks?.enter(real) ?? true else { return record }
      looked += 1
      var early = false
      let date = prober(record.path, 10) {
        if !early { early = walks?.wanted(real) ?? false }
        return early
      }
      walks?.leave(real, early: early)
      guard !early else { return record }
      let look = AutopilotLook(date: date, at: now, head: record.head, status: record.status)
      lock.withLock { known[record.id] = look }
      remembered = true
      dated.lastFileChange = date
      return dated
    }
    // Looks past their hour go; a store that can't be written leaves them in memory only.
    if remembered {
      lock.withLock {
        known = known.filter { Self.good($0.value, now: now) }
        try? store?.save(ages: known)
      }
    }
    return result
  }

  private static func good(_ look: AutopilotLook, now: Date) -> Bool {
    now.timeIntervalSince(look.at) < 3600
  }
}
