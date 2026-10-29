import CryptoKit
import Darwin
import Foundation
import Security

public enum WorktreeRecoveryKey {
  public static func load(create: Bool = true, namespace: String = "BurnZombies.WorktreeRecovery", allowInteraction: Bool = false) throws -> SymmetricKey {
    guard namespace.hasPrefix("BurnZombies.WorktreeRecovery"), namespace.count <= 120 else { throw StoreError.message("Invalid recovery-key namespace.") }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: namespace, kSecAttrAccount as String: "archive-key-v1",
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationUI as String: allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
    guard status == errSecItemNotFound && create else { throw StoreError.message("Recovery key unavailable in Keychain. Preserve the checkout; unlock Keychain and retry explicitly.") }
    let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    var item = query
    item.removeValue(forKey: kSecReturnData as String); item.removeValue(forKey: kSecMatchLimit as String)
    item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StoreError.message("Cannot store the worktree recovery key; nothing removed.") }
    return SymmetricKey(data: data)
  }
}

struct WorktreeManifest: Codable {
  var version = 1
  var operation: String
  var head: String
  var status: String
  var dirty: Bool
  var files: [WorktreeFile]
  var objects: [String]
  var index: [String]
  var indexDigest: String
}

enum WorktreeRecovery {
  static let fm = FileManager.default
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func write(_ data: Data, to url: URL) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Recovery output already exists or is unsafe.") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
    try file.write(contentsOf: data); try file.synchronize()
  }
  static func read(_ url: URL, limit: Int) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.message("Recovery file is unavailable.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
    var s = stat()
    guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG, s.st_size <= limit else { throw StoreError.message("Recovery file identity/size is unsafe.") }
    return try handle.read(upToCount: limit + 1) ?? Data()
  }
  static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
    guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined else { throw StoreError.message("Archive encryption failed.") }; return combined
  }
  static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
    try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
  }
  static func encrypt(_ url: URL, to directory: URL, key: SymmetricKey, context: String) throws -> ([String], String) {
    let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.message("Cannot preserve an exact source file.") }
    let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? source.close() }
    var before = stat(), after = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size <= 10_737_418_240 else { throw StoreError.message("Unsupported recovery input.") }
    var blocks: [String] = [], hash = SHA256(), bytes: Int64 = 0
    while let data = try source.read(upToCount: 1_048_576), !data.isEmpty {
      guard !Task.isCancelled, blocks.count < 10_240 else { throw StoreError.message("Recovery capture interrupted or too large.") }
      hash.update(data: data); bytes += Int64(data.count)
      let name = UUID().uuidString + ".enc"
      try write(seal(data, key: key, context: context + "|\(blocks.count)"), to: directory.appendingPathComponent(name)); blocks.append(name)
    }
    guard fstat(fd, &after) == 0, bytes == before.st_size, before.st_ino == after.st_ino,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      before.st_size == after.st_size else { throw StoreError.message("A file changed while it was being preserved.") }
    return (blocks, hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
  static func decrypt(_ blocks: [String], from directory: URL, to url: URL, key: SymmetricKey, context: String) throws -> String {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Restoration destination exists or is unsafe.") }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? output.close() }
    var hash = SHA256()
    for (i, name) in blocks.enumerated() {
      try Task.checkCancellation()
      guard name.hasSuffix(".enc"), UUID(uuidString: String(name.dropLast(4))) != nil else { throw StoreError.message("Invalid archive block name.") }
      let bytes = try open(read(directory.appendingPathComponent(name), limit: 1_048_604), key: key, context: context + "|\(i)")
      hash.update(data: bytes); try output.write(contentsOf: bytes)
    }
    try output.synchronize(); return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func capture(_ record: WorktreeRecord, operation: WorktreeOperation, key: SymmetricKey) throws -> (String, UInt64) {
    guard let identity = record.identity, let head = record.head else { throw StoreError.message("Recovery requires exact Git identity.") }
    let directory = URL(fileURLWithPath: operation.recoveryPath)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    _ = try WorkspaceSafety.statAt(directory.path)
    let original = try WorktreeInspection.files(record.path, seconds: 60, permitLinks: true).0
    guard original.reduce(Int64(0), { $0 + ($1.kind == "file" ? $1.size : 0) }) <= 10_737_418_240 else { throw StoreError.message("Recovery exceeds the 10 GiB capture limit; preserve it with the owner.") }
    let volume = try fm.attributesOfFileSystem(forPath: directory.path)
    let required = original.reduce(UInt64(0)) { $0 + UInt64(max(0, $1.size)) }
    guard let free = volume[.systemFreeSize] as? NSNumber, free.uint64Value > required + 67_108_864 else { throw StoreError.message("Not enough recovery storage; nothing removed.") }
    let ref = "refs/burnzombies/worktrees/" + operation.id.lowercased()
    var tip = head
    if operation.kind == "dirty" || operation.kind == "rescue" {
      let tree = try WorktreeGit.line(record.path, ["write-tree"])
      tip = try WorktreeGit.line(record.path, ["-c", "user.name=BurnZombies Recovery", "-c", "user.email=recovery@example.invalid", "commit-tree", tree, "-p", head, "-m", "Preserved staged work"])
    }
    _ = try WorktreeGit.run(record.repository, ["update-ref", ref, tip, String(repeating: "0", count: head.count)])
    let bundle = directory.appendingPathComponent("objects.bundle")
    defer { try? fm.removeItem(at: bundle); try? fm.removeItem(atPath: bundle.path + ".lock") }
    _ = try WorktreeGit.run(record.path, ["bundle", "create", bundle.path, ref], seconds: 180)
    let objectBlocks = try encrypt(bundle, to: directory, key: key, context: operation.id + "|objects").0
    try fm.removeItem(at: bundle)
    let (indexBlocks, indexDigest) = try encrypt(URL(fileURLWithPath: identity.administration + "/index"), to: directory, key: key, context: operation.id + "|index")
    var files = original
    for i in files.indices where files[i].kind == "file" {
      let (blocks, digest) = try encrypt(URL(fileURLWithPath: record.path).appendingPathComponent(files[i].path), to: directory, key: key, context: operation.id + "|" + files[i].path)
      files[i].blocks = blocks; files[i].digest = digest
    }
    guard try WorktreeInspection.files(record.path, seconds: 60, permitLinks: true).0 == original,
      try WorktreeGit.line(record.path, ["rev-parse", "HEAD"]) == head,
      WorkEvidence.hash(try WorktreeGit.run(record.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"]).base64EncodedString()) == record.status else { throw StoreError.message("Checkout changed during capture. Keep the original.") }
    let manifest = WorktreeManifest(operation: operation.id, head: head, status: record.status,
      dirty: operation.kind != "clean", files: files, objects: objectBlocks, index: indexBlocks, indexDigest: indexDigest)
    let encrypted = try seal(WorktreeEncoding.data(manifest), key: key, context: operation.id + "|manifest")
    try write(encrypted, to: directory.appendingPathComponent("manifest.enc"))
    let check = directory.appendingPathComponent("verify-" + UUID().uuidString)
    defer { try? fm.removeItem(at: check) }
    try restore(operation, destination: check.path, key: key, digest: digest(encrypted))
    try fm.removeItem(at: check)
    let size = try WorktreeInspection.files(directory.path, seconds: 60).1
    return (digest(encrypted), size)
  }
  static func restore(_ operation: WorktreeOperation, destination: String, key: SymmetricKey, digest expectedDigest: String) throws {
    guard destination.hasPrefix("/"), destination == WorkspaceSafety.canonical(destination), !fm.fileExists(atPath: destination),
      !WorkspaceSafety.contains(operation.originalPath, destination) else { throw StoreError.message("Choose a new canonical restore destination outside the original checkout.") }
    let parent = (destination as NSString).deletingLastPathComponent
    _ = try WorkspaceSafety.statAt(parent)
    let directory = URL(fileURLWithPath: operation.recoveryPath)
    let encrypted = try read(directory.appendingPathComponent("manifest.enc"), limit: 33_554_432)
    guard digest(encrypted) == expectedDigest else { throw StoreError.message("Recovery manifest integrity failed.") }
    let manifest = try JSONDecoder().decode(WorktreeManifest.self, from: open(encrypted, key: key, context: operation.id + "|manifest"))
    guard manifest.version == 1, manifest.operation == operation.id, manifest.head == operation.head, manifest.files.count <= 100_000 else { throw StoreError.message("Unsupported or mismatched recovery manifest.") }
    var paths = Set<String>()
    let kinds = Dictionary(manifest.files.map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a })
    for file in manifest.files {
      if file.path.isEmpty {
        guard file.kind == "directory", paths.insert("").inserted else { throw StoreError.message("Invalid recovery root metadata.") }; continue
      }
      let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
      guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }),
        !file.path.hasPrefix("/"), !file.path.contains("\0"), paths.insert(file.path).inserted,
        ["file", "directory", "link"].contains(file.kind) else { throw StoreError.message("Unsafe path or type in recovery manifest.") }
      for i in 1..<parts.count {
        let ancestor = parts.prefix(i).joined(separator: "/")
        guard kinds[ancestor] == "directory" else { throw StoreError.message("Recovery path traverses a non-directory.") }
      }
    }
    try fm.createDirectory(atPath: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    // A failed restoration remains at its explicitly selected location for diagnosis.
    _ = try WorktreeGit.run(destination, ["init", "--initial-branch=restored"] + (manifest.head.count == 64 ? ["--object-format=sha256"] : []))
    let bundle = URL(fileURLWithPath: destination).appendingPathComponent(".git/bz-objects.bundle")
    _ = try decrypt(manifest.objects, from: directory, to: bundle, key: key, context: operation.id + "|objects")
    _ = try WorktreeGit.run(destination, ["bundle", "unbundle", bundle.path], seconds: 180)
    try fm.removeItem(at: bundle)
    _ = try WorktreeGit.run(destination, ["update-ref", "HEAD", manifest.head])
    _ = try WorktreeGit.run(destination, ["fsck", "--strict", "--no-reflogs"], seconds: 180)
    let indexDigest = try decrypt(manifest.index, from: directory, to: URL(fileURLWithPath: destination).appendingPathComponent(".git/index"), key: key, context: operation.id + "|index")
    guard indexDigest == manifest.indexDigest else { throw StoreError.message("Restored index integrity failed.") }
    let directories = manifest.files.filter { $0.kind == "directory" }.sorted { $0.path.count < $1.path.count }
    for file in directories where !file.path.isEmpty { try fm.createDirectory(atPath: destination + "/" + file.path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    for file in manifest.files where file.kind != "directory" {
      try Task.checkCancellation()
      let target = URL(fileURLWithPath: destination).appendingPathComponent(file.path)
      if file.kind == "link" {
        guard let link = file.target else { throw StoreError.message("Missing link target.") }; try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
      } else {
        let actual = try decrypt(file.blocks ?? [], from: directory, to: target, key: key, context: operation.id + "|" + file.path)
        guard actual == file.digest else { throw StoreError.message("Restored content integrity failed.") }
        guard chmod(target.path, mode_t(file.mode)) == 0 else { throw StoreError.message("Cannot restore file permissions.") }
      }
    }
    for file in directories.reversed() { guard chmod(destination + "/" + file.path, mode_t(file.mode)) == 0 else { throw StoreError.message("Cannot restore directory permissions.") } }
    for file in manifest.files.sorted(by: { $0.path.count > $1.path.count }) {
      let path = destination + "/" + file.path
      for (name, value) in file.attributes ?? [:] {
        let code = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        guard code == 0 else { throw StoreError.message("Cannot restore extended file attributes.") }
      }
      var times = [timespec(tv_sec: Int(file.modified), tv_nsec: Int(file.nanos)), timespec(tv_sec: Int(file.modified), tv_nsec: Int(file.nanos))]
      guard utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw StoreError.message("Cannot restore file timestamps.") }
    }
    let status = try WorktreeGit.run(destination, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"])
    guard WorkEvidence.hash(status.base64EncodedString()) == manifest.status else { throw StoreError.message("Restored staged/unstaged state differs. Archive retained; inspect restored copy.") }
  }
  static func verifySource(_ r: WorktreeRecord, operation: WorktreeOperation, key: SymmetricKey) throws {
    let data = try read(URL(fileURLWithPath: operation.recoveryPath).appendingPathComponent("manifest.enc"), limit: 33_554_432)
    guard digest(data) == operation.archiveDigest, let identity = r.identity else { throw StoreError.message("Preservation manifest changed.") }
    let manifest = try JSONDecoder().decode(WorktreeManifest.self, from: open(data, key: key, context: operation.id + "|manifest"))
    let expectedFiles = manifest.files.map { file in
      var metadata = file; metadata.digest = nil; metadata.blocks = nil; return metadata
    }
    guard try WorktreeInspection.files(r.path, seconds: 60, permitLinks: true).0 == expectedFiles,
      try WorktreeGit.line(r.path, ["rev-parse", "HEAD"]) == manifest.head,
      WorkEvidence.hash(try WorktreeGit.run(r.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"]).base64EncodedString()) == manifest.status else {
      throw StoreError.message("Checkout paths, metadata or Git state changed after preservation; retain every original file.")
    }
    func hashFile(_ path: String, expected: WorktreeFile? = nil) throws -> String {
      let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw StoreError.message("Source file identity changed.") }
      let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? source.close() }
      var metadata = stat()
      guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_nlink == 1, metadata.st_flags == 0, metadata.st_size <= 10_737_418_240 else { throw StoreError.message("Source file type, ownership or bounds changed after preservation.") }
      if let expected {
        guard metadata.st_ino == expected.inode, metadata.st_size == expected.size,
          Int64(metadata.st_mtimespec.tv_sec) == expected.modified, Int64(metadata.st_mtimespec.tv_nsec) == expected.nanos else { throw StoreError.message("Source file identity or metadata changed after preservation.") }
      }
      var hash = SHA256()
      while let data = try source.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    guard try hashFile(identity.administration + "/index") == manifest.indexDigest else { throw StoreError.message("Index changed after preservation.") }
    for file in manifest.files where file.kind == "file" {
      guard try hashFile(r.path + "/" + file.path, expected: file) == file.digest else { throw StoreError.message("File content changed after preservation.") }
    }
  }
}
