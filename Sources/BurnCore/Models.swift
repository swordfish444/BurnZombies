import Foundation

public struct ProcessIdentity: Codable, Hashable, Sendable {
  public var pid: Int32
  public var seconds: UInt64
  public var micros: UInt64
  public var boot: UInt64
  public var key: String { "\(boot):\(pid):\(seconds):\(micros)" }
  public init(pid: Int32, seconds: UInt64, micros: UInt64 = 0, boot: UInt64 = 1) {
    self.pid = pid
    self.seconds = seconds
    self.micros = micros
    self.boot = boot
  }
}

public struct Observation: Codable, Sendable {
  public var identity: ProcessIdentity
  public var parent: Int32
  public var uid: UInt32
  public var executable: String
  public var rss: UInt64
  public var cpuNS: UInt64
  public var readBytes: UInt64
  public var writeBytes: UInt64
  public var fds: Int  // Allocated descriptor-table slots (pbi_nfiles), not open descriptors.
  public var threads: Int
  public var zombie: Bool
  public var metricsValid: Bool
  public var time: Date
  public var monotonic: Double
  public var name: String {
    URL(fileURLWithPath: executable).lastPathComponent.isEmpty
      ? (zombie ? "Exited child" : "Hidden process")
      : URL(fileURLWithPath: executable).lastPathComponent
  }
  public init(
    identity: ProcessIdentity, parent: Int32 = 1, uid: UInt32 = 501,
    executable: String = "/test/helper", rss: UInt64 = 0, cpuNS: UInt64 = 0, readBytes: UInt64 = 0,
    writeBytes: UInt64 = 0, fds: Int = 0, threads: Int = 1, zombie: Bool = false,
    metricsValid: Bool = true, time: Date = Date(), monotonic: Double = 0
  ) {
    self.identity = identity
    self.parent = parent
    self.uid = uid
    self.executable = executable
    self.rss = rss
    self.cpuNS = cpuNS
    self.readBytes = readBytes
    self.writeBytes = writeBytes
    self.fds = fds
    self.threads = threads
    self.zombie = zombie
    self.metricsValid = metricsValid
    self.time = time
    self.monotonic = monotonic
  }
}

public struct Record: Codable, Identifiable, Sendable {
  public var id: String { latest.identity.key }
  public var firstSeen: Date
  public var latest: Observation
  public var samples: [Observation]
  public var missingSince: Date?
  public var orphanSince: Date?
  public var protection: Bool = false
  public var ignoreUntil: Date?
  public var alertedAt: Date?
  public var alertLevel: UInt64 = 0
  public var cpuPercent: Double? {
    guard samples.count >= 2, let a = samples.dropLast().last, latest.metricsValid, a.metricsValid,
      latest.monotonic > a.monotonic, latest.cpuNS >= a.cpuNS
    else { return nil }
    return Double(latest.cpuNS - a.cpuNS) / 1e9 / (latest.monotonic - a.monotonic) * 100
  }
  public init(_ o: Observation) {
    firstSeen = o.time
    latest = o
    samples = [o]
  }
}

public struct Member: Codable, Hashable, Sendable {
  public var identity: ProcessIdentity
  public var executable: String
  public init(_ o: Observation) {
    identity = o.identity
    executable = o.executable
  }
}

public struct Lease: Codable, Identifiable, Sendable {
  public var id: UUID
  public var label: String
  public var owner: ProcessIdentity
  public var members: [Member]
  public var created: Date
  public var ended: Date?
  public var allowCleanup: Bool
  public var disarmed: Bool
  public init(
    label: String, owner: ProcessIdentity, members: [Member], allowCleanup: Bool, now: Date = Date()
  ) {
    id = UUID()
    self.label = String(
      label.filter { !$0.isNewline && !$0.isASCII || ($0.asciiValue ?? 0) >= 32 }.prefix(60))
    self.owner = owner
    self.members = members
    created = now
    self.allowCleanup = allowCleanup
    disarmed = false
  }
}

public enum OwnerState: String, Sendable { case alive, gone, unknown }
public enum Disposition: String, Codable, Sendable {
  case healthy, investigate, eligible, protected
}
public struct Finding: Identifiable, Sendable {
  public var id: String
  public var title: String
  public var disposition: Disposition
  public var reason: String
  public var evidence: [String]
  public var uncertainty: String
  public var members: [String]
  public var leaseID: UUID?
  public var rss: UInt64
}

public struct CleanupEvent: Codable, Identifiable, Sendable {
  public var id = UUID()
  public var leaseID: UUID
  public var label: String
  public var date: Date
  public var targets: [Member]
  public var recurrenceScopes: [RecurrenceScope]?
  public var residentBefore: UInt64
  public var outcome: String
  public var detail: String
  public var verifiedCount: Int = 0
  public var verificationDate: Date?
  public var ownerProtocol: Bool?
  public var ownerExitObservedAt: Date?
  public var cpuSecondsSavedEstimate: Double?
  public var cpuSavingsRate: Double?
  public var cpuObservedSeconds: Double?
  public var cpuLegacyFloorSeconds: Double?
  public var cpuAccrualEnded: Bool?
  public var responseBeforeMS: Double?
  public var responseAfterMS: Double?
  public var responseBeforeSamples: [Double]?
  public var responseAfterSamples: [Double]?
  public init(
    leaseID: UUID, label: String, date: Date, targets: [Member], residentBefore: UInt64,
    outcome: String, detail: String
  ) {
    self.leaseID = leaseID
    self.label = label
    self.date = date
    self.targets = targets
    self.residentBefore = residentBefore
    self.outcome = outcome
    self.detail = detail
  }
}

public struct RecurrenceScope: Codable, Sendable {
  public var executable: String
  public var parent: Member
  public init(executable: String, parent: Member) { self.executable = executable; self.parent = parent }
}

public struct Preferences: Codable, Sendable {
  public var automaticCleanup = false
  public var notifications = false
  public var protectedExecutables: Set<String> = []
  public init() {}
}

public struct Catalog: Codable, Sendable {
  public var version = 1
  public var workEvidence: [WorkEvidence]?
  public var passiveEvidence: [PassiveEvidence]?
  public var diskCandidates: [DiskCandidate]?
  public var diskDiscovery: [DiskSpaceNode]?
  public var diskReceipts: [DiskReceipt]?
  public var ownerDaemons: [GradleDaemonEvidence]?
  public var managedCache: BuildKitCache.Inventory?
  public var managedCacheReviewAllowed: Bool?
  public var managedCacheAllowanceBytes: UInt64?
  public var managedCacheAttempts: [ManagedCacheAttempt]?
  public var ownerEvidenceGaps: [String]?
  public var workspaces: [WorkspaceClaim]?
  public var worktreeEvidence: [ReviewEvidence]?
  public var workspaceReceipts: [WorkspaceReceipt]?
  public var lifetimeWorktreesCleaned: Int?
  public var lifetimeDiskReclaimedBytes: UInt64?
  public var records: [String: Record] = [:]
  public var events: [CleanupEvent] = []
  public var preferences = Preferences()
  public var lifetimeVerified = 0
  public var lifetimeActions = 0
  public var lifetimeCPUSecondsSaved: Double?
  public var lifetimeResidentReleased: UInt64?
  public var lastSample: Date?
  public init() {}
  public mutating func resetContinuity() {
    for key in Array(records.keys) {
      records[key]?.samples = []
      records[key]?.orphanSince = nil
    }
    for i in events.indices where events[i].outcome == "verifying" {
      events[i].outcome = "unverified"
      events[i].detail =
        "Observation was interrupted by restart, sleep, or a sampling gap. No benefit credited."
    }
  }
  public mutating func prune(now: Date) {
    records = records.filter {
      $0.value.missingSince == nil || now.timeIntervalSince($0.value.missingSince!) < 86400
    }
    if records.count > 4096 {
      let keep = records.values.sorted { $0.latest.time > $1.latest.time }.prefix(4096)
      records = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
    }
    if let attempts = managedCacheAttempts {
      managedCacheAttempts = attempts.filter { ["prepared", "uncertain"].contains($0.outcome) }
        + Array(attempts.filter { !["prepared", "uncertain"].contains($0.outcome) }.suffix(500))
    }
    if let receipts = diskReceipts { diskReceipts = Array(receipts.suffix(500)) }
    if let receipts = workspaceReceipts {
      workspaceReceipts = receipts.filter { $0.outcome == "prepared" } + Array(receipts.filter { $0.outcome != "prepared" && now.timeIntervalSince($0.verifiedAt ?? $0.date) < 30 * 86400 }.suffix(500))
    }
    events = Array(events.filter { now.timeIntervalSince($0.date) < 30 * 86400 }.suffix(500))
  }
}
