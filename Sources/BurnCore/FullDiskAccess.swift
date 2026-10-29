import CryptoKit
import Darwin
import Foundation

public enum FullDiskAccessState: String, Codable, Sendable { case required, unknown, granted }

/// An operational access check, not a query of Apple's private TCC settings.
public struct FullDiskAccessStatus: Codable, Sendable, Equatable {
  public var state: FullDiskAccessState
  public var detail: String
  public var canScan: Bool { state == .granted }
  public init(state: FullDiskAccessState = .required, detail: String = FullDiskAccess.instructions) {
    self.state = state; self.detail = detail
  }
}

public enum FullDiskAccess {
  public static let instructions = "Enable BurnZombies in System Settings → Privacy & Security → Full Disk Access, then check access in BurnZombies Settings. Scans and AI reviews wait until setup is complete."
  private struct Receipt: Codable {
    var executableDigest: String
    var verified: Bool
  }
  private static let lock = NSLock()
  // A different ad-hoc build is a different privacy identity. Helpers bind to the
  // same app executable, but verify their own inherited operational capability.
  private static let digest: String? = {
    var executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let macOS = executable.deletingLastPathComponent()
    if macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" {
      executable = macOS.appendingPathComponent("BurnZombiesApp")
    }
    guard let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }()

  public static func status(root: URL = Store.defaultRoot) -> FullDiskAccessStatus {
    lock.withLock {
      status(root: root, executableDigest: digest, probe: probe)
    }
  }
  // Injectable functions keep tests off protected user paths; production has no
  // environment variable or persisted Boolean that alone grants scan access.
  public static func status(root: URL, executableDigest: String?, probe: () -> FullDiskAccessStatus) -> FullDiskAccessStatus {
    guard let executableDigest, let store = try? Store(root: root),
      let data = try? store.read(root.appendingPathComponent("full-disk-access.json"), limit: 4096),
      let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
      receipt.executableDigest == executableDigest, receipt.verified else { return .init() }
    let result = probe()
    if !result.canScan {
      // No repeated protected-path probes after denial. The next attempt requires
      // the user's Check Access button, including after macOS revokes access.
      try? store.write(JSONEncoder().encode(Receipt(executableDigest: executableDigest, verified: false)),
        to: root.appendingPathComponent("full-disk-access.json"), limit: 4096)
    }
    return result
  }
  public static func confirmSetup(root: URL = Store.defaultRoot) throws -> FullDiskAccessStatus {
    try lock.withLock { try confirmSetup(root: root, executableDigest: digest, probe: probe) }
  }
  public static func confirmSetup(root: URL, executableDigest: String?, probe: () -> FullDiskAccessStatus) throws -> FullDiskAccessStatus {
    guard let executableDigest else { return .init(state: .unknown, detail: "This app build could not be verified. Reinstall BurnZombies before checking access.") }
    let store = try Store(root: root)
    let result = probe()
    try store.write(JSONEncoder().encode(Receipt(executableDigest: executableDigest, verified: result.canScan)),
      to: root.appendingPathComponent("full-disk-access.json"), limit: 4096)
    return result
  }
  public static func requireAccess(root: URL = Store.defaultRoot) throws {
    let access = status(root: root)
    guard access.canScan else { throw StoreError.message(access.detail) }
  }
  /// FDA-only directories, not per-folder Desktop/Documents grants. No contents
  /// are enumerated or read. Apple's public preflight avoids consent dialogs.
  /// Missing paths are inconclusive, never proof of access.
  public static func probe() -> FullDiskAccessStatus {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return evaluate(paths: [home.appendingPathComponent("Library/Mail").path,
      home.appendingPathComponent("Library/Messages").path]) { path in
      var metadata = stat()
      guard lstat(path, &metadata) == 0 else {
        return errno == ENOENT ? .missing : .unavailable
      }
      guard metadata.st_mode & S_IFMT == S_IFDIR else { return .unavailable }
      guard FileManager.default.isReadableFile(atPath: path), access(path, R_OK | X_OK) == 0 else { return .denied }
      guard let directory = opendir(path) else { return .denied }
      closedir(directory)
      return .readable
    }
  }
  public enum ProbeResult { case missing, unavailable, denied, readable }
  public static func evaluate(paths: [String], probe: (String) -> ProbeResult) -> FullDiskAccessStatus {
    var readable = false, unavailable = false
    for path in paths {
      switch probe(path) {
      case .denied: return .init(state: .required, detail: "Protected-folder access is still blocked. Enable Full Disk Access for this BurnZombies app, relaunch if macOS asks, then check again.")
      case .readable: readable = true
      case .unavailable: unavailable = true
      case .missing: break
      }
    }
    if readable && !unavailable { return .init(state: .granted, detail: "Protected-folder access verified for this app build. Each cleanup still requires its own safety checks.") }
    return .init(state: .unknown, detail: "Access could not be verified on this Mac. Scans remain paused; confirm Full Disk Access in System Settings and check again.")
  }
}
