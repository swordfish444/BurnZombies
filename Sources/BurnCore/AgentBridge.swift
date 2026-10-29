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
  public let action: String?
  public let workToken: String?
  public let completionCondition: String?
  public let workspacePath: String?
  public let workspaceID: String?
  public let reviewIDs: [String]?
  public let recordIDs: [String]?
  // Populated from the authenticated Unix peer, never from request JSON.
  public var callerPID: Int32 = -1
  enum CodingKeys: String, CodingKey {
    case operation, findingID, previewToken, processIDs, pids, offset, label, rationale, action, workToken, completionCondition, workspacePath, workspaceID, reviewIDs, recordIDs
  }
  public init(_ operation: String, findingID: String? = nil, previewToken: String? = nil,
    processIDs: [String]? = nil, pids: [Int32]? = nil, offset: Int? = nil,
    label: String? = nil, rationale: String? = nil, action: String? = nil, reviewIDs: [String]? = nil,
    workToken: String? = nil, completionCondition: String? = nil, workspacePath: String? = nil, workspaceID: String? = nil, recordIDs: [String]? = nil) {
    self.operation = operation; self.findingID = findingID; self.previewToken = previewToken
    self.processIDs = processIDs; self.pids = pids; self.offset = offset
    self.label = label; self.rationale = rationale
    self.action = action; self.workToken = workToken; self.completionCondition = completionCondition
    self.workspacePath = workspacePath; self.workspaceID = workspaceID
    self.reviewIDs = reviewIDs; self.recordIDs = recordIDs
  }
}

public struct AgentProcess: Codable, Sendable {
  public let id: String
  public let pid: Int32
  public let parentPID: Int32
  public let liveChildCount: Int
  public let liveChildren: [Member]
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
  public var workToken: String?
  public var work: [WorkSummary] = []
  public var releasedWorkCount: Int = 0
  public var disk: [DiskCandidate] = []
  public var diskDiscovery: [DiskSpaceSummary] = []
  public var diskInspection: DiskInspection?
  public var ownerProcesses: [OwnerProcessSummary]?
  public var managedCache: ManagedCacheSummary?
  public var managedCacheAllowanceBytes: UInt64?
  public var managedCacheReceipts: [BuildKitCache.Receipt]?
  public var ownerEvidenceGaps: [String]?
  public var diskEvidence: [String: String]?
  public var failureKind: String?
  public var diskPolicy: DiskReviewPolicy?
  public var activeWorkCount: Int = 0
  public var previewToken: String?
  public var workspaces: [WorkspaceSummary] = []
  public var worktreeReceipts: [WorkspaceReceipt] = []
  public var worktreesCleaned: Int = 0
  public var diskReclaimedBytes: UInt64 = 0
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
    let caller: ProcessIdentity
  }
  private struct WorkspacePreview {
    let claim: WorkspaceClaim
    let created: Date
    let caller: ProcessIdentity
  }
  private var ownerPreviews: [String: (GradleDaemonEvidence, String, Date, ProcessIdentity)] = [:]
  private var cachePreviews: [String: (BuildKitCache.Plan, String, Date, ProcessIdentity)] = [:]
  private var diskPreviews: [String: (DiskCandidate, String, Date, ProcessIdentity)] = [:]
  private var workspacePreviews: [String: WorkspacePreview] = [:]
  private var previews: [String: Preview] = [:]
  public init(monitor: Monitor) { self.monitor = monitor }
  public func call(_ request: AgentRequest) async -> AgentReply {
    guard ["status", "inspect", "preview", "burn", "lifecycle", "work", "workspace", "workspace_preview", "workspace_clean", "disk_decide", "disk_preview", "disk_clean", "disk_inspect", "disk_explore", "disk_recommend", "disk_evidence", "owner_preview", "owner_stop", "cache_preview", "cache_clean"].contains(request.operation) else {
      return AgentReply(ok: false, message: "Unknown operation.")
    }
    previews = previews.filter { Date().timeIntervalSince($0.value.created) < 60 }
    workspacePreviews = workspacePreviews.filter { Date().timeIntervalSince($0.value.created) < 60 }
    var state = await monitor.snapshot()
    if ["inspect", "preview", "burn", "lifecycle"].contains(request.operation) {
      state = await monitor.refresh()
    }
    if let error = state.error { return AgentReply(ok: false, message: error) }
    var reply = AgentReply(message: "Computer-wide observation across all projects and sessions for this macOS user. Inspect live ownership evidence to distinguish abandoned helpers from active work. No active chat, wrapper or reboot required.")
    do {
      if ["owner_preview", "cache_preview"].contains(request.operation) {
        ownerPreviews = ownerPreviews.filter { Date().timeIntervalSince($0.value.2) < 60 }
        cachePreviews = cachePreviews.filter { Date().timeIntervalSince($0.value.2) < 60 }
        guard let id = request.findingID, let rationale = request.rationale, (20...1200).contains(rationale.count),
          request.reviewIDs == nil || request.reviewIDs!.contains(id),
          ownerPreviews.count + cachePreviews.count < 8,
          case .found(let peer) = Native().probe(request.callerPID) else { throw StoreError.message("Exact queued owner, rationale and authenticated caller required.") }
        let token = UUID().uuidString
        if request.operation == "owner_preview" {
          let evidence = try await monitor.previewOwnerProcess(id, callerPID: request.callerPID)
          ownerPreviews[token] = (evidence, rationale, Date(), peer.identity)
        } else {
          let plan = try await monitor.previewManagedCache(id, recordIDs: request.recordIDs ?? [])
          cachePreviews[token] = (plan, rationale, Date(), peer.identity)
        }
        reply.previewToken = token
        reply.message = "Exact owner candidate previewed. No cleanup yet. Single-use caller-bound token expires in 60 seconds; background producer revalidation remains mandatory before dispatch."
      } else if request.operation == "owner_stop" {
        guard let token = request.previewToken, let p = ownerPreviews.removeValue(forKey: token),
          (0...60).contains(Date().timeIntervalSince(p.2)),
          case .found(let peer) = Native().probe(request.callerPID), peer.identity == p.3 else { throw StoreError.message("Fresh caller-bound owner preview required.") }
        reply.message = try await monitor.startOwnerStop(p.0, rationale: p.1, callerPID: request.callerPID)
        state = await monitor.snapshot()
      } else if request.operation == "cache_clean" {
        guard let token = request.previewToken, let p = cachePreviews.removeValue(forKey: token),
          (0...60).contains(Date().timeIntervalSince(p.2)),
          case .found(let peer) = Native().probe(request.callerPID), peer.identity == p.3 else { throw StoreError.message("Fresh caller-bound cache preview required.") }
        reply.message = try await monitor.startManagedCache(p.0, rationale: p.1)
        state = await monitor.snapshot()
      } else if ["disk_inspect", "disk_explore", "disk_recommend", "disk_evidence"].contains(request.operation) {
        return try await monitor.diskDiscoveryRequest(request)
      } else if request.operation == "workspace" {
        let result = try await monitor.recordWorkspace(request)
        reply.workToken = result.0; reply.message = result.1
        if let claim = result.2 { reply.workspaces = [WorkspaceSummary(claim)] }
        state = await monitor.snapshot()
      } else if request.operation == "disk_decide" {
        reply.message = try await monitor.diskDecision(request.findingID ?? "", decision: request.action ?? "", rationale: request.rationale ?? "")
        state = await monitor.snapshot()
      } else if request.operation == "disk_preview" {
        diskPreviews = diskPreviews.filter { Date().timeIntervalSince($0.value.2) < 60 }
        guard let id = request.findingID, let rationale = request.rationale, (20...1200).contains(rationale.count),
          diskPreviews.count < 8, case .found(let peer) = Native().probe(request.callerPID) else { throw StoreError.message("Fresh candidate, rationale and caller required.") }
        let c = try await monitor.previewDisk(id), token = UUID().uuidString
        diskPreviews[token] = (c, rationale, Date(), peer.identity); reply.previewToken = token
        reply.message = "Exact regenerable folder passed guards. Token expires in 60 seconds; no files removed."
      } else if request.operation == "disk_clean" {
        guard let token = request.previewToken, let p = diskPreviews.removeValue(forKey: token), Date().timeIntervalSince(p.2) < 60,
          case .found(let peer) = Native().probe(request.callerPID), peer.identity == p.3 else { throw StoreError.message("Fresh caller-bound disk preview required.") }
        reply.message = try await monitor.cleanDisk(p.0, rationale: p.1)
        state = await monitor.snapshot()
      } else if request.operation == "workspace_preview" {
        guard let id = request.workspaceID, let rationale = request.rationale, (20...2000).contains(rationale.count),
          workspacePreviews.count < 16, case .found(let peer) = Native().probe(request.callerPID) else {
          throw StoreError.message("A released workspace ID, evidence-based rationale and authenticated caller are required.")
        }
        let claim = try await monitor.previewWorkspace(id)
        let token = UUID().uuidString
        workspacePreviews[token] = .init(claim: claim, created: Date(), caller: peer.identity)
        reply.previewToken = token
        reply.message = "Clean released workspace passed native guards. Removal preserves HEAD in a recovery ref. Token is single-use, bound to this caller and expires in 60 seconds. No files removed."
      } else if request.operation == "workspace_clean" {
        guard let token = request.previewToken, let preview = workspacePreviews[token],
          case .found(let peer) = Native().probe(request.callerPID), preview.caller == peer.identity else {
          throw StoreError.message("A fresh workspace preview token from this connection is required.")
        }
        workspacePreviews.removeValue(forKey: token)
        reply.message = try await monitor.cleanWorkspace(preview.claim)
        state = await monitor.snapshot()
      } else if request.operation == "lifecycle" {
        let result = try await monitor.recordWork(request)
        reply.workToken = result.0; reply.message = result.1
        state = await monitor.snapshot()
      } else if request.operation == "work" {
        let offset = request.offset ?? 0
        guard (0...256).contains(offset) else { throw StoreError.message("Work offset must be 0–256.") }
        let work = await monitor.workSummaries()
        reply.work = Array(work.dropFirst(offset).prefix(16))
        if offset + 16 < work.count { reply.nextOffset = offset + 16 }
        reply.message = "Owner statements with captured live ancestry, not disposal verdicts. Active claims block cleanup. Release tokens are private to the owning task."
      } else if request.operation == "inspect" {
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
          let children = state.catalog.records.values.filter { $0.missingSince == nil && $0.latest.parent == o.identity.pid }.sorted { $0.latest.identity.pid < $1.latest.identity.pid }
          return AgentProcess(id: r.id, pid: o.identity.pid, parentPID: o.parent,
            liveChildCount: children.count, liveChildren: children.prefix(16).map { Member($0.latest) },
            executable: o.executable, residentBytes: o.rss, cpuPercent: r.cpuPercent,
            cpuTimeNS: o.cpuNS, readBytes: o.readBytes, writeBytes: o.writeBytes,
            observationCount: r.samples.count, exitedChild: o.zombie,
            protectedReason: WorkEvidence.blockingTree(state.catalog.workEvidence ?? [], record: r, records: state.catalog.records)
              ? "Active owner claim on this helper or its parent."
              : AgentSafety.refusal(r, preferences: state.catalog.preferences, protectedPIDs: protected),
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
        guard case .found(let peer) = Native().probe(request.callerPID) else { throw StoreError.message("Caller identity unavailable.") }
        let token = UUID().uuidString
        previews[token] = Preview(targets: targets, label: label, rationale: rationale, created: Date(), caller: peer.identity)
        reply.previewToken = token
        reply.message = "Preview: graceful stop of \(targets.count) exact process identities. The harness owns the abandonment decision and must have cleanup authorization. Token expires in 60 seconds. No process was stopped."
      } else if request.operation == "burn" {
        guard let token = request.previewToken, let preview = previews[token],
          case .found(let peer) = Native().probe(request.callerPID), peer.identity == preview.caller else {
          return AgentReply(ok: false, message: "A fresh, unused preview token is required.")
        }
        previews.removeValue(forKey: token)
        reply.message = try await monitor.burnTargets(preview.targets, label: preview.label,
          rationale: preview.rationale, callerPID: request.callerPID)
        state = await monitor.snapshot()
      }
    } catch is DiskAdviceError {
      var reply = AgentReply(ok: false, message: "Recommendation text did not meet the declared limits. Leave this branch pending; do not retry in this review.")
      reply.failureKind = "recommendation_rejected"
      return reply
    } catch { return AgentReply(ok: false, message: error.localizedDescription) }
    reply.worktreesCleaned = state.catalog.lifetimeWorktreesCleaned ?? 0
    reply.diskReclaimedBytes = state.catalog.lifetimeDiskReclaimedBytes ?? 0
    reply.worktreeReceipts = Array((state.catalog.workspaceReceipts ?? []).suffix(8))
    if request.operation == "status" {
      reply.ownerProcesses = (state.catalog.ownerDaemons ?? []).filter { evidence in
        evidence.eligible && (request.reviewIDs == nil || request.reviewIDs!.contains(evidence.id))
      }.map(OwnerProcessSummary.init)
      if let inventory = state.catalog.managedCache {
        let summary = ManagedCacheSummary(inventory, blocked: ManagedCacheAttempt.blockedIDs(state.catalog.managedCacheAttempts ?? [], inventory: inventory), allowance: state.catalog.managedCacheAllowanceBytes)
        if request.reviewIDs == nil || request.reviewIDs!.contains(summary.id) { reply.managedCache = summary; reply.managedCacheAllowanceBytes = try? await monitor.managedAvailableBytes() }
      }
      if request.reviewIDs == nil { reply.ownerEvidenceGaps = state.catalog.ownerEvidenceGaps }
      if request.reviewIDs == nil { reply.managedCacheReceipts = Array((state.catalog.managedCacheAttempts ?? []).compactMap(\.receipt).suffix(4)) }
      reply.workspaces = (state.catalog.workspaces ?? []).filter { $0.state == "released" && (request.reviewIDs == nil || request.reviewIDs!.contains($0.id)) }.prefix(8).map(WorkspaceSummary.init)
    }
    reply.verifiedHelpers = state.catalog.lifetimeVerified
    reply.memoryReleasedBytes = state.catalog.lifetimeResidentReleased ?? 0
    reply.cpuSecondsSaved = state.catalog.lifetimeCPUSecondsSaved
    reply.memoryPressure = Native().memoryPressure()
    reply.observedProcesses = state.processCount
    reply.observedAt = state.catalog.lastSample
    reply.partial = state.partial
    reply.disk = Array((state.catalog.diskCandidates ?? []).filter { $0.bytes >= DiskCandidate.minimumReviewBytes && (request.reviewIDs == nil || request.reviewIDs!.contains($0.id)) }.prefix(3))
    reply.diskDiscovery = (state.catalog.diskDiscovery ?? []).filter { request.reviewIDs == nil || request.reviewIDs!.contains($0.id) }.prefix(3).map(DiskSpaceSummary.init)
    if !reply.disk.isEmpty || !reply.diskDiscovery.isEmpty || reply.managedCache != nil { reply.diskPolicy = (try? await monitor.diskPolicy()).map(DiskReviewPolicy.init) }
    let work = await monitor.workSummaries()
    reply.activeWorkCount = work.filter { $0.state == "active" && !$0.livePIDs.isEmpty }.count
    let released = work.filter { ["released", "candidate"].contains($0.state) && !$0.blockedByActiveClaim && !$0.livePIDs.isEmpty
      && (request.reviewIDs == nil || request.reviewIDs!.contains($0.id)) }
    reply.releasedWorkCount = released.count
    if request.operation == "status" {
      reply.work = Array(released.prefix(8))
      let groups = Dictionary(grouping: state.catalog.records.values.filter { $0.missingSince == nil }, by: { $0.latest.name })
      reply.groups = request.reviewIDs == nil ? groups.map { name, records in
        AgentGroup(executableName: name, count: records.count, residentBytes: records.reduce(0) { $0 + $1.latest.rss })
      }.sorted { $0.residentBytes > $1.residentBytes }.prefix(20).map { $0 } : []
    }
    reply.receipts = state.catalog.events.suffix(10).map {
      AgentReceipt(id: $0.id, outcome: $0.outcome, verifiedHelpers: $0.verifiedCount)
    }
    return reply
  }
}

/// Only mechanical operation/timing metadata is persisted; never arguments or tool text.
public struct AgentTransportReceipt: Codable, Sendable {
  public var id = UUID().uuidString
  public var started: Date
  public var operation: String
  public var status: String
  public var frameMilliseconds: UInt64
  public var handlerMilliseconds: UInt64
  public var totalMilliseconds: UInt64
  public var responseBytes: Int
}

private final class AgentClients: @unchecked Sendable {
  private struct Client { var task: Task<Void, Never>? }
  private let lock = NSLock()
  private var clients: [Int32: Client] = [:]
  private var rejectedClient: Int32?
  private var stopped = false
  private let receiptLock = NSLock()
  private let store: Store
  private var receipts: [AgentTransportReceipt]
  init(store: Store) {
    self.store = store
    let file = store.root.appendingPathComponent("agent-transport.json")
    receipts = (try? JSONDecoder().decode([AgentTransportReceipt].self,
      from: store.read(file, limit: 65_536))) ?? []
    receipts = Array(receipts.suffix(64))
  }
  func reserve(_ fd: Int32) -> Bool {
    lock.withLock {
      guard !stopped, clients.count < 8 else { return false }
      clients[fd] = Client()
      return true
    }
  }
  func attach(_ task: Task<Void, Never>, to fd: Int32) {
    lock.withLock {
      if stopped { task.cancel() }
      if clients[fd] != nil { clients[fd]?.task = task }
    }
  }
  func finish(_ fd: Int32) {
    lock.withLock {
      // Serialize close with shutdown so a recycled descriptor is never touched.
      if clients.removeValue(forKey: fd) != nil { close(fd) }
    }
  }
  func trackRejection(_ fd: Int32) -> Bool {
    lock.withLock {
      guard !stopped, rejectedClient == nil else { return false }
      rejectedClient = fd
      return true
    }
  }
  func finishRejection(_ fd: Int32) {
    lock.withLock {
      if rejectedClient == fd { rejectedClient = nil; close(fd) }
    }
  }
  func cancel() -> [Task<Void, Never>] {
    lock.withLock {
      stopped = true
      if let rejectedClient { _ = shutdown(rejectedClient, SHUT_RDWR) }
      for (fd, client) in clients {
        client.task?.cancel()
        _ = shutdown(fd, SHUT_RDWR)
      }
      return clients.values.compactMap(\.task)
    }
  }
  func record(_ value: AgentTransportReceipt) {
    receiptLock.withLock {
      receipts.removeAll { $0.id == value.id }
      receipts = Array((receipts + [value]).suffix(64))
      if let data = try? JSONEncoder().encode(receipts) {
        try? store.write(data, to: store.root.appendingPathComponent("agent-transport.json"), limit: 65_536)
      }
    }
  }
}

public final class AgentListener: @unchecked Sendable {
  private let wakeup: Int32
  private let task: Task<Void, Never>
  private let clients: AgentClients
  public static func socketPath(_ root: URL = Store.defaultRoot) -> String {
    root.appendingPathComponent("agent.sock").path
  }
  public init(root: URL = Store.defaultRoot,
    handler: @escaping @Sendable (AgentRequest) async -> AgentReply) throws {
    let store = try Store(root: root)
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
    let clients = AgentClients(store: store)
    self.clients = clients
    task = Task.detached {
      defer { close(listener); close(readSignal); unlink(path) }
      while !Task.isCancelled {
        // Socket polling is blocking C I/O, so keep it off Swift's cooperative executor.
        let client: Int32 = await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: bz_agent_accept(listener, readSignal))
          }
        }
        guard client >= 0 else { break }
        guard clients.reserve(client) else {
          guard clients.trackRejection(client) else { close(client); continue }
          let began = bz_continuous_ns()
          var receipt = AgentTransportReceipt(started: Date(), operation: "unknown", status: "rejecting",
            frameMilliseconds: 0, handlerMilliseconds: 0, totalMilliseconds: 0, responseBytes: 0)
          clients.record(receipt)
          // Drain one bounded frame before closing. Closing with an unread request
          // can reset the socket and discard the busy reply on macOS. The accept
          // task handles at most one rejection; shutdown tracks and interrupts it.
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
              var discard = [CChar](repeating: 0, count: 65_536)
              _ = bz_agent_read_timeout(client, &discard, Int32(discard.count), 1000)
              continuation.resume()
            }
          }
          receipt.frameMilliseconds = (bz_continuous_ns() - began) / 1_000_000
          if !Task.isCancelled {
            let line = "{\"ok\":false,\"message\":\"Observer connection capacity reached. Leave work pending for a later review.\"}\n"
            receipt.responseBytes = line.utf8.count
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
              DispatchQueue.global(qos: .utility).async {
                _ = line.withCString { bz_agent_write(client, $0, Int32(line.utf8.count)) }
                continuation.resume()
              }
            }
          }
          receipt.status = Task.isCancelled ? "cancelled" : "busy"
          receipt.totalMilliseconds = (bz_continuous_ns() - began) / 1_000_000
          clients.finishRejection(client)
          clients.record(receipt)
          continue
        }
        let work = Task.detached {
          defer { clients.finish(client) }
          let began = bz_continuous_ns()
          var receipt = AgentTransportReceipt(started: Date(), operation: "unknown", status: "read_failed",
            frameMilliseconds: 0, handlerMilliseconds: 0, totalMilliseconds: 0, responseBytes: 0)
          defer {
            receipt.totalMilliseconds = (bz_continuous_ns() - began) / 1_000_000
            if Task.isCancelled { receipt.status = "cancelled" }
            clients.record(receipt)
          }
          let data: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
              var input = [CChar](repeating: 0, count: 65_536)
              let count = bz_agent_read(client, &input, Int32(input.count))
              continuation.resume(returning: count > 0
                ? input.withUnsafeBytes { Data($0.prefix(Int(count))) } : nil)
            }
          }
          receipt.frameMilliseconds = (bz_continuous_ns() - began) / 1_000_000
          guard let data, !Task.isCancelled else { return }
          let reply: AgentReply
          do {
            var request = try JSONDecoder().decode(AgentRequest.self, from: data)
            // The operation field is untrusted too. Persist only known wire operation names.
            let known = ["status", "inspect", "preview", "burn", "lifecycle", "work", "workspace",
              "workspace_preview", "workspace_clean", "disk_decide", "disk_preview", "disk_clean",
              "disk_inspect", "disk_explore", "disk_recommend", "disk_evidence",
              "owner_preview", "owner_stop", "cache_preview", "cache_clean"]
            if known.contains(request.operation) { receipt.operation = request.operation }
            request.callerPID = bz_agent_peer_pid(client)
            let handling = bz_continuous_ns()
            receipt.status = "running"
            clients.record(receipt)
            reply = await handler(request)
            receipt.handlerMilliseconds = (bz_continuous_ns() - handling) / 1_000_000
            receipt.status = reply.ok ? "ok" : "refused"
          } catch {
            receipt.status = "invalid_request"
            reply = AgentReply(ok: false, message: "Invalid agent request.")
          }
          guard !Task.isCancelled else { return }
          do {
            let line = try reply.json() + "\n"
            receipt.responseBytes = line.utf8.count
            guard line.utf8.count <= 262_144 else { receipt.status = "oversize"; return }
            let written: Int32 = await withCheckedContinuation { continuation in
              DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: line.withCString {
                  bz_agent_write(client, $0, Int32(line.utf8.count))
                })
              }
            }
            if written != 0 {
              receipt.status = "write_failed"
            }
          } catch { receipt.status = "encoding_failed" }
        }
        clients.attach(work, to: client)
      }
    }
  }
  public func stop() async {
    task.cancel()
    _ = "x".withCString { bz_agent_write(wakeup, $0, 1) }
    _ = clients.cancel()
    await task.value
    // All accepted work has now been attached. Drain cancelled handlers and sockets.
    for work in clients.cancel() { await work.value }
  }
  deinit {
    task.cancel()
    _ = "x".withCString { bz_agent_write(wakeup, $0, 1) }
    _ = clients.cancel()
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
    guard fd >= 0 else {
      throw StoreError.message("BurnZombies connection unavailable (errno \(errno): \(String(cString: strerror(errno)))). Do not open UI. If sandbox access was denied, use connected MCP or the harness normal permission flow; otherwise check observer status.")
    }
    defer { close(fd) }
    let data = try JSONEncoder().encode(request)
    let line = String(decoding: data, as: UTF8.self) + "\n"
    guard line.utf8.count < 65_536,
      line.withCString({ bz_agent_write(fd, $0, Int32(line.utf8.count)) }) == 0 else {
      throw StoreError.message("Agent request could not be sent.")
    }
    var buffer = [CChar](repeating: 0, count: 262_144)
    // Preserve the existing bounded wire deadline for storage callers. Cached
    // inspection returns promptly; optional analysis runs outside the request.
    let count = bz_agent_read_timeout(fd, &buffer, Int32(buffer.count), request.operation == "disk_inspect" ? 15000 : 5000)
    guard count > 0 else { throw StoreError.message("BurnZombies did not respond. Check the app and try again.") }
    return buffer.withUnsafeBytes { String(decoding: $0.prefix(Int(count)), as: UTF8.self) }
  }
}
