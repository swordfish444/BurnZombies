import CBurn
import CryptoKit
import Darwin
import Foundation

public struct DiskRule: Codable, Sendable, Identifiable {
  public var path: String
  public var disposition: String // keep, review, regenerable; exact directory only
  public var note: String
  public var id: String { path }
  public init(path: String, disposition: String, note: String = "") { self.path = path; self.disposition = disposition; self.note = note }
}
public struct DiskPolicy: Codable, Sendable {
  public var mode = "recommend"
  public var minimumAgeDays = 14
  public var keepNewest = 3
  public var scanHours = 6
  public var targetFreeGB = 150
  public var maximumGBPerDay = 20
  public var minimumCandidateMB = 10_000
  public var roots: [String] = []
  public var protectedPaths: [String] = []
  public var instructions = "Preserve useful QA evidence and the newest successful run. Prefer rebuildable output over whole worktrees."
  public var rules: [DiskRule] = []
  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    roots = [home.appendingPathComponent(".codex/worktrees").path]
  }
  public mutating func preset(_ name: String) {
    switch name {
    case "conservative": minimumAgeDays = 14; keepNewest = 5; scanHours = 6; maximumGBPerDay = 10
    case "balanced": minimumAgeDays = 7; keepNewest = 3; scanHours = 3; maximumGBPerDay = 20
    case "proactive": minimumAgeDays = 2; keepNewest = 2; scanHours = 1; maximumGBPerDay = 50
    default: break
    }
  }
  public var revision: String { WorkEvidence.hash(String(decoding: (try? JSONEncoder.sorted.encode(self)) ?? Data(), as: UTF8.self)) }
  public func validate() throws {
    guard ["off", "recommend", "automatic"].contains(mode), (1...90).contains(minimumAgeDays), (1...20).contains(keepNewest),
      (1...24).contains(scanHours), (10...1000).contains(targetFreeGB), (1...500).contains(maximumGBPerDay),
      (1...100_000).contains(minimumCandidateMB), instructions.count <= 1600, roots.count <= 12, protectedPaths.count <= 100, rules.count <= 200 else {
      throw StoreError.message("Disk settings exceed their supported bounds.")
    }
    for path in roots + protectedPaths + rules.map(\.path) {
      guard path.hasPrefix("/"), path.count < 4096, path == WorkspaceSafety.canonical(path), path != "/", path != NSHomeDirectory() else {
        throw StoreError.message("Use exact canonical subfolders, never the whole disk or home directory.")
      }
    }
    guard rules.allSatisfy({ ["keep", "review", "regenerable"].contains($0.disposition) && $0.note.count <= 600 }), Set(rules.map(\.path)).count == rules.count else { throw StoreError.message("Invalid or duplicate disk rule.") }
  }
  public static func load(_ store: Store) throws -> Self {
    let url = store.root.appendingPathComponent("disk-policy.json")
    if !FileManager.default.fileExists(atPath: url.path) { return Self() }
    let value = try JSONDecoder().decode(Self.self, from: store.read(url, limit: 131072)); try value.validate(); return value
  }
  public func save(_ store: Store) throws { try validate(); try store.write(JSONEncoder.sorted.encode(self), to: store.root.appendingPathComponent("disk-policy.json"), limit: 131072) }
}
private extension JSONEncoder { static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e } }
public struct DiskCandidate: Codable, Sendable, Identifiable {
  public static let minimumReviewBytes: UInt64 = 10_000_000_000
  public var id: String
  public var path: String
  public var repository: String
  public var kind: String
  public var bytes: UInt64
  public var newest: Date
  public var fingerprint: String
  public var complete: Bool
  public var guardReason: String
  public var reviewable: Bool
  public var userRule: String
  public var decision: String?
  public var decisionRevision: String?
  public var rationale: String?
  public var policyRevision: String = ""
  public var recommendationEligible: Bool?
  public var recommendationPolicyRevision: String?
  public var adviceRevision: String {
    WorkEvidence.hash(path + "|" + (recommendationPolicyRevision ?? policyRevision) + "|" + userRule + "|" + String(bytes / Self.minimumReviewBytes) + "|" + guardReason + "|\(recommendationEligible == true)")
  }
  public var pendingReview: Bool { bytes >= Self.minimumReviewBytes && decision == nil && (reviewable || recommendationEligible == true) }
  public var queueRevision: String { reviewable ? "cleanup|" + revision : "advice|" + adviceRevision }
  public var revision: String { fingerprint + "|" + userRule + "|" + policyRevision }
}
public struct DiskSnapshot: Codable, Sendable {
  public var recommendationVersion: Int? = 2
  public var date: Date = .distantPast
  public var freeBytes: UInt64 = 0
  public var policyRevision = ""
  public var candidates: [DiskCandidate] = []
  public var detail = "Waiting for a bounded disk inventory."
  public init() {}
  public static func load(_ store: Store) throws -> Self {
    let url = store.root.appendingPathComponent("disk-inventory.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
    return try JSONDecoder().decode(Self.self, from: store.read(url, limit: 1_048_576))
  }
  public func save(_ store: Store) throws { try store.write(JSONEncoder.sorted.encode(self), to: store.root.appendingPathComponent("disk-inventory.json"), limit: 1_048_576) }
}
public struct DiskReceipt: Codable, Sendable {
  public var id: UUID
  public var candidateID: String
  public var path: String
  public var date: Date
  public var outcome: String
  public var allocatedRemoved: UInt64
  public var diskReclaimedBytes: UInt64
  public var rationale: String
}
public struct DiskManifest {
  public var bytes: UInt64 = 0
  public var newest: Date = .distantPast
  public var count = 0
  public var fingerprint = ""
  public var complete = true
  public var unsafe = false
}

/// Native code collects facts and enforces scope. The harness decides semantic
/// disposability; no age/size threshold grants deletion authority.
public enum DiskInventory {
  public static let generatedNames: Set<String> = [".cache", "dist-web", "dist", "build", "test-results", "playwright-report"]
  public static func manifest(_ path: String, seconds: Double = 5) throws -> DiskManifest {
    let root = try WorkspaceSafety.statAt(path)
    guard root.st_mode & S_IFMT == S_IFDIR else { throw StoreError.message("Expected a real directory.") }
    var result = DiskManifest(), digest = SHA256()
    result.newest = Date(timeIntervalSince1970: Double(root.st_mtimespec.tv_sec) + Double(root.st_mtimespec.tv_nsec)/1e9)
    let deadline = Date().addingTimeInterval(seconds)
    digest.update(data: Data("\(root.st_dev):\(root.st_ino):\(root.st_mtimespec.tv_sec):\(root.st_mtimespec.tv_nsec)".utf8))
    guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
      errorHandler: { _, _ in result.complete = false; return false }) else { throw StoreError.message("Directory is unreadable.") }
    for case let url as URL in iterator {
      guard result.count < 250_000, Date() < deadline else { result.complete = false; break }
      result.count += 1
      guard let s = try? WorkspaceSafety.statAt(url.path), s.st_dev == root.st_dev else { result.complete = false; iterator.skipDescendants(); continue }
      let name = url.lastPathComponent.lowercased()
      if [".git", "credentials", "keychain", "cookies", "login data"].contains(name) || name.hasPrefix(".env") || name.hasSuffix(".pem") || name.hasSuffix(".key") || name.hasSuffix(".sqlite") || name.hasSuffix(".db") {
        result.unsafe = true
      }
      guard [S_IFREG, S_IFDIR].contains(s.st_mode & S_IFMT), s.st_nlink <= 1 || s.st_mode & S_IFMT == S_IFDIR else { result.unsafe = true; iterator.skipDescendants(); continue }
      let date = Date(timeIntervalSince1970: Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec)/1e9)
      result.newest = max(result.newest, date)
      if s.st_mode & S_IFMT == S_IFREG { result.bytes += UInt64(max(0, s.st_blocks)) * 512 }
      digest.update(data: Data("\(url.path.dropFirst(path.count))|\(s.st_ino)|\(s.st_size)|\(s.st_mtimespec.tv_sec)|\(s.st_mtimespec.tv_nsec)|\(s.st_ctimespec.tv_sec)|\(s.st_ctimespec.tv_nsec)\n".utf8))
    }
    result.fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return result
  }
  public static func repositories(_ policy: DiskPolicy, deadline: Date = .distantFuture) -> [String] {
    var found = Set<String>(), visited = 0
    for root in policy.roots {
      var queue = [(root, 0)]
      while !queue.isEmpty && visited < 10_000 && Date() < deadline {
        let (path, depth) = queue.removeFirst(); visited += 1
        guard let s = try? WorkspaceSafety.statAt(path), s.st_mode & S_IFMT == S_IFDIR,
          !policy.protectedPaths.contains(where: { WorkspaceSafety.contains($0, path) }) else { continue }
        if FileManager.default.fileExists(atPath: path + "/.git") { found.insert(path); continue }
        guard depth < 4, let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
        queue += children.filter { !$0.hasPrefix(".") && !["node_modules", "build", "artifacts", "dist", "vendor"].contains($0) }.sorted().map { (path + "/" + $0, depth + 1) }
      }
    }
    return found.sorted()
  }
  public static func check(_ c: DiskCandidate, policy: DiskPolicy, now: Date = Date(), deadline: Date = Date().addingTimeInterval(15), visibility: (String) -> Int32 = { bz_path_in_use($0) }) throws -> DiskManifest {
    guard c.kind != "worktree", policy.mode != "off", policy.roots.contains(where: { WorkspaceSafety.contains($0, c.path) }),
      !policy.protectedPaths.contains(where: { WorkspaceSafety.contains($0, c.path) || WorkspaceSafety.contains(c.path, $0) }),
      policy.rules.first(where: { $0.path == c.path })?.disposition == "regenerable" else {
      throw StoreError.message("An exact regenerable-folder rule is required. Worktrees stay with their owner.")
    }
    guard c.repository == WorkspaceSafety.canonical(c.repository), c.path == WorkspaceSafety.canonical(c.path), WorkspaceSafety.contains(c.repository, c.path), c.path != c.repository,
      WorkspaceSafety.canonical(WorkspaceSafety.line(try WorkspaceSafety.git(c.repository, ["rev-parse", "--show-toplevel"]))) == c.repository else { throw StoreError.message("Repository identity changed.") }
    let relative = String(c.path.dropFirst(c.repository.count + 1))
    let gitDirectory = WorkspaceSafety.canonical(WorkspaceSafety.line(try WorkspaceSafety.git(c.repository, ["rev-parse", "--absolute-git-dir"])))
    for name in ["locked", "index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
      var entry = stat()
      guard lstat(gitDirectory + "/" + name, &entry) != 0, errno == ENOENT else { throw StoreError.message("Locked or unfinished repository operation; preserved.") }
    }
    let components = relative.split(separator: "/").map(String.init)
    guard (components.count == 1 && generatedNames.contains(components[0])) || (components.count == 2 && components[0] == "artifacts") else {
      throw StoreError.message("Only supported generated output folders qualify; source, dependencies and arbitrary paths are protected.")
    }
    guard try WorkspaceSafety.git(c.repository, ["ls-files", "-z", "--", relative]).isEmpty else { throw StoreError.message("Tracked files are protected.") }
    _ = try WorkspaceSafety.git(c.repository, ["check-ignore", "--", relative])
    guard Date() < deadline else { throw StoreError.message("Disk inspection budget exhausted; preserved.") }
    let manifest = try manifest(c.path, seconds: min(5, deadline.timeIntervalSinceNow))
    guard manifest.complete, !manifest.unsafe, manifest.count > 0, manifest.fingerprint == c.fingerprint, manifest.bytes == c.bytes,
      now.timeIntervalSince(manifest.newest) >= Double(policy.minimumAgeDays) * 86400 else { throw StoreError.message("Changed, recent, special or sensitive files are protected.") }
    if c.kind == "evidence" {
      let parent = URL(fileURLWithPath: c.path).deletingLastPathComponent()
      let entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
      guard entries.count <= 200 else { throw StoreError.message("Evidence retention set exceeds inspection bound.") }
      var newest: [(String, Date)] = []
      for url in entries {
        guard Date() < deadline else { throw StoreError.message("Evidence inspection budget exhausted; preserved.") }
        let item = try Self.manifest(url.path, seconds: min(1, deadline.timeIntervalSinceNow))
        guard item.complete else { throw StoreError.message("Incomplete evidence retention inspection.") }
        newest.append((url.path, item.newest))
      }
      guard !newest.sorted(by: { $0.1 > $1.1 }).prefix(policy.keepNewest).contains(where: { $0.0 == c.path }) else {
        throw StoreError.message("Newest evidence runs must be kept.")
      }
    }
    // A directory allowed by the user still cannot override an active/hidden consumer.
    guard Date() < deadline, visibility(c.repository) == 0 else { throw StoreError.message("Repository has active consumers, incomplete handle visibility or exhausted inspection time; preserve it.") }
    return manifest
  }
  public static func scan(policy: DiskPolicy, previous: DiskSnapshot, now: Date = Date(), seconds: Double = 20, visibility: (String) -> Int32 = { bz_path_in_use($0) }) -> DiskSnapshot {
    var snapshot = DiskSnapshot(); snapshot.date = now; snapshot.policyRevision = policy.revision
    snapshot.freeBytes = (try? WorkspaceSafety.freeBytes(NSHomeDirectory())) ?? 0
    guard policy.mode != "off" else { snapshot.detail = "Disk discovery paused."; return snapshot }
    let deadline = Date().addingTimeInterval(seconds)
    var candidates: [DiskCandidate] = []
    let repos = repositories(policy, deadline: deadline)
    // Rotate repository coverage so a large first checkout cannot starve the rest.
    let start = repos.isEmpty ? 0 : Int(now.timeIntervalSince1970 / Double(policy.scanHours * 3600)) % repos.count
    let ordered = Array(repos.dropFirst(start)) + Array(repos.prefix(start))
    var scanned = Set<String>()
    for repo in ordered where Date() < deadline {
      scanned.insert(repo)
      var paths: [(String, String)] = generatedNames.sorted().map { (repo + "/" + $0, "generated") }
      if let children = try? FileManager.default.contentsOfDirectory(atPath: repo + "/artifacts") {
        paths += children.sorted().prefix(100).map { (repo + "/artifacts/" + $0, "evidence") }
      }
      for (path, kind) in paths where Date() < deadline {
        guard let m = try? manifest(path, seconds: min(3, max(0.05, deadline.timeIntervalSinceNow))), m.bytes >= UInt64(policy.minimumCandidateMB) * 1_000_000 else { continue }
        let rule = policy.rules.first { $0.path == path }
        var c = DiskCandidate(id: "disk:" + WorkEvidence.hash(path), path: path, repository: repo, kind: kind, bytes: m.bytes, newest: m.newest,
          fingerprint: m.fingerprint, complete: m.complete, guardReason: "Needs an exact retention rule; ignored files can still be valuable.", reviewable: false, userRule: rule?.disposition ?? "review")
        c.policyRevision = policy.revision
        c.recommendationPolicyRevision = WorkEvidence.hash(policy.instructions + "|\(policy.minimumAgeDays)|\(policy.keepNewest)|" + (rule?.note ?? ""))
        if rule?.disposition == "keep" { c.guardReason = "Kept by your rule." }
        else if policy.protectedPaths.contains(where: { WorkspaceSafety.contains($0, path) || WorkspaceSafety.contains(path, $0) }) { c.guardReason = "Protected by your folder preferences." }
        else if !m.complete || m.unsafe { c.guardReason = "Incomplete scan or sensitive/special files; preserved." }
        else if now.timeIntervalSince(m.newest) < Double(policy.minimumAgeDays) * 86400 { c.guardReason = "Inside your minimum retention period." }
        else if rule?.disposition == "regenerable" {
          do { _ = try check(c, policy: policy, now: now, deadline: deadline, visibility: visibility); c.reviewable = true; c.guardReason = "Eligible for independent harness review; not a deletion verdict." }
          catch { c.guardReason = error.localizedDescription }
        }
        // Read-only advice can precede deletion permission or complete consumer
        // visibility. It cannot mint a cleanup token or weaken check(_:policy:).
        if c.bytes >= DiskCandidate.minimumReviewBytes, m.complete, !m.unsafe, rule?.disposition != "keep",
          !policy.protectedPaths.contains(where: { WorkspaceSafety.contains($0, path) || WorkspaceSafety.contains(path, $0) }), Date() < deadline {
          let relative = String(path.dropFirst(repo.count + 1))
          if let tracked = try? WorkspaceSafety.git(repo, ["ls-files", "-z", "--", relative]), tracked.isEmpty,
            (try? WorkspaceSafety.git(repo, ["check-ignore", "--", relative])) != nil {
            c.recommendationEligible = true
          }
        }
        candidates.append(c)
      }
      // Whole worktree discovery does not recursively measure it again or authorize adoption.
      if let s = try? WorkspaceSafety.statAt(repo + "/.git"), s.st_mode & S_IFMT == S_IFREG {
        candidates.append(.init(id: "disk:" + WorkEvidence.hash(repo), path: repo, repository: repo, kind: "worktree", bytes: 0, newest: now,
          fingerprint: "owner-managed", complete: true, guardReason: "Use the owning harness's recoverable archive. Age, merged commits and chat closure alone are insufficient.", reviewable: false, userRule: "owner-managed"))
      }
    }
    // Protect the newest evidence runs within each repository, irrespective of aggressiveness.
    for repo in scanned {
      let keep = Set(candidates.filter { $0.repository == repo && $0.kind == "evidence" }.sorted { $0.newest > $1.newest }.prefix(policy.keepNewest).map(\.id))
      for i in candidates.indices where keep.contains(candidates[i].id) { candidates[i].reviewable = false; candidates[i].guardReason = "One of the newest evidence runs; retained." }
    }
    for i in candidates.indices {
      let c = candidates[i]
      if let old = previous.candidates.first(where: { $0.id == c.id && ($0.decisionRevision ?? $0.queueRevision) == c.queueRevision }) {
        candidates[i].decision = old.decision; candidates[i].rationale = old.rationale
        candidates[i].decisionRevision = old.decisionRevision
      }
    }
    candidates += previous.candidates.filter { old in !scanned.contains(old.repository) && policy.roots.contains(where: { WorkspaceSafety.contains($0, old.path) }) }.map { old in
      var c = old; c.reviewable = false; c.recommendationEligible = false; c.guardReason = "Awaiting fresh bounded inspection."; return c
    }
    snapshot.candidates = Array(candidates.sorted { $0.bytes > $1.bytes }.prefix(160))
    snapshot.detail = "Inspected \(scanned.count)/\(repos.count) repositories. Sizes are allocated-file candidates, not guaranteed recoverable space. Incomplete visibility blocks removal."
    return snapshot
  }
}

public struct DiskReviewPolicy: Codable, Sendable {
  public var mode: String
  public var instructions: String
  public var minimumAgeDays: Int
  public var keepNewest: Int
  public init(_ policy: DiskPolicy) {
    mode = policy.mode; instructions = policy.instructions; minimumAgeDays = policy.minimumAgeDays; keepNewest = policy.keepNewest
  }
}
