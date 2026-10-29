import Foundation

enum WorktreeEncoding {
  static func data<T: Encodable>(_ value: T) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return try e.encode(value)
  }
}

public struct WorktreeIdentity: Codable, Equatable, Sendable {
  public var path: String
  public var common: String
  public var administration: String
  public var device: Int32
  public var inode: UInt64
  public var commonInode: UInt64
  public var administrationInode: UInt64
  public var id: String {
    WorkEvidence.hash("\(common)|\(device)|\(commonInode)|\(administration)|\(inode)")
  }
}

public struct WorktreeRecord: Codable, Identifiable, Sendable {
  public var id: String
  public var path: String
  public var repository: String
  public var identity: WorktreeIdentity?
  public var branch: String?
  public var head: String?
  public var main = false
  public var bare = false
  public var ownerManaged = false
  public var locked = false
  public var missing = false
  public var observedAt = Date()
  public var firstSeen = Date()
  public var changedAt = Date()
  public var revision = ""
  public var status = ""
  public var changes = 0
  public var ignored = 0
  public var allocated: UInt64 = 0
  public var blockers: [String] = []
  public var gaps: [String] = []
  public var consumer = "unknown"
  public var managed = false
  public var kept = false
  public var confirmedRevision: String?
  public var confirmedAt: Date?
  public var retired = false
  public var readinessRevision: String?
  public var lastCommitAt: Date?
  public var lastFileChange: Date?
  public var apparentIdleDays: Int? {
    let dates = [lastCommitAt, lastFileChange].compactMap { $0 }
    guard let latest = dates.max(), latest <= Date() else { return nil }
    return Int(Date().timeIntervalSince(latest) / 86400)
  }
  public init(id: String, path: String, repository: String, identity: WorktreeIdentity? = nil) {
    self.id = id
    self.path = path
    self.repository = repository
    self.identity = identity
  }
  public var state: String {
    if retired { return "Retired / recoverable" }
    if missing { return "Missing or moved" }
    if consumer == "in use" || kept { return "Active" }
    if !gaps.isEmpty || !blockers.isEmpty { return "Inspection blocked" }
    if changes + ignored > 0 { return "Contains local work" }
    if confirmedRevision == revision { return "Ready to retire" }
    return (apparentIdleDays ?? 0) >= 14 ? "Possibly stale" : "Needs review"
  }
}

public struct WorktreeClaim: Codable, Identifiable, Sendable {
  public var id: String
  public var worktreeID: String
  public var tokenHash: String
  public var label: String
  public var condition: String
  public var evidence: String
  public var state: String
  public var head: String?
  public var updated: Date
  public var releasedRevision: String?
}

public struct WorktreePolicy: Codable, Sendable {
  public var roots: [String] = []
  public var automaticRepositories: [String] = []
  public var staleDays = 14
  public var releaseGraceHours = 24
  public var maximumPerDay = 3
  public var archiveRetentionDays = 30
  public init() {}
  public func validate() throws {
    guard roots.count <= 32, automaticRepositories.count <= 1000, (1...365).contains(staleDays),
      (0...168).contains(releaseGraceHours), (1...20).contains(maximumPerDay),
      (30...3650).contains(archiveRetentionDays),
      roots.allSatisfy({
        $0.hasPrefix("/") && $0.utf8.count < 4096 && $0 != "/" && $0 != NSHomeDirectory()
      }),
      Set(roots).count == roots.count,
      Set(automaticRepositories).count == automaticRepositories.count
    else { throw StoreError.message("Invalid worktree policy; operations paused.") }
  }
  public var revision: String {
    WorkEvidence.hash(String(decoding: (try? WorktreeEncoding.data(self)) ?? Data(), as: UTF8.self))
  }
}

public struct WorktreeOperation: Codable, Identifiable, Sendable {
  public var id: String
  public var worktreeID: String
  public var originalPath: String
  public var repository: String
  public var head: String
  public var phase: String
  public var kind: String
  public var date: Date
  public var completedAt: Date?
  public var recoveryPath: String
  public var archiveDigest: String?
  public var detail: String
  public var allocated: UInt64
  public var diskCredit: UInt64 = 0
  public var archiveBytes: UInt64 = 0
  public var purged = false
  public var restoredPaths: [String] = []
  public var quarantinePath: String?
  public var quarantineIdentity: WorktreeIdentity?
  public var purgePending: Bool?
  public var interruptedPhase: String?
  public init(
    id: String, worktreeID: String, originalPath: String, repository: String, head: String,
    phase: String, kind: String, date: Date, recoveryPath: String, detail: String, allocated: UInt64
  ) {
    self.id = id
    self.worktreeID = worktreeID
    self.originalPath = originalPath
    self.repository = repository
    self.head = head
    self.phase = phase
    self.kind = kind
    self.date = date
    self.recoveryPath = recoveryPath
    self.detail = detail
    self.allocated = allocated
  }
}

public struct WorktreePlan: Codable, Sendable {
  public var token: String
  public var worktreeID: String
  public var revision: String
  public var claimRevision: String
  public var policyRevision: String
  public var identity: WorktreeIdentity
  public var created: Date
  public var caller: String
  public var dirty: Bool
  public var interactive: Bool?
}

public struct WorktreeRequest: Codable, Sendable {
  public var action: String
  public var id: String?
  public var revision: String?
  public var path: String?
  public var token: String?
  public var evidence: String?
  public var condition: String?
  public var offset: Int?
  public var enabled: Bool?
  public var ids: [String]?
  public var revisions: [String: String]?
  public init(
    _ action: String, id: String? = nil, revision: String? = nil, path: String? = nil,
    token: String? = nil, evidence: String? = nil, condition: String? = nil, offset: Int? = nil,
    enabled: Bool? = nil,
    ids: [String]? = nil, revisions: [String: String]? = nil
  ) {
    self.action = action
    self.id = id
    self.revision = revision
    self.path = path
    self.token = token
    self.evidence = evidence
    self.condition = condition
    self.offset = offset
    self.enabled = enabled
    self.ids = ids
    self.revisions = revisions
  }
}

public struct WorktreeReply: Codable, Sendable {
  public var records: [WorktreeRecord] = []
  public var operations: [WorktreeOperation] = []
  public var policy = WorktreePolicy()
  public var nextOffset: Int?
  public var nextOperationOffset: Int?
  public var token: String?
  public var detail = "Read-only worktree inventory. Unknown evidence is not removal permission."
  public var gaps: [String] = []
  public var owners: [WorktreeOwnerSummary] = []
  public var advice: [WorktreeAdvice] = []
  public var batch: [WorktreeBatchItem] = []
  public var delivery: [WorktreeDeliveryEvidence] = []
  public var restores: [WorktreeRestoreAttempt] = []
  public var suggestedRoots: [String] = []
  public init() {}
}

public struct WorktreeRestoreAttempt: Codable, Identifiable, Sendable {
  public var id: String
  public var recoveryID: String
  public var destination: String
  public var phase: String
  public var date: Date
  public var detail: String
}

public struct WorktreeBatchItem: Codable, Identifiable, Sendable {
  public var id: String
  public var path: String
  public var detail: String
  public var ready: Bool
}

public struct WorktreeOwnerSummary: Codable, Sendable {
  public var id: String
  public var worktreeID: String
  public var label: String
  public var condition: String
  public var evidence: String
  public var state: String
  public var updated: Date
  public var releasedHead: String?
  public var releasedRevision: String?
}
public struct WorktreeAdvice: Codable, Identifiable, Sendable {
  public var id: String
  public var revision: String
  public var summary: String
  public var nextStep: String
  public var date: Date
  public var readinessRevision: String?
}
