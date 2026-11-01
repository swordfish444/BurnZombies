import CBurn
import Darwin
import Foundation

final class WorktreeScanControl: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = true
  var active: Bool { lock.withLock { enabled } }
  func cancel() { lock.withLock { enabled = false } }
}

private final class WorktreePathBox {
  var paths = Set<String>()
  var invalid = false
  let roots: [String]
  init(roots: [String]) { self.roots = roots }
}
public struct WorktreeConsumerSnapshot: Sendable {
  public let paths: Set<String>
  public let gap: String?
  private let roots: [String]
  public init(roots: [String] = []) {
    let box = WorktreePathBox(roots: roots.map(WorkspaceSafety.canonical))
    self.roots = box.roots
    var detail = [CChar](repeating: 0, count: 256)
    let status = bz_worktree_paths(
      { context, path in
        guard let context, let path else { return }
        let b = Unmanaged<WorktreePathBox>.fromOpaque(context).takeUnretainedValue()
        guard let value = String(validatingUTF8: path), value.isEmpty || value.hasPrefix("/") else {
          b.invalid = true
          return
        }
        // Kernel vnode paths are physical file-backed paths. Project the
        // requested roots before retaining metadata from unrelated large VMs.
        if !b.roots.isEmpty && !b.roots.contains(where: { WorkspaceSafety.contains($0, value) }) {
          return
        }
        guard b.paths.contains(value) || b.paths.count < 500_000 else {
          b.invalid = true
          return
        }
        b.paths.insert(value)
      }, Unmanaged.passUnretained(box).toOpaque(), &detail, detail.count)
    paths = Set(box.paths.map(WorkspaceSafety.canonical))
    gap =
      status == 0 && !box.invalid
      ? nil
      : (box.invalid
        ? "Path snapshot exceeded its bounds or encoding support." : String(cString: detail))
  }
  public func state(_ path: String) -> Int32 {
    if !roots.isEmpty && !roots.contains(where: { WorkspaceSafety.contains($0, path) }) {
      return -1
    }
    if paths.contains(where: { WorkspaceSafety.contains(path, $0) }) { return 1 }
    return gap == nil ? 0 : -1
  }
}

struct WorktreeScanEnvelope: Codable {
  var run: String
  var record: WorktreeRecord?
  var gap: String?
  var complete = false
  var cursor: Int?
  var unavailablePath: String?
  var inspecting: String?
  var deferred: Bool?
}

public enum WorktreeScanWorker {
  public static func run(
    arguments: [String], access: () -> FullDiskAccessStatus = { FullDiskAccess.status() }
  ) -> Int32 {
    guard arguments.count >= 3, let run = arguments.first, UUID(uuidString: run) != nil,
      let cursor = Int(arguments[1]), (0...100_000).contains(cursor),
      arguments.count <= 35,
      arguments.dropFirst(2).allSatisfy({ $0.hasPrefix("/") && $0.utf8.count < 4096 }),
      access().canScan
    else { return 64 }
    func emit(
      _ record: WorktreeRecord? = nil, gap: String? = nil, complete: Bool = false,
      cursor: Int? = nil, unavailablePath: String? = nil, inspecting: String? = nil,
      deferred: Bool? = nil
    ) {
      if let data = try? WorktreeEncoding.data(
        WorktreeScanEnvelope(
          run: run, record: record, gap: gap, complete: complete, cursor: cursor,
          unavailablePath: unavailablePath, inspecting: inspecting, deferred: deferred)
      ) {
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
      }
    }
    emit()
    let started = ProcessInfo.processInfo.systemUptime
    let knownOnly = ProcessInfo.processInfo.environment["BURNZOMBIES_WORKTREE_REFRESH"] == "1"
    let roots = Array(arguments.dropFirst(2))
    if knownOnly {
      do {
        let store = try Store()
        let input = store.root.appendingPathComponent("worktree-refresh-" + run + ".json")
        let rows = try JSONDecoder().decode(
          [WorktreeRecord].self, from: store.read(input, limit: 2_097_152))
        guard !rows.isEmpty, rows.count <= 8, Set(rows.map(\.id)).count == rows.count,
          rows.map(\.path) == roots, rows.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count < 4096 })
        else { return 64 }
        // Inspect recorded identities directly. Rediscovery by path can report a
        // replacement repository instead and leave the original row stale forever.
        var consumers: WorktreeConsumerSnapshot?
        for row in rows {
          // Reserve a useful inspection slice. Exhausting the batch is normal
          // bounded progress, not a loss of the observations already completed.
          guard ProcessInfo.processInfo.systemUptime - started < 9 else {
            emit(complete: true, deferred: true)
            return 0
          }
          emit(inspecting: row.id)
          emit(
            WorktreeInspection.inspect(
              row,
              visibility: { path in
                if consumers == nil {
                  consumers = WorktreeConsumerSnapshot(roots: roots)
                  if let gap = consumers?.gap { emit(gap: "Consumer coverage: " + gap) }
                }
                return consumers?.state(path) ?? -1
              }))
        }
        emit(complete: true, cursor: 0)
        return 0
      } catch {
        emit(gap: "Known worktree request unavailable: " + error.localizedDescription)
        return 65
      }
    }
    let consumers = WorktreeConsumerSnapshot(roots: roots)
    if let gap = consumers.gap { emit(gap: "Consumer coverage: " + gap) }
    let result = WorktreeDiscovery.scan(
      roots: roots,
      seconds: 240,
      visibility: { consumers.state($0) }, inspectOffset: cursor, publish: { emit($0) },
      progress: { emit() },
      checkpoint: Store.defaultRoot.appendingPathComponent("worktree-discovery-cursor.json"))
    for (path, gap) in result.unavailablePaths { emit(gap: gap, unavailablePath: path) }
    for gap in result.gaps where !result.unavailablePaths.values.contains(gap) { emit(gap: gap) }
    emit(complete: true, cursor: result.nextInspection)
    return 0
  }
}

private final class WorktreeScanCapture {
  let fd: Int32
  let run: String
  let publish: @Sendable (WorktreeRecord) -> Void
  let keepGoing: @Sendable () -> Bool
  var offset: UInt64 = 0
  var buffer = Data()
  var progress = ProcessInfo.processInfo.systemUptime
  var result = WorktreeDiscoveryResult()
  var complete = false
  var inspectionUptime: TimeInterval?
  init(
    fd: Int32, run: String, publish: @escaping @Sendable (WorktreeRecord) -> Void,
    keepGoing: @escaping @Sendable () -> Bool
  ) {
    self.fd = fd
    self.run = run
    self.publish = publish
    self.keepGoing = keepGoing
  }
  func poll(_ size: UInt64) -> Bool {
    guard keepGoing(), !Task.isCancelled, size >= offset else { return false }
    if size > offset {
      var bytes = [UInt8](repeating: 0, count: min(65_536, Int(size - offset)))
      let count = pread(fd, &bytes, bytes.count, off_t(offset))
      guard count > 0 else { return false }
      offset += UInt64(count)
      buffer.append(contentsOf: bytes.prefix(count))
      progress = ProcessInfo.processInfo.systemUptime
      guard buffer.count <= 4_194_304 else { return false }
      while let end = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<end])
        buffer.removeSubrange(...end)
        guard let item = try? JSONDecoder().decode(WorktreeScanEnvelope.self, from: line),
          item.run == run
        else { return false }
        if let inspecting = item.inspecting {
          guard !inspecting.isEmpty, inspecting.utf8.count < 4096 else { return false }
          result.inspectionInProgress = inspecting
          result.inspectionStartedAt = Date()
          inspectionUptime = ProcessInfo.processInfo.systemUptime
        }
        if let record = item.record {
          guard record.path.hasPrefix("/"), record.path.utf8.count < 4096,
            result.records.count < 20_000
          else { return false }
          result.records.append(record)
          publish(record)
          if result.inspectionInProgress == record.id {
            result.inspectionInProgress = nil
            result.inspectionStartedAt = nil
            inspectionUptime = nil
          }
        }
        if let gap = item.gap {
          let detail = String(gap.prefix(1000))
          result.gaps.append(detail)
          if let path = item.unavailablePath, path.hasPrefix("/"), path.utf8.count < 4096 {
            result.unavailablePaths[path] = detail
          }
        }
        if let cursor = item.cursor, (0...100_000).contains(cursor) {
          result.nextInspection = cursor
        }
        complete = item.complete || complete
        result.deferred = item.deferred == true || result.deferred
      }
    }
    return ProcessInfo.processInfo.systemUptime - progress < 30
  }
}

public final class WorktreeScanRunner: @unchecked Sendable {
  let executable: URL
  let prefix: [String]
  private let lock = NSLock()
  private var unsafe = false
  public init(executable: URL? = nil, prefix: [String] = ["--worktree-scan-worker"]) {
    self.executable =
      executable
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      .appendingPathComponent("burnzombies")
    self.prefix = prefix
  }
  public func run(
    roots: [String], root: URL, inspectOffset: Int = 0,
    knownRecords: [WorktreeRecord]? = nil,
    publish: @escaping @Sendable (WorktreeRecord) -> Void,
    keepGoing: @escaping @Sendable () -> Bool = { true }
  ) -> WorktreeDiscoveryResult {
    lock.lock()
    defer { lock.unlock() }
    guard !unsafe else {
      return .init(gaps: ["Worktree worker teardown could not be verified; new scans are paused."])
    }
    guard !roots.isEmpty else { return .init() }
    guard roots.count <= 33 else {
      return .init(gaps: ["Discovery root count exceeds bounded worker support."])
    }
    let run = UUID().uuidString
    let requestFile = root.appendingPathComponent("worktree-refresh-" + run + ".json")
    if let rows = knownRecords {
      guard !rows.isEmpty, rows.count <= 8, rows.map(\.path) == roots else {
        return .init(gaps: ["Invalid bounded known worktree request."])
      }
      do {
        try Store(root: root).write(
          WorktreeEncoding.data(rows), to: requestFile, limit: 2_097_152)
      } catch { return .init(gaps: [error.localizedDescription]) }
    }
    defer { if knownRecords != nil { unlink(requestFile.path) } }
    let file = root.appendingPathComponent("worktree-scan-" + run)
    let fd = open(file.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return .init(gaps: ["Cannot create bounded worktree scan capture."]) }
    defer {
      close(fd)
      unlink(file.path)
    }
    let capture = WorktreeScanCapture(fd: fd, run: run, publish: publish, keepGoing: keepGoing)
    var words =
      ([executable.path] + prefix + [run, String(inspectOffset)] + roots).map { (value: String) in
        value.withCString { strdup($0) }
      } + [nil]
    var environment =
      (["PATH=/usr/bin:/bin", "HOME=" + NSHomeDirectory(), "BURNZOMBIES_HOME=" + root.path]
      + (knownRecords != nil ? ["BURNZOMBIES_WORKTREE_REFRESH=1"] : [])).map {
        (value: String) in
        value.withCString { strdup($0) }
      } + [nil]
    defer {
      words.forEach { free($0) }
      environment.forEach { free($0) }
    }
    var unreaped: Int32 = -1
    let status = bz_capture_worktree_worker(
      &words, &environment, fd,
      { context, size in
        guard let context else { return 0 }
        return Unmanaged<WorktreeScanCapture>.fromOpaque(context).takeUnretainedValue().poll(size)
          ? 1 : 0
      }, Unmanaged.passUnretained(capture).toOpaque(), &unreaped)
    var s = stat()
    _ = fstat(fd, &s)
    while capture.offset < UInt64(max(0, s.st_size)), capture.poll(UInt64(max(0, s.st_size))) {}
    if status == 72 {
      unsafe = true
      capture.result.gaps.append(
        "Owned worker teardown unverified for PID \(unreaped); scans paused.")
    }
    if status != 0 || !capture.complete {
      capture.result.gaps.append(
        "Worktree worker interrupted or incomplete (status \(status)); completed observations retained."
      )
    }
    capture.result.workerCompleted = status == 0 && capture.complete
    if let started = capture.inspectionUptime {
      capture.result.inspectionElapsed = ProcessInfo.processInfo.systemUptime - started
    }
    return capture.result
  }
}
