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
  /// Process group. An orphan whose group leader is gone was left behind by a job.
  public var pgid: Int32?
  /// From the path's spelling: a file URL would look at the file, which can be in a place
  /// macOS protects.
  public var name: String {
    let name = (executable as NSString).lastPathComponent
    return name.isEmpty || executable.isEmpty ? (zombie ? "Exited child" : "Hidden process") : name
  }
  public init(
    identity: ProcessIdentity, parent: Int32 = 1, uid: UInt32 = 501,
    executable: String = "/test/helper", rss: UInt64 = 0, cpuNS: UInt64 = 0, readBytes: UInt64 = 0,
    writeBytes: UInt64 = 0, fds: Int = 0, threads: Int = 1, zombie: Bool = false,
    metricsValid: Bool = true, time: Date = Date(), monotonic: Double = 0, pgid: Int32? = nil
  ) {
    self.pgid = pgid
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
  /// Set when the process was seen with a live parent and later reparented to launchd.
  public var orphanSince: Date?
  /// Last observation with noticeable CPU use; nil means idle since first seen.
  public var lastBusy: Date?
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

public struct CleanupEvent: Codable, Identifiable, Sendable {
  public var fixture: Bool?
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
  public init(executable: String, parent: Member) {
    self.executable = executable
    self.parent = parent
  }
}

public struct Preferences: Codable, Sendable {
  public var automaticCleanup = false
  public var notifications = false
  public var notificationBudget: Int?
  public var notificationDetails: Bool?
  public var shareDecisionHistory: Bool?
  public var protectedExecutables: Set<String> = []
  public init() {}
}

public struct Catalog: Codable, Sendable {
  public var version = 1
  public var intentVersion: Int?
  public var workEvidence: [WorkEvidence]?
  public var passiveEvidence: [PassiveEvidence]?
  public var pinnedOperationIDs: Set<String>?
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
    let pinned = pinnedOperationIDs ?? []
    if let attempts = managedCacheAttempts {
      let preserve = attempts.filter {
        ["prepared", "uncertain"].contains($0.outcome) || pinned.contains($0.plan.id.uuidString)
      }
      let ids = Set(preserve.map { $0.plan.id })
      managedCacheAttempts = Self.retained(
        preserve, attempts.filter { !ids.contains($0.plan.id) }, by: \.date)
    }
    if let receipts = diskReceipts {
      let preserve = receipts.filter {
        !["verified", "refused"].contains($0.outcome) || pinned.contains($0.id.uuidString)
      }
      let ids = Set(preserve.map(\.id))
      diskReceipts = Self.retained(preserve, receipts.filter { !ids.contains($0.id) }, by: \.date)
    }
    if let receipts = workspaceReceipts {
      let preserve = receipts.filter {
        !["verified", "refused"].contains($0.outcome) || pinned.contains($0.id.uuidString)
      }
      let ids = Set(preserve.map(\.id))
      let recent = receipts.filter {
        !ids.contains($0.id) && now.timeIntervalSince($0.verifiedAt ?? $0.date) < 30 * 86400
      }
      workspaceReceipts = Self.retained(preserve, recent) { $0.verifiedAt ?? $0.date }
    }
    let preserve = events.filter {
      !["verified", "refused"].contains($0.outcome) || pinned.contains($0.id.uuidString)
    }
    let ids = Set(preserve.map(\.id))
    let recent = events.filter { !ids.contains($0.id) && now.timeIntervalSince($0.date) < 30 * 86400 }
    events = Self.retained(preserve, recent, by: \.date)
  }
  /// What a list of receipts keeps: everything unresolved, and the newest 500 of the rest, oldest
  /// first. Date decides, not place: a row is unresolved when it's added, so it stops being last.
  private static func retained<Row>(_ unresolved: [Row], _ rest: [Row], by date: (Row) -> Date)
    -> [Row]
  {
    let newest: ArraySlice<Row> = rest.sorted { date($0) < date($1) }.suffix(500)
    return (unresolved + newest).sorted { date($0) < date($1) }
  }
}
