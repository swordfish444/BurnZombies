import Compression
import Darwin
import Foundation

public enum StoreError: Error, LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}
public final class Store {
  public let root: URL
  public let leasesURL: URL
  public static var defaultRoot: URL {
    if let path = ProcessInfo.processInfo.environment["BURNZOMBIES_HOME"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BurnZombies", isDirectory: true)
  }
  public init(root: URL = Store.defaultRoot) throws {
    self.root = root
    leasesURL = root.appendingPathComponent("leases", isDirectory: true)
    for url in [root, leasesURL] {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var s = stat()
      guard lstat(url.path, &s) == 0, s.st_uid == getuid(), (s.st_mode & S_IFMT) == S_IFDIR else {
        throw StoreError.message("State directory must be an owned real directory.")
      }
      guard chmod(url.path, 0o700) == 0 else {
        throw StoreError.message("Could not secure local state permissions.")
      }
    }
  }
  public func read(_ url: URL, limit: Int) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.message("State file unavailable.") }
    defer { close(fd) }
    var s = stat()
    guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG,
      s.st_size <= limit, s.st_size >= 0
    else { throw StoreError.message("Unsafe or oversized state file.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    return try handle.read(upToCount: limit) ?? Data()
  }
  public func write(_ data: Data, to url: URL, limit: Int) throws {
    guard data.count <= limit else {
      throw StoreError.message("Local storage budget reached; cleanup is paused.")
    }
    let temp = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
    let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Cannot create private checkpoint.") }
    defer {
      close(fd)
      unlink(temp.path)
    }
    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
    guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else {
      throw StoreError.message("Cannot commit private checkpoint.")
    }
    let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
    if dir >= 0 {
      _ = fsync(dir)
      close(dir)
    }
  }
  public func load() throws -> Catalog {
    let url = root.appendingPathComponent("catalog.bzcat")
    guard FileManager.default.fileExists(atPath: url.path) else { return Catalog() }
    let packed = try read(url, limit: 4 * 1024 * 1024)
    guard !packed.isEmpty else { throw StoreError.message("Empty catalog; cleanup is paused.") }
    let limit = 24 * 1024 * 1024
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: limit)
    defer { output.deallocate() }
    let size = packed.withUnsafeBytes { buffer in
      compression_decode_buffer(
        output, limit, buffer.bindMemory(to: UInt8.self).baseAddress!, packed.count, nil,
        COMPRESSION_LZFSE)
    }
    guard size > 0, size < limit else {
      throw StoreError.message("Corrupt or oversized catalog; cleanup is paused.")
    }
    let unpacked = Data(bytes: output, count: size)
    let c = try JSONDecoder().decode(Catalog.self, from: unpacked)
    guard c.version == 1 else {
      throw StoreError.message("Unsupported catalog version. Preserve state and update the app.")
    }
    return c
  }
  @discardableResult public func save(_ catalog: Catalog) throws -> Int {
    let data = try JSONEncoder().encode(catalog)
    guard data.count <= 24 * 1024 * 1024 else {
      throw StoreError.message("Catalog exceeds its decoded size budget.")
    }
    let compressed = try (data as NSData).compressed(using: .lzfse) as Data
    try write(compressed, to: root.appendingPathComponent("catalog.bzcat"), limit: 4 * 1024 * 1024)
    return compressed.count
  }
  public func saveLease(_ lease: Lease) throws {
    guard lease.members.count <= 512 else {
      throw StoreError.message("Session exceeds 512 tracked helpers; registration stopped.")
    }
    try write(
      JSONEncoder().encode(lease),
      to: leasesURL.appendingPathComponent(lease.id.uuidString + ".json"), limit: 256 * 1024)
  }
  public func leases() throws -> [Lease] {
    let files = try FileManager.default.contentsOfDirectory(
      at: leasesURL, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }
    guard files.count <= 256 else {
      throw StoreError.message("Session catalog exceeds 256 leases. Cleanup paused.")
    }
    return try files.map { try JSONDecoder().decode(Lease.self, from: read($0, limit: 256 * 1024)) }
  }
  public func pruneLeases(now: Date, native: Native) throws {
    for lease in try leases()
    where now.timeIntervalSince(lease.created) > 30 * 86400
      && native.ownerState(lease.owner) == .gone
    {
      guard lease.members.allSatisfy({ native.ownerState($0.identity) == .gone }) else { continue }
      try FileManager.default.removeItem(
        at: leasesURL.appendingPathComponent(lease.id.uuidString + ".json"))
    }
    // Recover only our bounded atomic-write debris. Never inspect other directories.
    for dir in [root, leasesURL] {
      for file in try FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
      ).prefix(1024) where file.lastPathComponent.hasPrefix(".write-") {
        if let time = try file.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate, now.timeIntervalSince(time) > 86400
        {
          try FileManager.default.removeItem(at: file)
        }
      }
    }
  }
}
