import CBurn
import Darwin
import Foundation

public struct AgentRequest: Codable, Sendable {
  public let operation: String
  public let findingID: String?
  public let previewToken: String?
  public init(_ operation: String, findingID: String? = nil, previewToken: String? = nil) {
    self.operation = operation; self.findingID = findingID; self.previewToken = previewToken
  }
}

public struct AgentReply: Codable, Sendable {
  public var ok: Bool
  public var message: String
  public var findings: [AgentFinding] = []
  public var receipts: [AgentReceipt] = []
  public var verifiedHelpers = 0
  public var memoryReleasedBytes: UInt64 = 0
  public var cpuSecondsSaved: Double?
  public var memoryPressure: String?
  public var observedProcesses = 0
  public var observedAt: Date?
  public var previewToken: String?
  public init(ok: Bool = true, message: String) { self.ok = ok; self.message = message }
  public func json() throws -> String {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}
public struct AgentFinding: Codable, Sendable {
  public let id: String
  public let label: String
  public let disposition: String
  public let reason: String
  public let helperCount: Int
  public let residentBytes: UInt64
}
public struct AgentReceipt: Codable, Sendable {
  public let id: UUID
  public let outcome: String
  public let verifiedHelpers: Int
}

/// The app remains the only catalog owner. Agents use the same action authority.
public actor AgentService {
  private let monitor: Monitor
  private var previews: [String: (Finding, Date)] = [:]
  public init(monitor: Monitor) { self.monitor = monitor }
  public func call(_ request: AgentRequest) async -> AgentReply {
    guard ["status", "preview", "burn"].contains(request.operation) else {
      return AgentReply(ok: false, message: "Unknown operation.")
    }
    previews = previews.filter { Date().timeIntervalSince($0.value.1) < 60 }
    var state = await monitor.snapshot()
    if request.operation != "status" || Date().timeIntervalSince(state.catalog.lastSample ?? .distantPast) >= 5 {
      state = await monitor.refresh()
    }
    if let error = state.error { return AgentReply(ok: false, message: error) }
    var reply = AgentReply(message: "Monitoring is active. Only explicitly registered disposable helpers can be burned.")
    if request.operation == "preview" {
      guard let id = request.findingID, UUID(uuidString: id) != nil,
        let finding = state.findings.first(where: { $0.id == id && $0.disposition == .eligible }),
        !state.partial else {
        return AgentReply(ok: false, message: "This activity is not eligible. Active, unknown and protected work stays untouched.")
      }
      guard previews.count < 16 else {
        return AgentReply(ok: false, message: "Too many open previews. Wait for a preview to expire.")
      }
      let token = UUID().uuidString
      previews[token] = (finding, Date())
      reply.previewToken = token
      reply.message = "Preview: stop \(finding.members.count) disposable helper(s) in \(finding.title). \(finding.reason) This requests SIGTERM and is irreversible. Token expires in 60 seconds."
    } else if request.operation == "burn" {
      guard let token = request.previewToken, let (finding, created) = previews.removeValue(forKey: token),
        Date().timeIntervalSince(created) < 60 else {
        return AgentReply(ok: false, message: "A fresh, unused preview token is required. Preview the activity again.")
      }
      do {
        reply.message = try await monitor.cleanup(finding)
        state = await monitor.snapshot()
      } catch { return AgentReply(ok: false, message: error.localizedDescription) }
    }
    reply.verifiedHelpers = state.catalog.lifetimeVerified
    reply.memoryReleasedBytes = state.catalog.lifetimeResidentReleased ?? 0
    reply.cpuSecondsSaved = state.catalog.lifetimeCPUSecondsSaved
    reply.memoryPressure = Native().memoryPressure()
    reply.observedProcesses = state.processCount
    reply.observedAt = state.catalog.lastSample
    // Only owned activities expose actionable IDs. Inferred group IDs can contain paths.
    let ordered = state.findings.sorted { ($0.disposition == .eligible ? 0 : 1) < ($1.disposition == .eligible ? 0 : 1) }
    reply.findings = ordered.prefix(40).map { finding in
      AgentFinding(id: finding.leaseID?.uuidString ?? "", label: finding.title,
        disposition: finding.disposition.rawValue, reason: finding.reason,
        helperCount: finding.members.count, residentBytes: finding.rss)
    }
    reply.receipts = state.catalog.events.suffix(10).map {
      AgentReceipt(id: $0.id, outcome: $0.outcome, verifiedHelpers: $0.verifiedCount)
    }
    return reply
  }
}

public final class AgentListener: @unchecked Sendable {
  private let wakeup: Int32
  private let task: Task<Void, Never>
  public static func socketPath(_ root: URL = Store.defaultRoot) -> String {
    root.appendingPathComponent("agent.sock").path
  }
  public init(root: URL = Store.defaultRoot,
    handler: @escaping @Sendable (AgentRequest) async -> AgentReply) throws {
    _ = try Store(root: root) // Enforce the owned, private real directory first.
    let path = Self.socketPath(root)
    let listener = bz_agent_listen(path)
    guard listener >= 0 else { throw StoreError.message("Could not start the private agent connection (errno \(errno)).") }
    var pair: [Int32] = [0, 0]
    guard bz_agent_wakeup_pair(&pair) == 0 else {
      close(listener); unlink(path)
      throw StoreError.message("Could not create agent shutdown signal.")
    }
    let readSignal = pair[0]
    wakeup = pair[1]
    task = Task.detached {
      defer { close(listener); close(readSignal); unlink(path) }
      while !Task.isCancelled {
        let client = bz_agent_accept(listener, readSignal)
        guard client >= 0 else { break }
        do {
          defer { close(client) }
          var input = [CChar](repeating: 0, count: 65_536)
          let count = bz_agent_read(client, &input, Int32(input.count))
          guard count > 0 else { continue }
          let data = input.withUnsafeBytes { Data($0.prefix(Int(count))) }
          let reply: AgentReply
          do { reply = await handler(try JSONDecoder().decode(AgentRequest.self, from: data)) }
          catch { reply = AgentReply(ok: false, message: "Invalid agent request.") }
          let line = try reply.json() + "\n"
          guard line.utf8.count <= 262_144 else { continue }
          _ = line.withCString { bz_agent_write(client, $0, Int32(line.utf8.count)) }
        } catch { continue }
      }
    }
  }
  public func stop() async {
    task.cancel()
    _ = "x".withCString { bz_agent_write(wakeup, $0, 1) }
    await task.value
  }
  deinit {
    task.cancel()
    _ = "x".withCString { bz_agent_write(wakeup, $0, 1) }
    close(wakeup)
  }
}

public enum AgentConnection {
  public static func isAvailable(root: URL = Store.defaultRoot) -> Bool {
    let fd = bz_agent_connect(AgentListener.socketPath(root))
    guard fd >= 0 else { return false }
    close(fd)
    return true
  }
  public static func call(_ request: AgentRequest, root: URL = Store.defaultRoot) throws -> String {
    _ = try Store(root: root)
    let fd = bz_agent_connect(AgentListener.socketPath(root))
    guard fd >= 0 else { throw StoreError.message("Open BurnZombies to start monitoring, then try again.") }
    defer { close(fd) }
    let data = try JSONEncoder().encode(request)
    let line = String(decoding: data, as: UTF8.self) + "\n"
    guard line.utf8.count < 65_536,
      line.withCString({ bz_agent_write(fd, $0, Int32(line.utf8.count)) }) == 0 else {
      throw StoreError.message("Agent request could not be sent.")
    }
    var buffer = [CChar](repeating: 0, count: 262_144)
    let count = bz_agent_read(fd, &buffer, Int32(buffer.count))
    guard count > 0 else { throw StoreError.message("BurnZombies did not respond. Check the app and try again.") }
    return buffer.withUnsafeBytes { String(decoding: $0.prefix(Int(count)), as: UTF8.self) }
  }
}
