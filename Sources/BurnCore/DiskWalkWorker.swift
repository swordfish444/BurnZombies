import CBurn
import Darwin
import Foundation

/// Private, bounded IPC. `entries` is completed traversal-step work, not a storage metric.
public struct DiskWalkCheckpoint: Codable, Sendable {
  public var runID: String
  public var root: String
  public var sequence: UInt64
  public var entries: UInt64
  public var complete: Bool
  public var nodes: [DiskSpaceNode]
  public init(runID: String, root: String, sequence: UInt64, entries: UInt64,
    complete: Bool, nodes: [DiskSpaceNode]) {
    self.runID = runID; self.root = root; self.sequence = sequence
    self.entries = entries; self.complete = complete; self.nodes = nodes
  }
}

public struct DiskWalkOutcome: Sendable {
  public var status: String
  public var nodes: [DiskSpaceNode]
  public var childPID: Int32?
  public var childReaped: Bool
}

/// Owns exactly one unreaped child PID. Filesystem calls that cannot be interrupted
/// never run in the app, and a failed teardown permanently stops this runner.
public final class DiskWalkRunner: @unchecked Sendable {
  public static let maximumBytes = 8_388_608
  private let executable: URL
  private let argumentPrefix: [String]
  private let progressTimeout: TimeInterval
  private let rootTimeout: TimeInterval
  private let teardownTimeout: TimeInterval
  private let lock = NSLock()
  private var unsafeToSpawn = false

  public init(executable: URL? = nil, argumentPrefix: [String] = ["--disk-walk-worker"],
    progressTimeout: TimeInterval = 30, rootTimeout: TimeInterval = 1800,
    teardownTimeout: TimeInterval = 5) {
    self.executable = executable ?? URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent().appendingPathComponent("burnzombies")
    self.argumentPrefix = argumentPrefix
    self.progressTimeout = max(0.1, min(progressTimeout, 120))
    self.rootTimeout = max(0.1, min(rootTimeout, 1800))
    self.teardownTimeout = max(0.1, min(teardownTimeout, 5))
  }

  // Lexical validation deliberately performs no filesystem resolution in the parent.
  static func validPath(_ path: String) -> Bool {
    path.hasPrefix("/") && path.utf8.count < 4096 && !path.contains("\0")
      && !path.contains("//") && (path == "/" || !path.hasSuffix("/"))
      && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
  }
  public static func decode(data: Data, root: String, runID: String,
    previous: DiskWalkCheckpoint? = nil) throws -> DiskWalkCheckpoint {
    guard data.count <= maximumBytes, validPath(root), UUID(uuidString: runID) != nil else {
      throw StoreError.message("Invalid storage worker envelope.")
    }
    let value = try JSONDecoder().decode(DiskWalkCheckpoint.self, from: data)
    guard value.runID == runID, value.root == root, value.sequence > 0,
      value.nodes.count > 0, value.nodes.count <= 4096,
      Set(value.nodes.map(\.path)).count == value.nodes.count,
      let rootNode = value.nodes.first(where: { $0.path == root }),
      rootNode.complete == value.complete,
      value.nodes.allSatisfy({ node in
        validPath(node.path) && (node.path == root || node.path.hasPrefix(root + "/"))
          && node.scanRoot == root && node.members == nil
          && node.path.split(separator: "/").count - root.split(separator: "/").count <= 3
          && node.unshared <= node.allocated && node.measured.timeIntervalSinceReferenceDate.isFinite
          && [node.allocated, node.unshared, node.files, node.unknown, node.errors,
              node.hardlinks, node.dataless].allSatisfy({ $0 <= UInt64.max / 65536 })
          && (!value.complete || node.complete)
      }) else { throw StoreError.message("Storage worker escaped its exact root or bounds.") }
    if let previous {
      guard value.sequence > previous.sequence, value.entries > previous.entries,
        !previous.complete else { throw StoreError.message("Storage worker did not advance.") }
      let old = Dictionary(uniqueKeysWithValues: previous.nodes.map { ($0.path, $0) })
      guard Set(old.keys).isSubset(of: Set(value.nodes.map(\.path))),
        value.nodes.allSatisfy({ node in
          guard let before = old[node.path] else { return true }
          return node.files >= before.files && node.allocated >= before.allocated
            && node.unshared >= before.unshared && (!before.complete || node.complete)
        }) else { throw StoreError.message("Storage worker checkpoint regressed.") }
    }
    return value
  }

  public func run(root: String, temporaryParent: URL,
    shouldContinue: () -> Bool = { true },
    publish: ([DiskSpaceNode], Bool) -> Void = { _, _ in }) -> DiskWalkOutcome {
    // Serialization also prevents concurrent calls creating more than one blocked worker.
    lock.lock(); defer { lock.unlock() }
    guard !unsafeToSpawn, Self.validPath(root), shouldContinue() else {
      return .init(status: unsafeToSpawn ? "teardownFailed" : "cancelled", nodes: [],
        childPID: nil, childReaped: !unsafeToSpawn)
    }
    let runID = UUID().uuidString
    let directory = temporaryParent.appendingPathComponent("disk-worker-" + runID)
    var child: pid_t = -1
    var reaped = false
    var checkpoint: DiskWalkCheckpoint?
    var outcome = "failed"
    do {
      var childSignal = sigaction()
      guard sigaction(SIGCHLD, nil, &childSignal) == 0,
        childSignal.sa_flags & SA_NOCLDWAIT == 0,
        unsafeBitCast(childSignal.__sigaction_u.__sa_handler, to: UInt.self)
          != unsafeBitCast(SIG_IGN, to: UInt.self) else {
        throw StoreError.message("Storage worker requires exclusive child reaping.")
      }
      let privateStore = try Store(root: directory)
      defer { if child <= 1 || reaped { try? FileManager.default.removeItem(at: directory) } }
      let arguments = [executable.path] + argumentPrefix + [root, runID, directory.path]
      let words = arguments.map { strdup($0) }
      let environmentWords: [String] = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8",
        "BZ_DISK_PARENT_PID=\(getpid())"]
      let environment = environmentWords.map { strdup($0) }
      defer { words.forEach { free($0) }; environment.forEach { free($0) } }
      var argv = words + [nil], env = environment + [nil]
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw StoreError.message("Storage worker file actions unavailable.")
      }
      defer { posix_spawn_file_actions_destroy(&actions) }
      guard posix_spawnattr_init(&attributes) == 0 else {
        throw StoreError.message("Storage worker attributes unavailable.")
      }
      defer { posix_spawnattr_destroy(&attributes) }
      var defaults = sigset_t(), mask = sigset_t()
      sigemptyset(&defaults); sigemptyset(&mask)
      sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGPIPE)
      guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
        posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
        posix_spawnattr_setsigmask(&attributes, &mask) == 0,
        posix_spawnattr_setflags(&attributes,
          Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
        posix_spawn(&child, executable.path, &actions, &attributes, &argv, &env) == 0, child > 1
      else { throw StoreError.message("Could not start private storage worker.") }
      let started = ProcessInfo.processInfo.systemUptime
      var progress = started
      var lastFileIdentity: (UInt64, Int64)?
      var lastData: Data?
      let file = directory.appendingPathComponent("checkpoint.json")
      while true {
        if !shouldContinue() { outcome = "cancelled"; break }
        var status: Int32 = 0
        let waited = waitpid(child, &status, WNOHANG)
        if waited == child { reaped = true }
        else if waited < 0 && errno != EINTR {
          unsafeToSpawn = true; outcome = "teardownFailed"; break
        }
        var metadata = stat()
        if lstat(file.path, &metadata) == 0 {
          guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
            metadata.st_nlink == 1, metadata.st_size >= 0,
            metadata.st_size <= Self.maximumBytes else {
            throw StoreError.message("Invalid storage worker checkpoint file.")
          }
          let identity = (UInt64(metadata.st_ino), Int64(metadata.st_mtimespec.tv_nsec))
          if lastFileIdentity?.0 != identity.0 || lastFileIdentity?.1 != identity.1 {
            let data = try privateStore.read(file, limit: Self.maximumBytes)
            lastFileIdentity = identity
            if data != lastData {
              let value = try Self.decode(data: data, root: root, runID: runID, previous: checkpoint)
              checkpoint = value; lastData = data
              progress = ProcessInfo.processInfo.systemUptime
              publish(value.nodes, value.complete)
            }
          }
        } else if errno != ENOENT { throw StoreError.message("Storage worker checkpoint inaccessible.") }
        if reaped {
          outcome = status == 0 && checkpoint?.complete == true ? "complete" : "failed"
          break
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - progress >= progressTimeout || now - started >= rootTimeout {
          outcome = "stalled"; break
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
    } catch { outcome = "failed" }
    if child > 1 && !reaped && !unsafeToSpawn {
      // The PID has not been reaped by anybody: an exiting child cannot be recycled.
      // Never signal a process group or a PID reconstructed from a checkpoint.
      _ = kill(child, SIGKILL)
      let deadline = ProcessInfo.processInfo.systemUptime + teardownTimeout
      repeat {
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        if result == child { reaped = true; break }
        if result < 0 && errno != EINTR { break }
        Thread.sleep(forTimeInterval: 0.01)
      } while ProcessInfo.processInfo.systemUptime < deadline
      if !reaped { unsafeToSpawn = true; outcome = "teardownFailed" }
    }
    if reaped { try? FileManager.default.removeItem(at: directory) }
    return .init(status: outcome, nodes: checkpoint?.nodes ?? [],
      childPID: child > 1 ? child : nil, childReaped: child <= 1 || reaped)
  }
}

public enum DiskWalkWorker {
  /// Internal CLI entry point. No observer, harness, UI, or child processes are created.
  public static func run(arguments: [String]) -> Int32 {
    guard arguments.count == 3 else { return 64 }
    let root = arguments[0], runID = arguments[1], directory = URL(fileURLWithPath: arguments[2])
    guard UUID(uuidString: runID) != nil, DiskWalkRunner.validPath(root),
      directory.lastPathComponent == "disk-worker-" + runID,
      DiskWalkRunner.validPath(directory.path) else { return 64 }
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0, metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o077 == 0 else { return 64 }
    // Survive neither parent death nor a failed parent deadline. This thread only
    // exits its own private worker; it never enumerates or signals other processes.
    let parent = getppid(), started = ProcessInfo.processInfo.systemUptime
    guard parent > 1, ProcessInfo.processInfo.environment["BZ_DISK_PARENT_PID"] == String(parent)
      else { return 64 }
    DispatchQueue.global(qos: .background).async {
      while true {
        Thread.sleep(forTimeInterval: 1)
        if getppid() != parent || ProcessInfo.processInfo.systemUptime - started > 1810 { _exit(124) }
      }
    }
    do {
      let store = try Store(root: directory)
      guard root == WorkspaceSafety.canonical(root), let walk = bz_disk_open(root, 3) else { return 66 }
      defer { bz_disk_close(walk) }
      var sequence: UInt64 = 0, entries: UInt64 = 0
      func checkpoint(_ complete: Bool) throws {
        sequence += 1
        let value = DiskWalkCheckpoint(runID: runID, root: root, sequence: sequence,
          entries: entries, complete: complete,
          nodes: DiskDiscovery.read(walk, root: root, complete: complete))
        try store.write(JSONEncoder().encode(value), to: directory.appendingPathComponent("checkpoint.json"),
          limit: DiskWalkRunner.maximumBytes)
      }
      try checkpoint(false)
      var published = ProcessInfo.processInfo.systemUptime
      while true {
        let done = bz_disk_step(walk, 2000) != 0
        entries += 2000
        let now = ProcessInfo.processInfo.systemUptime
        if done || now - published >= 5 {
          try checkpoint(done); published = now
        }
        if done { return 0 }
        Thread.sleep(forTimeInterval: 0.01)
      }
    } catch { return 74 }
  }
}
