import CBurn
import Darwin
import Foundation

/// Scratch folders finished AI coding chats leave behind: `$TMPDIR/claude-*` sandboxes untouched
/// for 2+ days, `~/.codex/{artifacts,session-artifacts,task-artifacts}/*` untouched for 14+ days,
/// and `~/.gemini/antigravity/brain/<id>/{scratch,browser_sandbox}` for non-live chats untouched
/// for 14+ days. Transcripts, conversation artifacts, and live sessions are never touched.
public enum AutopilotAgentScratch {
  public static let tempSettle: TimeInterval = 2 * 86_400
  public static let homeSettle: TimeInterval = 14 * 86_400
  private static let entryLimit = 2_000
  private static let codexStores = [
    (relative: ".codex/artifacts", name: "Codex scratch leftovers"),
    (relative: ".codex/session-artifacts", name: "Codex session scratch leftovers"),
    (relative: ".codex/task-artifacts", name: "Codex task scratch leftovers"),
  ]

  public struct Leftover: Sendable, Equatable {
    public var path: String
    public var bytes: UInt64
    public var changed: Date
  }

  /// Discovers scratch items across `home` and optional `temp` (`$TMPDIR`). Each returned item
  /// carries a real existing directory path so `Never touches`, `Show in Finder` and cache
  /// invalidation behave identically to every other disk item.
  public static func items(
    home: String, temp: String? = nil, now: Date = Date(), minimumBytes: UInt64 = 100_000_000,
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) }
  ) -> (items: [AutopilotItem], measured: Set<String>) {
    let baseHome = WorkspaceSafety.canonical(home)
    guard baseHome.hasPrefix("/"), baseHome != "/" else { return ([], []) }

    var result: [AutopilotItem] = []
    var measured = Set<String>()

    if let temp {
      let baseTemp = WorkspaceSafety.canonical(temp)
      if baseTemp.hasPrefix("/"), baseTemp != "/",
        let names = try? FileManager.default.contentsOfDirectory(atPath: baseTemp)
      {
        for name in names.sorted().prefix(entryLimit) where name.hasPrefix("claude-") {
          let path = baseTemp + "/" + name
          let entries = claudeLeftovers(at: path, now: now, sizer: sizer)
          measured.insert(path)
          let bytes = entries.reduce(0) { $0 + $1.bytes }
          guard !entries.isEmpty, bytes >= minimumBytes, let newest = entries.map(\.changed).max()
          else { continue }
          let count = entries.count
          result.append(
            AutopilotItem(
              id: "disk:" + AutopilotItem.hash(path + "#agent-scratch"), kind: .disk,
              name: "Claude scratch leftovers (\(name))",
              detail:
                "\(count) scratch folder\(count == 1 ? "" : "s") finished Claude chats left in your temp folder. Nothing has used \(count == 1 ? "it" : "them") for 2+ days.",
              path: path, bytes: bytes,
              facts: [
                "folder": "agent-temp", "home": "temp",
                "stale": AutopilotPolicy.stale(since: newest, now: now),
                "size": AutopilotDisk.scale(bytes),
              ], observedAt: now, lastUsed: newest))
        }
      }
    }

    for store in codexStores {
      let root = baseHome + "/" + store.relative
      guard plainOwnedDirectory(root) else { continue }
      let entries = childLeftovers(in: root, settle: homeSettle, now: now, sizer: sizer)
      measured.insert(root)
      let bytes = entries.reduce(0) { $0 + $1.bytes }
      guard !entries.isEmpty, bytes >= minimumBytes, let newest = entries.map(\.changed).max()
      else { continue }
      let count = entries.count
      result.append(
        AutopilotItem(
          id: "disk:" + AutopilotItem.hash(root + "#agent-scratch"), kind: .disk,
          name: store.name,
          detail:
            "\(count) scratch folder\(count == 1 ? "" : "s") finished Codex chats left behind. Nothing has used \(count == 1 ? "it" : "them") for 2+ weeks.",
          path: root, bytes: bytes,
          facts: [
            "folder": "agent-temp", "home": "temp",
            "stale": AutopilotPolicy.stale(since: newest, now: now),
            "size": AutopilotDisk.scale(bytes),
          ], observedAt: now, lastUsed: newest))
    }

    let brainRoot = baseHome + "/.gemini/antigravity/brain"
    if plainOwnedDirectory(brainRoot) {
      let entries = antigravityLeftovers(home: baseHome, now: now, sizer: sizer)
      measured.insert(brainRoot)
      let bytes = entries.reduce(0) { $0 + $1.bytes }
      if !entries.isEmpty, bytes >= minimumBytes, let newest = entries.map(\.changed).max() {
        let count = entries.count
        result.append(
          AutopilotItem(
            id: "disk:" + AutopilotItem.hash(brainRoot + "#agent-scratch"), kind: .disk,
            name: "Antigravity scratch leftovers",
            detail:
              "\(count) scratch folder\(count == 1 ? "" : "s") finished Antigravity chats left behind. Conversation notes and artifacts stay untouched.",
            path: brainRoot, bytes: bytes,
            facts: [
              "folder": "agent-temp", "home": "temp",
              "stale": AutopilotPolicy.stale(since: newest, now: now),
              "size": AutopilotDisk.scale(bytes),
            ], observedAt: now, lastUsed: newest))
      }
    }

    return (result, measured)
  }

  /// Re-checks live session state, ownership, age and open file handles on each scratch subfolder
  /// right before removing it. Parent containers and non-scratch conversation files stay untouched.
  public static func reclaim(
    _ item: AutopilotItem, authority: String, home: String = NSHomeDirectory(),
    temp: String? = nil, now: Date = Date(), inUse: ((String) -> Int32)? = nil,
    authorize: () -> Bool = { true }
  ) -> AutopilotReceipt {
    func refuse(_ reason: String) -> AutopilotReceipt {
      .refused(item, authority: authority, reason)
    }
    guard item.kind == .disk, item.facts["folder"] == "agent-temp", let rawPath = item.path else {
      return refuse("That isn't an AI scratch folder, so I left it alone.")
    }
    let baseHome = WorkspaceSafety.canonical(home)
    let path = WorkspaceSafety.canonical(rawPath)
    guard path == rawPath, baseHome.hasPrefix("/"), baseHome != "/" else {
      return refuse("That scratch folder moved or turned into a shortcut, so I left it alone.")
    }

    let candidates: [Leftover]
    let settle: TimeInterval
    let removeContainerWhenWhole: Bool
    var liveSkip: Set<String> = []

    let brainRoot = baseHome + "/.gemini/antigravity/brain"
    if path == brainRoot {
      settle = homeSettle
      removeContainerWhenWhole = false
      liveSkip = AgentThreads.liveAntigravityIDs(home: baseHome, now: now)
      candidates = antigravityLeftovers(home: baseHome, now: now, liveIDs: liveSkip)
    } else if codexStores.contains(where: { baseHome + "/" + $0.relative == path }) {
      settle = homeSettle
      removeContainerWhenWhole = false
      candidates = childLeftovers(in: path, settle: homeSettle, now: now)
    } else {
      let resolvedTemp = (temp ?? AutopilotBrowserTrail.temporaryFolder()).map(
        WorkspaceSafety.canonical)
      let parent = (path as NSString).deletingLastPathComponent
      let name = (path as NSString).lastPathComponent
      guard let resolvedTemp, parent == resolvedTemp, name.hasPrefix("claude-") else {
        return refuse("That isn't an AI scratch folder I recognize, so I left it alone.")
      }
      settle = tempSettle
      candidates = claudeLeftovers(at: path, now: now)
      removeContainerWhenWhole = candidates.count == 1 && candidates[0].path == path
    }

    guard !candidates.isEmpty else {
      return refuse("Nothing AI chats left in scratch folders is old enough now.")
    }

    let snapshot = inUse == nil ? WorktreeConsumerSnapshot(roots: [path]) : nil
    let using = inUse ?? { snapshot!.state($0) }
    guard authorize() else {
      return refuse("Permissions changed since I decided, so I left it alone.")
    }

    if path == brainRoot {
      liveSkip = AgentThreads.liveAntigravityIDs(home: baseHome, now: now)
    }

    var removed = 0
    var bytes: UInt64 = 0
    var held = 0
    var unchecked = 0

    for entry in candidates {
      if path == brainRoot {
        let brainID = brainFolderID(for: entry.path, brainRoot: brainRoot)
        if let brainID, liveSkip.contains(brainID) {
          held += 1
          continue
        }
      }
      let use = using(entry.path)
      guard use == 0, settled(entry.path, settle: settle, now: now) != nil else {
        if use == 0 || use == 1 { held += 1 } else { unchecked += 1 }
        continue
      }
      let size = AutopilotDisk.allocatedSize(entry.path) ?? entry.bytes
      let deleted: Bool = keepingParentTime(of: entry.path, preserve: !removeContainerWhenWhole) {
        (try? FileManager.default.removeItem(atPath: entry.path)) != nil
          && !FileManager.default.fileExists(atPath: entry.path)
      }
      guard deleted else {
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
          : "Something is still using those AI scratch folders, so I left them alone.")
    }

    var detail =
      "Cleared \(removed) scratch folder\(removed == 1 ? "" : "s") finished AI chats left behind."
    if held + unchecked > 0 {
      detail += " \(held + unchecked) that may still be in use stayed."
    }
    return AutopilotReceipt(
      itemID: item.id, kind: .disk, name: item.name, authority: authority, outcome: "burned",
      detail: detail, bytes: bytes)
  }

  // MARK: - Discovery Helpers

  private static func claudeLeftovers(
    at path: String, now: Date,
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) }
  ) -> [Leftover] {
    guard plainOwnedDirectory(path) else { return [] }
    if let wholeChanged = settled(path, settle: tempSettle, now: now),
      let bytes = sizer(path)
    {
      return [Leftover(path: path, bytes: bytes, changed: wholeChanged)]
    }
    // `$TMPDIR/claude-<uid>` often holds one folder per project: keep recent project folders while
    // reclaiming stale sibling folders (or stale `tasks/*` subfolders inside active projects)
    // untouched for 2+ days.
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
    var found: [Leftover] = []
    for name in names.sorted().prefix(entryLimit) where !name.hasPrefix(".") {
      let child = path + "/" + name
      guard plainOwnedDirectory(child), !exists(child + "/.git") else { continue }
      if let changed = settled(child, settle: tempSettle, now: now), let bytes = sizer(child) {
        found.append(Leftover(path: child, bytes: bytes, changed: changed))
      } else {
        let tasks = child + "/tasks"
        if plainOwnedDirectory(tasks), !exists(tasks + "/.git") {
          found += childLeftovers(in: tasks, settle: tempSettle, now: now, sizer: sizer)
        }
      }
    }
    return found
  }

  private static func childLeftovers(
    in root: String, settle: TimeInterval, now: Date,
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) }
  ) -> [Leftover] {
    guard plainOwnedDirectory(root),
      let names = try? FileManager.default.contentsOfDirectory(atPath: root)
    else { return [] }
    var found: [Leftover] = []
    for name in names.sorted().prefix(entryLimit) where !name.hasPrefix(".") {
      let child = root + "/" + name
      guard let changed = settled(child, settle: settle, now: now), let bytes = sizer(child) else {
        continue
      }
      found.append(Leftover(path: child, bytes: bytes, changed: changed))
    }
    return found
  }

  private static func antigravityLeftovers(
    home: String, now: Date, liveIDs: Set<String>? = nil,
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) }
  ) -> [Leftover] {
    let brainRoot = home + "/.gemini/antigravity/brain"
    guard plainOwnedDirectory(brainRoot),
      let ids = try? FileManager.default.contentsOfDirectory(atPath: brainRoot)
    else { return [] }
    let active = liveIDs ?? AgentThreads.liveAntigravityIDs(home: home, now: now)
    var found: [Leftover] = []
    for id in ids.sorted().prefix(entryLimit) where !id.hasPrefix(".") && !active.contains(id) {
      let brain = brainRoot + "/" + id
      guard plainOwnedDirectory(brain) else { continue }
      for sub in ["scratch", "browser_sandbox"] {
        let target = brain + "/" + sub
        guard let changed = settled(target, settle: homeSettle, now: now),
          let bytes = sizer(target)
        else { continue }
        found.append(Leftover(path: target, bytes: bytes, changed: changed))
      }
    }
    return found
  }

  private static func brainFolderID(for target: String, brainRoot: String) -> String? {
    let prefix = brainRoot + "/"
    guard target.hasPrefix(prefix) else { return nil }
    let rest = target.dropFirst(prefix.count)
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    return String(rest[..<slash])
  }

  private static func settled(_ path: String, settle: TimeInterval, now: Date) -> Date? {
    guard plainOwnedDirectory(path), !exists(path + "/.git"),
      let changed = AutopilotBrowserTrail.newestChange(path),
      now.timeIntervalSince(changed) >= settle
    else { return nil }
    return changed
  }

  private static func plainOwnedDirectory(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
      return false
    }
    return WorkspaceSafety.canonical(path) == path
  }

  private static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private static func keepingParentTime<T>(
    of path: String, preserve: Bool, _ body: () -> T
  ) -> T {
    guard preserve else { return body() }
    let parent = (path as NSString).deletingLastPathComponent
    var before = stat()
    let directory = lstat(parent, &before) == 0 && before.st_mode & S_IFMT == S_IFDIR
    defer {
      if directory {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), before.st_mtimespec]
        _ = utimensat(AT_FDCWD, parent, &times, AT_SYMLINK_NOFOLLOW)
      }
    }
    return body()
  }
}
