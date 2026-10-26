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
          time: now, monotonic: Double(bz_continuous_ns()) / 1e9))
    default: return .unknown
    }
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
    guard case .found(let current) = probe(expected.identity.pid), current.identity == expected.identity else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    guard bz_cwd(expected.identity.pid, &path, Int32(path.count)) == 1,
      case .found(let after) = probe(expected.identity.pid), after.identity == expected.identity else { return nil }
    return String(cString: path)
  }
}

public final class InstanceLock {
  private let fd: Int32
  public init(url: URL) throws {
    fd = bz_lock(url.path)
    if fd < 0 {
      throw StoreError.message("Another instance is running, or the private lock is unavailable.")
    }
  }
  deinit { bz_unlock(fd) }
}
