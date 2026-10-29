import CBurn
import Darwin
import Foundation

/// Optional external analyzer. No Mole source is bundled and no deleting command is exposed.
public struct MoleEvidence: Codable, Sendable {
  public struct Entry: Codable, Sendable {
    public var path: String
    public var bytes: UInt64
    public var scanStatus: String
    public var cleanupHint: Bool
  }
  public var provider = "Mole analyze"
  public var scanStatus: String
  public var entries: [Entry]
  public var scope =
    "Read-only hints. cleanable is not proof of disposability or permission. Partial/unavailable results preserve uncertainty. Native APFS measurements govern recovery totals."

  public static func decode(_ data: Data, root: String, protected: [String] = []) throws -> Self {
    struct Row: Decodable {
      var path: String
      var size: Int64
      var scan_status: String
      var cleanable: Bool?
    }
    struct Output: Decodable {
      var path: String
      var scan_status: String
      var entries: [Row]
    }
    guard data.count <= 1_048_576 else {
      throw StoreError.message("Mole output exceeded its bound.")
    }
    let output = try JSONDecoder().decode(Output.self, from: data)
    let statuses: Set<String> = ["complete", "partial", "unavailable"]
    guard output.path == root, statuses.contains(output.scan_status), output.entries.count <= 10_000
    else {
      throw StoreError.message("Mole returned a different path or unsupported scan state.")
    }
    let entries = output.entries.filter { row in
      row.size >= 0 && statuses.contains(row.scan_status) && row.path != root
        && WorkspaceSafety.contains(root, row.path)
        && row.path == WorkspaceSafety.canonical(row.path)
        && !protected.contains(where: { p in
          WorkspaceSafety.contains(p, row.path) || WorkspaceSafety.contains(row.path, p)
        })
    }.sorted { $0.size > $1.size }.prefix(12).map {
      Entry(
        path: $0.path, bytes: UInt64($0.size), scanStatus: $0.scan_status,
        cleanupHint: $0.cleanable == true && output.scan_status == "complete"
          && $0.scan_status == "complete")
    }
    return .init(scanStatus: output.scan_status, entries: entries)
  }
  fileprivate struct Saved: Codable {
    var date: Date
    var value: MoleEvidence?
  }
  fileprivate static func cacheFile(_ path: String, store: Store, protected: [String]) -> URL? {
    guard path == WorkspaceSafety.canonical(path),
      !protected.contains(where: {
        WorkspaceSafety.contains($0, path) || WorkspaceSafety.contains(path, $0)
      }), let identity = try? WorkspaceSafety.statAt(path),
      identity.st_mode & S_IFMT == S_IFDIR, identity.st_flags & UInt32(SF_DATALESS) == 0
    else { return nil }
    return store.root.appendingPathComponent("mole-analysis-" + WorkEvidence.hash(
      path + "|\(identity.st_dev):\(identity.st_ino)|" + protected.sorted().joined(separator: "|")) + ".json")
  }
  fileprivate static func cached(_ file: URL, store: Store) -> Saved? {
    guard let data = try? store.read(file, limit: 16384),
      let saved = try? JSONDecoder().decode(Saved.self, from: data),
      (0..<21600).contains(Date().timeIntervalSince(saved.date)) else { return nil }
    return saved
  }
  public static func analyze(_ path: String, store: Store, protected: [String]) -> Self? {
    // Protected descendants prevent the whole external invocation: Mole has no exclusion contract.
    guard let cache = cacheFile(path, store: store, protected: protected) else { return nil }
    if let saved = cached(cache, store: store) { return saved.value }
    // Fixed Homebrew locations avoid PATH/repository command substitution. The bundled
    // Go analyzer runs directly; its own du/Spotlight helpers share our bounded group.
    let binaries = [
      "/opt/homebrew/opt/mole/libexec/bin/analyze-go", "/usr/local/opt/mole/libexec/bin/analyze-go",
    ]
    guard let binary = binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    var result: Self?
    defer {
      if let bytes = try? JSONEncoder().encode(Saved(date: Date(), value: result)) {
        try? store.write(bytes, to: cache, limit: 16384)
      }
    }
    let output = store.root.appendingPathComponent("mole-output-" + UUID().uuidString)
    let fd = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: output)
    }
    var argv =
      [binary, "--json", path].map { (value: String) in value.withCString { strdup($0) } } + [nil]
    var environment =
      ["HOME=" + NSHomeDirectory(), "PATH=/usr/bin:/bin", "LC_ALL=C", "NO_COLOR=1"]
      .map { (value: String) in value.withCString { strdup($0) } } + [nil]
    defer {
      argv.forEach { free($0) }
      environment.forEach { free($0) }
    }
    guard bz_capture_tool(&argv, &environment, fd, 8000, 1_048_576) == 0 else { return nil }
    do {
      try handle.seek(toOffset: 0)
      result = try decode(
        handle.read(upToCount: 1_048_577) ?? Data(), root: path, protected: protected)
    } catch { return nil }
    return result
  }
}

/// Optional analysis never occupies a request handler. One eight-second analyzer group
/// runs at a time; at most eight distinct branches wait, with no automatic retries.
public struct MoleAnalysisState: Codable, Sendable {
  public var status: String
  public var evidence: MoleEvidence?
  public var observedAt: Date?
}

public final class MoleAnalyzer: @unchecked Sendable {
  public typealias Analysis = @Sendable (String, Store, [String]) -> MoleEvidence?
  private struct Job {
    let key: String
    let path: String
    let store: Store
    let protected: [String]
    let ready: @Sendable (String) -> Void
  }
  private let lock = NSLock()
  private let analysis: Analysis
  private var queue: [Job] = []
  private var results: [String: MoleAnalysisState] = [:]
  private var worker = false
  private var stopped = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  public init(analysis: @escaping Analysis = { MoleEvidence.analyze($0, store: $1, protected: $2) }) {
    self.analysis = analysis
  }
  public func request(_ path: String, store: Store, protected: [String],
    ready: @escaping @Sendable (String) -> Void = { _ in }) -> MoleAnalysisState {
    guard let file = MoleEvidence.cacheFile(path, store: store, protected: protected) else {
      return .init(status: "unavailable", evidence: nil, observedAt: nil)
    }
    if let saved = MoleEvidence.cached(file, store: store) {
      return .init(status: saved.value == nil ? "unavailable" : "cached",
        evidence: saved.value, observedAt: saved.date)
    }
    return lock.withLock {
      let key = file.path
      if let old = results[key], old.observedAt == nil || (0..<21600).contains(Date().timeIntervalSince(old.observedAt!)) {
        return old
      }
      guard !stopped else { return .init(status: "unavailable", evidence: nil, observedAt: nil) }
      guard queue.count < 8 else { return .init(status: "deferred", evidence: nil, observedAt: nil) }
      // Bound retained in-memory results independently of the finite work queue.
      if results.count >= 64, let oldest = results.filter({ $0.value.observedAt != nil })
        .min(by: { $0.value.observedAt! < $1.value.observedAt! })?.key {
        results.removeValue(forKey: oldest)
      }
      let pending = MoleAnalysisState(status: "queued", evidence: nil, observedAt: nil)
      results[key] = pending
      queue.append(.init(key: key, path: path, store: store, protected: protected, ready: ready))
      if !worker {
        worker = true
        DispatchQueue.global(qos: .utility).async { [self] in run() }
      }
      return pending
    }
  }
  private func run() {
    while let job = lock.withLock({ () -> Job? in
      guard !stopped, !queue.isEmpty else {
        worker = false
        let completions = waiters; waiters = []
        completions.forEach { $0.resume() }
        return nil
      }
      let job = queue.removeFirst()
      results[job.key]?.status = "running"
      return job
    }) {
      let value = analysis(job.path, job.store, job.protected)
      let result = MoleAnalysisState(status: value == nil ? "unavailable" : "cached",
        evidence: value, observedAt: Date())
      let deliver = lock.withLock { () -> Bool in
        results[job.key] = result
        return !stopped
      }
      if deliver {
        // Evidence identity, not completion time, makes new facts reviewable once.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(value)) ?? Data()
        job.ready(WorkEvidence.hash(result.status + String(decoding: encoded, as: UTF8.self)))
      }
    }
  }
  public func cancelPending() {
    lock.withLock {
      stopped = true
      for job in queue { results.removeValue(forKey: job.key) }
      queue = []
    }
  }
  public func stop() async {
    cancelPending()
    // The production analyzer owns and tears down its process group in <= 8 seconds.
    await withCheckedContinuation { continuation in
      lock.withLock {
        if worker { waiters.append(continuation) } else { continuation.resume() }
      }
    }
  }
}
