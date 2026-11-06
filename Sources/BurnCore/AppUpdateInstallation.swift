import CBurn
import CryptoKit
import Darwin
import Foundation

public struct AppUpdateBundle: Codable, Sendable, Equatable {
  public var version: String
  public var build: String
  public var inode: UInt64
  public var device: Int32
  static func properties(_ app: URL) throws -> [String: Any] {
    var contents = stat()
    guard lstat(app.appendingPathComponent("Contents").path, &contents) == 0,
      contents.st_mode & S_IFMT == S_IFDIR, contents.st_uid == getuid()
    else {
      throw StoreError.message("The app has an unsafe Contents folder.")
    }
    let fd = open(
      app.appendingPathComponent("Contents/Info.plist").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.message("The app's version information is unavailable.") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_size > 0, info.st_size <= 65_536,
      let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65_536),
      let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { throw StoreError.message("The app's version information is invalid.") }
    return object
  }
  public static func read(_ app: URL) throws -> Self {
    var info = stat()
    guard app.pathExtension == "app", app.path == WorkspaceSafety.canonical(app.path),
      lstat(app.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      case let object = try properties(app),
      object["CFBundleIdentifier"] as? String == "io.burnzombies.app",
      object["CFBundleExecutable"] as? String == "BurnZombiesApp",
      let version = object["CFBundleShortVersionString"] as? String,
      let build = object["CFBundleVersion"] as? String,
      !build.isEmpty, build.count <= 20, build.allSatisfy({ $0.isASCII && $0.isNumber })
    else { throw StoreError.message("The update needs an owned, ordinary BurnZombies app bundle.") }
    _ = try AppVersion(version)
    return .init(version: version, build: build, inode: info.st_ino, device: info.st_dev)
  }
}

public enum AppUpdateVerification {
  public static let certificate = "F6EE40DDEBB01F056DE8FC7910091F4FAC3D7B49"
  public static func verifySignature(_ url: URL, deep: Bool = false) throws {
    try tool(
      "/usr/bin/codesign",
      ["--verify", "--strict"] + (deep ? ["--deep"] : [])
        + ["-R", "=certificate leaf = H\"\(certificate)\"", url.path])
  }
  public static func verify(_ app: URL, version: String) throws -> AppUpdateBundle {
    let info = try AppUpdateBundle.read(app)
    guard info.version == version else {
      throw StoreError.message("The downloaded app has a different version from the release.")
    }
    let plist = try AppUpdateBundle.properties(app)
    guard let minimum = plist["LSMinimumSystemVersion"] as? String,
      minimum.range(of: #"^\d+\.\d+(?:\.\d+)?$"#, options: .regularExpression) != nil
    else { throw StoreError.message("The update does not declare a supported macOS version.") }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    guard
      "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)".compare(minimum, options: .numeric)
        != .orderedAscending
    else {
      throw StoreError.message("This update needs macOS \(minimum) or later.")
    }
    try verifySignature(app, deep: true)
    for name in ["BurnZombiesApp", "burnzombies", "burnzombies-mcp"] {
      let executable = app.appendingPathComponent("Contents/MacOS/" + name)
      var s = stat()
      guard lstat(executable.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
        s.st_uid == getuid(), access(executable.path, X_OK) == 0
      else {
        throw StoreError.message("The update is missing a regular app executable.")
      }
      try verifySignature(executable)
      #if arch(arm64)
        let arch = "arm64"
      #else
        let arch = "x86_64"
      #endif
      try tool("/usr/bin/lipo", ["-verify_arch", arch, executable.path])
    }
    return info
  }
  public static func hash(_ file: URL) throws -> String {
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StoreError.message("The update download is unavailable.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var s = stat()
    guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_size > 0,
      s.st_size <= 268_435_456, s.st_uid == getuid()
    else { throw StoreError.message("Unsafe update download.") }
    var hash = SHA256()
    var count: Int64 = 0
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      count += Int64(data.count)
      guard count <= 268_435_456 else {
        throw StoreError.message("The update download is too large.")
      }
      hash.update(data: data)
    }
    guard count == s.st_size else {
      throw StoreError.message("The update changed while it was being verified.")
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func validateArchive(_ archive: URL) throws {
    let names = try tool("/usr/bin/tar", ["-tzf", archive.path], maximum: 4_194_304)
    let details = try tool(
      "/usr/bin/tar", ["--numeric-owner", "-tvzf", archive.path], maximum: 4_194_304)
    guard let paths = String(data: names, encoding: .utf8),
      let listing = String(data: details, encoding: .utf8)
    else {
      throw StoreError.message("The update archive paths are unreadable.")
    }
    let entries = paths.split(separator: "\n", omittingEmptySubsequences: false).dropLast(
      paths.hasSuffix("\n") ? 1 : 0)
    let rows = listing.split(separator: "\n")
    var total: UInt64 = 0
    guard !entries.isEmpty, entries.count <= 20_000, entries.count == rows.count else {
      throw StoreError.message("The update archive contains too many or ambiguous entries.")
    }
    for (path, row) in zip(entries, rows) {
      let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropLast(
        path.hasSuffix("/") ? 1 : 0)
      let fields = row.split(whereSeparator: \.isWhitespace)
      guard path.utf8.count <= 4096, parts.first == "BurnZombies.app",
        parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
        path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
        fields.count >= 9, fields[0].count == 10, ["d", "-"].contains(String(fields[0].prefix(1))),
        fields[1...3].allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
        let bytes = UInt64(fields[4]), bytes <= 1_073_741_824 - total
      else {
        throw StoreError.message(
          "The update archive has unsafe paths, links, contents or size. Your app is unchanged.")
      }
      total += bytes
    }
    guard total > 0 else {
      throw StoreError.message(
        "The update archive has unsafe paths, links, contents or size. Your app is unchanged.")
    }
  }
  @discardableResult public static func tool(
    _ executable: String, _ arguments: [String], seconds: Int = 30, maximum: Int = 65_536,
    environment: [String: String] = [:]
  ) throws -> Data {
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bz-update-tool-" + UUID().uuidString)
    let fd = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Cannot capture the update verification.") }
    defer {
      close(fd)
      unlink(output.path)
    }
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let values = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C"].merging(
      environment
    ) { _, new in new }
    var env = values.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer {
      argv.forEach { free($0) }
      env.forEach { free($0) }
    }
    let status = bz_capture_update_tool(&argv, &env, fd, Int32(seconds * 1000), UInt64(maximum))
    guard status == 0 else {
      throw StoreError.message(
        "\(URL(fileURLWithPath: executable).lastPathComponent) could not verify or prepare the update (exit \(status)). Your previous app is preserved."
      )
    }
    _ = lseek(fd, 0, SEEK_SET)
    return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum)
      ?? Data()
  }
}

public struct AppUpdatePlan: Codable, Sendable {
  public var directory: String
  public var destination: String
  public var previous: AppUpdateBundle
  public var replacement: AppUpdateBundle
  public var parent: ProcessIdentity
  /// Restore Settings only if the person was still using BZ at the handoff.
  public var reopenSettings: Bool?
  public var app: URL { URL(fileURLWithPath: destination) }
  public var workspace: URL { URL(fileURLWithPath: directory) }
  public var payload: URL { workspace.appendingPathComponent("unpacked/BurnZombies.app") }
  public var backup: URL { workspace.appendingPathComponent("previous.app") }
  public var file: URL { workspace.appendingPathComponent("update.json") }
  public var helper: URL { workspace.appendingPathComponent("update-helper") }

  public init(
    directory: String, destination: String, previous: AppUpdateBundle,
    replacement: AppUpdateBundle, parent: ProcessIdentity
  ) {
    self.directory = directory
    self.destination = destination
    self.previous = previous
    self.replacement = replacement
    self.parent = parent
    reopenSettings = nil
  }
  public func validatePaths() throws {
    let parentDirectory = app.deletingLastPathComponent()
    var s = stat()
    guard directory == WorkspaceSafety.canonical(directory),
      destination == WorkspaceSafety.canonical(destination),
      workspace.deletingLastPathComponent() == parentDirectory,
      workspace.lastPathComponent.hasPrefix(".BurnZombies-update-"),
      UUID(uuidString: String(workspace.lastPathComponent.dropFirst(".BurnZombies-update-".count)))
        != nil,
      lstat(directory, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
      s.st_mode & 0o077 == 0,
      try AppVersion(replacement.version) > AppVersion(previous.version)
    else {
      throw StoreError.message(
        "The private update plan is invalid. Your existing app is preserved.")
    }
  }
  public func save() throws {
    try validatePaths()
    try Store(root: workspace).write(JSONEncoder().encode(self), to: file, limit: 65_536)
  }
  public static func load(_ file: URL) throws -> Self {
    guard file.lastPathComponent == "update.json" else {
      throw StoreError.message("Unexpected update plan.")
    }
    let directory = file.deletingLastPathComponent()
    var s = stat()
    guard directory.path == WorkspaceSafety.canonical(directory.path),
      directory.lastPathComponent.hasPrefix(".BurnZombies-update-"),
      UUID(uuidString: String(directory.lastPathComponent.dropFirst(".BurnZombies-update-".count)))
        != nil,
      lstat(directory.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
      s.st_mode & 0o077 == 0
    else { throw StoreError.message("The update plan is outside its private staging folder.") }
    let value = try JSONDecoder().decode(
      Self.self, from: Store(root: directory).read(file, limit: 65_536))
    guard value.workspace == directory else { throw StoreError.message("The update plan moved.") }
    try value.validatePaths()
    return value
  }
  public func verifyBeforeQuit() throws {
    try validatePaths()
    try AppUpdateVerification.verifySignature(app, deep: true)
    guard try AppUpdateBundle.read(app) == previous,
      try AppUpdateVerification.verify(payload, version: replacement.version) == replacement
    else {
      throw StoreError.message("The app changed while the update was prepared. Please check again.")
    }
  }
}

public enum AppUpdateProgress: Sendable {
  case downloading(Double?)
  case verifying
}

public enum AppUpdatePreparation {
  public static func prepare(
    _ release: AppUpdateRelease, destination: URL,
    progress: @escaping @Sendable (AppUpdateProgress) -> Void = { _ in }
  ) async throws -> AppUpdatePlan {
    let app = URL(fileURLWithPath: WorkspaceSafety.canonical(destination.path))
    let old = try AppUpdateBundle.read(app)
    guard release.version > (try AppVersion(old.version)) else {
      throw StoreError.message("This app is already up to date.")
    }
    let parent = app.deletingLastPathComponent()
    guard access(parent.path, W_OK | X_OK) == 0 else {
      throw StoreError.message(
        "This app folder isn't writable. Install BurnZombies in your Applications folder to update it here."
      )
    }
    // The old app and rollback copy stay on this volume so replacement uses directory renames.
    let workspace = parent.appendingPathComponent(".BurnZombies-update-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var ready = false
    defer { if !ready { try? FileManager.default.removeItem(at: workspace) } }
    let archive = workspace.appendingPathComponent("download.tar.gz")
    let sums = workspace.appendingPathComponent("SHA256SUMS")
    progress(.downloading(nil))
    try await AppUpdateDownload(maximum: 268_435_456) { progress(.downloading($0)) }.download(
      release.archive, to: archive)
    try await AppUpdateDownload(maximum: 65_536).download(release.checksums, to: sums)
    try Task.checkCancellation()
    progress(.verifying)
    let replacement = try await Task.detached {
      let expected = try AppUpdateRelease.checksum(Data(contentsOf: sums))
      let actual = try AppUpdateVerification.hash(archive)
      guard actual == expected, release.digest.map({ $0 == "sha256:" + actual }) ?? true else {
        throw StoreError.message("The update checksum doesn't match. Your app is unchanged.")
      }
      try AppUpdateVerification.validateArchive(archive)
      let unpacked = workspace.appendingPathComponent("unpacked")
      try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
      try AppUpdateVerification.tool(
        "/usr/bin/tar",
        ["-xzf", archive.path, "-C", unpacked.path, "--no-same-owner", "--no-same-permissions"],
        seconds: 60)
      return try AppUpdateVerification.verify(
        unpacked.appendingPathComponent("BurnZombies.app"), version: release.version.description)
    }.value
    try Task.checkCancellation()
    guard case .found(let owner) = Native().probe(getpid()) else {
      throw StoreError.message("The running app identity is unavailable.")
    }
    let plan = AppUpdatePlan(
      directory: workspace.path, destination: app.path, previous: old, replacement: replacement,
      parent: owner.identity)
    // Copy the already-installed helper, never a downloaded script. Authenticate it before use.
    try FileManager.default.copyItem(
      at: app.appendingPathComponent("Contents/MacOS/burnzombies"), to: plan.helper)
    try await Task.detached { try AppUpdateVerification.verifySignature(plan.helper) }.value
    try plan.save()
    ready = true
    return plan
  }
}

public struct AppUpdateResult: Codable, Sendable {
  public var state: String
  public var version: String
  public var detail: String
  public var date: Date
  public var worker: ProcessIdentity?
  public init(state: String, version: String, detail: String) {
    self.state = state
    self.version = version
    self.detail = detail
    date = Date()
    if case .found(let process) = Native().probe(getpid()) { worker = process.identity }
  }
  public func save(root: URL = Store.defaultRoot) throws {
    try Store(root: root).write(
      JSONEncoder().encode(self), to: root.appendingPathComponent("app-update-result.json"),
      limit: 16_384)
  }
  public static func load(root: URL = Store.defaultRoot) -> Self? {
    guard
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("app-update-result.json").path),
      let data = try? Store(root: root).read(
        root.appendingPathComponent("app-update-result.json"), limit: 16_384)
    else { return nil }
    guard var result = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
    if result.state == "installing", let worker = result.worker,
      Native().ownerState(worker) == .gone
    {
      result.state = "failed"
      result.detail =
        "An update was interrupted. The installed app is still in place. Check for updates to try again."
    }
    return result
  }
}

public enum AppUpdateInstallation {
  public typealias Verification = @Sendable (URL, String) throws -> AppUpdateBundle
  public typealias Launch = @Sendable (URL) async throws -> Void

  /// The CLI helper calls this only after the old app has exited. Proofs use inert fixture apps.
  public static func install(
    _ plan: AppUpdatePlan, root: URL = Store.defaultRoot,
    verify: Verification = AppUpdateVerification.verify, launch: Launch, stop: Launch
  ) async throws {
    try plan.validatePaths()
    guard try AppUpdateBundle.read(plan.app) == plan.previous,
      try verify(plan.app, plan.previous.version) == plan.previous,
      try verify(plan.payload, plan.replacement.version) == plan.replacement
    else {
      throw StoreError.message(
        "The app changed before installation. Your previous app is preserved.")
    }
    let fm = FileManager.default
    guard !fm.fileExists(atPath: plan.backup.path) else {
      throw StoreError.message("An update backup already exists; preserve it.")
    }
    try AppUpdateResult(
      state: "installing", version: plan.replacement.version, detail: "Finishing the update…"
    ).save(root: root)
    var swapped = false
    do {
      try fm.moveItem(at: plan.payload, to: plan.backup)
      // Both directories are on the same volume. There is never a missing install path,
      // including if the helper or Mac stops between the replacement and health check.
      guard
        renameatx_np(AT_FDCWD, plan.backup.path, AT_FDCWD, plan.app.path, UInt32(RENAME_SWAP)) == 0
      else {
        throw StoreError.message(
          "This app folder couldn't complete an atomic update (\(String(cString: strerror(errno))))."
        )
      }
      swapped = true
      guard try verify(plan.app, plan.replacement.version) == plan.replacement else {
        throw StoreError.message("The installed update changed before launch.")
      }
      try await launch(plan.app)
      guard try AppUpdateBundle.read(plan.app) == plan.replacement else {
        throw StoreError.message("The app changed during restart.")
      }
      try AppUpdateResult(
        state: "updated", version: plan.replacement.version,
        detail: "Updated to \(plan.replacement.version)."
      ).save(root: root)
      try? fm.removeItem(at: plan.workspace)
    } catch {
      let cause = error
      do {
        if swapped {
          guard try AppUpdateBundle.read(plan.app) == plan.replacement else {
            throw StoreError.message(
              "The app folder changed. The previous app is preserved at \(plan.backup.path).")
          }
          try await stop(plan.app)
          guard try AppUpdateBundle.read(plan.app) == plan.replacement,
            try AppUpdateBundle.read(plan.backup) == plan.previous
          else {
            throw StoreError.message(
              "The app folder changed while it was closing. The previous app is preserved at \(plan.backup.path)."
            )
          }
          guard
            renameatx_np(AT_FDCWD, plan.backup.path, AT_FDCWD, plan.app.path, UInt32(RENAME_SWAP))
              == 0
          else {
            throw StoreError.message(
              "The previous app is preserved at \(plan.backup.path); its automatic restore couldn't finish."
            )
          }
        }
        guard try AppUpdateBundle.read(plan.app) == plan.previous else {
          throw StoreError.message(
            "The app path changed; update files were preserved at \(plan.workspace.path).")
        }
        try AppUpdateResult(
          state: "failed", version: plan.replacement.version,
          detail:
            "The update couldn't finish. Your previous version is in place. \(cause.localizedDescription)"
        ).save(root: root)
        try await launch(plan.app)
        try? fm.removeItem(at: plan.workspace)
      } catch {
        try? AppUpdateResult(
          state: "failed", version: plan.replacement.version,
          detail:
            "The update couldn't finish. \(error.localizedDescription) App and update files were preserved at \(plan.destination) and \(plan.directory)."
        ).save(root: root)
        throw error
      }
      throw cause
    }
  }
}
