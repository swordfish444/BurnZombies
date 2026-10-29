import CBurn
import Darwin
import Foundation

enum DiskAdviceError: LocalizedError {
  case invalidText
  var errorDescription: String? { "Supply a short factual recommendation and one concrete next step." }
}

/// Storage facts are deliberately independent of cleanup permissions and folder names.
public struct DiskSpaceNode: Codable, Sendable, Identifiable {
  public var path: String
  public var scanRoot: String
  public var allocated: UInt64
  public var unshared: UInt64
  public var files: UInt64
  public var unknown: UInt64 = 0
  public var errors: UInt64 = 0
  public var hardlinks: UInt64 = 0
  public var dataless: UInt64 = 0
  public var complete: Bool
  public var childrenTruncated = false
  public var measured: Date
  public var members: [String]? = nil
  public var reviewPolicyRevision: String? = nil
  public var supplementaryRevision: String? = nil
  public init(
    path: String, scanRoot: String, allocated: UInt64, unshared: UInt64, files: UInt64,
    unknown: UInt64 = 0, errors: UInt64 = 0, hardlinks: UInt64 = 0, dataless: UInt64 = 0,
    complete: Bool, childrenTruncated: Bool = false, measured: Date
  ) {
    self.path = path
    self.scanRoot = scanRoot
    self.allocated = allocated
    self.unshared = unshared
    self.files = files
    self.unknown = unknown
    self.errors = errors
    self.hardlinks = hardlinks
    self.dataless = dataless
    self.complete = complete
    self.childrenTruncated = childrenTruncated
    self.measured = measured
  }
  public var id: String {
    "space:" + WorkEvidence.hash(path + "|" + (members == nil ? "folder" : "group"))
  }
  public var revision: String {
    let sizes = "\(allocated / 10_000_000_000)|\(unshared / 10_000_000_000)"
    let coverage = "\(complete)|\(errors > 0)|\(unknown > 0)|\(dataless > 0)"
    let memberKey = members?.joined(separator: "|") ?? ""
    return WorkEvidence.hash(
      [id, sizes, coverage, memberKey, reviewPolicyRevision ?? "", supplementaryRevision ?? ""].joined(separator: "|"))
  }
  public var folderCount: Int { members?.count ?? 1 }
}
public struct DiskAdvice: Codable, Sendable, Identifiable {
  public var id: String
  public var revision: String
  public var title: String
  public var summary: String
  public var nextStep: String
  public var disposition: String
  public var date: Date
  public init(
    id: String, revision: String, title: String, summary: String, nextStep: String,
    disposition: String, date: Date
  ) {
    self.id = id
    self.revision = revision
    self.title = title
    self.summary = summary
    self.nextStep = nextStep
    self.disposition = disposition
    self.date = date
  }
}
/// Public tool projection: group members stay in the private index, not model context.
public struct DiskSpaceSummary: Codable, Sendable {
  public var id: String
  public var path: String
  public var allocated: UInt64
  public var unshared: UInt64
  public var files: UInt64
  public var folders: Int
  public var complete: Bool
  public var coverageGaps: UInt64
  public var childrenTruncated: Bool
  public init(_ node: DiskSpaceNode) {
    id = node.id
    path = node.path
    allocated = node.allocated
    unshared = node.unshared
    files = node.files
    folders = node.folderCount
    complete = node.complete
    coverageGaps = node.errors + node.unknown + node.dataless
    childrenTruncated = node.childrenTruncated
  }
}
public struct DiskDiscoveryState: Codable, Sendable {
  public var nodes: [DiskSpaceNode] = []
  public var advice: [String: DiskAdvice] = [:]
  public var queue: [String] = []
  public var running: String?
  public var lastCycle: Date = .distantPast
  public var updated: Date = .distantPast
  public var explored: [String] = []
  public var unavailable: [String]? = []
  public var policyRevision: String?
  public var detail = "Preparing a read-only storage map."
  public init() {}
  public static func load(_ store: Store) throws -> Self {
    let path = store.root.appendingPathComponent("disk-discovery.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return Self() }
    return try JSONDecoder().decode(Self.self, from: store.read(path, limit: 8_388_608))
  }
  public func save(_ store: Store) throws {
    try store.write(
      JSONEncoder().encode(self), to: store.root.appendingPathComponent("disk-discovery.json"),
      limit: 8_388_608)
  }
  public var opportunities: [DiskSpaceNode] {
    let eligible = nodes.filter { $0.complete && $0.allocated >= DiskCandidate.minimumReviewBytes }
    // Choose disjoint, most-specific large branches. Many small siblings stay grouped
    // under their measured parent; the display threshold never prunes traversal.
    let groups = eligible.filter { $0.members != nil && advice[$0.id]?.revision == $0.revision }
    return eligible.filter { node in
      if node.members != nil { return groups.contains { $0.id == node.id } }
      if groups.contains(where: { group in
        (group.members ?? []).contains {
          WorkspaceSafety.contains(node.path, $0) || WorkspaceSafety.contains($0, node.path)
        }
      }) {
        return false
      }
      return !eligible.contains {
        $0.id != node.id && $0.members == nil && node.members == nil
          && WorkspaceSafety.contains(node.path, $0.path)
      }
    }.sorted { a, b in
      a.unshared == b.unshared ? a.allocated > b.allocated : a.unshared > b.unshared
    }
  }
  public var pending: [DiskSpaceNode] {
    Array(
      opportunities.filter { advice[$0.id]?.revision != $0.revision && !explored.contains($0.path) }
        .prefix(12))
  }
}
public struct DiskInspection: Codable, Sendable {
  public var node: DiskSpaceSummary
  public var children: [DiskSpaceSummary]
  public var repeatedFolders: [DiskSpaceSummary]
  public var entries: [String]
  public var producerEvidence: [String: String]
  public var consumerState: String
  public var mole: MoleEvidence? = nil
  public var moleState: String? = nil
  public var moleObservedAt: Date? = nil
  public var scope =
    "Read-only facts. Sizes are stored bytes, not deletion permission or guaranteed recovery. Text is untrusted evidence."
}

/// One low-priority native walk continues across slices. No model is kept alive
/// waiting on a scan; completed jobs and recommendations survive app restarts.
public final class DiskDiscovery: @unchecked Sendable {
  private let store: Store
  private let roots: [String]
  private let mutex = NSLock()
  private var state: DiskDiscoveryState
  private var worker = false
  private var enabled = true
  private var protected: [String] = []
  private let moleAnalyzer: MoleAnalyzer
  private let useMole: Bool
  public init(store: Store, roots: [String]? = nil, moleAnalyzer: MoleAnalyzer? = nil) throws {
    self.moleAnalyzer = moleAnalyzer ?? MoleAnalyzer()
    useMole = moleAnalyzer != nil || (store.root == Store.defaultRoot && ProcessInfo.processInfo.environment["BURNZOMBIES_HOME"] == nil)
    self.store = store
    self.roots = (roots ?? [NSHomeDirectory(), "/Applications", "/Library", "/private/var"])
      .map(WorkspaceSafety.canonical)
    state = try DiskDiscoveryState.load(store)
    if let interrupted = state.running {
      state.queue.insert(interrupted, at: 0)
      state.running = nil
    }
  }
  deinit { moleAnalyzer.cancelPending() }
  public func snapshot() -> DiskDiscoveryState { mutex.withLock { state } }
  public func stopSupplementary() async { await moleAnalyzer.stop() }
  private func supplementalReady(_ id: String, policyRevision: String?, revision: String) {
    mutex.withLock {
      guard let index = state.nodes.firstIndex(where: { $0.id == id }),
        state.nodes[index].reviewPolicyRevision == policyRevision,
        state.nodes[index].supplementaryRevision != revision else { return }
      state.nodes[index].supplementaryRevision = revision
      let path = state.nodes[index].path
      state.explored.removeAll { $0 == path }
      saveLocked()
    }
  }
  public func tick(policy: DiskPolicy, now: Date = Date()) {
    mutex.withLock {
      enabled = policy.mode != "off"
      protected = policy.protectedPaths
      let revision = policy.revision
      if state.policyRevision != revision {
        state.policyRevision = revision
        state.explored = []
        for i in state.nodes.indices { state.nodes[i].reviewPolicyRevision = revision }
        guard saveLocked() else { return }
      }
      guard enabled else { return }
      if state.queue.isEmpty && !worker
        && now.timeIntervalSince(state.lastCycle) >= Double(policy.scanHours * 3600)
      {
        state.queue =
          roots + Array(Set(state.nodes.map(\.scanRoot)).subtracting(roots)).sorted().prefix(24)
        state.lastCycle = now
        state.explored = []
        state.unavailable = []
      }
      startLocked()
    }
  }
  private func startLocked() {
    guard enabled, !worker, !state.queue.isEmpty else { return }
    worker = true
    DispatchQueue.global(qos: .background).async { [self] in run() }
  }
  @discardableResult private func saveLocked() -> Bool {
    do {
      state.updated = Date()
      try state.save(store)
      return true
    } catch {
      state.detail = "Storage discovery could not save its progress: \(error.localizedDescription)"
      enabled = false
      return false
    }
  }
  private func run() {
    while let path = mutex.withLock({ () -> String? in
      guard enabled, !state.queue.isEmpty else {
        worker = false
        return nil
      }
      let p = state.queue.removeFirst()
      state.running = p
      state.detail =
        "Mapping storage locally. AI reviews start only when new measurements are ready."
      saveLocked()
      return p
    }) {
      guard roots.contains(where: { WorkspaceSafety.contains($0, path) }),
        path == WorkspaceSafety.canonical(path), let walk = bz_disk_open(path, 3)
      else {
        mutex.withLock {
          state.running = nil
          state.unavailable = Array(Set((state.unavailable ?? []) + [path])).sorted()
          state.detail =
            "Some storage is unavailable or online-only. It has not been treated as empty."
          saveLocked()
        }
        continue
      }
      var done = false
      var lastPublish = Date.distantPast
      while mutex.withLock({ enabled }) && !done {
        done = bz_disk_step(walk, 2000) != 0
        if done || Date().timeIntervalSince(lastPublish) >= 15 {
          var values = Self.read(walk, root: path, complete: done)
          mutex.withLock {
            let priorSupplements = Dictionary(uniqueKeysWithValues: state.nodes.filter { $0.members == nil }
              .map { ($0.path, $0.supplementaryRevision) })
            for i in values.indices {
              values[i].reviewPolicyRevision = state.policyRevision
              values[i].supplementaryRevision = priorSupplements[values[i].path] ?? nil
            }
            // Prefer the latest measurement for identical paths. Never add an
            // ancestor's size to its descendants' sizes.
            let paths = Set(values.map(\.path))
            state.nodes.removeAll {
              $0.members == nil && ($0.scanRoot == path || paths.contains($0.path))
            }
            state.nodes += values
            if done {
              let byPath = Dictionary(uniqueKeysWithValues: values.map { ($0.path, $0) })
              for i in state.nodes.indices {
                guard let members = state.nodes[i].members,
                  members.contains(where: { byPath[$0] != nil })
                else { continue }
                let measured = members.compactMap { byPath[$0] }
                guard measured.count == members.count else {
                  state.nodes[i].complete = false
                  continue
                }
                state.nodes[i].allocated = measured.reduce(0) { $0 + $1.allocated }
                state.nodes[i].unshared = measured.reduce(0) { $0 + $1.unshared }
                state.nodes[i].files = measured.reduce(0) { $0 + $1.files }
                state.nodes[i].unknown = measured.reduce(0) { $0 + $1.unknown }
                state.nodes[i].errors = measured.reduce(0) { $0 + $1.errors }
                state.nodes[i].dataless = measured.reduce(0) { $0 + $1.dataless }
                state.nodes[i].measured = Date()
                state.nodes[i].complete = true
              }
            }
            state.nodes = Array(state.nodes.sorted { $0.measured > $1.measured }.prefix(12_000))
            if done {
              state.running = nil
              state.detail =
                (state.unavailable ?? []).isEmpty
                ? "Storage mapped. Recommendations use saved evidence and focused AI reviews."
                : "Storage mapped with \(state.unavailable?.count ?? 0) unavailable locations. Missing visibility is not empty space."
            }
            saveLocked()
          }
          lastPublish = Date()
        }
        if !done { Thread.sleep(forTimeInterval: 0.01) }
      }
      bz_disk_close(walk)
      if !done {
        mutex.withLock {
          state.queue.insert(path, at: 0)
          state.running = nil
          saveLocked()
        }
      }
    }
  }
  private static func read(_ walk: UnsafeMutableRawPointer, root: String, complete: Bool)
    -> [DiskSpaceNode]
  {
    var result: [DiskSpaceNode] = []
    var now = Date()
    for i in 0..<bz_disk_count(walk) {
      var n = bz_disk_node()
      guard bz_disk_node_at(walk, i, &n) != 0 else { continue }
      let path = withUnsafePointer(to: &n.path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
      }
      result.append(
        .init(
          path: path, scanRoot: root, allocated: n.allocated, unshared: n.unshared, files: n.files,
          unknown: n.unknown, errors: n.errors, hardlinks: n.links, dataless: n.dataless,
          complete: complete || n.finished != 0,
          childrenTruncated: bz_disk_overflow(walk) != 0, measured: now))
    }
    return result
  }
  /// Used by tests and the explicit headless audit command, never a second monitor.
  public static func measure(_ path: String) throws -> [DiskSpaceNode] {
    guard let walk = bz_disk_open(path, 3) else {
      throw StoreError.message("Storage directory is unavailable.")
    }
    defer { bz_disk_close(walk) }
    while bz_disk_step(walk, 5000) == 0 {}
    return read(walk, root: path, complete: true)
  }
  private func resolved(_ id: String, allowed: [String]?) throws -> DiskSpaceNode {
    guard let node = state.nodes.first(where: { $0.id == id }), node.complete,
      allowed == nil || allowed!.contains(id)
        || state.nodes.contains(where: { parent in
          allowed!.contains(parent.id) && parent.members == nil
            && WorkspaceSafety.contains(parent.path, node.path)
        }),
      !(node.members ?? [node.path]).contains(where: { p in
        protected.contains { WorkspaceSafety.contains($0, p) }
      })
    else {
      throw StoreError.message(
        "Use a measured directory within this review's supplied storage branch. Protected or unknown paths cannot be inspected."
      )
    }
    return node
  }
  public func explore(_ id: String, allowed: [String]? = nil) throws -> String {
    try mutex.withLock {
      let node = try resolved(id, allowed: allowed)
      guard node.members == nil, roots.contains(where: { WorkspaceSafety.contains($0, node.path) }),
        node.path == WorkspaceSafety.canonical(node.path),
        node.path.split(separator: "/").count < 24,
        state.explored.count < 24
      else { throw StoreError.message("Discovery scope or per-cycle exploration limit reached.") }
      if state.running == node.path || state.queue.contains(node.path) {
        return "This branch is already being mapped. Finish now; do not poll."
      }
      if !state.explored.contains(node.path) { state.explored.append(node.path) }
      state.queue.insert(node.path, at: 0)
      guard saveLocked() else { throw StoreError.message(state.detail) }
      startLocked()
      return
        "Deeper read-only mapping queued. New evidence will be reviewed later in a later scheduled review. Finish now; do not wait or poll."
    }
  }
  public func inspect(
    _ id: String, allowed: [String]? = nil, visibility: ((String) -> Int32)? = nil
  ) throws -> DiskInspection {
    let (node, children, groups) = try mutex.withLock {
      () -> (DiskSpaceNode, [DiskSpaceNode], [DiskSpaceNode]) in
      let node = try resolved(id, allowed: allowed)
      let children = state.nodes.filter {
        $0.members == nil
          && URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == node.path
      }
      .sorted { $0.allocated > $1.allocated }
      let descendants = state.nodes.filter {
        $0.members == nil && $0.path != node.path && WorkspaceSafety.contains(node.path, $0.path)
      }
      // Group equal leaf names only at equal depth, so parent/child bytes never overlap.
      let byName = Dictionary(grouping: descendants) {
        "\($0.path.split(separator: "/").count)|\(URL(fileURLWithPath: $0.path).lastPathComponent)"
      }
      var groups: [DiskSpaceNode] = []
      for members in byName.values where members.count >= 3 {
        let bytes = members.reduce(UInt64(0)) { $0 + $1.allocated }
        guard bytes >= DiskCandidate.minimumReviewBytes else { continue }
        let name = URL(fileURLWithPath: members[0].path).lastPathComponent
        var group = DiskSpaceNode(
          path: node.path + "/[group] " + name, scanRoot: node.scanRoot, allocated: bytes,
          unshared: members.reduce(0) { $0 + $1.unshared },
          files: members.reduce(0) { $0 + $1.files },
          unknown: members.reduce(0) { $0 + $1.unknown },
          errors: members.reduce(0) { $0 + $1.errors },
          hardlinks: members.reduce(0) { $0 + $1.hardlinks },
          dataless: members.reduce(0) { $0 + $1.dataless },
          complete: members.allSatisfy(\.complete), measured: node.measured)
        group.members = members.map(\.path).sorted()
        group.reviewPolicyRevision = node.reviewPolicyRevision
        groups.append(group)
      }
      groups = Array(groups.sorted { $0.unshared > $1.unshared }.prefix(8))
      for group in groups {
        state.nodes.removeAll { $0.id == group.id }
        state.nodes.append(group)
      }
      if !groups.isEmpty { saveLocked() }
      return (node, Array(children.prefix(12)), groups)
    }
    let paths = node.members ?? [node.path]
    var evidence: [String: String] = [:]
    var entries: [String] = []
    for path in paths.prefix(2) {
      guard path == WorkspaceSafety.canonical(path),
        roots.contains(where: { WorkspaceSafety.contains($0, path) })
      else { continue }
      if let iterator = FileManager.default.enumerator(atPath: path) {
        for case let name as String in iterator {
          iterator.skipDescendants()
          entries.append(name)
          if entries.count >= 32 { break }
        }
      }
      var parent = URL(fileURLWithPath: path)
      for _ in 0..<4 {
        guard roots.contains(where: { WorkspaceSafety.contains($0, parent.path) }) else { break }
        for name in [
          "package.json", "manifest.json", ".gitignore", "Cargo.toml", "pyproject.toml",
          "Package.swift", "build.gradle", "build.gradle.kts", "CMakeLists.txt",
        ] where evidence.count < 4 {
          let file = parent.appendingPathComponent(name)
          if let text = Self.manifest(file.path) { evidence[file.path] = text }
        }
        parent.deleteLastPathComponent()
      }
    }
    // A group can contain hundreds of paths; do not claim complete consumer visibility
    // from a sample. Destructive operations still run their independent full guards.
    // Read-only discovery must not enumerate every process descriptor on the request path.
    // Explicit visibility is a fixture seam; production cleanup uses its independent full guard.
    let use = paths.count == 1 ? (visibility?(paths[0]) ?? -1) : -1
    var result = DiskInspection(
      node: DiskSpaceSummary(node), children: children.map(DiskSpaceSummary.init),
      repeatedFolders: groups.map(DiskSpaceSummary.init), entries: entries,
      producerEvidence: evidence,
      consumerState: use > 0
        ? "Visible active consumer; preserve."
        : use == 0
          ? "No consumer found by the native guard at inspection time. Recheck before any action."
          : "Incomplete consumer visibility: not checked by this read-only inspection; raw cleanup remains blocked until the independent action guard succeeds.")
    if node.members == nil, node.dataless == 0, node.errors == 0, node.unknown == 0, useMole {
      let supplement = moleAnalyzer.request(node.path, store: store,
        protected: mutex.withLock { protected }) { [weak self] revision in
          self?.supplementalReady(node.id, policyRevision: node.reviewPolicyRevision, revision: revision)
        }
      result.mole = supplement.evidence
      result.moleState = supplement.status
      result.moleObservedAt = supplement.observedAt
    } else { result.moleState = "unavailable" }
    return result
  }
  private static func manifest(_ path: String) -> String? {
    guard path == WorkspaceSafety.canonical(path) else { return nil }
    var before = stat()
    guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_flags & UInt32(SF_DATALESS) == 0
    else { return nil }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var actual = [CChar](repeating: 0, count: 4096)
    guard fcntl(fd, F_GETPATH, &actual) == 0, String(cString: actual) == path else { return nil }
    var s = stat()
    guard fstat(fd, &s) == 0, s.st_dev == before.st_dev, s.st_ino == before.st_ino,
      s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_size <= 65536,
      s.st_flags & UInt32(SF_DATALESS) == 0
    else { return nil }
    guard
      let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65536),
      let value = String(data: data, encoding: .utf8)
    else { return nil }
    // JSON values are projected, never arbitrary manifest data or credentials.
    if path.hasSuffix(".json") {
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
      }
      let names: Set<String> = [
        "name", "scripts", "complete", "producer_head", "producer_dirty", "producer_path",
        "generatedBy", "schema", "inputs", "outputs", "status", "outcome", "sourceRevision",
        "retention",
      ]
      let projected = object.filter { names.contains($0.key) }
      guard !projected.isEmpty,
        let bytes = try? JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys]),
        let text = String(data: bytes, encoding: .utf8)
      else { return nil }
      return redact(text)
    }
    return redact(value)
  }
  public func readEvidence(_ id: String, relativePath: String, allowed: [String]? = nil) throws
    -> [String: String]
  {
    let node = try mutex.withLock { try resolved(id, allowed: allowed) }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    let extensions: Set<String> = [
      "md", "toml", "yaml", "yml", "swift", "gradle", "kts", "js", "mjs", "cjs", "ts", "py", "rs",
      "go", "sh", "json",
    ]
    let forbidden = [
      "secret", "credential", "password", "token", "session", "history", "transcript", "cookie",
      "keychain", "profile", "auth",
    ]
    guard node.members == nil, !relativePath.isEmpty, relativePath.count <= 512,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }),
      !forbidden.contains(where: relativePath.lowercased().contains),
      extensions.contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased())
    else {
      throw StoreError.message(
        "Read only a bounded source, build manifest or retention document inside the measured branch. Private state and transcripts are excluded."
      )
    }
    let path = URL(fileURLWithPath: node.path).appendingPathComponent(relativePath).path
    guard WorkspaceSafety.contains(node.path, path), path == WorkspaceSafety.canonical(path),
      !mutex.withLock({ protected.contains { WorkspaceSafety.contains($0, path) } }),
      let text = Self.manifest(path)
    else {
      throw StoreError.message(
        "Evidence is unavailable, protected, linked, online-only or oversized; preserve uncertainty."
      )
    }
    return [relativePath: text]
  }
  private static func redact(_ value: String) -> String {
    let lines = value.split(separator: "\n").filter {
      let text = $0.lowercased()
      return ![
        "password", "secret", "token", "api_key", "apikey", "credential", "authorization",
        "private key",
      ].contains(where: text.contains)
        && text.range(of: "://[^/ ]+@", options: .regularExpression) == nil
    }
    return String(lines.joined(separator: "\n").prefix(1600))
  }
  public func recommend(
    _ id: String, disposition: String, title: String, summary: String, nextStep: String,
    allowed: [String]? = nil
  ) throws -> String {
    try mutex.withLock {
      let node = try resolved(id, allowed: allowed)
      guard ["keep", "investigate", "owner-cleanup", "rebuildable"].contains(disposition),
        (3...80).contains(title.count), (20...500).contains(summary.count),
        (10...280).contains(nextStep.count)
      else {
        throw DiskAdviceError.invalidText
      }
      let selected = node.members ?? [node.path]
      for other in state.nodes where other.id != id && state.advice[other.id] != nil {
        if (other.members ?? [other.path]).contains(where: { p in
          selected.contains { WorkspaceSafety.contains(p, $0) || WorkspaceSafety.contains($0, p) }
        }) {
          state.advice.removeValue(forKey: other.id)
        }
      }
      state.advice[id] = .init(
        id: id, revision: node.revision, title: title, summary: summary, nextStep: nextStep,
        disposition: disposition, date: Date())
      guard saveLocked() else { throw StoreError.message(state.detail) }
      return "Recommendation saved. No cleanup permission, preference, or user file was changed."
    }
  }
}
