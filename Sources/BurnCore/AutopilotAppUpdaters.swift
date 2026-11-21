import CBurn
import Darwin
import Foundation

/// Universal macOS staged desktop app updater leftovers (`~/Library/Caches/*.ShipIt` from
/// Squirrel.Mac and `~/Library/Caches/*-updater` from `electron-updater`) plus settled temporary
/// JS/TS runtime compile caches (`$TMPDIR/tsx-<uid>` and `$TMPDIR/node-compile-cache`).
public enum AutopilotAppUpdaters {
  public static let updaterSettle: TimeInterval = 2 * 86_400
  public static let electronUpdaterSettle: TimeInterval = 7 * 86_400
  public static let tsxSettle: TimeInterval = 2 * 86_400
  public static let nodeCompileSettle: TimeInterval = 3 * 86_400
  private static let entryLimit = 500
  private static let fileScanBudget = 200_000

  public struct UpdaterTarget: Sendable, Equatable {
    public var path: String
    public var name: String
    public var subject: String
    public var modified: Date
  }

  private enum ShipItActivity {
    case none
    case allBusy
    case suites(names: Set<String>, paths: Set<String>)

    func blocks(entry: String, path: String) -> Bool {
      switch self {
      case .none: return false
      case .allBusy: return true
      case .suites(let names, let paths):
        return names.contains(entry) || paths.contains(path)
      }
    }
  }

  // MARK: - Staged macOS App Updaters (`~/Library/Caches/*.ShipIt` & `*-updater`)

  public static func discoverUpdaters(
    home: String, now: Date = Date(), protected: ProtectedLocations = .limited(),
    shipItRunning: Bool? = nil
  ) -> (targets: [UpdaterTarget], discarded: Set<String>) {
    let base = WorkspaceSafety.canonical(home)
    let cachesRoot = base + "/Library/Caches"
    guard base.hasPrefix("/"), base != "/",
      protected.resolution(cachesRoot).place == nil,
      plainOwnedDirectory(cachesRoot),
      let entries = try? FileManager.default.contentsOfDirectory(atPath: cachesRoot)
    else { return ([], []) }

    let shipItState: ShipItActivity =
      if let shipItRunning {
        shipItRunning ? .allBusy : .none
      } else {
        liveShipItActivity()
      }
    var targets: [UpdaterTarget] = []
    var discarded = Set<String>()

    for entry in entries.sorted().prefix(entryLimit)
    where entry.hasSuffix(".ShipIt") || entry.hasSuffix("-updater") {
      let path = cachesRoot + "/" + entry
      guard protected.resolution(path).place == nil, plainOwnedDirectory(path),
        !exists(path + "/.git")
      else { continue }

      if entry.hasSuffix(".ShipIt") {
        guard isVerifiedShipIt(path), !shipItState.blocks(entry: entry, path: path),
          let changed = AutopilotBrowserTrail.newestChange(path, budget: 25_000)
        else {
          discarded.insert(path)
          continue
        }
        guard now.timeIntervalSince(changed) >= updaterSettle else {
          discarded.insert(path)
          continue
        }
        let appLabel = humanizeUpdaterLabel(entry)
        targets.append(
          UpdaterTarget(
            path: path, name: "Staged app update (\(appLabel))", subject: appLabel,
            modified: changed))
      } else {
        guard isVerifiedElectronUpdater(path),
          let changed = AutopilotBrowserTrail.newestChange(path, budget: 25_000)
        else {
          discarded.insert(path)
          continue
        }
        guard now.timeIntervalSince(changed) >= electronUpdaterSettle else {
          discarded.insert(path)
          continue
        }
        let appLabel = humanizeUpdaterLabel(entry)
        targets.append(
          UpdaterTarget(
            path: path, name: "Staged app update (\(appLabel))", subject: appLabel,
            modified: changed))
      }
    }
    return (targets, discarded)
  }

  public static func recognizedUpdater(_ path: String, home: String) -> String? {
    let base = WorkspaceSafety.canonical(home)
    let cachesRoot = base + "/Library/Caches/"
    guard path.hasPrefix(cachesRoot) else { return nil }
    let rest = String(path.dropFirst(cachesRoot.count))
    guard !rest.isEmpty, !rest.contains("/") else { return nil }
    if rest.hasSuffix(".ShipIt") && plainOwnedDirectory(path) && isVerifiedShipIt(path) {
      return "package-cache"
    }
    if rest.hasSuffix("-updater") && plainOwnedDirectory(path) && isVerifiedElectronUpdater(path) {
      return "package-cache"
    }
    return nil
  }

  public static func updaterRefusal(
    _ path: String, home: String, now: Date = Date(), shipItRunning: Bool? = nil
  ) -> String? {
    let base = WorkspaceSafety.canonical(home)
    let cachesRoot = base + "/Library/Caches/"
    guard path.hasPrefix(cachesRoot) else { return nil }
    let rest = String(path.dropFirst(cachesRoot.count))
    guard !rest.contains("/"), rest.hasSuffix(".ShipIt") || rest.hasSuffix("-updater") else {
      return nil
    }
    guard plainOwnedDirectory(path), !exists(path + "/.git") else {
      return "That staged app update folder changed or moved, so I left it alone."
    }
    if rest.hasSuffix(".ShipIt") {
      guard isVerifiedShipIt(path) else {
        return "That folder doesn't look like a verified Squirrel update cache, so I left it alone."
      }
      let activity: ShipItActivity =
        if let shipItRunning {
          shipItRunning ? .allBusy : .none
        } else {
          liveShipItActivity()
        }
      if activity.blocks(entry: rest, path: path) {
        return "An app update helper is still waiting to install that update, so I left it alone."
      }
    } else {
      guard isVerifiedElectronUpdater(path) else {
        return "That folder doesn't look like a verified app updater cache, so I left it alone."
      }
    }
    let requiredSettle = rest.hasSuffix(".ShipIt") ? updaterSettle : electronUpdaterSettle
    guard let changed = AutopilotBrowserTrail.newestChange(path, budget: 25_000),
      now.timeIntervalSince(changed) >= requiredSettle
    else {
      return "That staged app update was used recently, so I left it alone."
    }
    return nil
  }

  // MARK: - Temp JS/TS Runtime Compile Caches (`$TMPDIR/tsx-<uid>` & `$TMPDIR/node-compile-cache`)

  public static func isTempCompileItem(_ item: AutopilotItem) -> Bool {
    item.id.hasSuffix(":temp-compile") || item.facts["cacheKind"] == "temp-compile"
      || isTempCompilePath(item.path)
  }

  public static func isTempCompilePath(_ rawPath: String?, temp: String? = nil) -> Bool {
    guard let rawPath else { return false }
    let baseTemp = (temp ?? AutopilotBrowserTrail.temporaryFolder()).map(WorkspaceSafety.canonical)
    guard let baseTemp,
      rawPath == baseTemp + "/tsx-\(getuid())"
        || rawPath == baseTemp + "/node-compile-cache"
    else { return false }
    return true
  }

  public static func tempCompilerItems(
    in temp: String, now: Date = Date(), minimumBytes: UInt64 = 100_000_000
  ) -> (items: [AutopilotItem], measured: Set<String>) {
    let baseTemp = WorkspaceSafety.canonical(temp)
    guard baseTemp.hasPrefix("/"), baseTemp != "/" else { return ([], []) }

    var items: [AutopilotItem] = []
    var measured = Set<String>()

    let tsxPath = baseTemp + "/tsx-\(getuid())"
    if plainOwnedDirectory(tsxPath) {
      let scan = settledTsxFiles(in: tsxPath, now: now)
      if scan.complete { measured.insert(tsxPath) }
      if scan.bytes >= minimumBytes, let newest = scan.newest {
        items.append(
          AutopilotItem(
            id: "disk:" + AutopilotItem.hash(tsxPath + "#temp-compile"), kind: .disk,
            name: "tsx compile cache",
            detail:
              "Cached TypeScript transforms finished tsx runs left in your temp folder. Active runs stay untouched.",
            path: tsxPath, bytes: scan.bytes,
            facts: [
              "folder": "package-cache", "home": "global-cache",
              "stale": AutopilotPolicy.stale(since: newest, now: now),
              "size": AutopilotDisk.scale(scan.bytes),
            ], observedAt: now, lastUsed: newest))
      }
    }

    let nodeCachePath = baseTemp + "/node-compile-cache"
    if plainOwnedDirectory(nodeCachePath) {
      let scan = settledNodeCompileEntries(in: nodeCachePath, now: now)
      if scan.complete { measured.insert(nodeCachePath) }
      if scan.bytes >= minimumBytes, let newest = scan.newest {
        items.append(
          AutopilotItem(
            id: "disk:" + AutopilotItem.hash(nodeCachePath + "#temp-compile"), kind: .disk,
            name: "Node compile cache",
            detail:
              "Cached JavaScript bytecode in your temp folder untouched for 3+ days. Node rebuilds it automatically.",
            path: nodeCachePath, bytes: scan.bytes,
            facts: [
              "folder": "package-cache", "home": "global-cache",
              "stale": AutopilotPolicy.stale(since: newest, now: now),
              "size": AutopilotDisk.scale(scan.bytes),
            ], observedAt: now, lastUsed: newest))
      }
    }

    return (items, measured)
  }

  public static func reclaimTempCompiler(
    _ item: AutopilotItem, authority: String, temp: String? = nil, now: Date = Date(),
    inUse: ((String) -> Int32)? = nil, authorize: () -> Bool = { true }
  ) -> AutopilotReceipt {
    func refuse(_ reason: String) -> AutopilotReceipt {
      .refused(item, authority: authority, reason)
    }
    guard item.kind == .disk, let rawPath = item.path,
      let baseTemp = (temp ?? AutopilotBrowserTrail.temporaryFolder()).map(
        WorkspaceSafety.canonical)
    else {
      return refuse("That isn't a recognized temp compile cache, so I left it alone.")
    }
    let path = WorkspaceSafety.canonical(rawPath)
    guard path == rawPath, plainOwnedDirectory(path), !exists(path + "/.git") else {
      return refuse("That temp compile cache moved or changed, so I left it alone.")
    }

    if path == baseTemp + "/tsx-\(getuid())" {
      let scan = settledTsxFiles(in: path, now: now)
      guard !scan.files.isEmpty else {
        return refuse("Nothing in the tsx compile cache is old enough to clear right now.")
      }
      let snapshot = inUse == nil ? WorktreeConsumerSnapshot(roots: [path]) : nil
      let using = inUse ?? { snapshot!.state($0) }
      guard authorize() else {
        return refuse("Permissions changed since I decided, so I left it alone.")
      }
      var removed = 0
      var reclaimed: UInt64 = 0
      for file in scan.files {
        guard using(file.path) == 0 else { continue }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_uid == getuid()
        else { continue }
        let mtime = AutopilotDisk.changed(info)
        guard now.timeIntervalSince(mtime) >= tsxSettle else { continue }
        let blocks = UInt64(max(0, info.st_blocks)) * 512
        if unlink(file.path) == 0 {
          removed += 1
          reclaimed += blocks
        }
      }
      guard removed > 0 else {
        return refuse("Something is still using the tsx compile cache, so I left it alone.")
      }
      malloc_zone_pressure_relief(nil, 0)
      return AutopilotReceipt(
        itemID: item.id, kind: .disk, name: item.name, authority: authority, outcome: "burned",
        detail: "Cleared \(removed) stale tsx compile cache files. Active runs stayed untouched.",
        bytes: reclaimed)
    }

    if path == baseTemp + "/node-compile-cache" {
      let scan = settledNodeCompileEntries(in: path, now: now)
      guard !scan.targets.isEmpty else {
        return refuse("Nothing in the Node compile cache is old enough to clear right now.")
      }
      let snapshot = inUse == nil ? WorktreeConsumerSnapshot(roots: [path]) : nil
      let using = inUse ?? { snapshot!.state($0) }
      guard authorize() else {
        return refuse("Permissions changed since I decided, so I left it alone.")
      }
      var removed = 0
      var reclaimed: UInt64 = 0
      for entry in scan.targets {
        guard using(entry.path) == 0 else { continue }
        var info = stat()
        guard lstat(entry.path, &info) == 0, info.st_uid == getuid() else { continue }
        if entry.isDirectory {
          guard info.st_mode & S_IFMT == S_IFDIR,
            WorkspaceSafety.canonical(entry.path) == entry.path
          else { continue }
          if (try? FileManager.default.removeItem(atPath: entry.path)) != nil,
            !FileManager.default.fileExists(atPath: entry.path)
          {
            removed += 1
            reclaimed += entry.bytes
          }
        } else if info.st_mode & S_IFMT == S_IFREG {
          let mtime = AutopilotDisk.changed(info)
          guard now.timeIntervalSince(mtime) >= nodeCompileSettle else { continue }
          if unlink(entry.path) == 0 {
            removed += 1
            reclaimed += entry.bytes
          }
        }
      }
      guard removed > 0 else {
        return refuse("Something is still using the Node compile cache, so I left it alone.")
      }
      malloc_zone_pressure_relief(nil, 0)
      return AutopilotReceipt(
        itemID: item.id, kind: .disk, name: item.name, authority: authority, outcome: "burned",
        detail: "Cleared stale Node compile cache entries. Active entries stayed untouched.",
        bytes: reclaimed)
    }

    return refuse("That isn't a recognized temp compile cache, so I left it alone.")
  }

  // MARK: - Private Helpers

  private static func settledTsxFiles(in path: String, now: Date) -> (
    files: [(path: String, bytes: UInt64)], bytes: UInt64, newest: Date?, complete: Bool
  ) {
    guard let dir = opendir(path) else { return ([], 0, nil, false) }
    defer { closedir(dir) }
    var files: [(path: String, bytes: UInt64)] = []
    var totalBytes: UInt64 = 0
    var newest: Date?
    var scanned = 0
    var complete = true
    let uid = getuid()
    while let entry = readdir(dir) {
      scanned += 1
      if scanned > fileScanBudget {
        complete = false
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." || name.hasPrefix(".") { continue }
      if let pid = extractedTsxPID(from: name), pid > 1 {
        if kill(pid, 0) == 0 || errno == EPERM { continue }
      }
      let full = path + "/" + name
      var info = stat()
      guard lstat(full, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid else {
        continue
      }
      let changed = AutopilotDisk.changed(info)
      guard now.timeIntervalSince(changed) >= tsxSettle else { continue }
      let bytes = UInt64(max(0, info.st_blocks)) * 512
      files.append((path: full, bytes: bytes))
      totalBytes += bytes
      newest = newest.map { max($0, changed) } ?? changed
    }
    return (files, totalBytes, newest, complete)
  }

  private static func settledNodeCompileEntries(in root: String, now: Date) -> (
    targets: [(path: String, bytes: UInt64, isDirectory: Bool)], bytes: UInt64, newest: Date?,
    complete: Bool
  ) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
      return ([], 0, nil, false)
    }
    let uid = getuid()
    var targets: [(path: String, bytes: UInt64, isDirectory: Bool)] = []
    var totalBytes: UInt64 = 0
    var newest: Date?
    var scanned = 0
    var complete = true

    for sub in names.sorted().prefix(entryLimit) where !sub.hasPrefix(".") {
      let subPath = root + "/" + sub
      guard plainOwnedDirectory(subPath), !exists(subPath + "/.git"),
        let subDir = opendir(subPath)
      else { continue }
      defer { closedir(subDir) }

      var allSettled = true
      var subBytes: UInt64 = 0
      var subNewest: Date?
      var staleFiles: [(path: String, bytes: UInt64)] = []
      var hasAnyEntries = false

      while let entry = readdir(subDir) {
        scanned += 1
        if scanned > fileScanBudget {
          complete = false
          allSettled = false
          break
        }
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
            String(cString: $0)
          }
        }
        if name == "." || name == ".." { continue }
        hasAnyEntries = true
        let filePath = subPath + "/" + name
        var info = stat()
        guard lstat(filePath, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == uid
        else {
          allSettled = false
          continue
        }
        let changed = AutopilotDisk.changed(info)
        let bytes = UInt64(max(0, info.st_blocks)) * 512
        if now.timeIntervalSince(changed) >= nodeCompileSettle {
          staleFiles.append((path: filePath, bytes: bytes))
          subBytes += bytes
          subNewest = subNewest.map { max($0, changed) } ?? changed
        } else {
          allSettled = false
        }
      }

      if allSettled && hasAnyEntries, let subNewest {
        targets.append((path: subPath, bytes: subBytes, isDirectory: true))
        totalBytes += subBytes
        newest = newest.map { max($0, subNewest) } ?? subNewest
      } else {
        for f in staleFiles {
          targets.append((path: f.path, bytes: f.bytes, isDirectory: false))
          totalBytes += f.bytes
        }
        if let subNewest { newest = newest.map { max($0, subNewest) } ?? subNewest }
      }
      if !complete { break }
    }
    return (targets, totalBytes, newest, complete)
  }

  private static func extractedTsxPID(from name: String) -> Int32? {
    let body = name.hasPrefix("tsx-") ? Substring(name.dropFirst(4)) : Substring(name)
    guard let dash = body.firstIndex(of: "-") else { return Int32(body) }
    return Int32(body[..<dash])
  }

  private static func isVerifiedShipIt(_ path: String) -> Bool {
    guard
      regularFile(path + "/ShipItState.plist") || regularFile(path + "/ShipIt_stdout.log")
        || regularFile(path + "/ShipIt_stderr.log"),
      let children = try? FileManager.default.contentsOfDirectory(atPath: path)
    else { return false }
    return children.contains { $0.lowercased().hasPrefix("update.") }
  }

  private static func isVerifiedElectronUpdater(_ path: String) -> Bool {
    if regularFile(path + "/pending/update-info.json") || regularFile(path + "/current.blockmap")
      || regularFile(path + "/update.zip") || regularFile(path + "/installer.dmg")
    {
      return true
    }
    guard let pending = try? FileManager.default.contentsOfDirectory(atPath: path + "/pending")
    else { return false }
    return pending.contains {
      $0.hasSuffix(".zip") || $0.hasSuffix(".dmg") || $0 == "update-info.json"
    }
  }

  /// Squirrel.Mac spawns `ShipIt <suite> <path/to/ShipItState.plist>` while waiting for an open app
  /// to quit. Protect any `.ShipIt` directory whose `ShipIt` helper is alive, and fail closed for
  /// all `.ShipIt` directories if a running `ShipIt` helper's arguments cannot be read.
  private static func liveShipItActivity() -> ShipItActivity {
    let uid = getuid()
    let native = Native()
    let helpers = native.scan().observations.filter {
      $0.uid == uid && !$0.zombie && $0.name.lowercased() == "shipit"
    }
    guard !helpers.isEmpty else { return .none }
    var names = Set<String>()
    var paths = Set<String>()
    for helper in helpers {
      guard let args = native.arguments(helper.identity.pid), args.count >= 2 else {
        return .allBusy
      }
      for arg in args.dropFirst() {
        if arg.hasSuffix(".ShipIt") && !arg.contains("/") {
          names.insert(arg)
        } else if arg.hasPrefix("/") {
          let parent = (arg as NSString).deletingLastPathComponent
          if parent.hasSuffix(".ShipIt") {
            paths.insert(WorkspaceSafety.canonical(parent))
          } else if arg.hasSuffix(".ShipIt") {
            paths.insert(WorkspaceSafety.canonical(arg))
          }
        }
      }
    }
    return names.isEmpty && paths.isEmpty ? .allBusy : .suites(names: names, paths: paths)
  }

  private static func humanizeUpdaterLabel(_ folder: String) -> String {
    if folder.hasSuffix(".ShipIt") {
      let base = String(folder.dropLast(".ShipIt".count))
      let last = base.split(separator: ".").last.map(String.init) ?? base
      return last.isEmpty ? folder : last
    }
    if folder.hasSuffix("-updater") {
      var base = String(folder.dropLast("-updater".count))
      if base.hasPrefix("@") { base.removeFirst() }
      return base.isEmpty ? folder : base
    }
    return folder
  }

  private static func plainOwnedDirectory(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
      return false
    }
    return WorkspaceSafety.canonical(path) == path
  }

  private static func regularFile(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
      && WorkspaceSafety.canonical(path) == path
  }

  private static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }
}
