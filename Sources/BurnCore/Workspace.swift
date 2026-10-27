import CBurn
import Darwin
import Foundation

public struct WorkspaceIdentity: Codable, Equatable, Sendable {
  public var path: String
  public var common: String
  public var gitDirectory: String
  public var device: Int32
  public var inode: UInt64
}
public struct WorkspaceClaim: Codable, Sendable {
  public var id: String
  public var tokenHash: String
  public var identity: WorkspaceIdentity
  public var label: String
  public var purpose: String
  public var completionCondition: String
  public var state: String
  public var evidence: String
  public var head: String?
  public var created: Date
  public var updated: Date
}
public struct WorkspaceSummary: Codable, Sendable {
  public var purpose: String
  public var created: Date
  public var updated: Date
  public var id: String
  public var path: String
  public var label: String
  public var state: String
  public var evidence: String
  public var completionCondition: String
  public var head: String?
  public init(_ c: WorkspaceClaim) {
    purpose = c.purpose; created = c.created; updated = c.updated
    id = c.id; path = c.identity.path; label = c.label; state = c.state
    evidence = c.evidence; completionCondition = c.completionCondition; head = c.head
  }
}
public struct WorkspaceReceipt: Codable, Sendable {
  public var id: UUID
  public var workspaceID: String
  public var identity: WorkspaceIdentity
  public var label: String
  public var head: String
  public var recoveryRef: String
  public var date: Date
  public var verifiedAt: Date?
  public var outcome: String
  public var diskReclaimedBytes: UInt64
  public var detail: String
}
public struct WorkspaceCheck: Sendable {
  public var identity: WorkspaceIdentity
  public var head: String
  public var allocated: UInt64
}

/// Only disposable worktrees created inside the private BZ workspace root qualify.
/// Existing checkouts, including custom-location Codex worktrees, cannot be adopted.
public enum WorkspaceSafety {
  static func fail(_ message: String) -> StoreError { .message(message) }
  public static func canonical(_ path: String) -> String {
    if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }
  public static func contains(_ root: String, _ path: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }
  static func statAt(_ path: String) throws -> stat {
    var s = stat()
    guard lstat(path, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT != S_IFLNK else {
      throw fail("Workspace identity or ownership is unavailable; preserve it.")
    }
    return s
  }
  /// Bounded, local Git only. No shell, hooks, fsmonitor, global config or network.
  @discardableResult public static func git(_ directory: String, _ arguments: [String]) throws -> String {
    let p = Process(), url = FileManager.default.temporaryDirectory.appendingPathComponent("bz-git-" + UUID().uuidString)
    let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw fail("Cannot create private Git output.") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close(); try? FileManager.default.removeItem(at: url) }
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", directory] + arguments
    p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
    p.standardInput = FileHandle.nullDevice; p.standardOutput = file; p.standardError = file
    try p.run()
    let deadline = Date().addingTimeInterval(10)
    while p.isRunning {
      var s = stat(); _ = fstat(fd, &s)
      if Date() >= deadline || s.st_size > 1_048_576 {
        p.terminate(); Thread.sleep(forTimeInterval: 0.05)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit(); throw fail("Git inspection exceeded its bounded budget. Workspace preserved where present.")
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    p.waitUntilExit()
    try file.seek(toOffset: 0)
    let data = try file.read(upToCount: 1_048_577) ?? Data()
    guard data.count <= 1_048_576 else { throw fail("Git output exceeded its inspection limit.") }
    guard p.terminationStatus == 0 else { throw fail("Git refused the workspace operation (exit \(p.terminationStatus)).") }
    return String(decoding: data, as: UTF8.self)
  }
  static func line(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
  public static func identity(_ path: String, root: URL) throws -> WorkspaceIdentity {
    let parent = canonical(root.appendingPathComponent("workspaces").path)
    guard path == canonical(path), (path as NSString).deletingLastPathComponent == parent,
      UUID(uuidString: URL(fileURLWithPath: path).lastPathComponent) != nil else {
      throw fail("Only BurnZombies-created disposable worktrees can be reclaimed. Existing and harness-managed worktrees stay with their owner.")
    }
    let s = try statAt(path), pointer = try statAt(path + "/.git")
    guard s.st_mode & S_IFMT == S_IFDIR, pointer.st_mode & S_IFMT == S_IFREG else { throw fail("Linked worktree directory or .git pointer type changed.") }
    let top = line(try git(path, ["rev-parse", "--show-toplevel"]))
    guard canonical(top) == path else { throw fail("Linked worktree root mismatch: \(top) versus \(path)") }
    let common = canonical(line(try git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])))
    let directory = canonical(line(try git(path, ["rev-parse", "--absolute-git-dir"])))
    _ = try statAt(common); _ = try statAt(directory)
    guard (directory as NSString).deletingLastPathComponent == common + "/worktrees",
      !contains(path, common), canonical(line(try String(contentsOfFile: directory + "/gitdir", encoding: .utf8))) == path + "/.git" else {
      throw fail("Main worktrees and ambiguous Git administration are protected.")
    }
    return .init(path: path, common: common, gitDirectory: directory, device: s.st_dev, inode: s.st_ino)
  }
  static func administration(_ i: WorkspaceIdentity) throws {
    for name in ["locked", "index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_START", "rebase-merge", "rebase-apply", "sequencer"] {
      var entry = stat()
      guard lstat(i.gitDirectory + "/" + name, &entry) != 0, errno == ENOENT else {
        throw fail("Worktree is locked or a Git operation is unfinished.")
      }
    }
    let list = try git(i.common, ["worktree", "list", "--porcelain", "-z"])
    guard list.components(separatedBy: "\0").contains(where: { $0.hasPrefix("worktree ") && canonical(String($0.dropFirst(9))) == i.path }) else { throw fail("Worktree registration changed.") }
  }
  public static func check(_ claim: WorkspaceClaim, root: URL, visibility: (String) -> Int32 = { bz_path_in_use($0) }) throws -> WorkspaceCheck {
    guard claim.state == "released", let releasedHead = claim.head else { throw fail("The owning agent has not released this workspace.") }
    let i = try identity(claim.identity.path, root: root)
    guard i == claim.identity else { throw fail("Workspace identity changed. Preserve it.") }
    try administration(i)
    let configuration = try git(i.path, ["config", "--null", "--list"])
    guard !configuration.split(separator: "\0").contains(where: { $0.hasPrefix("filter.") }) else {
      throw fail("Checkout filters require the owning harness; preserve this workspace.")
    }
    let head = line(try git(i.path, ["rev-parse", "--verify", "HEAD^{commit}"]))
    guard head == releasedHead else { throw fail("New commits appeared after release. Renew the owner claim.") }
    // Remote reachability is a preservation prerequisite, never completion evidence.
    guard !line(try git(i.path, ["for-each-ref", "--format=%(refname)", "--contains=" + head, "refs/remotes/"])).isEmpty else {
      throw fail("HEAD is not preserved in a remote-tracking ref. Unpushed work is protected.")
    }
    let tracked = try git(i.path, ["ls-files", "-v", "-z"])
    guard tracked.split(separator: "\0").allSatisfy({ $0.first == "H" }) else { throw fail("Sparse, assume-unchanged or unusual index entries are protected.") }
    guard !(try git(i.path, ["ls-files", "--stage", "-z"])).split(separator: "\0").contains(where: { $0.hasPrefix("160000 ") }) else {
      throw fail("Submodules are protected.")
    }
    // --ignored prevents silently deleting ignored secrets, generated output or caches.
    guard try git(i.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"]).isEmpty else {
      throw fail("Worktree contains changes, untracked or ignored files. Preserve it.")
    }
    let allocated = try allocatedBytes(i.path)
    switch visibility(i.path) {
    case 0: break
    case 1: throw fail("A process still has this workspace open or uses it as its working directory. Preserve it.")
    default: throw fail("Complete process/file-handle visibility is unavailable. Preserve this workspace.")
    }
    return .init(identity: i, head: head, allocated: allocated)
  }
  static func allocatedBytes(_ path: String) throws -> UInt64 {
    var enumerationFailed = false
    guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
      errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw fail("Workspace files could not be inspected.") }
    let deadline = Date().addingTimeInterval(10)
    var total: UInt64 = 0, count = 0
    for case let url as URL in e {
      count += 1
      guard count <= 100_000, Date() < deadline else { throw fail("Workspace exceeds the bounded file inspection limit.") }
      let s = try statAt(url.path)
      if canonical(url.path) == path + "/.git" { continue }
      guard url.lastPathComponent != ".git", s.st_mode & S_IFMT == S_IFREG || s.st_mode & S_IFMT == S_IFDIR else {
        throw fail("Nested repositories, symlinks and special files are protected.")
      }
      if s.st_mode & S_IFMT == S_IFREG {
        guard s.st_nlink == 1 else { throw fail("Hardlinked files are protected.") }
        total += UInt64(max(0, s.st_blocks)) * 512
      }
    }
    guard !enumerationFailed else { throw fail("Incomplete workspace file visibility.") }
    return total
  }
  public static func freeBytes(_ path: String) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
    guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw fail("Free disk space is unavailable.") }
    return bytes.uint64Value
  }
  public static func removed(_ receipt: WorkspaceReceipt) -> Bool {
    var s = stat()
    guard lstat(receipt.identity.path, &s) != 0, errno == ENOENT,
      let refs = try? git(receipt.identity.common, ["rev-parse", "--verify", receipt.recoveryRef]), line(refs) == receipt.head,
      let list = try? git(receipt.identity.common, ["worktree", "list", "--porcelain", "-z"]),
      !list.components(separatedBy: "\0").contains(where: { $0.hasPrefix("worktree ") && canonical(String($0.dropFirst(9))) == receipt.identity.path }) else { return false }
    return true
  }
}

public enum WorkspaceInput {
  public static func request(_ data: Data) throws -> AgentRequest {
    guard data.count <= 16384, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let action = o["action"] as? String, ["create", "release", "retain"].contains(action),
      let evidence = o["evidence"] as? String, (20...1200).contains(evidence.count) else {
      throw StoreError.message("Use create/release/retain with factual evidence (20–1200 characters).")
    }
    if action == "create" {
      guard Set(o.keys) == ["action", "repository", "label", "evidence", "completion_condition"],
        let repository = o["repository"] as? String, repository.hasPrefix("/"), repository.count <= 4096,
        let label = o["label"] as? String, (1...80).contains(label.count),
        let condition = o["completion_condition"] as? String, (10...500).contains(condition.count) else {
        throw StoreError.message("Create requires an absolute repository path, label, evidence and completion_condition.")
      }
      return .init("workspace", label: label, rationale: evidence, action: action,
        completionCondition: condition, workspacePath: repository)
    }
    guard Set(o.keys) == ["action", "evidence", "work_token"], let token = o["work_token"] as? String, token.count == 72 else {
      throw StoreError.message("Release/retain requires the owning task's work_token and evidence only.")
    }
    return .init("workspace", rationale: evidence, action: action, workToken: token)
  }
}
