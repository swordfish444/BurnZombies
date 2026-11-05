import CBurn
import Darwin
import Foundation

/// Junk folders: rebuildable output inside projects and old copies, and global developer
/// caches. Only known rebuildable kinds are ever removed autonomously.
public enum AutopilotDisk {
  /// Folder name → `folder` fact.
  public static let rebuildable: [String: String] = [
    "node_modules": "node_modules",
    ".build": "build-output", "build": "build-output", "dist": "build-output",
    "target": "build-output", ".next": "build-output", ".nuxt": "build-output",
    ".svelte-kit": "build-output", ".turbo": "build-output", ".parcel-cache": "build-output",
    ".output": "build-output",
    "DerivedData": "xcode-derived",
    ".gradle": "package-cache", ".cache": "package-cache", "Pods": "package-cache",
    ".venv": "python-env", "venv": "python-env", "__pycache__": "python-env",
    ".pytest_cache": "python-env", ".mypy_cache": "python-env", ".ruff_cache": "python-env",
    ".tox": "python-env",
  ]

  private static let kinds = Set(rebuildable.values)
  private static let minimumBytes: UInt64 = 100_000_000
  private static let staleAfter: TimeInterval = 14 * 86_400
  private static let maximumDepth = 3
  private static let directoryBudget = 5_000
  private static let candidateLimit = 500
  /// Entries a copy's own walk may look at before its age counts as unknown.
  private static let entryBudget = 100_000
  private static let timeBudget: TimeInterval = 60
  /// Relative to the home folder. Nothing here is ever listed or removed.
  private static let excluded = [
    "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Pictures", ".ssh", ".gnupg",
    "Library/Keychains",
  ]
  /// Relative to the home folder. With `children`, each folder inside is its own item.
  private static let globalCaches: [(path: String, folder: String, label: String, children: Bool)] =
    [
      ("Library/Developer/Xcode/DerivedData", "xcode-derived", "Xcode", true),
      ("Library/Caches/ms-playwright", "package-cache", "Playwright", true),
      (".cache/ms-playwright", "package-cache", "Playwright", true),
      (".npm/_cacache", "package-cache", "npm", false),
      ("Library/Caches/Yarn", "package-cache", "Yarn", false),
      ("Library/Caches/Homebrew", "package-cache", "Homebrew", false),
      ("Library/Caches/pip", "package-cache", "pip", false),
      (".cache/pip", "package-cache", "pip", false),
      (".gradle/caches", "package-cache", "Gradle", false),
      ("Library/Developer/CoreSimulator/Caches", "xcode-derived", "Simulator", false),
    ]

  /// Where Playwright keeps its browsers, relative to the home folder. Beside them are profiles
  /// its tools keep, logins included (`mcp-chrome`, `daemon`), which are never listed.
  static let playwrightCaches: Set<String> = ["Library/Caches/ms-playwright", ".cache/ms-playwright"]

  /// The browser builds among the names in a Playwright cache that may go: every one but the
  /// newest of its kind, which is the one the installed Playwright uses. Deleting that one only
  /// makes the next run download it again.
  public static func playwrightBuilds(_ names: [String]) -> [String] {
    var newest: [String: Int] = [:]
    for name in names {
      if let (kind, version) = build(name) { newest[kind] = max(newest[kind] ?? version, version) }
    }
    return names.filter { name in
      guard let (kind, version) = build(name) else { return false }
      return version < newest[kind] ?? version
    }
  }

  /// A Playwright build folder's kind and version ("chromium_headless_shell-1200"), or nil.
  private static func build(_ name: String) -> (kind: String, version: Int)? {
    guard let dash = name.lastIndex(of: "-"), let version = Int(name[name.index(after: dash)...]),
      version > 0
    else { return nil }
    let kind = String(name[..<dash])
    let letters = kind.unicodeScalars.allSatisfy {
      CharacterSet.lowercaseLetters.contains($0) || $0 == "_" || $0 == "-"
    }
    guard !kind.isEmpty, letters, !kind.hasPrefix("mcp") else { return nil }
    return (kind, version)
  }

  /// Why a folder in a Playwright cache stays, or nil when it is an old browser build.
  private static func playwrightRefusal(_ path: String, home: String) -> String? {
    let relative = String(path.dropFirst(home.count + 1))
    guard playwrightCaches.contains(parent(relative)) else { return nil }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent(path))) ?? []
    if playwrightBuilds(names).contains(leaf(path)) { return nil }
    return build(leaf(path)) == nil
      ? "That's a browser profile or file a Playwright tool keeps, so I left it alone."
      : "That's the newest Playwright browser of its kind, the one your tools use, so I left it alone."
  }

  private struct Checkout {
    var path: String
    var linked: Bool
    /// The newest date its inventory record holds: last file change or last commit.
    var activity: Date?
    /// Whether that record's latest inspection walked every file in it.
    var walked: Bool
  }

  /// Rebuildable folders of at least 100 MB: inside live checkouts (with `mains`, also the main
  /// checkout each one belongs to) and, with `caches`, in the global developer caches. Nothing
  /// outside `home`, no link, no private area, nothing Git tracks. Work stops at a time budget;
  /// the rest comes next time. With `walks`, nothing being burned is walked: a checkout or cache
  /// folder a burn wants is skipped, or left at the next step.
  public static func items(
    worktrees: [WorktreeRecord], home: String = NSHomeDirectory(), caches: Bool = true,
    mains: Bool = true, now: Date = Date(),
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) },
    protected: ProtectedLocations? = nil, walks: AutopilotWalks? = nil, trail: String? = nil
  ) -> [AutopilotItem] {
    let protected = protected ?? .limited(homes: [home])
    let base = WorkspaceSafety.canonical(home)
    guard base.hasPrefix("/"), base != "/" else { return [] }
    let deadline = Date().addingTimeInterval(timeBudget)
    var found: [String: AutopilotItem] = [:]

    for cache in globalCaches where caches {
      let location = base + "/" + cache.path
      guard Date() < deadline, refusal(location, home: base, protected: protected) == nil else {
        continue
      }
      var targets = [location]
      if cache.children {
        var names = (try? FileManager.default.contentsOfDirectory(atPath: location)) ?? []
        if playwrightCaches.contains(cache.path) { names = playwrightBuilds(names) }
        targets = names.sorted().map { location + "/" + $0 }
      }
      for target in targets {
        guard Date() < deadline, refusal(target, home: base, protected: protected) == nil,
          walks?.enter(target) ?? true
        else { continue }
        defer { walks?.leave(target, early: false) }
        guard let bytes = sizer(target), bytes >= minimumBytes, let touched = modified(target)
        else { continue }
        let child = leaf(target)
        let name = cache.children ? child + " in " + cache.label : cache.label + " cache"
        let subject = cache.children && cache.folder == "xcode-derived" ? child : cache.label
        let item = AutopilotItem(
          id: "disk:" + AutopilotItem.hash(target), kind: .disk, name: name,
          detail: sentence(cache.folder, subject: subject), path: target, bytes: bytes,
          facts: [
            "folder": cache.folder, "home": "global-cache",
            "stale": AutopilotPolicy.stale(since: touched, now: now), "size": scale(bytes),
          ], observedAt: now, lastUsed: touched)
        found[item.id] = item
      }
    }

    // What robot browsers left in the temp folder, sized with the caches.
    if caches, let trail, Date() < deadline,
      let item = AutopilotBrowserTrail.item(
        in: trail, now: now, minimumBytes: minimumBytes, sizer: sizer)
    {
      found[item.id] = item
    }

    for checkout in checkouts(worktrees, home: base, mains: mains, protected: protected) {
      guard Date() < deadline else { break }
      guard walks?.enter(checkout.path) ?? true else { continue }
      var early = false
      defer { walks?.leave(checkout.path, early: early) }
      // Whether a burn wants the walk out of this checkout. Once it does, nothing more is read.
      func away() -> Bool {
        if !early { early = walks?.wanted(checkout.path) ?? false }
        return early
      }
      // Git is asked about the checkout, so its Git data must be within reach too.
      guard refusal(checkout.path, home: base, protected: protected) == nil,
        protected.pointerPlace(checkout.path) == nil
      else { continue }
      let folders = rebuildableFolders(under: checkout.path, stop: away).filter {
        refusal($0.path, home: base, protected: protected) == nil
      }
      guard !folders.isEmpty, !away(),
        let blocked = trackedFolders(folders.map { $0.path }, in: checkout.path)
      else { continue }
      // Another repository inside a folder is somebody's project, not build output.
      let junk = folders.filter { !blocked.contains($0.path) && !exists($0.path + "/.git") }
      guard !junk.isEmpty else { continue }
      let place = leaf(checkout.path)
      let worked = lastWorked(
        checkout, skipping: Set(junk.map { $0.path }), now: now, until: deadline, stop: away)
      for folder in junk {
        guard Date() < deadline, !away() else { break }
        guard let bytes = sizer(folder.path), bytes >= minimumBytes,
          let touched = modified(folder.path)
        else { continue }
        let fact = rebuildable[folder.name] ?? "other"
        let inside = parent(String(folder.path.dropFirst(checkout.path.count + 1)))
        var name = folder.name + " in " + place
        if !inside.isEmpty { name += "/" + inside }
        let newest = worked.date.map { max($0, touched) } ?? touched
        let item = AutopilotItem(
          id: "disk:" + AutopilotItem.hash(folder.path), kind: .disk, name: name,
          detail: sentence(fact, subject: place), path: folder.path, bytes: bytes,
          facts: [
            "folder": fact, "home": worked.old ? "stale-worktree" : "repo",
            "stale": AutopilotPolicy.stale(since: newest, now: now), "size": scale(bytes),
          ], observedAt: now, lastUsed: newest)
        found[item.id] = item
      }
    }
    return found.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
  }

  /// Disk space a folder really uses (allocated blocks) with the native read-only fts walker:
  /// no symlinks, no other volumes, no hydration of online-only files. Nil when the path is
  /// not a plain folder, or the time limit passes or `stop` says so first.
  public static func allocatedSize(
    _ path: String, deadline: TimeInterval = 30, stop: () -> Bool = { false }
  ) -> UInt64? {
    walk(path, deadline: deadline, partial: false, stop: stop)
  }

  /// Like `allocatedSize`, but when the time limit passes it returns what it counted so far:
  /// a lower bound, so a folder too big to measure in time never looks empty.
  public static func countedSize(_ path: String, deadline: TimeInterval) -> UInt64? {
    walk(path, deadline: deadline, partial: true)
  }

  private static func walk(
    _ path: String, deadline: TimeInterval, partial: Bool, stop: () -> Bool = { false }
  ) -> UInt64? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      let handle = bz_disk_open(path, 1)
    else { return nil }
    defer { bz_disk_close(handle) }
    func total() -> UInt64? {
      var root = bz_disk_node()
      return bz_disk_count(handle) > 0 && bz_disk_node_at(handle, 0, &root) == 1
        ? root.allocated : nil
    }
    let limit = ProcessInfo.processInfo.systemUptime + deadline
    while !Task.isCancelled, !stop(), ProcessInfo.processInfo.systemUptime < limit {
      let step = bz_disk_step(handle, 5000)
      if step < 0 { return nil }
      if step == 1 { return total() }
    }
    return partial ? total() ?? 0 : nil
  }

  /// Why a junk folder was left when the check for programs using it couldn't finish.
  static let uncheckedUse = "I couldn't tell if something is using that folder, so I left it alone."

  /// Removes one junk folder after checking every rail again on the live path. Never throws;
  /// a refusal leaves the folder untouched. Known kinds are deleted and measured first; any
  /// other folder goes to the Trash, and only for an operator rule or the operator.
  public static func reclaim(
    _ item: AutopilotItem, authority: String, home: String = NSHomeDirectory(),
    inUse: (String) -> Int32 = { bz_path_in_use($0) }, protected: ProtectedLocations? = nil
  ) -> AutopilotReceipt {
    let protected = protected ?? .limited(homes: [home])
    func refuse(_ reason: String) -> AutopilotReceipt {
      .refused(item, authority: authority, reason)
    }
    func finish(_ outcome: String, _ detail: String, bytes: UInt64 = 0) -> AutopilotReceipt {
      AutopilotReceipt(
        itemID: item.id, kind: item.kind, name: item.name, authority: authority, outcome: outcome,
        detail: detail, bytes: bytes)
    }
    guard item.kind == .disk, let path = item.path else {
      return refuse("That isn't a junk folder, so I left it alone.")
    }
    // The temp folder isn't in the home folder; its leftovers have checks of their own.
    if item.facts["folder"] == "browser-temp" {
      return AutopilotBrowserTrail.reclaim(item, authority: authority)
    }
    let folder = item.facts["folder"] ?? "other"
    let known = kinds.contains(folder)
    guard known || authority.hasPrefix("rule:") || authority == "operator" else {
      return refuse("I only move this kind of folder to the Trash when you've told me to.")
    }
    let base = WorkspaceSafety.canonical(home)
    guard base.hasPrefix("/"), base != "/" else {
      return refuse("I can't find your home folder, so I left this alone.")
    }
    if let reason = refusal(path, home: base, protected: protected) { return refuse(reason) }
    if let reason = playwrightRefusal(path, home: base) { return refuse(reason) }
    if known && recognized(path, home: base) != folder {
      return refuse("That doesn't look like a folder I know how to rebuild, so I left it alone.")
    }
    if exists(path + "/.git") {
      return refuse("There's a project inside that folder, so I left it alone.")
    }
    if let root = enclosingCheckout(of: path, home: base) {
      if let place = protected.pointerPlace(root) {
        return refuse(Self.protectedRefusal(place))
      }
      let relative = String(path.dropFirst(root.count + 1))
      guard
        let listing = try? WorktreeGit.run(
          root, ["--literal-pathspecs", "ls-files", "-z", "--", relative])
      else { return refuse("I couldn't ask Git about that folder, so I left it alone.") }
      guard listing.isEmpty else {
        return refuse("Git saves files in that folder, so they're part of your project. I left it alone.")
      }
    }
    switch inUse(path) {
    case 0: break
    case 1: return refuse("Something is using that folder right now, so I left it alone.")
    default: return refuse(uncheckedUse)
    }
    // One last look right before removing it.
    if let reason = refusal(path, home: base, protected: protected) { return refuse(reason) }
    guard known else {
      do {
        try keepingParentTime(of: path) {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
      } catch {
        return finish("failed", "I couldn't move \(item.name) to the Trash, so I left it there.")
      }
      guard !exists(path) else {
        return finish("failed", "\(item.name) is still where it was, so nothing moved.")
      }
      // The space comes back when the Trash is emptied, so no bytes are claimed yet.
      return finish("burned", "Moved \(item.name) to the Trash. Empty the Trash to get the space back.")
    }
    let bytes = allocatedSize(path) ?? item.bytes
    do {
      try keepingParentTime(of: path) { try FileManager.default.removeItem(atPath: path) }
    } catch {
      return finish("failed", "I couldn't remove all of \(item.name), so some of it is still there.")
    }
    guard !exists(path) else {
      return finish("failed", "\(item.name) is still there, so I'm not counting it as burned.")
    }
    return finish(
      "burned", "Cleared \(item.name). Your tools will rebuild it when they need it.", bytes: bytes)
  }

  /// Removing a folder stamps its parent with the current time, which would make the old copy
  /// it sits in look worked in today. The parent keeps the time it had.
  private static func keepingParentTime(of path: String, _ remove: () throws -> Void) rethrows {
    let parent = (path as NSString).deletingLastPathComponent
    var before = stat()
    let directory = lstat(parent, &before) == 0 && before.st_mode & S_IFMT == S_IFDIR
    defer {
      if directory {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), before.st_mtimespec]
        _ = utimensat(AT_FDCWD, parent, &times, AT_SYMLINK_NOFOLLOW)
      }
    }
    try remove()
  }

  /// Why a path may not be touched, or nil when it is a real folder of this user inside the
  /// home folder and clear of the private areas. `home` must already be canonical.
  private static func refusal(_ path: String, home: String, protected: ProtectedLocations)
    -> String?
  {
    // Without Full Disk Access a place macOS protects is never looked at.
    if let place = protected.resolution(path).place { return protectedRefusal(place) }
    var info = stat()
    guard lstat(path, &info) == 0 else { return "That folder is already gone." }
    guard info.st_mode & S_IFMT != S_IFLNK else {
      return "That folder is a shortcut to somewhere else, so I left it alone."
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      return "That isn't a folder, so I left it alone."
    }
    let real = WorkspaceSafety.canonical(path)
    guard real == path, real.hasPrefix(home + "/") else {
      return "That folder isn't really inside your home folder, so I left it alone."
    }
    let relative = String(real.dropFirst(home.count + 1)).lowercased()
    let guarded = excluded.contains {
      relative == $0.lowercased() || relative.hasPrefix($0.lowercased() + "/")
    }
    guard !guarded else {
      return "That folder is somewhere private (iCloud, Mail, Messages, Photos or keys), so I left it alone."
    }
    guard info.st_uid == getuid() else {
      return "That folder belongs to someone else, so I left it alone."
    }
    return nil
  }

  static func protectedRefusal(_ place: String) -> String {
    "That's in " + place + ", which macOS protects, so I left it alone. Turn on Full Disk Access to let me check it."
  }

  /// The `folder` fact a live path earns by its place (global caches) or by its name inside a
  /// checkout, or nil when it is not a known rebuildable kind. `home` must be canonical.
  private static func recognized(_ path: String, home: String) -> String? {
    let relative = String(path.dropFirst(home.count + 1))
    for cache in globalCaches {
      let match = cache.children ? (parent(relative) == cache.path) : (relative == cache.path)
      if match { return cache.folder }
    }
    guard let folder = rebuildable[leaf(path)],
      enclosingCheckout(of: path, home: home, levels: maximumDepth) != nil
    else { return nil }
    return folder
  }

  /// The nearest folder above `path` holding a `.git` entry, looking at most `levels` folders
  /// up and never as far as the home folder itself. `home` must be canonical.
  private static func enclosingCheckout(of path: String, home: String, levels: Int = 64)
    -> String?
  {
    var directory = parent(path)
    for _ in 0..<levels {
      guard directory.hasPrefix(home + "/") else { return nil }
      if exists(directory + "/.git") { return directory }
      directory = parent(directory)
    }
    return nil
  }

  /// Live checkouts to search: each live record, plus (with `mains`) the main checkout it belongs
  /// to. A checkout that is also a main checkout is never counted as a linked copy.
  private static func checkouts(
    _ worktrees: [WorktreeRecord], home: String, mains: Bool, protected: ProtectedLocations
  ) -> [Checkout] {
    var byPath: [String: Checkout] = [:]
    func consider(_ path: String, linked: Bool, activity: Date?, walked: Bool) {
      // A checkout in a place macOS protects is not even resolved without Full Disk Access.
      guard let real = protected.resolve(path), real.hasPrefix(home + "/") else { return }
      var checkout = Checkout(path: real, linked: linked, activity: activity, walked: walked)
      if let known = byPath[real] {
        if known.activity != nil { checkout = known }
        checkout.linked = known.linked && linked
      }
      byPath[real] = checkout
    }
    for record in worktrees where !record.missing && !record.retired && !record.bare {
      let activity = [record.lastFileChange, record.lastCommitAt].compactMap { $0 }.max()
      // Any gap means the latest inspection may have stopped before its file walk finished, so a
      // file date the record holds could be from an earlier one.
      let walked = record.lastFileChange != nil && record.gaps.isEmpty
      consider(record.path, linked: !record.main, activity: activity, walked: walked)
      if mains, record.repository.hasSuffix("/.git") {
        consider(String(record.repository.dropLast(5)), linked: false, activity: nil, walked: false)
      }
    }
    // The scan is time-bounded, so the stalest checkouts (likeliest junk) go first.
    return byPath.values.sorted {
      let a = $0.activity ?? .distantFuture
      let b = $1.activity ?? .distantFuture
      return a != b ? a < b : $0.path < $1.path
    }
  }

  /// When a linked copy was last worked in, and whether that was over two weeks ago. An old commit
  /// can hide newer edits, so the copy is old only when its files say so too: its inventory
  /// record's complete walk or, when that walk couldn't finish, a walk here past its junk. A copy
  /// that walk can't finish either has an unknown age, which is never old.
  private static func lastWorked(
    _ checkout: Checkout, skipping junk: Set<String>, now: Date, until deadline: Date,
    stop: () -> Bool
  ) -> (date: Date?, old: Bool) {
    guard checkout.linked, let known = checkout.activity else { return (nil, false) }
    let stale = now.timeIntervalSince(known) > staleAfter
    // No walk makes a recent copy older.
    if !stale || checkout.walked { return (known, stale) }
    guard
      let files = newestChange(under: checkout.path, skipping: junk, until: deadline, stop: stop)
    else {
      return (known, false)
    }
    let latest = max(known, files)
    return (latest, now.timeIntervalSince(latest) > staleAfter)
  }

  /// Rebuildable folders up to three levels below a checkout root. Never enters `.git`, other
  /// repositories, links or the folders it finds.
  private static func rebuildableFolders(under root: String, stop: () -> Bool)
    -> [(path: String, name: String)]
  {
    var found: [(path: String, name: String)] = []
    var queue: [(path: String, depth: Int)] = [(path: root, depth: 0)]
    var listed = 0
    while !queue.isEmpty, listed < directoryBudget, found.count < candidateLimit, !stop() {
      let (directory, depth) = queue.removeFirst()
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        continue
      }
      listed += 1
      for name in names.sorted() where name != ".git" {
        let path = directory + "/" + name
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
        if rebuildable[name] != nil {
          found.append((path: path, name: name))
        } else if depth + 1 < maximumDepth && !exists(path + "/.git") {
          queue.append((path: path, depth: depth + 1))
        }
      }
    }
    return found
  }

  /// The newest change in a checkout past its junk: rebuildable folders Git doesn't track and no
  /// other project lives in. Nil when Git can't say what it tracks, or the walk can't see
  /// everything by `deadline` or `stop` says so first.
  static func newestChange(in checkout: String, until deadline: Date, stop: () -> Bool) -> Date? {
    let folders = rebuildableFolders(under: checkout, stop: stop).map { $0.path }
    var junk = Set<String>()
    if !folders.isEmpty {
      let wait = min(deadline.timeIntervalSinceNow, 15)
      guard wait > 0.001, !stop(),
        let tracked = trackedFolders(folders, in: checkout, seconds: wait)
      else { return nil }
      junk = Set(folders.filter { !tracked.contains($0) && !exists($0 + "/.git") })
    }
    return newestChange(under: checkout, skipping: junk, until: deadline, stop: stop)
  }

  /// The newest change to anything in a copy, folders included, except Git's data and what is
  /// inside the given junk folders (their own times count). Never follows links or leaves the
  /// volume. Nil when it can't see everything within the entry budget and the deadline, or `stop`
  /// says so first.
  private static func newestChange(
    under root: String, skipping junk: Set<String>, until deadline: Date, stop: () -> Bool
  ) -> Date? {
    var info = stat()
    guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    let volume = info.st_dev
    var newest = changed(info)
    var pending = [root]
    var seen = 0
    while let directory = pending.popLast() {
      guard Date() < deadline, !stop(),
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
      else { return nil }
      for name in names where name != ".git" {
        let path = directory + "/" + name
        seen += 1
        guard seen <= entryBudget, lstat(path, &info) == 0 else { return nil }
        newest = max(newest, changed(info))
        guard info.st_mode & S_IFMT == S_IFDIR, !junk.contains(path) else { continue }
        // Another volume could hold newer work this walk can't see.
        guard info.st_dev == volume else { return nil }
        pending.append(path)
      }
    }
    return newest
  }

  /// Candidate folders in which Git tracks anything (a committed build/ is not junk), asked
  /// in one call. Nil when Git cannot say, so nothing in that checkout is offered.
  private static func trackedFolders(_ folders: [String], in root: String, seconds: Double = 15)
    -> Set<String>?
  {
    let relatives = folders.map { String($0.dropFirst(root.count + 1)) }
    guard
      let listing = try? WorktreeGit.run(
        root, ["--literal-pathspecs", "ls-files", "-z", "--"] + relatives, seconds: seconds)
    else { return nil }
    let files = listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    var blocked = Set<String>()
    for (folder, relative) in zip(folders, relatives)
    where files.contains(where: { $0 == relative || $0.hasPrefix(relative + "/") }) {
      blocked.insert(folder)
    }
    return blocked
  }

  private static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private static func modified(_ path: String) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return changed(info)
  }

  static func changed(_ info: stat) -> Date {
    let seconds =
      TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    return Date(timeIntervalSince1970: seconds)
  }

  private static func parent(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return slash == path.startIndex ? "/" : String(path[..<slash])
  }

  private static func leaf(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  /// `medium` under 1 GB, `large` under 10 GB, otherwise `huge`.
  static func scale(_ bytes: UInt64) -> String {
    bytes < 1_000_000_000 ? "medium" : bytes < 10_000_000_000 ? "large" : "huge"
  }

  private static func sentence(_ folder: String, subject: String) -> String {
    switch folder {
    case "node_modules":
      return "Downloaded packages for \(subject). npm rebuilds them when needed."
    case "build-output":
      return "Build files for \(subject). The project makes them again the next time it builds."
    case "xcode-derived":
      return "Xcode build files for \(subject). Xcode makes them again when you build."
    case "package-cache":
      return "Saved downloads for \(subject). They download again when needed."
    case "python-env":
      return "Python packages for \(subject). They install again when the project is set up."
    default:
      return "A folder in \(subject)."
    }
  }
}
