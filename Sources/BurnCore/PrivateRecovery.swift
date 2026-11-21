import Compression
import CryptoKit
import Darwin
import Foundation

/// Raw local changes never enter Git objects. Every retained byte is authenticated, compressed
/// and encrypted with the existing device recovery key, then restored and verified before use.
public enum PrivateRecovery {
  public struct Reference: Codable, Sendable, Equatable {
    public var directory: String
    public var id: String
    public var source: String
    public var digest: String
    public var allocated: UInt64
  }
  struct Manifest: Codable {
    var files: [WorktreeFile]
    var excluded: Set<String>
    /// Big unsaved files and folders the owner let go: never kept, deleted with the copy.
    var left: Set<String>?
    var gitPointers: Set<String>?
    var repository: String?
    var head: String?
    var committed: Set<String>?
    /// Files with other names were kept by their contents; the check walks the same way.
    var hardLinks: Bool?
  }
  /// `excluding` names proven generated folders; `leavingOut`, big unsaved files and folders the
  /// owner let go, which nothing keeps. With `hardLinks`, a file that has other names is kept by
  /// its contents and comes back as a file of its own.
  public static func capture(
    _ path: String, root: URL, excluding: Set<String> = [], leavingOut: Set<String> = [],
    gitPointers: Set<String> = [], repository: String? = nil, head: String? = nil,
    key: SymmetricKey? = nil, hardLinks: Bool = false
  ) throws -> Reference {
    let key = try key ?? WorktreeRecoveryKey.load()
    let storeRoot = try Store(root: root.appendingPathComponent("private-recovery")).root
    let base = URL(fileURLWithPath: WorkspaceSafety.canonical(storeRoot.path))
    let id = UUID().uuidString
    let directory = base.appendingPathComponent(id)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    var complete = false
    defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
    let original = try WorktreeInspection.files(
      path, seconds: 120, permitLinks: true, excluding: excluding, leavingOut: leavingOut,
      ignoringGitPointers: gitPointers, hardLinks: hardLinks
    ).0
    guard
      let free = try FileManager.default.attributesOfFileSystem(forPath: base.path)[.systemFreeSize]
        as? NSNumber
    else {
      throw StoreError.message("Private recovery capacity is unknown; preserve the original.")
    }
    var uniqueBytes: UInt64 = 0
    var committed = Set<String>()
    if let repository, let head {
      // Reuse only tracked files Git independently reports unchanged, with ordinary index flags.
      // No new source bytes enter Git and clean saved checkouts do not duplicate their contents.
      let configuration = try WorktreeGit.text(path, ["config", "--null", "--name-only", "--list"])
      let partial = configuration.split(separator: "\0").contains {
        $0 == "extensions.partialclone" || $0.hasSuffix(".promisor")
      }
      let changed = Set(
        try WorktreeGit.run(
          path,
          [
            "diff", "--name-only", "-z", "--no-ext-diff", "--no-textconv",
            "--ignore-submodules=all", head, "--",
          ]
        ).split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
      let flags = try WorktreeGit.run(path, ["ls-files", "-v", "-z"]).split(separator: 0)
      for entry in flags {
        let name = String(decoding: entry.dropFirst(2), as: UTF8.self)
        if !partial, entry.first == 72, !changed.contains(name) { committed.insert(name) }
      }
      _ = try WorktreeGit.run(repository, ["cat-file", "-e", head + "^{commit}"])
    }
    var files = original
    let scratchCapacity = 1_100_000
    var encodeScratch = [UInt8](repeating: 0, count: scratchCapacity)
    defer { malloc_zone_pressure_relief(nil, 0) }
    for i in files.indices where files[i].kind == "file" {
      if committed.contains(files[i].path) { continue }
      uniqueBytes += UInt64(max(0, files[i].size))
      guard free.uint64Value > uniqueBytes + 67_108_864 else {
        throw StoreError.message(
          "Insufficient private recovery capacity; preserve the original without truncation.")
      }
      try autoreleasepool {
        let file = URL(fileURLWithPath: path).appendingPathComponent(files[i].path)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
          throw StoreError.message("Recovery source unavailable; nothing removed.")
        }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        var after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
          before.st_ino == files[i].inode, before.st_size == files[i].size
        else {
          throw StoreError.message("Recovery source changed; nothing removed.")
        }
        var hash = SHA256()
        var size: Int64 = 0
        var blocks: [String] = []
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
          try Task.checkCancellation()
          try autoreleasepool {
            hash.update(data: data)
            size += Int64(data.count)
            let packed: Data
            let encodedCount = encodeScratch.withUnsafeMutableBytes { dst in
              data.withUnsafeBytes { src in
                compression_encode_buffer(
                  dst.bindMemory(to: UInt8.self).baseAddress!, scratchCapacity,
                  src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
              }
            }
            if encodedCount > 0 {
              packed = Data(bytes: encodeScratch, count: encodedCount)
            } else {
              packed = try (data as NSData).compressed(using: .lzfse) as Data
            }
            let name = UUID().uuidString + ".enc"
            try WorktreeRecovery.write(
              WorktreeRecovery.seal(
                packed, key: key, context: id + "|" + files[i].path + "|\(blocks.count)"),
              to: directory.appendingPathComponent(name))
            blocks.append(name)
          }
        }
        guard fstat(fd, &after) == 0, size == before.st_size, before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
          throw StoreError.message("Recovery source changed; nothing removed.")
        }
        files[i].blocks = blocks
        files[i].digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
      }
    }
    let manifest = try JSONEncoder().encode(
      Manifest(
        files: files, excluded: excluding, left: leavingOut.isEmpty ? nil : leavingOut,
        gitPointers: gitPointers, repository: repository, head: head, committed: committed,
        hardLinks: hardLinks ? true : nil))
    guard manifest.count <= 32 << 20 else {
      throw StoreError.message("Recovery metadata exceeds its bound; nothing removed.")
    }
    let sealed = try WorktreeRecovery.seal(manifest, key: key, context: id + "|" + path)
    try WorktreeRecovery.write(sealed, to: directory.appendingPathComponent("manifest.enc"))
    var reference = Reference(
      directory: directory.path, id: id, source: path,
      digest: WorktreeRecovery.digest(sealed), allocated: 0)
    let verify = base.appendingPathComponent("verify-" + id)
    defer { try? FileManager.default.removeItem(at: verify) }
    try restore(reference, to: verify.path, key: key, storedOnly: true)
    try validate(reference, key: key)
    reference.allocated = AutopilotDisk.allocatedSize(directory.path) ?? UInt64(sealed.count)
    complete = true
    return reference
  }
  static func manifest(_ reference: Reference, key: SymmetricKey) throws -> Manifest {
    guard UUID(uuidString: reference.id) != nil,
      reference.directory == WorkspaceSafety.canonical(reference.directory)
    else {
      throw StoreError.message("Unsafe private recovery reference.")
    }
    let bytes = try WorktreeRecovery.read(
      URL(fileURLWithPath: reference.directory).appendingPathComponent("manifest.enc"),
      limit: (32 << 20) + 28)
    guard WorktreeRecovery.digest(bytes) == reference.digest else {
      throw StoreError.message("Private recovery integrity failed.")
    }
    return try JSONDecoder().decode(
      Manifest.self,
      from: WorktreeRecovery.open(bytes, key: key, context: reference.id + "|" + reference.source))
  }
  public static func validate(_ reference: Reference, key: SymmetricKey? = nil) throws {
    let key = try key ?? WorktreeRecoveryKey.load(create: false)
    let saved = try manifest(reference, key: key)
    var metadata = saved.files
    for i in metadata.indices {
      metadata[i].blocks = nil
      metadata[i].digest = nil
    }
    guard
      try WorktreeInspection.files(
        reference.source, seconds: 120, permitLinks: true, excluding: saved.excluded,
        leavingOut: saved.left ?? [], ignoringGitPointers: saved.gitPointers ?? [],
        hardLinks: saved.hardLinks ?? false
      ).0 == metadata
    else {
      throw StoreError.message("Contents changed after recovery; nothing removed.")
    }
    defer { malloc_zone_pressure_relief(nil, 0) }
    for file in saved.files
    where file.kind == "file" && !(saved.committed ?? []).contains(file.path) {
      try autoreleasepool {
        let fd = open(reference.source + "/" + file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.message("Recovery source changed.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
          hash.update(data: bytes)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.digest else {
          throw StoreError.message("File contents changed after recovery; nothing removed.")
        }
      }
    }
  }
  public static func restore(
    _ reference: Reference, to path: String, key: SymmetricKey? = nil,
    emptyWorktree: Bool = false, storedOnly: Bool = false
  ) throws {
    defer { malloc_zone_pressure_relief(nil, 0) }
    let key = try key ?? WorktreeRecoveryKey.load(create: false)
    let saved = try manifest(reference, key: key)
    var kinds: [String: String] = [:]
    for file in saved.files.sorted(by: { $0.path.count < $1.path.count }) {
      let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
      guard
        file.path == ""
          || (!file.path.hasPrefix("/") && !file.path.contains("\0")
            && parts.allSatisfy {
              !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
            }),
        ["directory", "file", "link"].contains(file.kind), kinds[file.path] == nil
      else {
        throw StoreError.message("Unsafe private recovery manifest.")
      }
      for n in 1..<max(1, parts.count) {
        guard kinds[parts.prefix(n).joined(separator: "/")] == "directory" else {
          throw StoreError.message("Recovery path crosses a non-directory.")
        }
      }
      kinds[file.path] = file.kind
    }
    let fm = FileManager.default
    let parent = (path as NSString).deletingLastPathComponent
    guard path.hasPrefix("/"), parent == WorkspaceSafety.canonical(parent),
      path == WorkspaceSafety.canonical(path)
    else { throw StoreError.message("Recovery destination resolves elsewhere.") }
    if emptyWorktree {
      guard path == WorkspaceSafety.canonical(path),
        try fm.contentsOfDirectory(atPath: path) == [".git"]
      else {
        throw StoreError.message("Recovery destination is not an empty new worktree.")
      }
    } else {
      guard mkdir(path, 0o700) == 0 else {
        throw StoreError.message("Recovery destination already exists or is unavailable.")
      }
    }
    if !storedOnly, !(saved.committed ?? []).isEmpty {
      guard let repository = saved.repository, let head = saved.head else {
        throw StoreError.message("Missing committed recovery binding.")
      }
      let paths = saved.files.filter {
        $0.kind == "file" && (saved.committed ?? []).contains($0.path)
      }.map(\.path)
      try WorktreeGit.checkout(repository, revision: head, to: path, paths: paths)
    }
    var decodeScratch = [UInt8](repeating: 0, count: 1_048_577)
    for file in saved.files.sorted(by: { $0.path.count < $1.path.count }) where !file.path.isEmpty {
      let target = URL(fileURLWithPath: path).appendingPathComponent(file.path)
      if (saved.committed ?? []).contains(file.path), file.kind == "file" {
        continue
      }
      switch file.kind {
      case "directory":
        if FileManager.default.fileExists(atPath: target.path) { continue }
        try fm.createDirectory(
          at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      case "link":
        guard let link = file.target else { throw StoreError.message("Missing recovery link.") }
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
      default:
        try autoreleasepool {
          let fd = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
          guard fd >= 0 else { throw StoreError.message("Recovery destination already exists.") }
          let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
          defer { try? output.close() }
          var hash = SHA256()
          for (index, name) in (file.blocks ?? []).enumerated() {
            try autoreleasepool {
              guard name.hasSuffix(".enc"), UUID(uuidString: String(name.dropLast(4))) != nil else {
                throw StoreError.message("Invalid encrypted block.")
              }
              let packed = try WorktreeRecovery.open(
                WorktreeRecovery.read(
                  URL(fileURLWithPath: reference.directory).appendingPathComponent(name),
                  limit: 1_100_000),
                key: key, context: reference.id + "|" + file.path + "|\(index)")
              let count = decodeScratch.withUnsafeMutableBytes { out in
                packed.withUnsafeBytes { input in
                  compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, 1_048_577,
                    input.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil,
                    COMPRESSION_LZFSE)
                }
              }
              guard count > 0, count <= 1_048_576 else {
                throw StoreError.message("Invalid compressed recovery block.")
              }
              decodeScratch.withUnsafeBytes { raw in
                let slice = UnsafeRawBufferPointer(rebasing: raw.prefix(count))
                hash.update(bufferPointer: slice)
              }
              try output.write(contentsOf: decodeScratch.prefix(count))
            }
          }
          try output.synchronize()
          guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.digest else {
            throw StoreError.message("Recovered file integrity failed.")
          }
        }
      }
    }
    for file in saved.files.sorted(by: { $0.path.count > $1.path.count }) {
      if storedOnly && file.kind == "file" && (saved.committed ?? []).contains(file.path) {
        continue
      }
      let target = file.path.isEmpty ? path : path + "/" + file.path
      if file.kind != "link", chmod(target, mode_t(file.mode)) != 0 {
        throw StoreError.message("Cannot restore permissions.")
      }
      for (name, value) in file.attributes ?? [:]
      where !WorktreeInspection.ignoredSystemAttributes.contains(name) {
        let code = value.withUnsafeBytes {
          setxattr(target, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
        }
        if code != 0 {
          if errno == EPERM && name.hasPrefix("com.apple.") { continue }
          throw StoreError.message("Cannot restore file attributes.")
        }
      }
      var times = [
        timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
        timespec(tv_sec: Int(file.modified), tv_nsec: Int(file.nanos)),
      ]
      guard utimensat(AT_FDCWD, target, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw StoreError.message("Cannot restore file dates.")
      }
    }
  }

  /// Removes one owned archive directory under `<root>/private-recovery/<id>` when a pre-removal
  /// check refuses after `capture` completed, or when a receipt's retention window has ended.
  public static func remove(_ reference: Reference, root: URL) {
    guard UUID(uuidString: reference.id) != nil else { return }
    let base = WorkspaceSafety.canonical(root.appendingPathComponent("private-recovery").path)
    guard base.hasPrefix("/"), base != "/" else { return }
    let expected = base + "/" + reference.id
    var info = stat()
    guard lstat(expected, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      WorkspaceSafety.canonical(reference.directory) == expected
    else { return }
    try? FileManager.default.removeItem(atPath: expected)
  }

  /// Reclaims unreferenced `<root>/private-recovery/<uuid>` archives past `graceAge` so trimmed,
  /// restored or aborted backups do not leak gigabytes and millions of `.enc` blocks forever.
  /// Any directory modified within `graceAge` (default 2 hours) stays untouched so an in-flight
  /// `capture` that has not yet appended its receipt can never race pruning.
  @discardableResult
  public static func prune(
    root: URL, keepingIDs: Set<String>, graceAge: TimeInterval = 2 * 3600, now: Date = Date()
  ) -> (removed: Int, bytes: UInt64) {
    let rawBase = root.appendingPathComponent("private-recovery").path
    var baseStat = stat()
    guard lstat(rawBase, &baseStat) == 0, baseStat.st_mode & S_IFMT == S_IFDIR,
      baseStat.st_uid == getuid()
    else { return (0, 0) }
    let base = WorkspaceSafety.canonical(rawBase)
    guard base == rawBase, base.hasPrefix("/"), base != "/",
      let names = try? FileManager.default.contentsOfDirectory(atPath: base)
    else { return (0, 0) }

    var removed = 0
    var reclaimed: UInt64 = 0
    for name in names where UUID(uuidString: name) != nil && !keepingIDs.contains(name) {
      let target = base + "/" + name
      var info = stat()
      guard lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
        WorkspaceSafety.canonical(target) == target
      else { continue }
      let modified = Date(
        timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
          + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
      guard now.timeIntervalSince(modified) >= graceAge else { continue }

      var archiveBytes: UInt64 = 0
      let restorePath = target + "/restore.json"
      if let data = try? Data(contentsOf: URL(fileURLWithPath: restorePath)),
        let restore = try? JSONDecoder().decode(AutopilotRestore.self, from: data)
      {
        archiveBytes = restore.recovery?.allocated ?? 0
        if !restore.repository.isEmpty, restore.ref.hasPrefix("refs/burnzombies/retired/"),
          FileManager.default.fileExists(atPath: restore.repository)
        {
          _ = try? WorktreeGit.run(
            restore.repository, ["update-ref", "-d", restore.ref], seconds: 5)
        }
      }
      if archiveBytes == 0 {
        archiveBytes = AutopilotDisk.countedSize(target, deadline: 2) ?? 0
      }
      if (try? FileManager.default.removeItem(atPath: target)) != nil,
        !FileManager.default.fileExists(atPath: target)
      {
        removed += 1
        reclaimed += archiveBytes
      }
    }
    if removed > 0 { malloc_zone_pressure_relief(nil, 0) }
    return (removed, reclaimed)
  }
}
