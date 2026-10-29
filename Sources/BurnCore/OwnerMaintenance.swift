import Foundation

/// Cheap observer-facing cache. Producer inspection runs locally, off the monitor
/// actor, and never invokes a model or decides whether a resource is disposable.
public final class OwnerMaintenance: @unchecked Sendable {
  public struct Snapshot: Sendable {
    public var daemons: [GradleDaemonEvidence] = []
    public var cache: BuildKitCache.Inventory?
    public var checkedAt: Date?
    public var gaps: [String] = []
  }
  public typealias ProcessCollector = @Sendable ([Record], [String: Record], Bool) -> ([GradleDaemonEvidence], [String])
  public typealias CacheCollector = @Sendable (DiskPolicy) throws -> BuildKitCache.Inventory
  private let lock = NSLock()
  private let processCollector: ProcessCollector
  private let cacheCollector: CacheCollector
  private var value = Snapshot()
  private var running = false
  private var lastProcess = Date.distantPast
  private var lastCache = Date.distantPast
  private var policyRevision: String?
  private var cacheGeneration: UInt64 = 0
  private var processProbeRound: UInt64 = 0
  private var lastProcessProbe: [String: UInt64] = [:]
  public init(store: Store, processCollector: ProcessCollector? = nil, cacheCollector: CacheCollector? = nil) {
    self.processCollector = processCollector ?? { selected, records, complete in
      var daemons: [GradleDaemonEvidence] = [], gaps: [String] = []
      if records.values.filter({ $0.missingSince == nil && $0.latest.name == "java" }).count > selected.count {
        gaps.append("Gradle owner inspection rotates through at most 16 live Java identities per round.")
      }
      for record in selected {
        do { if let evidence = try GradleDaemon.inspect(record.latest, records: records, complete: complete) { daemons.append(evidence) } }
        catch { gaps.append("PID \(record.latest.identity.pid): supported Gradle owner evidence unavailable; preserved.") }
      }
      return (daemons, gaps)
    }
    self.cacheCollector = cacheCollector ?? { policy in
      // Decode only routing metadata; never copy credentials to a tool or model.
      let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/config.json")
      struct Config: Decodable { var currentContext: String? }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard data.count <= 262144 else { throw StoreError.message("Docker context metadata exceeds bound.") }
      let context = try JSONDecoder().decode(Config.self, from: data).currentContext ?? "default"
      return try BuildKitCache.live(store: store).inspect(target: .init(context: context, builder: context), policy: policy)
    }
    // Restore selection facts only. The next native tick prunes exact identities,
    // and every owner action still requires fresh producer revalidation. Never
    // restore a managed-cache route or treat saved checkedAt as a new probe.
    value.daemons = (try? store.load().ownerDaemons) ?? []
  }
  public func snapshot() -> Snapshot { lock.withLock { value } }
  public func tick(records: [String: Record], policy: DiskPolicy, complete: Bool, now: Date = Date()) {
    let job = lock.withLock { () -> (process: Bool, probes: [Record], cache: Bool, generation: UInt64)? in
      value.daemons.removeAll { owner in
        guard let live = records[owner.member.identity.key], live.missingSince == nil else { return true }
        return Member(live.latest) != owner.member
      }
      if policyRevision != policy.revision {
        policyRevision = policy.revision
        cacheGeneration &+= 1
        value.cache = nil; lastCache = .distantPast
      }
      let processDue = now.timeIntervalSince(lastProcess) >= 300
      let cacheInterval = (value.cache?.eligibleBytes ?? 0) >= DiskCandidate.minimumReviewBytes ? 300 : Double(policy.scanHours * 3600)
      let cacheDue = policy.mode != "off" && now.timeIntervalSince(lastCache) >= cacheInterval
      guard !running, processDue || cacheDue else { return nil }
      running = true
      var probes: [Record] = []
      if processDue {
        lastProcess = now
        let candidates = records.values.filter { $0.missingSince == nil && $0.latest.name == "java" }
        let live = Set(candidates.map(\.id))
        lastProcessProbe = lastProcessProbe.filter { live.contains($0.key) }
        probes = Array(candidates.sorted {
          let a = lastProcessProbe[$0.id] ?? 0, b = lastProcessProbe[$1.id] ?? 0
          if a != b { return a < b }
          if $0.latest.identity.pid != $1.latest.identity.pid { return $0.latest.identity.pid < $1.latest.identity.pid }
          return $0.id < $1.id
        }.prefix(16))
        processProbeRound &+= 1
        for probe in probes { lastProcessProbe[probe.id] = processProbeRound }
      }
      if cacheDue { lastCache = now }
      return (processDue, probes, cacheDue, cacheGeneration)
    }
    guard let job else { return }
    // Producer probes are blocking local I/O; never occupy a cooperative actor worker.
    DispatchQueue.global(qos: .utility).async { [self] in
      // Keep the full process map for child/ownership checks; only owner probes rotate.
      let processResult = job.process ? processCollector(job.probes, records, complete) : nil
      var cache: BuildKitCache.Inventory?, cacheGap: String?
      if job.cache, lock.withLock({ cacheGeneration == job.generation }) {
        do { cache = try cacheCollector(policy) }
        catch { cacheGap = "Local BuildKit inventory unavailable: " + error.localizedDescription.prefix(180) }
      }
      lock.withLock {
        if let processResult {
          // Keep the full live backlog across bounded rounds. A reprobed failure
          // or busy owner replaces/removes its earlier positive evidence; only
          // unprobed identities retain their truthful original checkedAt.
          let probed = Set(job.probes.map(\.id))
          var retained = value.daemons.filter { !probed.contains($0.member.identity.key) }
          retained += processResult.0
          value.daemons = retained.sorted { $0.member.identity.pid < $1.member.identity.pid }
          value.gaps = Array(processResult.1.prefix(20))
        }
        if job.cache && cacheGeneration == job.generation {
          value.cache = cache
          if let cacheGap { value.gaps = Array((value.gaps + [cacheGap]).suffix(20)) }
        }
        value.checkedAt = Date()
        running = false
      }
    }
  }
  public func invalidateCache() {
    lock.withLock {
      cacheGeneration &+= 1
      value.cache = nil; lastCache = .distantPast
    }
  }
}

public extension GradleDaemonEvidence {
  var id: String { "owner-process:" + member.identity.key }
  var revision: String {
    WorkEvidence.hash(id + "|" + daemonUID + "|" + state + "|" + String(lastBusy.timeIntervalSince1970)
      + "|" + evidenceFingerprint + "|" + nativeChildren.map(\.key).sorted().joined(separator: ","))
  }
}

/// Explicit wire ID: Swift's synthesized Codable omits computed properties.
public struct OwnerProcessSummary: Codable, Sendable {
  public var id: String
  public var evidence: GradleDaemonEvidence
  public var requiresRevalidation: Bool
  public init(_ evidence: GradleDaemonEvidence) {
    id = evidence.id; self.evidence = evidence; requiresRevalidation = true
  }
}

public struct ManagedCacheAttempt: Codable, Sendable {
  public var plan: BuildKitCache.Plan
  public var date: Date
  public var outcome: String
  public var receipt: BuildKitCache.Receipt?
  public var detail: String
}

/// Model-facing projection excludes thousands of irrelevant cache records.
public struct ManagedCacheSummary: Codable, Sendable {
  public var id: String
  public var revision: String
  public var owner: BuildKitCache.Owner
  public var date: Date
  public var eligibleBytes: UInt64
  public var eligibleRecords: [BuildKitCache.Record]
  public var omittedEligibleRecords: Int
  public init(_ inventory: BuildKitCache.Inventory, blocked: Set<String> = [], allowance: UInt64? = nil) {
    id = "cache:" + WorkEvidence.hash(inventory.owner.daemonID + "|" + inventory.owner.target.context)
    owner = inventory.owner; date = inventory.date
    let eligible = inventory.records.filter { inventory.eligibleIDs.contains($0.id) && !blocked.contains($0.id) && (allowance == nil || $0.bytes <= allowance!) }.sorted { $0.bytes > $1.bytes }
    eligibleBytes = eligible.reduce(UInt64(0)) { $0 + $1.bytes }
    var opportunity = inventory
    opportunity.records = eligible; opportunity.eligibleIDs = eligible.map(\.id); opportunity.eligibleBytes = eligibleBytes
    revision = WorkEvidence.hash(opportunity.revision + "|" + (allowance.map(String.init) ?? "recommend"))
    eligibleRecords = Array(eligible.prefix(32)); omittedEligibleRecords = max(0, eligible.count - 32)
  }
}
