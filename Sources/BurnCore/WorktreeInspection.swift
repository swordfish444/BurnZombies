import CBurn
import CryptoKit
import Darwin
import Foundation

public enum WorktreeGit {
  private static let stateLock = NSLock()
  private static var unsafeTeardown = false
  public static func run(_ path: String, _ args: [String], seconds: Double = 15) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bz-worktree-git-" + UUID().uuidString)
    let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Cannot capture Git evidence.") }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? output.close(); unlink(url.path) }
    guard (0.001...180).contains(seconds), !stateLock.withLock({ unsafeTeardown }) else { throw StoreError.message("Git work is paused after an unverified owned-child teardown.") }
    var words = (["/usr/bin/git", "--no-pager", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "protocol.allow=never", "-C", path] + args).map { strdup($0) } + [nil]
    var env = ["PATH=/usr/bin:/bin", "HOME=" + NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "GIT_NO_LAZY_FETCH=1", "LC_ALL=C"].map { strdup($0) } + [nil]
    defer { words.forEach { free($0) }; env.forEach { free($0) } }
    var context: Int32 = 0, unreaped: Int32 = -1
    let status = bz_capture_worktree_git(&words, &env, fd, Int32(seconds * 1000), { _, _ in Task.isCancelled ? 0 : 1 }, &context, &unreaped)
    if status == 72 { stateLock.withLock { unsafeTeardown = true } }
    guard status == 0 else { throw StoreError.message("Git refused or exceeded the bounded \(args.first ?? "operation") request (status \(status)); preserve the worktree and inspect its operation history.") }
    try output.seek(toOffset: 0)
    return try output.read(upToCount: 8_388_609) ?? Data()
  }
  public static func text(_ path: String, _ args: [String], seconds: Double = 15) throws -> String {
    let data = try run(path, args, seconds: seconds)
    guard let text = String(data: data, encoding: .utf8) else { throw StoreError.message("Non-UTF-8 Git evidence requires owner handling; preserved without lossy parsing.") }
    return text
  }
  public static func line(_ path: String, _ args: [String]) throws -> String {
    let s = try text(path, args)
    return s.hasSuffix("\n") ? String(s.dropLast()) : s
  }
}

public struct WorktreeFile: Codable, Equatable, Sendable {
  public var path: String
  public var kind: String
  public var mode: UInt16
  public var size: Int64
  public var inode: UInt64
  public var modified: Int64
  public var nanos: Int64
  public var target: String?
  public var digest: String?
  public var blocks: [String]?
  public var attributes: [String: Data]?
}

public enum WorktreeInspection {
  public static func identity(_ path: String) throws -> WorktreeIdentity {
    guard path == WorkspaceSafety.canonical(path) else { throw StoreError.message("Worktree path resolves elsewhere.") }
    let s = try WorkspaceSafety.statAt(path)
    guard s.st_mode & S_IFMT == S_IFDIR else { throw StoreError.message("Worktree is not a real owned directory.") }
    let common = WorkspaceSafety.canonical(try WorktreeGit.line(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
    let admin = WorkspaceSafety.canonical(try WorktreeGit.line(path, ["rev-parse", "--absolute-git-dir"]))
    let cs = try WorkspaceSafety.statAt(common), ads = try WorkspaceSafety.statAt(admin)
    return .init(path: path, common: common, administration: admin, device: s.st_dev, inode: s.st_ino,
      commonInode: cs.st_ino, administrationInode: ads.st_ino)
  }
  public static func files(_ root: String, seconds: Double = 15, limit: Int = 100_000, permitLinks: Bool = false) throws -> ([WorktreeFile], UInt64) {
    let rootInfo = try WorkspaceSafety.statAt(root)
    guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw StoreError.message("Checkout root is not a directory.") }
    var failed = false
    guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
      errorHandler: { _, _ in failed = true; return false }) else { throw StoreError.message("Cannot enumerate checkout.") }
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    var result: [WorktreeFile] = [], allocated: UInt64 = 0, attributeBytes = 0
    var rootPending = true
    while let url = rootPending ? { rootPending = false; return URL(fileURLWithPath: root) }() : walk.nextObject() as? URL {
      guard !Task.isCancelled, result.count < limit, ProcessInfo.processInfo.systemUptime < deadline else { throw StoreError.message("Checkout inspection limit reached; coverage incomplete.") }
      let relative = url.path == root ? "" : String(url.path.dropFirst(root.count + 1))
      if relative == ".git" { walk.skipDescendants(); continue }
      guard url.lastPathComponent.lowercased() != ".git" else { throw StoreError.message("Nested repository is protected.") }
      var s = stat()
      guard lstat(url.path, &s) == 0, s.st_uid == getuid(), s.st_dev == rootInfo.st_dev else { throw StoreError.message("File identity, ownership or same-volume coverage unavailable.") }
      let type = s.st_mode & S_IFMT
      guard s.st_flags == 0 else { throw StoreError.message("Native file flags or online-only content require owner recovery.") }
      if type == S_IFDIR && FileManager.default.fileExists(atPath: url.path + "/HEAD") && FileManager.default.fileExists(atPath: url.path + "/objects") && FileManager.default.fileExists(atPath: url.path + "/config") { throw StoreError.message("Nested bare repository is protected.") }
      guard s.st_mode & 0o7000 == 0 else { throw StoreError.message("Special permission bits require owner handling.") }
      let namesSize = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
      guard namesSize >= 0, namesSize <= 65_536 else { throw StoreError.message("Extended attribute visibility is unavailable or exceeds inspection bounds.") }
      var attributes: [String: Data] = [:]
      if namesSize > 0 {
        var names = [CChar](repeating: 0, count: namesSize)
        guard listxattr(url.path, &names, names.count, XATTR_NOFOLLOW) == namesSize else { throw StoreError.message("Attribute names changed during inspection.") }
        for bytes in names.map({ UInt8(bitPattern: $0) }).split(separator: 0) {
          guard let name = String(bytes: bytes, encoding: .utf8) else { throw StoreError.message("Unsupported attribute name.") }
          let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
          guard size >= 0, size <= 1_048_576, attributeBytes + size <= 33_554_432 else { throw StoreError.message("Extended attributes exceed bounded recovery support.") }
          var data = Data(count: size)
          let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
          guard read == size else { throw StoreError.message("Attribute changed during inspection.") }
          attributes[name] = data; attributeBytes += size
        }
      }
      if let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) {
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0 else { throw StoreError.message("Extended ACLs require owner recovery.") }
      } else if errno != ENOENT && errno != ENOTSUP { throw StoreError.message("ACL visibility is unavailable.") }
      let kind: String
      var target: String?
      if type == S_IFREG {
        guard s.st_nlink == 1 else { throw StoreError.message("Hardlinked files require owner handling.") }
        kind = "file"; allocated += UInt64(max(0, s.st_blocks)) * 512
      } else if type == S_IFDIR { kind = "directory" }
      else if type == S_IFLNK && permitLinks {
        kind = "link"; target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path); walk.skipDescendants()
      } else { throw StoreError.message("Links or special files require supported recovery.") }
      // Dataless files must never be hydrated by rescue or treated as empty.
      guard s.st_flags & UInt32(0x40000000) == 0 else { throw StoreError.message("Online-only content is protected.") }
      result.append(.init(path: relative, kind: kind, mode: UInt16(s.st_mode & 0o777), size: s.st_size,
        inode: s.st_ino, modified: Int64(s.st_mtimespec.tv_sec), nanos: Int64(s.st_mtimespec.tv_nsec), target: target, attributes: attributes))
    }
    guard !failed else { throw StoreError.message("Incomplete file visibility.") }
    return (result.sorted { $0.path < $1.path }, allocated)
  }
  public static func inspect(_ original: WorktreeRecord, visibility: (String) -> Int32 = { bz_path_in_use($0) }) -> WorktreeRecord {
    var r = original; r.observedAt = Date(); r.blockers = []; r.gaps = []
    if r.main || r.bare { r.blockers.append("Main and bare repository anchors are protected.") }
    if r.ownerManaged { r.blockers.append("Use the owning application's supported archive/restore workflow.") }
    if r.locked { r.blockers.append("Git worktree lock is set.") }
    guard !r.missing else { r.gaps = ["Registered directory is missing or its volume is unavailable."]; return r }
    do {
      let identity = try identity(r.path)
      guard identity.common == r.repository else { throw StoreError.message("Worktree pointer no longer belongs to the recorded repository.") }
      if let old = r.identity, old != identity { r.gaps.append("Directory or repository identity changed; re-adoption required."); r.managed = false; r.confirmedRevision = nil }
      r.identity = identity
      let headData = try WorktreeRecovery.read(URL(fileURLWithPath: identity.administration + "/HEAD"), limit: 8192)
      guard let headFile = String(data: headData, encoding: .utf8), headFile.hasSuffix("\n") else { throw StoreError.message("HEAD binding unavailable.") }
      r.branch = headFile.hasPrefix("ref: ") ? String(headFile.dropFirst(5).dropLast()) : nil
      if ["refs/heads/main", "refs/heads/master"].contains(r.branch ?? "") { r.blockers.append("Default-branch checkout is protected.") }
      let commit = try WorktreeGit.line(r.path, ["log", "-1", "--format=%H%x00%ct"]).split(separator: "\0")
      guard commit.count == 2, let timestamp = Double(commit[1]), timestamp.isFinite else { throw StoreError.message("Commit identity/time evidence unavailable.") }
      r.head = String(commit[0]); r.lastCommitAt = Date(timeIntervalSince1970: timestamp)
      if let defaultRef = try? WorktreeGit.line(r.path, ["symbolic-ref", "refs/remotes/origin/HEAD"]),
        defaultRef.hasPrefix("refs/remotes/origin/"), r.branch == "refs/heads/" + defaultRef.dropFirst(20) {
        r.blockers.append("Cached remote default-branch checkout is protected.")
      }
      if !r.main && !r.bare {
        let top = try WorktreeGit.line(r.path, ["rev-parse", "--show-toplevel"])
        guard top == r.path, !WorkspaceSafety.contains(r.path, identity.common),
          (identity.administration as NSString).deletingLastPathComponent == identity.common + "/worktrees" else { throw StoreError.message("Ambiguous worktree registration or shared Git data inside target.") }
        let pointer = try WorkspaceSafety.statAt(r.path + "/.git")
        guard pointer.st_mode & S_IFMT == S_IFREG else { throw StoreError.message("Git pointer is not a regular owned file.") }
        let backlink = try String(contentsOfFile: identity.administration + "/gitdir", encoding: .utf8)
        guard backlink == r.path + "/.git\n" else { throw StoreError.message("Git administration backlink changed.") }
      }
      let config = try WorktreeGit.text(r.path, ["config", "--null", "--name-only", "--list"])
      if config.split(separator: "\0").contains(where: { $0.hasPrefix("filter.") || $0 == "extensions.partialclone" || $0.hasSuffix(".promisor") || $0 == "core.splitindex" || $0 == "index.sparse" }) { r.blockers.append("Filters, LFS or partial-clone recovery require owner handling.") }
      if FileManager.default.fileExists(atPath: identity.common + "/shallow") { r.blockers.append("Shallow object history is not supported for independent recovery.") }
      for name in ["locked", "index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_START", "rebase-merge", "rebase-apply", "sequencer"] {
        var s = stat()
        if lstat(identity.administration + "/" + name, &s) == 0 { r.blockers.append("Git state requires completion: " + name) }
        else if errno != ENOENT { r.gaps.append("Git state visibility unavailable: " + name) }
      }
      let flags = try WorktreeGit.text(r.path, ["ls-files", "-v", "-z"])
      if !flags.split(separator: "\0").allSatisfy({ $0.first == "H" }) { r.blockers.append("Sparse, conflicted or assume-unchanged index requires owner handling.") }
      if try WorktreeGit.text(r.path, ["ls-files", "--stage", "-z"]).split(separator: "\0").contains(where: { $0.hasPrefix("160000 ") }) { r.blockers.append("Submodules require owner handling.") }
      let status = try WorktreeGit.run(r.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"])
      guard let statusText = String(data: status, encoding: .utf8) else { throw StoreError.message("Unsupported byte paths; preserved.") }
      r.status = WorkEvidence.hash(status.base64EncodedString())
      let entries = statusText.split(separator: "\0")
      r.ignored = entries.filter { $0.hasPrefix("!! ") }.count
      r.changes = entries.filter { !$0.hasPrefix("!! ") }.count
      let (files, size) = try files(r.path, permitLinks: true); r.allocated = size
      r.lastFileChange = files.map { Date(timeIntervalSince1970: Double($0.modified) + Double($0.nanos) / 1_000_000_000) }.max()
      let metadata = try WorktreeEncoding.data(files)
      // Metadata invalidates plans; content capture performs independent digest verification.
      let revision = WorkEvidence.hash((r.head ?? "") + "|" + (r.branch ?? "detached") + "|" + r.status + metadata.base64EncodedString() + r.blockers.joined())
      if r.revision != revision { r.changedAt = Date(); r.confirmedRevision = nil; r.confirmedAt = nil }
      r.revision = revision
      switch visibility(r.path) {
      case 0: r.consumer = "none observed"
      case 1: r.consumer = "in use"
      default: r.consumer = "unknown"; r.gaps.append("Complete same-user cwd/file-handle visibility is unavailable.")
      }
    } catch { r.gaps.append(error.localizedDescription); r.consumer = "unknown" }
    return r
  }
}
