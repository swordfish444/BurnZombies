import CBurn
import CryptoKit
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
      (AutopilotGradleCaches.relativePath, "package-cache", "Gradle", true),
      ("Library/Developer/CoreSimulator/Caches", "xcode-derived", "Simulator", false),
    ]

  /// Where Playwright keeps its browsers, relative to the home folder. Beside them are profiles
  /// its tools keep, logins included (`mcp-chrome`, `daemon`), which are never listed.
  static let playwrightCaches: Set<String> = ["Library/Caches/ms-playwright", ".cache/ms-playwright"]

  /// Every name Playwright has given a browser folder (its registry's
  /// `allDownloadableDirectoriesThatEverExisted`).
  private static let playwrightBrowsers = [
    "android", "chromium", "firefox", "webkit", "ffmpeg", "firefox-beta", "chromium-tip-of-tree",
    "chromium-headless-shell", "chromium-tip-of-tree-headless-shell", "winldd",
  ]

  /// The browser builds among the names in a Playwright cache that may go, by Playwright's own
  /// rule (its registry's `_validateInstallationCache`): a browser folder no installed Playwright
  /// uses. Profiles and files its tools keep there are never browser folders.
  public static func playwrightBuilds(_ names: [String], used: Set<String>) -> [String] {
    names.filter { name in
      !used.contains(name)
        && playwrightBrowsers.contains {
          name.hasPrefix($0.replacingOccurrences(of: "-", with: "_") + "-")
        }
    }
  }

  /// The browser folders every installed Playwright uses from the cache at `folder`: each package
  /// that installed browsers there left a file in `.links` naming it, and its `browsers.json`
  /// names its builds. A link whose package is gone is skipped, as Playwright skips it. Nil when
  /// any of that can't be read, or a package is somewhere macOS protects.
  public static func playwrightUsed(_ folder: String, protected: ProtectedLocations = .limited())
    -> Set<String>?
  {
    let links = folder + "/.links"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: links) else {
      return nil
    }
    var used = Set<String>()
    for name in names {
      guard let target = try? String(contentsOfFile: links + "/" + name, encoding: .utf8) else {
        return nil
      }
      let package = target.trimmingCharacters(in: .whitespacesAndNewlines)
      guard package.hasPrefix("/"), protected.allows(package) else { return nil }
      var info = stat()
      guard lstat(package, &info) == 0 else {
        if errno == ENOENT || errno == ENOTDIR { continue }
        return nil
      }
      guard let data = FileManager.default.contents(atPath: package + "/browsers.json"),
        let list = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let browsers = list["browsers"] as? [[String: Any]]
      else { return nil }
      for browser in browsers {
        guard let browserName = browser["name"] as? String,
          let revision = browser["revision"] as? String
        else { return nil }
        used.insert(browserName.replacingOccurrences(of: "-", with: "_") + "-" + revision)
        // A platform with a build of its own keeps it in a folder named for that platform.
        for (platform, special) in (browser["revisionOverrides"] as? [String: String]) ?? [:] {
          let prefix = browserName + "_" + platform + "_special"
          used.insert(prefix.replacingOccurrences(of: "-", with: "_") + "-" + special)
        }
      }
    }
    return used
  }

  /// Why a folder in a Playwright cache stays, or nil when it is a build no Playwright uses.
  private static func playwrightRefusal(
    _ path: String, home: String, protected: ProtectedLocations
  ) -> String? {
    let relative = String(path.dropFirst(home.count + 1))
    guard playwrightCaches.contains(parent(relative)) else { return nil }
    guard let used = playwrightUsed(parent(path), protected: protected) else {
      return "I couldn't tell which Playwright uses that browser, so I left it alone."
    }
    if !playwrightBuilds([leaf(path)], used: used).isEmpty { return nil }
    return used.contains(leaf(path))
      ? "A Playwright you have installed still uses that browser, so I left it alone."
      : "That's a browser profile or file a Playwright tool keeps, so I left it alone."
  }

  private struct Checkout {
    var path: String
    var linked: Bool
    /// The newest date its inventory record holds: last file change or last commit.
    var activity: Date?
    /// Whether that record's latest inspection walked every file in it.
    var walked: Bool
  }

  /// Progress belongs to one six-hour discovery cycle. No open directory handles survive a
  /// slice: burns can still take a folder as soon as the active walk steps out of it.
  public struct ScanProgress {
    fileprivate var measured: Set<String> = []
    fileprivate var finishedRoots: Set<String> = []
    fileprivate var searches: [String: FolderSearch] = [:]
    fileprivate var prepared: [String: PreparedCheckout] = [:]
    /// Failed/occupied targets wait behind every not-yet-attempted target before retrying.
    fileprivate var deferred: Set<String> = []
    fileprivate var trailSizes: [String: UInt64] = [:]
    var roundFinished = false
    public fileprivate(set) var complete = false
    public init() {}

    mutating func invalidate(_ path: String) {
      measured = measured.filter { !WorkspaceSafety.contains(path, $0) }
      finishedRoots = finishedRoots.filter { !AutopilotWalks.overlap(path, $0) }
      searches = searches.filter { !AutopilotWalks.overlap(path, $0.key) }
      prepared = prepared.filter { !AutopilotWalks.overlap(path, $0.key) }
      deferred = deferred.filter { !AutopilotWalks.overlap(path, $0) }
      trailSizes = trailSizes.filter { !WorkspaceSafety.contains(path, $0.key) }
      roundFinished = false
      complete = false
    }
  }

  fileprivate struct FolderSearch {
    var pending: [(path: String, depth: Int)]
    var found: [(path: String, name: String)] = []
    var failed: [(path: String, depth: Int)] = []
    var current: DirectoryEntries?
  }

  fileprivate struct DirectoryEntries {
    var path: String
    var depth: Int
    var names: [String]
    var index: Int = 0
  }

  fileprivate struct PreparedCheckout {
    var folders: [(path: String, name: String)]
    var worked: (date: Date?, old: Bool)
  }

  /// Only successfully measured targets replace an earlier observation. A failed measurement
  /// stays unknown; a partial slice must not erase discoveries from preceding slices.
  public struct ScanBatch {
    public var items: [AutopilotItem]
    public var measured: Set<String>
    public var discarded: Set<String>
    /// Failed targets or parent checks cannot renew an earlier observation's cleanup authority.
    public var incomplete: Set<String>
  }

  /// Rebuildable folders of at least 100 MB inside live checkouts and known developer caches.
  /// Call `scan` with retained progress when discovery needs more than one bounded slice.
  public static func items(
    worktrees: [WorktreeRecord], home: String = NSHomeDirectory(), caches: Bool = true,
    mains: Bool = true, now: Date = Date(),
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) },
    protected: ProtectedLocations? = nil, walks: AutopilotWalks? = nil, trail: String? = nil
  ) -> [AutopilotItem] {
    var progress = ScanProgress()
    return scan(
      worktrees: worktrees, home: home, caches: caches, mains: mains, now: now,
      sizer: sizer, protected: protected, walks: walks, trail: trail, progress: &progress).items
  }

  /// Resume after the last measured folder, including inside a checkout. Budget and clock are
  /// dependencies for deterministic proofs; the live scanner uses the unchanged one-minute cap.
  public static func scan(
    worktrees: [WorktreeRecord], home: String = NSHomeDirectory(), caches: Bool = true,
    mains: Bool = true, now: Date = Date(),
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) },
    protected: ProtectedLocations? = nil, walks: AutopilotWalks? = nil, trail: String? = nil,
    progress: inout ScanProgress, budget: TimeInterval = 60, clock: () -> Date = Date.init
  ) -> ScanBatch {
    let protected = protected ?? .limited(homes: [home])
    let base = WorkspaceSafety.canonical(home)
    guard base.hasPrefix("/"), base != "/" else { return ScanBatch(items: [], measured: [], discarded: [], incomplete: []) }
    let deadline = clock().addingTimeInterval(budget)
    var found: [String: AutopilotItem] = [:]
    var measured: Set<String> = []
    var discarded: Set<String> = []
    var incomplete: Set<String> = []
    progress.complete = false
    progress.roundFinished = false
    func batch() -> ScanBatch {
      ScanBatch(
        items: found.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id },
        measured: measured, discarded: discarded,
        incomplete: incomplete.union(
          progress.searches.values.flatMap { $0.failed.map(\.path) }))
    }
    func deferCheck(_ path: String) {
      progress.deferred.insert(path)
      incomplete.insert(path)
    }

    for cache in globalCaches where caches {
      let location = base + "/" + cache.path
      guard clock() < deadline else { return batch() }
      guard refusal(location, home: base, protected: protected) == nil else { continue }
      var targets = [location]
      if cache.children {
        if progress.deferred.contains(location) { continue }
        guard var names = try? FileManager.default.contentsOfDirectory(atPath: location) else {
          progress.invalidate(location)
          deferCheck(location)
          continue
        }
        if playwrightCaches.contains(cache.path) {
          guard let used = playwrightUsed(location, protected: protected) else {
            progress.invalidate(location)
            deferCheck(location)
            continue
          }
          let eligible = playwrightBuilds(names, used: used)
          discarded.formUnion(Set(names).subtracting(eligible).map { location + "/" + $0 })
          names = eligible
        } else if cache.path == AutopilotGradleCaches.relativePath {
          let eligible = names.filter(AutopilotGradleCaches.isCacheDirectory)
          discarded.formUnion(Set(names).subtracting(eligible).map { location + "/" + $0 })
          discarded.insert(location)
          names = eligible
        }
        targets = names.sorted().map { location + "/" + $0 }
      }
      for target in targets {
        if progress.measured.contains(target) || progress.deferred.contains(target) { continue }
        guard clock() < deadline else { return batch() }
        guard refusal(target, home: base, protected: protected) == nil else { continue }
        guard walks?.enter(target) ?? true else {
          deferCheck(target)
          continue
        }
        defer { walks?.leave(target, early: walks?.wanted(target) ?? false) }
        guard let bytes = sizer(target), !(walks?.wanted(target) ?? false),
          let touched = modified(target)
        else {
          deferCheck(target)
          continue
        }
        progress.measured.insert(target)
        measured.insert(target)
        guard bytes >= minimumBytes else { continue }
        let child = leaf(target)
        let name = cache.path == AutopilotGradleCaches.relativePath
          ? (AutopilotGradleCaches.displayName(child) ?? child)
          : (cache.children ? child + " in " + cache.label : cache.label + " cache")
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

    // Reuse measured browser leftovers too: a large temp directory must not repeatedly consume
    // the slice before project folders get a turn. Eligibility is still checked fresh by its owner.
    if caches, let trail {
      guard clock() < deadline else { return batch() }
      var pendingTrail = false
      var unknownTrail = false
      let item = AutopilotBrowserTrail.item(
        in: trail, now: now, minimumBytes: minimumBytes,
        sizer: { path in
          if let bytes = progress.trailSizes[path] { return bytes }
          if progress.deferred.contains(path) { unknownTrail = true; return nil }
          guard clock() < deadline else { pendingTrail = true; return nil }
          guard let bytes = sizer(path) else {
            deferCheck(path)
            unknownTrail = true
            return nil
          }
          progress.trailSizes[path] = bytes
          return bytes
        })
      if let item { found[item.id] = item }
      if pendingTrail || unknownTrail { incomplete.insert(trail) }
      if !pendingTrail && !unknownTrail { measured.insert(trail) }
      if pendingTrail { return batch() }
    }

    for checkout in checkouts(worktrees, home: base, mains: mains, protected: protected) {
      if progress.finishedRoots.contains(checkout.path) || progress.deferred.contains(checkout.path) {
        continue
      }
      guard clock() < deadline else { return batch() }
      guard walks?.enter(checkout.path) ?? true else {
        deferCheck(checkout.path)
        continue
      }
      var early = false
      defer { walks?.leave(checkout.path, early: early) }
      func away() -> Bool {
        if !early { early = walks?.wanted(checkout.path) ?? false }
        return early
      }
      guard refusal(checkout.path, home: base, protected: protected) == nil,
        protected.pointerPlace(checkout.path) == nil
      else {
        progress.finishedRoots.insert(checkout.path)
        continue
      }
      if progress.prepared[checkout.path] == nil {
        var search = progress.searches[checkout.path]
          ?? FolderSearch(pending: [(path: checkout.path, depth: 0)])
        let searched = advanceFolders(&search, until: deadline, clock: clock, stop: away)
        progress.searches[checkout.path] = search
        guard searched else {
          if early { deferCheck(checkout.path); continue }
          return batch()
        }
        let folders = search.found.filter {
          refusal($0.path, home: base, protected: protected) == nil
        }
        guard !away() else { deferCheck(checkout.path); continue }
        // Git failure cannot make unknown files safe. Retry this checkout after unvisited ones.
        let blocked: Set<String>
        if folders.isEmpty {
          blocked = []
        } else if let tracked = trackedFolders(folders.map { $0.path }, in: checkout.path) {
          blocked = tracked
        } else {
          // Tracking is authority for the whole checkout. Its recovery must refresh every
          // descendant held by this failure, including ones measured in an earlier slice.
          progress.invalidate(checkout.path)
          deferCheck(checkout.path)
          continue
        }
        let junk = folders.filter { !blocked.contains($0.path) && !exists($0.path + "/.git") }
        discarded.formUnion(Set(folders.map(\.path)).subtracting(junk.map(\.path)))
        let worked = lastWorked(
          checkout, skipping: Set(junk.map { $0.path }), now: now,
          until: Date().addingTimeInterval(max(0, deadline.timeIntervalSince(clock()))), stop: away)
        guard !away() else { deferCheck(checkout.path); continue }
        progress.prepared[checkout.path] = PreparedCheckout(folders: junk, worked: worked)
        if search.failed.isEmpty { progress.searches[checkout.path] = nil }
      }
      guard let prepared = progress.prepared[checkout.path] else { continue }
      let place = leaf(checkout.path)
      for folder in prepared.folders {
        if progress.measured.contains(folder.path) || progress.deferred.contains(folder.path) {
          continue
        }
        guard clock() < deadline else { return batch() }
        guard !away() else { deferCheck(checkout.path); break }
        guard refusal(folder.path, home: base, protected: protected) == nil else {
          progress.measured.insert(folder.path)
          continue
        }
        guard let bytes = sizer(folder.path), !away(), let touched = modified(folder.path) else {
          deferCheck(folder.path)
          continue
        }
        progress.measured.insert(folder.path)
        measured.insert(folder.path)
        guard bytes >= minimumBytes else { continue }
        let fact = rebuildable[folder.name] ?? "other"
        let inside = parent(String(folder.path.dropFirst(checkout.path.count + 1)))
        var name = folder.name + " in " + place
        if !inside.isEmpty { name += "/" + inside }
        let newest = prepared.worked.date.map { max($0, touched) } ?? touched
        let item = AutopilotItem(
          id: "disk:" + AutopilotItem.hash(folder.path), kind: .disk, name: name,
          detail: sentence(fact, subject: place), path: folder.path, bytes: bytes,
          facts: [
            "folder": fact, "home": prepared.worked.old ? "stale-worktree" : "repo",
            "stale": AutopilotPolicy.stale(since: newest, now: now), "size": scale(bytes),
          ], observedAt: now, lastUsed: newest)
        found[item.id] = item
      }
      if !early && prepared.folders.allSatisfy({ progress.measured.contains($0.path) }) {
        if let search = progress.searches[checkout.path], !search.failed.isEmpty {
          incomplete.formUnion(search.failed.map(\.path))
          progress.searches[checkout.path] = FolderSearch(pending: search.failed)
          // The checkout waits its turn, but only failed descendants lose authority.
          progress.deferred.insert(checkout.path)
        } else {
          progress.finishedRoots.insert(checkout.path)
        }
        progress.prepared[checkout.path] = nil
      }
    }
    // Exhaust the first attempt at every target before revisiting failures. Completion is
    // truthful: a retryable failure is not a completed six-hour scan.
    progress.complete = progress.deferred.isEmpty
    progress.roundFinished = true
    progress.deferred = []
    return batch()
  }

  private static func advanceFolders(
    _ search: inout FolderSearch, until deadline: Date, clock: () -> Date, stop: () -> Bool
  ) -> Bool {
    var listed = 0
    let firstCount = search.found.count
    while search.current != nil || !search.pending.isEmpty {
      guard clock() < deadline, !stop(), listed < directoryBudget,
        search.found.count - firstCount < candidateLimit else { return false }
      if search.current == nil {
        let (directory, depth) = search.pending.removeFirst()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
          search.failed.append((path: directory, depth: depth))
          continue
        }
        listed += 1
        search.current = DirectoryEntries(path: directory, depth: depth, names: names.sorted())
      }
      guard var current = search.current else { continue }
      while current.index < current.names.count {
        guard clock() < deadline, !stop(), search.found.count - firstCount < candidateLimit else {
          search.current = current
          return false
        }
        let name = current.names[current.index]
        current.index += 1
        guard name != ".git" else { continue }
        let path = current.path + "/" + name
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
        if rebuildable[name] != nil {
          search.found.append((path: path, name: name))
        } else if current.depth + 1 < maximumDepth && !exists(path + "/.git") {
          search.pending.append((path: path, depth: current.depth + 1))
        }
      }
      search.current = nil
    }
    return true
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
  public static let backedUpWords = "What your tools can't rebuild is backed up, ready to restore."

  /// Removes one junk folder after checking every rail again on the live path. Never throws;
  /// a refusal leaves the folder untouched. Known kinds are deleted and measured first; any
  /// other folder goes to the Trash, and only for an operator rule or the operator.
  public static func reclaim(
    _ item: AutopilotItem, authority: String, home: String = NSHomeDirectory(),
    inUse: (String) -> Int32 = { bz_path_in_use($0) }, protected: ProtectedLocations? = nil,
    root: URL = Store.defaultRoot, recoveryKey: SymmetricKey? = nil,
    authorize: () -> Bool = { true }, keys: AutopilotRecoveryKey = .shared
  ) -> AutopilotReceipt {
    let protected = protected ?? .limited(homes: [home])
    var recovery: PrivateRecovery.Reference?
    func refuse(_ reason: String) -> AutopilotReceipt {
      .refused(item, authority: authority, reason)
    }
    func finish(_ outcome: String, _ detail: String, bytes: UInt64 = 0) -> AutopilotReceipt {
      var receipt = AutopilotReceipt(
        itemID: item.id, kind: item.kind, name: item.name, authority: authority, outcome: outcome,
        detail: detail, bytes: bytes)
      if let recovery {
        var restore = AutopilotRestore(
          repository: "", path: item.path ?? "", ref: "", head: "", branch: nil, snapshot: true)
        restore.recovery = recovery
        receipt.restore = restore
      }
      return receipt
    }
    guard item.kind == .disk, let path = item.path else {
      return refuse("That isn't a junk folder, so I left it alone.")
    }
    // The temp folder isn't in the home folder; its leftovers have checks of their own.
    if item.facts["folder"] == "browser-temp" {
      return AutopilotBrowserTrail.reclaim(item, authority: authority, authorize: authorize)
    }
    if BlazerAnatomy.isAnatomical(item) {
      return BlazerAnatomy.reclaim(
        item, authority: authority, home: home, inUse: inUse, protected: protected, root: root,
        authorize: authorize)
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
    if let reason = playwrightRefusal(path, home: base, protected: protected) {
      return refuse(reason)
    }
    var originalIdentity = stat()
    guard lstat(path, &originalIdentity) == 0 else { return refuse("That folder is already gone.") }
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
        return refuse(
          "Git saves files in that folder, so they're part of your project. I left it alone.")
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
      return finish(
        "burned", "Moved \(item.name) to the Trash. Empty the Trash to get the space back.")
    }
    let bytes = allocatedSize(path) ?? item.bytes
    if !regenerable(path, home: base) {
      // As retire does: no keychain question, and a dialog nobody answered refuses the folder.
      let key: SymmetricKey
      do { key = try recoveryKey ?? keys.forBurn() } catch {
        return refuse(AutopilotRecoveryKey.refusal)
      }
      do {
        recovery = try PrivateRecovery.capture(
          path, root: root,
          excluding: recoveryExclusions(path, home: base), key: key)
        try PrivateRecovery.validate(recovery!, key: key)
        guard inUse(path) == 0 else {
          return refuse("Something started using that folder, so I left it alone.")
        }
      } catch {
        // As retire does: the owner reads the reason, in words about a folder, and the receipt keeps
        // what failed.
        var receipt = refuse(AutopilotWorktrees.plainReason(error, about: .folder))
        receipt.cause = AutopilotWorktrees.cause(of: error, at: "backing it up")
        return receipt
      }
    }
    if let reason = refusal(path, home: base, protected: protected) { return refuse(reason) }
    var currentIdentity = stat()
    guard lstat(path, &currentIdentity) == 0, currentIdentity.st_ino == originalIdentity.st_ino,
      currentIdentity.st_dev == originalIdentity.st_dev
    else { return refuse("That folder changed while preserving it, so I left it alone.") }
    guard authorize() else {
      return refuse("Permissions changed while preserving it, so I left it alone.")
    }
    if let recovery {
      do {
        var restore = AutopilotRestore(
          repository: "", path: path, ref: "", head: "", branch: nil, snapshot: true)
        restore.recovery = recovery
        try Store(root: root).write(
          JSONEncoder().encode(restore),
          to: URL(fileURLWithPath: recovery.directory).appendingPathComponent("restore.json"),
          limit: 65536)
      } catch { return refuse("I couldn't save a recovery receipt, so I left it alone.") }
    }
    do {
      try keepingParentTime(of: path) { try FileManager.default.removeItem(atPath: path) }
    } catch {
      return finish(
        "failed", "I couldn't remove all of \(item.name), so some of it is still there.")
    }
    guard !exists(path) else {
      return finish("failed", "\(item.name) is still there, so I'm not counting it as burned.")
    }
    let retained = recovery.map { allocatedSize($0.directory) ?? $0.allocated } ?? 0
    var receipt = finish(
      "burned",
      "Cleared \(item.name)."
        + (recovery == nil
          ? " Your tools will rebuild it when they need it."
          : " " + backedUpWords),
      bytes: bytes > retained ? bytes - retained : 0)
    if let recovery {
      var restore = AutopilotRestore(
        repository: "", path: path, ref: "", head: "", branch: nil, snapshot: true)
      restore.recovery = recovery
      receipt.restore = restore
    }
    return receipt
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
      return
        "That folder is somewhere private (iCloud, Mail, Messages, Photos or keys), so I left it alone."
    }
    guard info.st_uid == getuid() else {
      return "That folder belongs to someone else, so I left it alone."
    }
    return nil
  }

  static func protectedRefusal(_ place: String) -> String {
    "That's in " + place
      + ", which macOS protects, so I left it alone. Turn on Full Disk Access to let me check it."
  }

  /// The `folder` fact a live path earns by its place (global caches) or by its name inside a
  /// checkout, or nil when it is not a known rebuildable kind. `home` must be canonical.
  private static func recognized(_ path: String, home: String) -> String? {
    let relative = String(path.dropFirst(home.count + 1))
    for cache in globalCaches {
      let match = cache.children ? (parent(relative) == cache.path) : (relative == cache.path)
      if match {
        if cache.path == AutopilotGradleCaches.relativePath,
          !AutopilotGradleCaches.isCacheDirectory(leaf(path)) { return nil }
        return cache.folder
      }
    }
    guard let folder = rebuildable[leaf(path)],
      enclosingCheckout(of: path, home: home, levels: maximumDepth) != nil
    else { return nil }
    return folder
  }

  /// Names keep discovery broad. Permanent removal additionally needs a native producer marker;
  /// generic build/dist folders stay eligible but their uncertain bytes get encrypted recovery.
  public static func regenerable(_ path: String, home: String = NSHomeDirectory()) -> Bool {
    let base = WorkspaceSafety.canonical(home)
    let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : ""
    if globalCaches.contains(where: {
      let matches = $0.children ? parent(relative) == $0.path : relative == $0.path
      return matches && ($0.path != AutopilotGradleCaches.relativePath
        || AutopilotGradleCaches.isCacheDirectory(leaf(path)))
    }) {
      return true
    }
    let folder = leaf(path)
    let parentPath = parent(path)
    func regular(_ relative: String) -> Bool {
      let target = path + "/" + relative
      var info = stat()
      return target == WorkspaceSafety.canonical(target) && lstat(target, &info) == 0
        && info.st_mode & S_IFMT == S_IFREG
    }
    switch folder {
    case "node_modules":
      let metadata: Set<String> = [
        ".package-lock.json", ".modules.yaml", ".yarn-integrity", ".yarn-state.yml",
        ".pnpm-workspace-state-v1.json",
      ]
      // Beside the packages: the package manager's store and commands, Prisma's generated client,
      // and caches tools keep in an install.
      let generated: Set<String> = [".bin", ".pnpm", ".prisma", ".vite", ".vite-temp", ".cache"]
      guard metadata.contains(where: regular),
        let entries = try? FileManager.default.contentsOfDirectory(atPath: path),
        entries.count <= 10_000
      else { return false }
      // pnpm links packages in, scoped ones too. Removing a link never touches what it points to.
      func linked(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path + "/" + relative, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
      }
      return entries.allSatisfy { name in
        if metadata.contains(name) || generated.contains(name) || linked(name) { return true }
        var info = stat()
        guard lstat(path + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
          return false
        }
        if name.hasPrefix("@"),
          let packages = try? FileManager.default.contentsOfDirectory(atPath: path + "/" + name)
        {
          return packages.allSatisfy {
            linked(name + "/" + $0) || regular(name + "/" + $0 + "/package.json")
          }
        }
        return regular(name + "/package.json")
      }
    case ".build": return regular("workspace-state.json") && exists(parentPath + "/Package.swift")
    case "target": return regular("CACHEDIR.TAG") && exists(parentPath + "/Cargo.toml")
    case ".venv", "venv": return regular("pyvenv.cfg")
    case ".pytest_cache", ".mypy_cache", ".ruff_cache": return regular("CACHEDIR.TAG")
    case "__pycache__":
      guard let files = try? FileManager.default.contentsOfDirectory(atPath: path),
        !files.isEmpty, files.count <= 10_000
      else { return false }
      return files.allSatisfy { name in
        guard name.hasSuffix(".pyc"), regular(name) else { return false }
        let fd = open(path + "/" + name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16)
        return bytes.map { $0.count == 16 && $0[2] == 13 && $0[3] == 10 } ?? false
      }
    case ".next": return regular("BUILD_ID") && regular("build-manifest.json")
    case ".nuxt": return regular("nuxt.json")
    case ".svelte-kit", ".turbo", ".parcel-cache": return regular("CACHEDIR.TAG")
    case "Pods": return regular("Manifest.lock") && exists(parentPath + "/Podfile")
    default: return false
    }
  }

  public static func recoveryExclusions(_ path: String, home: String = NSHomeDirectory()) -> Set<
    String
  > {
    guard let checkout = try? WorktreeGit.line(path, ["rev-parse", "--show-toplevel"]) else {
      return []
    }
    return Set(
      rebuildableFolders(under: path, stop: { false }).filter { folder in
        guard regenerable(folder.path, home: home), folder.path.hasPrefix(checkout + "/"),
          let tracked = try? WorktreeGit.run(
            checkout,
            [
              "--literal-pathspecs", "ls-files", "-z", "--",
              String(folder.path.dropFirst(checkout.count + 1)),
            ])
        else { return false }
        return tracked.isEmpty
      }.map { String($0.path.dropFirst(path.count + 1)) })
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
