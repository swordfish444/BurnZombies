import CBurn
import Darwin
import Foundation

public struct AgentRequest: Codable, Sendable {
  public let operation: String
  public let findingID: String?
  public let previewToken: String?
  public let processIDs: [String]?
  public let pids: [Int32]?
  public let offset: Int?
  public let label: String?
  public let rationale: String?
  // Populated from the authenticated Unix peer, never from request JSON.
  public var callerPID: Int32 = -1
  enum CodingKeys: String, CodingKey {
    case operation, findingID, previewToken, processIDs, pids, offset, label, rationale
  }
  public init(_ operation: String, findingID: String? = nil, previewToken: String? = nil,
    processIDs: [String]? = nil, pids: [Int32]? = nil, offset: Int? = nil,
    label: String? = nil, rationale: String? = nil) {
    self.operation = operation; self.findingID = findingID; self.previewToken = previewToken
    self.processIDs = processIDs; self.pids = pids; self.offset = offset
    self.label = label; self.rationale = rationale
  }
}

public struct AgentProcess: Codable, Sendable {
  public let id: String
  public let pid: Int32
  public let parentPID: Int32
  public let executable: String
  public let residentBytes: UInt64
  public let cpuPercent: Double?
  public let cpuTimeNS: UInt64
  public let readBytes: UInt64
  public let writeBytes: UInt64
  public let observationCount: Int
  public let exitedChild: Bool
  public let protectedReason: String?
  public let workingDirectory: String?
  public let descriptorSummary: String
}
public struct AgentGroup: Codable, Sendable {
  public let executableName: String
  public let count: Int
  public let residentBytes: UInt64
}

public struct AgentReply: Codable, Sendable {
  public var ok: Bool
  public var message: String
  public var findings: [AgentFinding] = []
  public var processes: [AgentProcess] = []
  public var groups: [AgentGroup] = []
  public var nextOffset: Int?
  public var partial = false
  public var receipts: [AgentReceipt] = []
  public var verifiedHelpers = 0
  public var memoryReleasedBytes: UInt64 = 0
  public var cpuSecondsSaved: Double?
  public var memoryPressure: String?
  public var observedProcesses = 0
  public var observedAt: Date?
  public var observationScope = "all visible processes owned by the logged-in macOS user; all projects and sessions"
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

/// One local evidence/actuation bridge, shared by all harnesses. No model or classifier here.
public actor AgentService {
  private let monitor: Monitor
  private struct Preview {
    let targets: [Observation]
    let label: String
    let rationale: String
    let created: Date
  }
  private var previews: [String: Preview] = [:]
  public init(monitor: Monitor) { self.monitor = monitor }
  public func call(_ request: AgentRequest) async -> AgentReply {
    guard ["status", "inspect", "preview", "burn"].contains(request.operation) else {
      return AgentReply(ok: false, message: "Unknown operation.")
    }
    previews = previews.filter { Date().timeIntervalSince($0.value.created) < 60 }
    var state = await monitor.snapshot()
    if request.operation != "status" || Date().timeIntervalSince(state.catalog.lastSample ?? .distantPast) >= 5 {
      state = await monitor.refresh()
    }
    if let error = state.error { return AgentReply(ok: false, message: error) }
    var reply = AgentReply(message: "Computer-wide observation across all projects and sessions for this macOS user. Inspect live ownership evidence to distinguish abandoned helpers from active work. No active chat, wrapper or reboot required.")
    do {
      if request.operation == "inspect" {
        let offset = request.offset ?? 0
        guard offset >= 0, offset <= 4096, (request.pids?.count ?? 0) <= 64,
          request.pids?.allSatisfy({ $0 > 0 }) ?? true else {
          return AgentReply(ok: false, message: "Use an offset from 0 to 4096 and at most 64 positive PIDs.")
        }
        let live = state.catalog.records.values.filter {
          $0.missingSince == nil && (request.pids == nil || request.pids!.contains($0.latest.identity.pid))
        }.sorted { $0.latest.identity.pid < $1.latest.identity.pid }
        let protected = (AgentSafety.ancestors(of: request.callerPID) ?? []).union(
          AgentSafety.ancestors(of: getpid()) ?? [])
        reply.processes = live.dropFirst(offset).prefix(64).map { r in
          let o = r.latest
          return AgentProcess(id: r.id, pid: o.identity.pid, parentPID: o.parent,
            executable: o.executable, residentBytes: o.rss, cpuPercent: r.cpuPercent,
            cpuTimeNS: o.cpuNS, readBytes: o.readBytes, writeBytes: o.writeBytes,
            observationCount: r.samples.count, exitedChild: o.zombie,
            protectedReason: AgentSafety.refusal(r, preferences: state.catalog.preferences, protectedPIDs: protected),
            workingDirectory: Native().workingDirectory(o), descriptorSummary: Native().enrich(o))
        }
        if offset + 64 < live.count { reply.nextOffset = offset + 64 }
        reply.message = "Computer-wide process evidence, not a disposal verdict. This list is not filtered to the calling chat, workspace or process tree. Names, paths and parent=1 do not prove abandonment. Corroborate live ownership; preserve uncertain work."
      } else if request.operation == "preview" {
        guard let ids = request.processIDs, let label = request.label,
          !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 120,
          let rationale = request.rationale, rationale.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20,
          rationale.count <= 2000, previews.count < 16 else {
          return AgentReply(ok: false, message: "Provide exact process_ids from inspect, a short label and an evidence-based rationale (20–2000 characters).")
        }
        let targets = try await monitor.previewTargets(ids, callerPID: request.callerPID)
        let token = UUID().uuidString
        previews[token] = Preview(targets: targets, label: label, rationale: rationale, created: Date())
        reply.previewToken = token
        reply.message = "Preview: graceful stop of \(targets.count) exact process identities. The harness owns the abandonment decision and must have cleanup authorization. Token expires in 60 seconds. No process was stopped."
      } else if request.operation == "burn" {
        guard let token = request.previewToken, let preview = previews.removeValue(forKey: token) else {
          return AgentReply(ok: false, message: "A fresh, unused preview token is required.")
        }
        reply.message = try await monitor.burnTargets(preview.targets, label: preview.label,
          rationale: preview.rationale, callerPID: request.callerPID)
        state = await monitor.snapshot()
      }
    } catch { return AgentReply(ok: false, message: error.localizedDescription) }
    reply.verifiedHelpers = state.catalog.lifetimeVerified
    reply.memoryReleasedBytes = state.catalog.lifetimeResidentReleased ?? 0
    reply.cpuSecondsSaved = state.catalog.lifetimeCPUSecondsSaved
    reply.memoryPressure = Native().memoryPressure()
    reply.observedProcesses = state.processCount
    reply.observedAt = state.catalog.lastSample
    reply.partial = state.partial
    if request.operation == "status" {
      let groups = Dictionary(grouping: state.catalog.records.values.filter { $0.missingSince == nil }, by: { $0.latest.name })
      reply.groups = groups.map { name, records in
        AgentGroup(executableName: name, count: records.count, residentBytes: records.reduce(0) { $0 + $1.latest.rss })
      }.sorted { $0.residentBytes > $1.residentBytes }.prefix(20).map { $0 }
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
          do {
            var request = try JSONDecoder().decode(AgentRequest.self, from: data)
            request.callerPID = bz_agent_peer_pid(client)
            reply = await handler(request)
          }
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
