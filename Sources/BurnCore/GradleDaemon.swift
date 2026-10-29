import CBurn
import CryptoKit
import Darwin
import Foundation

/// Owner evidence for one exact Gradle daemon. It does not authorize generic SIGTERM.
public struct GradleDaemonEvidence: Codable, Sendable {
  public var member: Member
  public var daemonUID: String
  public var gradleHome: String
  public var distribution: String
  public var version: String
  public var state: String
  public var residentBytes: UInt64
  public var cpuTimeNS: UInt64
  public var nativeChildren: [ProcessIdentity]
  public var childrenVisibilityComplete: Bool
  public var checkedAt: Date
  public var lastBusy: Date
  public var evidenceFingerprint: String
  public var eligible: Bool
  public var reason: String
}

public enum GradleDaemon {
  public static let supportedVersion = "8.14.6"
  private struct Reply: Decodable {
    var ok: Bool; var pid: Int32?; var uid: String?; var version: String?
    var state: String?; var lastBusyMillis: Double?; var accepted: Bool?; var boundary: Int?; var failureType: String?
  }
  private static func string<T>(_ value: inout T) -> String {
    withUnsafePointer(to: &value) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
  }
  private static func fingerprint(_ paths: [String]) throws -> String {
    var bytes = Data()
    for path in paths.sorted() {
      var value = stat()
      guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
        value.st_uid == 0 || value.st_uid == getuid(), value.st_mode & 0o022 == 0 else {
        throw StoreError.message("Gradle adapter configuration is missing or writable by another user; preserved.")
      }
      bytes.append(Data("\(path):\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)\n".utf8))
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  private static func configuration(_ observation: Observation) throws -> (String, String, String, URL) {
    guard observation.uid == getuid(), !observation.zombie, observation.metricsValid,
      case .found(let before) = Native().probe(observation.identity.pid), Member(before) == Member(observation) else {
      throw StoreError.message("Gradle native identity changed or is unavailable; preserved.")
    }
    var launch = bz_gradle_identity()
    guard bz_gradle_launch(observation.identity.pid, &launch) == 1 else {
      throw StoreError.message("Exact supported Gradle launcher and open owner log could not be verified; preserved.")
    }
    let distribution = string(&launch.distribution), home = string(&launch.home)
    guard string(&launch.version) == supportedVersion,
      let resource = Bundle.module.url(forResource: "BZGradleDaemon", withExtension: "java") else {
      throw StoreError.message("Supported Gradle message adapter is unavailable; preserved.")
    }
    let lib = URL(fileURLWithPath: distribution).appendingPathComponent("lib")
    let jars = try FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "jar" }.map(\.path)
    guard !jars.isEmpty, jars.count <= 256,
      jars.contains(lib.appendingPathComponent("gradle-daemon-main-\(supportedVersion).jar").path) else {
      throw StoreError.message("Gradle distribution is unsupported; preserved.")
    }
    let java = URL(fileURLWithPath: observation.executable).resolvingSymlinksInPath().path
    let signature = try fingerprint(jars + [java, resource.path])
    guard case .found(let after) = Native().probe(observation.identity.pid), Member(after) == Member(observation) else {
      throw StoreError.message("Gradle identity changed during inspection; preserved.")
    }
    return (home, distribution, signature, resource)
  }
  private static func call(_ action: String, observation: Observation, home: String, distribution: String,
                           resource: URL, uid: String = "", lastBusy: Date? = nil) throws -> Reply {
    var template = Array((NSTemporaryDirectory() + "bz-gradle-message-XXXXXX").utf8CString)
    let fd = mkstemp(&template)
    guard fd >= 0 else { throw StoreError.message("Could not capture the bounded owner response.") }
    unlink(template); defer { close(fd) }
    let millis = observation.identity.seconds * 1000 + observation.identity.micros / 1000
    let values = [observation.executable, "-Xmx128m", "-XX:ActiveProcessorCount=1", "--class-path", distribution + "/lib/*",
      resource.path, action, home, String(observation.identity.pid), String(millis), observation.executable, uid,
      lastBusy.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? ""]
    var argv: [UnsafeMutablePointer<CChar>?] = values.map { $0.withCString { strdup($0) } } + [nil]
    var environment = ["PATH=/usr/bin:/bin", "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)", "LANG=en_US.UTF-8"]
      .map { (value: String) in value.withCString { strdup($0) } } + [nil]
    defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
    let status = bz_capture_tool(&argv, &environment, fd, 8_000, 16_384)
    guard lseek(fd, 0, SEEK_SET) >= 0 else {
      throw StoreError.message("Gradle owner adapter refused or timed out; no generic stop fallback.")
    }
    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    guard data.count <= 16_384, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
      throw StoreError.message("Gradle owner response was unavailable (capture status \(status)); preserved.")
    }
    guard status == 0, reply.ok else {
      throw StoreError.message("Gradle owner adapter refused at boundary \(reply.boundary ?? 0) (\(reply.failureType ?? "unavailable")); preserved.")
    }
    return reply
  }
  /// Inspects only the supplied identity; never enumerates other Gradle homes or launches a daemon.
  public static func inspect(_ observation: Observation, records: [String: Record], complete: Bool = false) throws -> GradleDaemonEvidence? {
    guard observation.name == "java" else { return nil }
    let (home, distribution, signature, resource) = try configuration(observation)
    let reply = try call("inspect", observation: observation, home: home, distribution: distribution, resource: resource)
    guard reply.pid == observation.identity.pid, reply.version == supportedVersion,
      let uid = reply.uid, UUID(uuidString: uid) != nil, let state = reply.state, let lastBusy = reply.lastBusyMillis,
      case .found(let after) = Native().probe(observation.identity.pid), Member(after) == Member(observation) else {
      throw StoreError.message("Gradle owner and native identity do not agree; preserved.")
    }
    let children = records.values.filter { $0.missingSince == nil && $0.latest.parent == observation.identity.pid }.map { $0.latest.identity }
    let eligible = complete && state == "IDLE" && children.isEmpty
    return GradleDaemonEvidence(member: Member(observation), daemonUID: uid, gradleHome: home,
      distribution: distribution, version: supportedVersion, state: state, residentBytes: after.rss,
      cpuTimeNS: after.cpuNS, nativeChildren: children, childrenVisibilityComplete: complete,
      checkedAt: Date(), lastBusy: Date(timeIntervalSince1970: lastBusy / 1000), evidenceFingerprint: signature,
      eligible: eligible, reason: eligible ? "Owner reports idle; exact authenticated stop-when-idle is available."
        : "Owner is busy, has live child workers, or child visibility is incomplete; preserved.")
  }
  /// Request only. The caller must independently verify exact exit before recording a burn.
  /// Active owner claims/user protections remain mandatory in the caller's native preview.
  public static func requestGracefulStop(_ expected: GradleDaemonEvidence, records: [String: Record],
                                        authorize: () throws -> Void = {}) throws -> String {
    let scan = Native().scan()
    let freshRecords = Dictionary(uniqueKeysWithValues: scan.observations.map { ($0.identity.key, Record($0)) })
    guard !scan.partial, expected.eligible, expected.childrenVisibilityComplete,
      (0...60).contains(Date().timeIntervalSince(expected.checkedAt)),
      let record = records[expected.member.identity.key], record.missingSince == nil,
      Member(record.latest) == expected.member,
      let current = try inspect(record.latest, records: freshRecords, complete: true), current.eligible,
      current.daemonUID == expected.daemonUID, current.gradleHome == expected.gradleHome,
      current.distribution == expected.distribution, current.version == expected.version,
      current.lastBusy == expected.lastBusy,
      current.evidenceFingerprint == expected.evidenceFingerprint else {
      throw StoreError.message("Gradle preview expired, owner became active, or exact evidence changed; preserved.")
    }
    let (home, distribution, signature, resource) = try configuration(record.latest)
    guard signature == expected.evidenceFingerprint else { throw StoreError.message("Gradle adapter changed; preserved.") }
    try authorize()
    let reply = try call("stop-when-idle", observation: record.latest, home: home, distribution: distribution,
      resource: resource, uid: expected.daemonUID, lastBusy: expected.lastBusy)
    guard reply.uid == expected.daemonUID, reply.accepted == true else {
      throw StoreError.message("No exact owner stop request was confirmed; no cleanup credited.")
    }
    return "Exact owner stop-when-idle requested. Any raced build is allowed to finish. Verify native exit before crediting cleanup."
  }
}
