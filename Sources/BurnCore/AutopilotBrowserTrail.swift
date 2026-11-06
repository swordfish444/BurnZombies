import CBurn
import Darwin
import Foundation

/// What robot browsers leave in the user's temp folder when the program driving them dies before
/// closing them: throwaway profiles and the folders their recordings and downloads go to. Their
/// tool deletes each one on a clean close, so a leftover nothing holds is junk. All of them make
/// one item; each folder is checked again right before it is removed.
public enum AutopilotBrowserTrail {
  /// Playwright's, Puppeteer's and chromedriver's names for them.
  public static let prefixes =
    RobotBrowser.throwawayPrefixes + ["playwright-artifacts-"]
  /// A folder anything wrote to within this long may still be in use.
  public static let settle: TimeInterval = 3600
  /// Leftovers counted at most, so one look stays cheap.
  static let limit = 5_000

  public struct Leftover: Sendable {
    public var path: String
    public var bytes: UInt64
    public var changed: Date
  }

  /// This user's own temp folder, where macOS points `TMPDIR`. Canonical, or nil.
  public static func temporaryFolder() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
    let path = WorkspaceSafety.canonical(String(cString: buffer))
    return path.hasPrefix("/") && path != "/" ? path : nil
  }

  /// Robot-browser folders directly in `folder` that are real folders of this user, untouched
  /// for an hour and not locked by a running browser. Sized with `sizer`.
  public static func leftovers(
    in folder: String, now: Date = Date(),
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) }
  ) -> [Leftover] {
    let base = WorkspaceSafety.canonical(folder)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
    var found: [Leftover] = []
    for name in names.sorted() where prefixes.contains(where: name.hasPrefix) {
      guard found.count < limit else { break }
      let path = base + "/" + name
      guard let changed = settled(path, now: now), let bytes = sizer(path) else { continue }
      found.append(Leftover(path: path, bytes: bytes, changed: changed))
    }
    return found
  }

  /// One item for all the leftovers in `folder`, or nil below `minimumBytes`.
  public static func item(
    in folder: String, now: Date = Date(), minimumBytes: UInt64 = 100_000_000,
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) }
  ) -> AutopilotItem? {
    let found = leftovers(in: folder, now: now, sizer: sizer)
    let bytes = found.reduce(0) { $0 + $1.bytes }
    guard !found.isEmpty, bytes >= minimumBytes, let newest = found.map(\.changed).max() else {
      return nil
    }
    let base = WorkspaceSafety.canonical(folder)
    let count = found.count
    return AutopilotItem(
      id: "disk:" + AutopilotItem.hash(base + "#robot-browser-leftovers"), kind: .disk,
      name: "Robot-browser leftovers",
      detail:
        "\(count) folder\(count == 1 ? "" : "s") robot browsers left in your temp folder: throwaway profiles and recordings their tools delete on a clean close. Nothing has used \(count == 1 ? "it" : "them") for an hour.",
      path: base, bytes: bytes,
      facts: [
        "folder": "browser-temp", "home": "temp",
        "stale": AutopilotPolicy.stale(since: newest, now: now), "size": AutopilotDisk.scale(bytes),
      ], observedAt: now, lastUsed: newest)
  }

  /// Removes every leftover in the temp folder the item names that still passes every check, one
  /// folder at a time. `inUse` answers 0 for a folder no program has open (by default from one
  /// look at every program's open files), 1 for one in use, anything else when unknown.
  /// `authorize` says, right before the first removal, whether the decision to burn still stands.
  public static func reclaim(
    _ item: AutopilotItem, authority: String, folder: String? = nil, now: Date = Date(),
    inUse: ((String) -> Int32)? = nil, authorize: () -> Bool = { true }
  ) -> AutopilotReceipt {
    func refuse(_ reason: String) -> AutopilotReceipt {
      .refused(item, authority: authority, reason)
    }
    guard item.kind == .disk, item.facts["folder"] == "browser-temp",
      let base = (folder ?? temporaryFolder()).map(WorkspaceSafety.canonical)
    else { return refuse("I can't find your temp folder, so I left it alone.") }
    guard item.path == base else {
      return refuse("That isn't your temp folder anymore, so I left it alone.")
    }
    let found = leftovers(in: base, now: now)
    guard !found.isEmpty else { return refuse("Nothing robot browsers left is old enough now.") }
    let snapshot = inUse == nil ? WorktreeConsumerSnapshot(roots: [base]) : nil
    let using = inUse ?? { snapshot!.state($0) }
    guard authorize() else {
      return refuse("Permissions changed since I decided, so I left it alone.")
    }
    var removed = 0
    var bytes: UInt64 = 0
    var held = 0
    var unchecked = 0
    for leftover in found {
      // One last look at each folder right before it goes.
      let use = using(leftover.path)
      guard use == 0, settled(leftover.path, now: now) != nil else {
        if use == 0 || use == 1 { held += 1 } else { unchecked += 1 }
        continue
      }
      let size = AutopilotDisk.allocatedSize(leftover.path) ?? leftover.bytes
      guard (try? FileManager.default.removeItem(atPath: leftover.path)) != nil,
        !FileManager.default.fileExists(atPath: leftover.path)
      else {
        held += 1
        continue
      }
      removed += 1
      bytes += size
    }
    guard removed > 0 else {
      return refuse(
        unchecked > 0
          ? AutopilotDisk.uncheckedUse
          : "Something is still using what robot browsers left, so I left it alone.")
    }
    var detail =
      "Cleared \(removed) folder\(removed == 1 ? "" : "s") robot browsers left in your temp folder."
    if held + unchecked > 0 {
      detail += " \(held + unchecked) that may still be in use stayed."
    }
    return AutopilotReceipt(
      itemID: item.id, kind: .disk, name: item.name, authority: authority, outcome: "burned",
      detail: detail, bytes: bytes)
  }

  /// When the folder last changed, if it is a real folder of this user whose contents nothing
  /// changed for an hour and no running browser has locked; nil otherwise.
  static func settled(_ path: String, now: Date) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      WorkspaceSafety.canonical(path) == path, !locked(path),
      let changed = newestChange(path), now.timeIntervalSince(changed) >= settle
    else { return nil }
    return changed
  }

  /// A running browser holds its profile with a lock that names its process: Chrome's
  /// `SingletonLock` ("host-PID") and Firefox's `lock` ("address:+PID").
  static func locked(_ path: String) -> Bool {
    for name in ["SingletonLock", "lock"] {
      guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path + "/" + name)
      else { continue }
      let digits = target.split(whereSeparator: { $0 == "-" || $0 == "+" }).last.map(String.init)
      guard let pid = digits.flatMap({ Int32($0) }), pid > 0 else { return true }
      if kill(pid, 0) == 0 || errno == EPERM { return true }
    }
    return false
  }

  /// The newest change to anything in the folder, the folder included, within a small walk; nil
  /// when the walk can't see all of it.
  static func newestChange(_ root: String, budget: Int = 20_000) -> Date? {
    var info = stat()
    guard lstat(root, &info) == 0 else { return nil }
    let volume = info.st_dev
    var newest = AutopilotDisk.changed(info)
    var pending = [root]
    var seen = 0
    while let directory = pending.popLast() {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        return nil
      }
      for name in names {
        let path = directory + "/" + name
        seen += 1
        guard seen <= budget, lstat(path, &info) == 0 else { return nil }
        newest = max(newest, AutopilotDisk.changed(info))
        if info.st_mode & S_IFMT == S_IFDIR {
          guard info.st_dev == volume else { return nil }
          pending.append(path)
        }
      }
    }
    return newest
  }
}
