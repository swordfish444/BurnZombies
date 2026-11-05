import CBurn
import Darwin
import Foundation

public struct Scan: Sendable {
  public var observations: [Observation]
  public var partial: Bool
  public var hidden: Int
}
public enum Probe {
  case found(Observation)
  case absent, unknown
}
public struct Native {
  public init() {}
  public func codexSessionID(_ expected: Observation) -> String? {
    codexSessionEvidence(expected).id
  }
  public func codexSessionEvidence(_ expected: Observation) -> (id: String?, status: String) {
    guard case .found(let before) = probe(expected.identity.pid), Member(before) == Member(expected)
    else { return (nil, "identity-changed") }
    var value = [CChar](repeating: 0, count: 37)
    let result = bz_codex_session(expected.identity.pid, &value, 37)
    guard case .found(let after) = probe(expected.identity.pid), Member(after) == Member(expected)
    else { return (nil, "identity-changed") }
    guard result == 1, let id = UUID(uuidString: String(cString: value)) else {
      return (nil, result < 0 ? "metadata-unreadable" : "marker-absent")
    }
    return (id.uuidString.lowercased(), "bound-marker")
  }
  public var awakeSeconds: Double { Double(bz_awake_ns()) / 1e9 }
  public var boot: UInt64 { bz_boot() }
  public func memoryPressure() -> String {
    switch bz_memory_pressure() {
    case 1: return "Low"
    case 2: return "Elevated"
    case 4: return "High"
    default: return "—"
    }
  }
  public func probe(_ pid: Int32, now: Date = Date()) -> Probe {
    var raw = bz_process()
    switch bz_read(pid, &raw) {
    case 0: return .absent
    case 1:
      let path = withUnsafePointer(to: &raw.path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
      }
      return .found(
        Observation(
          identity: ProcessIdentity(
            pid: pid, seconds: raw.start_sec, micros: raw.start_usec, boot: bz_boot()),
          parent: raw.ppid, uid: raw.uid, executable: path, rss: raw.rss, cpuNS: raw.cpu_ns,
          readBytes: raw.disk_read, writeBytes: raw.disk_write, fds: Int(raw.fds),
          threads: Int(raw.threads), zombie: raw.status == 5, metricsValid: raw.metrics_valid == 1,
          time: now, monotonic: Double(bz_continuous_ns()) / 1e9, pgid: raw.pgid))
    default: return .unknown
    }
  }
  /// True when the process owns a listening TCP socket; nil when it cannot be inspected.
  public func listening(_ pid: Int32) -> Bool? {
    switch bz_listening(pid) {
    case 1: return true
    case 0: return false
    default: return nil
    }
  }
  /// Which agent harness launched the process, from environment variable names only.
  public func agent(_ pid: Int32) -> String? {
    let mask = bz_agent_markers(pid)
    guard mask >= 0 else { return nil }
    if mask & 1 != 0 { return "claude" }
    if mask & 2 != 0 { return "codex" }
    if mask & 4 != 0 { return "cursor" }
    return "none"
  }
  /// The live command line for inspection. Never persisted.
  public func commandLine(_ pid: Int32, limit: Int = 600) -> String? {
    var buffer = [CChar](repeating: 0, count: limit + 1)
    guard bz_command_line(pid, &buffer, Int32(buffer.count)) == 1 else { return nil }
    return String(cString: buffer)
  }
  /// The live arguments, the program first, one entry each. Read to recognize robot browsers;
  /// never persisted.
  public func arguments(_ pid: Int32, limit: Int = 131_072) -> [String]? {
    var buffer = [UInt8](repeating: 0, count: limit)
    let used = buffer.withUnsafeMutableBufferPointer { raw in
      raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) {
        bz_arguments(pid, $0, Int32(raw.count))
      }
    }
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard used > 0 else { return nil }
    return buffer[..<Int(used)].split(separator: 0, omittingEmptySubsequences: false).dropLast()
      .map { String(decoding: $0, as: UTF8.self) }
  }
  /// How many clients are connected to the ports the process listens on; nil when unknown.
  public func clients(_ pid: Int32) -> Int? {
    let count = bz_listen_peers(pid)
    return count < 0 ? nil : Int(count)
  }
  public func currentDirectory(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard bz_cwd(pid, &buffer, Int32(buffer.count)) == 1 else { return nil }
    let path = String(cString: buffer)
    return path.isEmpty ? nil : path
  }
  public func ownerState(_ identity: ProcessIdentity) -> OwnerState {
    let boot = bz_boot()
    guard identity.boot != 0, boot != 0 else { return .unknown }
    if identity.boot != boot { return .gone }
    switch probe(identity.pid) {
    case .absent: return .gone
    case .unknown: return .unknown
    case .found(let o): return o.identity == identity && !o.zombie ? .alive : .gone
    }
  }
  public func scan() -> Scan {
    var pids = [Int32](repeating: 0, count: 16384)
    let count = Int(bz_list(&pids, Int32(pids.count)))
    guard count > 0 else { return Scan(observations: [], partial: true, hidden: 0) }
    var result = [Observation]()
    var hidden = 0
    let now = Date()
    for pid in pids.prefix(min(count, pids.count)) where pid > 0 {
      switch probe(pid, now: now) {
      case .found(let o): if o.uid == getuid() { result.append(o) }
      case .unknown: hidden += 1
      case .absent: break
      }
    }
    return Scan(
      observations: result, partial: count >= pids.count || result.count > 4096, hidden: hidden)
  }
  public func terminate(_ expected: Observation) -> Int32 {
    var raw = bz_process()
    guard bz_read(expected.identity.pid, &raw) == 1, bz_boot() == expected.identity.boot,
      raw.start_sec == expected.identity.seconds, raw.start_usec == expected.identity.micros
    else { return ESTALE }
    let current = withUnsafePointer(to: &raw.path) {
      $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
    }
    guard current == expected.executable else { return ESTALE }
    return bz_term(&raw)
  }
  public func enrich(_ expected: Observation) -> String {
    guard case .found(let o) = probe(expected.identity.pid), o.identity == expected.identity else {
      return "Identity changed; refresh before inspecting."
    }
    var sockets: Int32 = 0
    var files: Int32 = 0
    let count = bz_fd_summary(o.identity.pid, &sockets, &files)
    guard count >= 0 else {
      return "Descriptor visibility unavailable or exceeds the 2,048-descriptor inspection limit."
    }
    return
      "\(count) descriptors · \(sockets) sockets · \(files) file handles. Socket endpoints and file contents are not collected."
  }
  public func workingDirectory(_ expected: Observation) -> String? {
    guard case .found(let current) = probe(expected.identity.pid),
      current.identity == expected.identity
    else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    guard bz_cwd(expected.identity.pid, &path, Int32(path.count)) == 1,
      case .found(let after) = probe(expected.identity.pid), after.identity == expected.identity
    else { return nil }
    return String(cString: path)
  }
}

public final class InstanceLock {
  private let fd: Int32
  public init(url: URL, timeout: TimeInterval = 0) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
    var acquired = bz_lock(url.path)
    while acquired < 0 && ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.01)
      acquired = bz_lock(url.path)
    }
    fd = acquired
    if fd < 0 {
      throw StoreError.message("Another instance is running, or the private lock is unavailable.")
    }
  }
  deinit { bz_unlock(fd) }
}
