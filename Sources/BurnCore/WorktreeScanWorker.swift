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
}
public struct WorktreeConsumerSnapshot: Sendable {
  public let paths: Set<String>
  public let gap: String?
  public init() {
    let box = WorktreePathBox()
    var detail = [CChar](repeating: 0, count: 256)
    let status = bz_worktree_paths(
      { context, path in
        guard let context, let path else { return }
        let b = Unmanaged<WorktreePathBox>.fromOpaque(context).takeUnretainedValue()
        guard let value = String(validatingUTF8: path), b.paths.count < 100_000 else {
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
      cursor: Int? = nil
    ) {
      if let data = try? WorktreeEncoding.data(
        WorktreeScanEnvelope(run: run, record: record, gap: gap, complete: complete, cursor: cursor)
      ) {
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
      }
    }
    emit()
    let consumers = WorktreeConsumerSnapshot()
    if let gap = consumers.gap { emit(gap: "Consumer coverage: " + gap) }
    let result = WorktreeDiscovery.scan(
      roots: Array(arguments.dropFirst(2)), seconds: 240,
      visibility: { consumers.state($0) }, inspectOffset: cursor, publish: { emit($0) },
      progress: { emit() })
    for gap in result.gaps { emit(gap: gap) }
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
        if let record = item.record {
          guard record.path.hasPrefix("/"), record.path.utf8.count < 4096,
            result.records.count < 20_000
          else { return false }
          result.records.append(record)
          publish(record)
        }
        if let gap = item.gap { result.gaps.append(String(gap.prefix(1000))) }
        if let cursor = item.cursor, (0...100_000).contains(cursor) {
          result.nextInspection = cursor
        }
        complete = item.complete || complete
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
      ["PATH=/usr/bin:/bin", "HOME=" + NSHomeDirectory(), "BURNZOMBIES_HOME=" + root.path].map {
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
    return capture.result
  }
}
