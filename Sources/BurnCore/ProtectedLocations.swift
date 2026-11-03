import CBurn
import Darwin
import Foundation

/// The places macOS guards with its privacy controls. Without verified Full Disk Access,
/// BurnZombies never looks inside them: no listing, no metadata read and no Git command, so
/// macOS never asks the user for access. A skipped place is reported, never counted as empty.
public struct ProtectedLocations: Sendable {
  /// Full Disk Access is verified, so nothing is out of reach.
  public let unrestricted: Bool
  /// Home folders as given and as the file system spells them, in lowercase: volumes ignore
  /// letter case, so `~/documents` is `~/Documents`.
  private let homes: [String]
  private let spelledHomes: [String]
  /// Mount points of network and removable volumes outside `/Volumes`.
  private let mounts: [String]

  /// Folders inside a home folder, with the plain name a coverage note uses.
  static let places: [(path: String, name: String)] = [
    ("Desktop", "Desktop"), ("Documents", "Documents"), ("Downloads", "Downloads"),
    ("Library/Mobile Documents", "iCloud Drive"), ("Library/CloudStorage", "cloud drives"),
    ("Library/Mail", "Mail"), ("Library/Messages", "Messages"),
    ("Pictures/Photos Library.photoslibrary", "Photos"),
    ("Library/Containers", "other apps' data"), ("Library/Group Containers", "other apps' data"),
  ]
  static let drives = "external and network drives"
  /// Every place, for notes that cannot know which ones held something.
  public static let summary =
    "Desktop, Documents, Downloads, iCloud Drive, Mail, Messages, Photos, other apps' data and external drives"

  public init(access: FullDiskAccessStatus, homes: [String] = []) {
    unrestricted = access.canScan
    var given = homes + [NSHomeDirectory(), FileManager.default.homeDirectoryForCurrentUser.path]
    if let account = getpwuid(getuid()) { given.append(String(cString: account.pointee.pw_dir)) }
    if let variable = ProcessInfo.processInfo.environment["HOME"], variable.hasPrefix("/") {
      given.append(variable)
    }
    var spelled: [String] = []
    for home in given.map(Self.lexical) where home != "/" {
      spelled.append(home)
      // A home folder itself is never protected, so resolving it touches nothing guarded.
      spelled.append(WorkspaceSafety.canonical(home))
      if home.hasPrefix("/Users/") { spelled.append("/System/Volumes/Data" + home) }
    }
    spelledHomes = Array(Set(spelled)).sorted()
    self.homes = Array(Set(spelledHomes.map { $0.lowercased() })).sorted()
    mounts = unrestricted ? [] : Self.guardedMounts()
  }
  /// What this process may reach now, by the Full Disk Access check recorded in `root`.
  public static func current(root: URL, homes: [String] = []) -> Self {
    .init(access: FullDiskAccess.status(root: root), homes: homes)
  }
  /// Everything except the places macOS protects, without reading any access record: the safe
  /// default for a caller that was not handed the current access.
  public static func limited(homes: [String] = []) -> Self { .init(access: .init(), homes: homes) }

  /// The protected place `path` is in, by its spelling alone, or nil when BurnZombies may look.
  public func place(_ path: String) -> String? {
    guard !unrestricted else { return nil }
    let key = Self.lexical(path).lowercased()
    for home in homes {
      for place in Self.places where Self.inside(home + "/" + place.path.lowercased(), key) {
        return place.name
      }
    }
    if key.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) {
      return "Photos"
    }
    // `/Volumes` lists the drives; each drive below it is guarded.
    if key.hasPrefix("/volumes/") || mounts.contains(where: { Self.inside($0, key) }) {
      return Self.drives
    }
    return nil
  }
  public func allows(_ path: String) -> Bool { place(path) == nil }

  /// The protected places strictly inside `root`, spelled as a walk of `root` meets them, so a
  /// walk can skip each one before reading it.
  public func excluded(under root: String) -> [String] {
    guard !unrestricted else { return [] }
    let base = Self.lexical(root).lowercased()
    var result = Set<String>()
    for home in spelledHomes {
      for place in Self.places {
        let path = home + "/" + place.path
        let key = path.lowercased()
        if key != base && Self.inside(base, key) { result.insert(path) }
      }
    }
    for mount in mounts where mount != base && Self.inside(base, mount) { result.insert(mount) }
    if base == "/" { result.insert("/Volumes") }
    return result.sorted()
  }

  /// `realpath`, except that each link is read and its target checked before it is followed.
  /// Nil when the path is, or leads into, a place BurnZombies may not look at.
  public func resolve(_ path: String) -> String? { walk(path).real }
  /// Where `path` really is, or else the protected place it is in or leads into.
  public func resolution(_ path: String) -> (real: String?, place: String?) { walk(path) }
  /// The canonical path where BurnZombies may resolve it, otherwise its tidied spelling.
  public func canonical(_ path: String) -> String {
    let found = walk(path)
    return found.place == nil ? (found.real ?? WorkspaceSafety.canonical(path)) : Self.lexical(path)
  }

  /// Native consumer checks then identify executables in these places from kernel records
  /// alone: resolving such a name would read the protected folder.
  public func guardNativeChecks() {
    let paths =
      unrestricted
      ? [] : spelledHomes.flatMap { home in Self.places.map { home + "/" + $0.path } } + ["/Volumes"] + mounts
    let words = paths.map { strdup($0) }
    defer { words.forEach { free($0) } }
    words.map { UnsafePointer($0) }.withUnsafeBufferPointer {
      bz_guard_paths($0.baseAddress, Int32($0.count))
    }
  }

  /// The protected place a checkout's Git data is in, read from its `.git` pointer and never by
  /// following it. Nil when the data is within reach.
  public func pointerPlace(_ checkout: String) -> String? {
    unrestricted ? nil : repository(of: checkout).place
  }
  /// The repository a checkout's `.git` pointer names, read without following the pointer:
  /// its path when it is within reach, otherwise the protected place it is in.
  public func repository(of checkout: String) -> (common: String?, place: String?) {
    let start = walk(checkout)
    guard let real = start.real else { return (nil, start.place) }
    let pointer = real + "/.git"
    var info = stat()
    guard lstat(pointer, &info) == 0 else { return (nil, nil) }
    let target: String
    switch info.st_mode & S_IFMT {
    case S_IFDIR: return (pointer, nil)  // A directory holds the data itself.
    case S_IFLNK:
      guard let link = Self.link(pointer) else { return (nil, nil) }
      target = link
    case S_IFREG:
      guard let text = Self.text(pointer), text.hasPrefix("gitdir: ") else { return (nil, nil) }
      target = String(text.dropFirst(8))
    default: return (nil, nil)
    }
    let gitdir = walk(target.hasPrefix("/") ? target : real + "/" + target)
    guard let data = gitdir.real else { return (nil, gitdir.place) }
    // A linked checkout's data names the shared repository in `commondir`.
    guard let common = Self.text(data + "/commondir") else { return (data, nil) }
    let shared = walk(common.hasPrefix("/") ? common : data + "/" + common)
    return (shared.real, shared.place)
  }

  /// One plain sentence naming what was skipped and how to cover it.
  public static func note(skipped names: [String]) -> String {
    let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    return "Full Disk Access is off, so BurnZombies skipped "
      + (unique.isEmpty ? summary : list(unique)) + ", which macOS protects. Turn on Full Disk Access to cover "
      + (unique.count == 1 ? "it" : "them") + " too."
  }
  /// Why one path was skipped.
  public static func reason(_ place: String) -> String {
    "It is in " + place + ", which macOS protects. Turn on Full Disk Access so BurnZombies can check it."
  }

  private func walk(_ path: String) -> (real: String?, place: String?) {
    if let place = place(path) { return (nil, place) }
    guard !unrestricted else { return (WorkspaceSafety.canonical(path), nil) }
    var pending = path.split(separator: "/").map(String.init)
    var walked = ""
    var links = 0
    while !pending.isEmpty {
      let part = pending.removeFirst()
      if part.isEmpty || part == "." { continue }
      if part == ".." {
        walked = String(walked[..<(walked.lastIndex(of: "/") ?? walked.startIndex)])
        continue
      }
      let next = walked + "/" + part
      if let place = place(next) { return (nil, place) }
      var info = stat()
      guard lstat(next, &info) == 0 else {
        // Nothing exists below a missing folder, so the rest is only spelling.
        let rest = Self.lexical(([next] + pending).joined(separator: "/"))
        if let place = place(rest) { return (nil, place) }
        return checked(WorkspaceSafety.canonical(rest))
      }
      guard info.st_mode & S_IFMT == S_IFLNK else {
        walked = next
        continue
      }
      links += 1
      guard links <= 32, let target = Self.link(next) else { return (nil, nil) }
      if target.hasPrefix("/") { walked = "" }
      pending = target.split(separator: "/").map(String.init) + pending
    }
    // Every component is checked and none is a link, so realpath only reads those.
    return checked(WorkspaceSafety.canonical(walked.isEmpty ? "/" : walked))
  }
  private func checked(_ real: String) -> (real: String?, place: String?) {
    let blocked = place(real)
    return (blocked == nil ? real : nil, blocked)
  }

  static func lexical(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
      if part == ".." { _ = parts.popLast() } else { parts.append(part) }
    }
    return "/" + parts.joined(separator: "/")
  }
  static func inside(_ root: String, _ path: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }
  private static func link(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
    let count = readlink(path, &buffer, Int(MAXPATHLEN))
    guard count > 0 else { return nil }
    return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
  static func text(_ path: String) -> String? {
    guard
      let data = try? WorktreeRecovery.read(
        URL(fileURLWithPath: path, isDirectory: false), limit: 4096),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func list(_ names: [String]) -> String {
    names.count < 2
      ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
  }
  /// Network volumes and removable media mounted outside `/Volumes`, from the kernel's mount
  /// table: nothing on them is read.
  private static func guardedMounts() -> [String] {
    let count = Int(getfsstat(nil, 0, MNT_NOWAIT))
    guard count > 0 else { return [] }
    let table = UnsafeMutablePointer<statfs>.allocate(capacity: count)
    defer { table.deallocate() }
    let filled = Int(getfsstat(table, Int32(count * MemoryLayout<statfs>.stride), MNT_NOWAIT))
    guard filled > 0 else { return [] }
    return (0..<min(filled, count)).compactMap { index in
      let mount = table[index]
      let point = withUnsafePointer(to: mount.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      let guarded =
        mount.f_flags & UInt32(MNT_LOCAL) == 0 || mount.f_flags & UInt32(MNT_REMOVABLE) != 0
      return guarded && point != "/" ? point.lowercased() : nil
    }
  }
}
