import BurnCore
import Darwin
import Foundation

private func ownerDecode<T: Decodable>(_ object: [String: Any], as: T.Type = T.self) throws -> T {
  try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
private func ownerObject<T: Encodable>(_ value: T) throws -> Any {
  try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
private func ownerInventory(_ policy: DiskPolicy, now: Date = Date()) throws -> BuildKitCache.Inventory {
  let record: [String: Any] = ["id": "oldcache111", "bytes": 12_000_000_000,
    "created": now.addingTimeInterval(-40 * 86400).timeIntervalSinceReferenceDate,
    "lastUsed": now.addingTimeInterval(-30 * 86400).timeIntervalSinceReferenceDate,
    "mutable": false, "reclaimable": true, "shared": false, "type": "regular"]
  return try ownerDecode(["owner": ["target": ["context": "fixture", "builder": "fixture"],
    "endpoint": "unix:///private/tmp/owned-fixture.sock", "socketIdentity": "fixture-inode",
    "executableIdentity": "fixture-cli", "daemonID": "fixture-daemon", "node": "fixture",
    "buildkitVersion": "v0.26.0"], "date": now.timeIntervalSinceReferenceDate,
    "policyRevision": policy.revision, "records": [record], "eligibleIDs": ["oldcache111"],
    "eligibleBytes": 12_000_000_000])
}

func ownerMaintenanceProof() async throws {
  let now = Date(), root = URL(fileURLWithPath: "/private/tmp/bz-owner-proof-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try Store(root: root)
  let observation = Observation(identity: .init(pid: 32101, seconds: 70), executable: "/fixture/java")
  let record = Record(observation)
  let evidence: GradleDaemonEvidence = try ownerDecode([
    "member": ownerObject(Member(observation)), "daemonUID": UUID().uuidString,
    "gradleHome": "/fixture/producer", "distribution": "/fixture/distribution", "version": "8.14.6",
    "state": "IDLE", "residentBytes": 0, "cpuTimeNS": 0, "nativeChildren": [], "childrenVisibilityComplete": true,
    "checkedAt": now.timeIntervalSinceReferenceDate, "lastBusy": now.addingTimeInterval(-900).timeIntervalSinceReferenceDate,
    "evidenceFingerprint": "fixture-owner-facts", "eligible": true, "reason": "fixture"])
  var catalog = Catalog(); catalog.records[record.id] = record; catalog.ownerDaemons = [evidence]
  var policy = DiskPolicy(); policy.mode = "automatic"; policy.maximumGBPerDay = 40
  let inventory = try ownerInventory(policy, now: now)
  catalog.managedCache = inventory
  let initial = ReviewEvidence.pending(in: catalog)
  equal(initial.count, 2, "Eligible owner process and aggregate cache must reach the real scheduling queue")
  equal(Set(initial.map { ReviewLane.lane(for: $0) }), [.ownerProcess, .managedCache])
  var reviewer = MachineReviewState()
  reviewer.reviewedEvidence = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.revision) })
  catalog.ownerDaemons?[0].checkedAt = now.addingTimeInterval(-1)
  catalog.managedCache?.date = now.addingTimeInterval(-1)
  let signal = HarnessHook.Signal(observedAt: now, processCount: 1, residentBytes: 0, pressure: "Low",
    reviewEvidence: ReviewEvidence.pending(in: catalog))
  check(reviewer.pending(signal, now: now).isEmpty, "Fresh timestamps alone must never wake another model review")

  var claim: WorkEvidence = try ownerDecode(["id": "active-owner", "tokenHash": "fixture-capability",
    "members": [ownerObject(Member(observation))], "anchors": [], "label": "retained work", "purpose": "fixture",
    "completionCondition": "owner releases it", "created": now.timeIntervalSinceReferenceDate,
    "updated": now.timeIntervalSinceReferenceDate, "state": "active", "evidence": "Still needed"])
  catalog.workEvidence = [claim]
  checkFalse(ReviewEvidence.pending(in: catalog).contains { $0.id == evidence.id }, "Active owner claims block owner-protocol review")
  claim.updated = .distantPast; catalog.workEvidence = [claim]
  checkFalse(ReviewEvidence.pending(in: catalog).contains { $0.id == evidence.id }, "Old active claims never expire into permission")
  catalog.workEvidence = nil
  let child = Observation(identity: .init(pid: 32102, seconds: 90), parent: observation.identity.pid)
  catalog.records[child.identity.key] = Record(child)
  checkFalse(ReviewEvidence.pending(in: catalog).contains { $0.id == evidence.id }, "A newly observed child blocks review before stale owner inventory refreshes")
  catalog.records.removeValue(forKey: child.identity.key)
  catalog.records[record.id]?.latest.identity.seconds += 1
  checkFalse(ReviewEvidence.pending(in: catalog).contains { $0.id == evidence.id }, "PID reuse cannot inherit owner evidence")
  catalog.records[record.id] = record
  catalog.ownerDaemons?[0].checkedAt = now.addingTimeInterval(-601)
  check(ReviewEvidence.pending(in: catalog).contains { $0.id == evidence.id }, "Cached owner facts remain selectable; fresh actuator revalidation is still mandatory")
  check(OwnerProcessSummary(catalog.ownerDaemons![0]).requiresRevalidation, "Cached facts must never imply current action authority")
  catalog.ownerDaemons?[0] = evidence
  catalog.ownerDaemons?[0].eligible = false
  catalog.ownerDaemons?[0].childrenVisibilityComplete = false
  checkFalse(ReviewEvidence.pending(in: catalog).contains { $0.id == evidence.id }, "Incomplete visibility preserves the owner")

  let projected = DiskReviewPolicy(policy)
  equal(projected.mode, "automatic"); equal(projected.maximumGBPerDay, 40)
  equal(projected.minimumAgeDays, policy.minimumAgeDays); equal(projected.keepNewest, policy.keepNewest)
  let metadata = try ownerObject(projected) as! [String: Any]
  equal(metadata["mode"] as? String, "automatic")
  equal(metadata["maximumGBPerDay"] as? Int, 40, "The model must receive the actual daily allowance")
  try ownerQueueProgressProof(evidence: evidence, inventory: inventory, now: now)
  try await ownerProbeFairnessProof(store: store)
  try await ownerBacklogFairnessProof(store: store, evidence: evidence)
  ownerLaneFairnessProof(now: now)
  try ownerRefusalRecoveryProof(evidence: evidence, now: now)
  try await collectorGenerationProof(store: store)
  ownerWatchProof()
  print("PASS owner queue visibility, unchanged-evidence economy, active claims, identities/children, collector invalidation and owner exit watch")
}

private func ownerQueueProgressProof(evidence: GradleDaemonEvidence, inventory seed: BuildKitCache.Inventory,
                                     now: Date) throws {
  var other = evidence
  other.member.identity.pid += 20
  other.daemonUID = UUID().uuidString
  var catalog = Catalog()
  catalog.ownerDaemons = [evidence, other]
  for owner in [evidence, other] {
    let observation = Observation(identity: owner.member.identity, executable: owner.member.executable)
    catalog.records[observation.identity.key] = Record(observation)
  }
  let signal = HarnessHook.Signal(observedAt: now, processCount: 2, residentBytes: 0, pressure: "Low",
    reviewEvidence: ReviewEvidence.pending(in: catalog))
  var state = MachineReviewState()
  let first = state.pending(signal, now: now)
  equal(first.map(\.id), [evidence.id], "An invocation offering one owner action must select exactly one owner")
  state.begin(first, now: now)
  state.complete(first, progress: ReviewProgress(attempt: UUID(), selected: first.map(\.id)))
  isNil(state.reviewedEvidence?[other.id])
  equal(state.pending(signal, now: now.addingTimeInterval(3600)).map(\.id), [other.id],
    "Completing the first owner must not acknowledge or starve the unvisited second owner")

  var inventory = seed
  var remaining = inventory.records[0]; remaining.id = "othercache22"; remaining.bytes = 9_000_000_000
  inventory.records.append(remaining); inventory.eligibleIDs.append(remaining.id)
  inventory.eligibleBytes += remaining.bytes
  let prepared: ManagedCacheAttempt = try ownerDecode([
    "plan": ["id": UUID().uuidString, "inventory": ownerObject(inventory),
      "recordIDs": [seed.records[0].id], "cacheBytes": seed.records[0].bytes,
      "created": now.timeIntervalSinceReferenceDate, "expires": now.addingTimeInterval(120).timeIntervalSinceReferenceDate],
    "date": now.addingTimeInterval(-40 * 86400).timeIntervalSinceReferenceDate,
    "outcome": "prepared", "detail": "Unresolved isolated fixture"])
  let blocked = ManagedCacheAttempt.blockedIDs([prepared], inventory: inventory, now: now)
  let summary = ManagedCacheSummary(inventory, blocked: blocked)
  equal(summary.eligibleBytes, 9_000_000_000, "An unresolved record must be removed from the displayed opportunity total")
  equal(summary.eligibleRecords.map(\.id), [remaining.id], "Blocked IDs must not reach the model's selectable records")
  catalog = Catalog(); catalog.managedCache = inventory; catalog.managedCacheAttempts = [prepared]
  check(ReviewEvidence.pending(in: catalog).isEmpty,
    "A raw aggregate over 10 GB must not queue when fewer than 10 GB remain actionable")
  inventory.records[1].bytes = 10_000_000_000; inventory.eligibleBytes += 1_000_000_000
  catalog.managedCache = inventory
  equal(ReviewEvidence.pending(in: catalog).count, 1, "Exactly 10 GB of unblocked owner cache remains reviewable")
  equal(ManagedCacheSummary(inventory, blocked: blocked).eligibleBytes, 10_000_000_000)
  catalog.managedCacheReviewAllowed = false
  check(ReviewEvidence.pending(in: catalog).isEmpty, "An owner cache outside current policy/allowance must not wake a review")
  catalog.managedCacheReviewAllowed = true
  catalog.managedCacheAllowanceBytes = 9_000_000_000
  var cacheReviewer = MachineReviewState(); cacheReviewer.pendingSince = now.addingTimeInterval(-120)
  var cacheSignal = HarnessHook.Signal(observedAt: now, processCount: 0, residentBytes: 0, pressure: "Low",
    reviewEvidence: ReviewEvidence.pending(in: catalog))
  checkFalse(cacheReviewer.due(cacheSignal, requested: true, now: now), "Under 10 GB allowance cannot dispatch a model")
  let skipped = cacheReviewer.pending(cacheSignal, now: now)
  check(skipped.isEmpty, "Under-budget cache must not enter the acknowledged batch")
  cacheReviewer.begin(skipped, now: now)
  check(cacheReviewer.reviewedEvidence?.isEmpty == true, "Insufficient allowance must not consume backlog revisions")
  catalog.managedCacheAllowanceBytes = 10_000_000_000
  cacheSignal.reviewEvidence = ReviewEvidence.pending(in: catalog)
  equal(cacheReviewer.pending(cacheSignal, now: now).count, 1, "Restored allowance wakes the unchanged cache backlog")
  check(cacheReviewer.due(cacheSignal, requested: false, now: now), "Restored allowance must be automatically dispatchable")
  let actionableRevision = cacheSignal.reviewEvidence?.first?.revision
  inventory.records[0].bytes += 5_000_000_000
  inventory.records[0].lastUsed = now
  inventory.records[0].mutable = true
  inventory.eligibleBytes += 5_000_000_000
  catalog.managedCache = inventory
  equal(ReviewEvidence.pending(in: catalog).first?.revision, actionableRevision,
    "Changes to an already-blocked cache record cannot manufacture a fresh review opportunity")
  equal(ManagedCacheSummary(inventory, blocked: blocked, allowance: 10_000_000_000).revision, actionableRevision)

  var uncertain = prepared; uncertain.plan.id = UUID(); uncertain.outcome = "uncertain"
  let completed = (0..<510).map { index -> ManagedCacheAttempt in
    var item = prepared; item.plan.id = UUID(); item.outcome = "refused"
    item.date = now.addingTimeInterval(Double(index)); return item
  }
  catalog.managedCacheAttempts = [prepared, uncertain] + completed
  catalog.prune(now: now)
  let retained = catalog.managedCacheAttempts ?? []
  check(retained.contains { $0.plan.id == prepared.plan.id && $0.outcome == "prepared" },
    "Pending cleanup tombstones must survive age and completed-history limits")
  check(retained.contains { $0.plan.id == uncertain.plan.id && $0.outcome == "uncertain" },
    "Uncertain owner RPCs must never become retryable because history was pruned")
  equal(retained.filter { $0.outcome == "refused" }.count, 500)
  equal(retained.count, 502)
}

private final class OwnerProbeRounds: @unchecked Sendable {
  struct Round { var selected: [String]; var visible: Set<String>; var complete: Bool }
  private let lock = NSLock()
  private var values: [Round] = []
  func collect(_ selected: [Record], _ all: [String: Record], _ complete: Bool) -> ([GradleDaemonEvidence], [String]) {
    lock.withLock { values.append(.init(selected: selected.map(\.id), visible: Set(all.keys), complete: complete)) }
    return ([], [])
  }
  var rounds: [Round] { lock.withLock { values } }
}
private func ownerProbeFairnessProof(store: Store) async throws {
  let java = (0..<40).map { index in
    Record(Observation(identity: .init(pid: Int32(41000 + index), seconds: 1), executable: "/fixture/java"))
  }
  var records = Dictionary(uniqueKeysWithValues: java.map { ($0.id, $0) })
  let child = Record(Observation(identity: .init(pid: 42000, seconds: 1), parent: 41039, executable: "/fixture/build-worker"))
  records[child.id] = child
  var missing = Record(Observation(identity: .init(pid: 40000, seconds: 1), executable: "/fixture/java"))
  missing.missingSince = Date(); records[missing.id] = missing
  let probes = OwnerProbeRounds()
  let collector = OwnerMaintenance(store: store, processCollector: { probes.collect($0, $1, $2) },
    cacheCollector: { _ in throw StoreError.message("Off policy must not collect cache") }, accessCheck: fixtureAccess)
  var policy = DiskPolicy(); policy.mode = "off"
  let now = Date()
  for round in 0..<3 {
    let previous = collector.snapshot().checkedAt
    collector.tick(records: records, policy: policy, complete: true, now: now.addingTimeInterval(Double(round * 300)))
    try await waitForOwner({ probes.rounds.count == round + 1 && collector.snapshot().checkedAt != previous }, "Rotating owner round did not finish")
  }
  let rounds = probes.rounds
  equal(rounds.map { $0.selected.count }, [16, 16, 16], "Every round remains bounded to 16 probes")
  equal(rounds[0].selected, Array(java.prefix(16)).map(\.id))
  equal(rounds[1].selected, Array(java.dropFirst(16).prefix(16)).map(\.id), "Later PIDs cannot be permanently starved")
  equal(Array(rounds[2].selected.prefix(8)), Array(java.suffix(8)).map(\.id), "Never-probed owners precede repeat probes")
  equal(Set(rounds.flatMap(\.selected)), Set(java.map(\.id)), "All 40 live identities are inspected within three bounded rounds")
  check(rounds.allSatisfy { $0.visible == Set(records.keys) && $0.complete }, "Every probe receives the full child/ownership map and visibility flag")
  checkFalse(rounds.flatMap(\.selected).contains(missing.id), "Missing process identities cannot consume probe slots")
  records.removeValue(forKey: java[0].id)
  let reused = Record(Observation(identity: .init(pid: 41000, seconds: 2), executable: "/fixture/java"))
  records[reused.id] = reused
  let previous = collector.snapshot().checkedAt
  collector.tick(records: records, policy: policy, complete: false, now: now.addingTimeInterval(900))
  try await waitForOwner({ probes.rounds.count == 4 && collector.snapshot().checkedAt != previous }, "Reused identity round did not finish")
  equal(probes.rounds[3].selected.first, reused.id, "PID reuse starts as an unprobed identity")
  checkFalse(probes.rounds[3].complete, "Rotation must never upgrade incomplete visibility")
}

private final class OwnerBacklogProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let template: GradleDaemonEvidence
  private var failed: String?
  private var busy: String?
  init(_ template: GradleDaemonEvidence) { self.template = template }
  func setChanges(failed: String, busy: String) { lock.withLock { self.failed = failed; self.busy = busy } }
  func collect(_ selected: [Record], _ records: [String: Record], _ complete: Bool) -> ([GradleDaemonEvidence], [String]) {
    lock.withLock {
      (selected.compactMap { record in
        guard record.id != failed else { return nil }
        var value = template; value.member = Member(record.latest)
        value.daemonUID = record.id; value.checkedAt = Date()
        value.state = record.id == busy ? "BUSY" : "IDLE"
        value.eligible = record.id != busy && complete
        return value
      }, [])
    }
  }
}
private func ownerBacklogFairnessProof(store: Store, evidence: GradleDaemonEvidence) async throws {
  let owners = (0..<48).map { Record(Observation(identity: .init(pid: Int32(43000 + $0), seconds: 1), executable: "/fixture/java")) }
  var records = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0) })
  let probe = OwnerBacklogProbe(evidence)
  let collector = OwnerMaintenance(store: store, processCollector: { probe.collect($0, $1, $2) },
    cacheCollector: { _ in throw StoreError.message("Off policy must not collect cache") }, accessCheck: fixtureAccess)
  var policy = DiskPolicy(); policy.mode = "off"
  let now = Date()
  for round in 0..<3 {
    let previous = collector.snapshot().checkedAt
    collector.tick(records: records, policy: policy, complete: true, now: now.addingTimeInterval(Double(round * 300)))
    try await waitForOwner({ collector.snapshot().checkedAt != previous }, "Owner backlog round did not finish")
    equal(collector.snapshot().daemons.count, (round + 1) * 16, "Unprobed owners must remain in the live backlog")
  }
  var catalog = Catalog(); catalog.records = records; catalog.ownerDaemons = collector.snapshot().daemons
  // Model cadence can exceed a full native probe cycle. Cached timestamps remain
  // honest and do not silently erase unvisited owners between hourly decisions.
  for index in catalog.ownerDaemons!.indices { catalog.ownerDaemons?[index].checkedAt = now.addingTimeInterval(-3600) }
  var reviewer = MachineReviewState(), selectedIDs = Set<String>()
  for hour in 0..<48 {
    let date = now.addingTimeInterval(Double(hour * 3600))
    let signal = HarnessHook.Signal(observedAt: date, processCount: 48, residentBytes: 0, pressure: "Low",
      reviewEvidence: ReviewEvidence.pending(in: catalog))
    reviewer.pendingSince = date.addingTimeInterval(-120)
    check(reviewer.due(signal, requested: false, now: date, intervalHours: 1), "An unvisited owner must stay dispatchable at hourly cadence")
    let selected = reviewer.pending(signal, now: date)
    equal(selected.count, 1)
    let liveIDs = Set(signal.reviewEvidence!.map(\.id))
    reviewer.reviewedEvidence = (reviewer.reviewedEvidence ?? [:]).filter { liveIDs.contains($0.key) }
    reviewer.attempts = (reviewer.attempts ?? [:]).filter { liveIDs.contains($0.key) }
    reviewer.lastStarted = date; reviewer.begin(selected, now: date)
    reviewer.complete(selected, progress: ReviewProgress(attempt: UUID(), selected: selected.map(\.id)))
    selectedIDs.formUnion(selected.map(\.id))
  }
  equal(selectedIDs.count, 48, "Hourly reviews must eventually visit all 48 owners, not one repeating 16-owner tranche")
  catalog.managedCache = try ownerInventory(policy, now: now)
  try store.save(catalog)
  let restarted = OwnerMaintenance(store: store, processCollector: { probe.collect($0, $1, $2) },
    cacheCollector: { _ in throw StoreError.message("Off policy must not collect cache") }, accessCheck: fixtureAccess)
  equal(restarted.snapshot().daemons.count, 48, "An observer restart must retain the saved owner review backlog")
  equal(restarted.snapshot().daemons.first?.checkedAt, now.addingTimeInterval(-3600), "Restoring facts must not freshen their timestamps")
  check(restarted.snapshot().cache == nil, "A persisted managed-cache route must not be restored as fresh owner evidence")
  check(restarted.snapshot().checkedAt == nil, "Restored owner facts are not a completed local probe")
  probe.setChanges(failed: owners[0].id, busy: owners[1].id)
  let previous = restarted.snapshot().checkedAt
  restarted.tick(records: records, policy: policy, complete: true, now: now.addingTimeInterval(900))
  try await waitForOwner({ restarted.snapshot().checkedAt != previous }, "Changed owner round did not finish")
  let updated = restarted.snapshot().daemons
  checkFalse(updated.contains { $0.member.identity.key == owners[0].id }, "Inaccessible reprobes must remove stale positive facts")
  checkFalse(updated.first { $0.member.identity.key == owners[1].id }?.eligible ?? true, "A freshly BUSY owner must replace stale IDLE facts")
  check(updated.contains { $0.member.identity.key == owners[47].id }, "Unprobed owners remain pending after another tranche changes")
  records.removeValue(forKey: owners[47].id)
  restarted.tick(records: records, policy: policy, complete: true, now: now.addingTimeInterval(901))
  checkFalse(restarted.snapshot().daemons.contains { $0.member.identity.key == owners[47].id }, "Departed identities are removed without another producer probe")
}

private func ownerLaneFairnessProof(now: Date) {
  var state = MachineReviewState(), lanes: [ReviewLane] = []
  for hour in 0..<4 {
    let date = now.addingTimeInterval(Double(hour * 3600))
    let evidence = [ReviewEvidence(id: "new-process-\(hour)", revision: "1"),
      ReviewEvidence(id: "owner-process:new-\(hour)", revision: "1"),
      ReviewEvidence(id: "cache:waiting", revision: "1", processCount: 0),
      ReviewEvidence(id: "space:waiting", revision: "1", processCount: 0, recommendationOnly: true)]
    let signal = HarnessHook.Signal(observedAt: date, processCount: 2, residentBytes: 0, pressure: "Low", reviewEvidence: evidence)
    let selected = state.pending(signal, now: date)
    check(!selected.isEmpty, "A pending lane must be selected")
    if let first = selected.first { lanes.append(ReviewLane.lane(for: first)) }
    state.begin(selected, now: date)
    state.complete(selected, progress: ReviewProgress(attempt: UUID(), selected: selected.map(\.id)))
  }
  equal(lanes, [.process, .ownerProcess, .managedCache, .discovery],
    "A continuous stream of new process owners cannot starve disk cleanup or discovery")
}

private func ownerRefusalRecoveryProof(evidence: GradleDaemonEvidence, now: Date) throws {
  // Exercise the exact failure boundary used by Monitor and the Gradle actuator.
  // Wording is deliberately identical: classification follows stage, never prose.
  let sameError = StoreError.message("Owner operation failed")
  var refused: Error = sameError, uncertain: Error = sameError
  do { _ = try OwnerStopFailure.preflight { () throws -> String in throw sameError }; failTest("Preflight failure escaped") }
  catch { refused = error }
  do { _ = try OwnerStopFailure.dispatch { throw sameError }; failTest("Dispatch failure escaped") }
  catch { uncertain = error }
  equal(OwnerStopFailure.receiptOutcome(for: refused), "refused")
  equal(OwnerStopFailure.receiptOutcome(for: uncertain), "unverified")
  equal(OwnerStopFailure.receiptOutcome(for: sameError), "unverified", "Unknown untyped failure must never become retryable")
  do { _ = try OwnerStopFailure.preflight { () throws -> String in throw uncertain }; failTest("Nested uncertain failure escaped") }
  catch { equal(OwnerStopFailure.receiptOutcome(for: error), "unverified", "An uncertain dispatch must never be downgraded by another boundary") }
  do { _ = try OwnerStopFailure.dispatch { throw refused }; failTest("Post-dispatch refusal escaped") }
  catch { equal(OwnerStopFailure.receiptOutcome(for: error), "unverified", "Any error after entering dispatch remains uncertain") }

  let record = Record(Observation(identity: evidence.member.identity, executable: evidence.member.executable))
  var catalog = Catalog(); catalog.records[record.id] = record; catalog.ownerDaemons = [evidence]
  var reviewer = MachineReviewState()
  var signal = HarnessHook.Signal(observedAt: now, processCount: 1, residentBytes: 0, pressure: "Low",
    reviewEvidence: ReviewEvidence.pending(in: catalog))
  reviewer.begin(reviewer.pending(signal, now: now), now: now)
  var event = CleanupEvent(leaseID: UUID(), label: "Owned refusal fixture", date: now, targets: [evidence.member],
    residentBefore: 4096, outcome: OwnerStopFailure.receiptOutcome(for: refused), detail: "Read-only producer preflight refused")
  event.ownerProtocol = true; catalog.events = [event]
  signal.reviewEvidence = ReviewEvidence.pending(in: catalog)
  check(reviewer.pending(signal, now: now.addingTimeInterval(3600)).isEmpty,
    "Known pre-dispatch refusal must not re-review unchanged producer evidence")
  var changed = evidence; changed.state = "BUSY"; changed.eligible = false; changed.lastBusy = now
  catalog.ownerDaemons = [changed]
  check(ReviewEvidence.pending(in: catalog).isEmpty, "BUSY must remain protected after a refused attempt")
  changed.state = "IDLE"; changed.eligible = true; changed.checkedAt = now.addingTimeInterval(3600)
  catalog.ownerDaemons = [changed]
  signal.reviewEvidence = ReviewEvidence.pending(in: catalog)
  equal(reviewer.pending(signal, now: now.addingTimeInterval(3600)).map(\.id), [changed.id],
    "Meaningfully new BUSY-to-IDLE producer facts may queue after a proven no-dispatch refusal")
  catalog.events[0].outcome = OwnerStopFailure.receiptOutcome(for: uncertain)
  check(ReviewEvidence.pending(in: catalog).isEmpty, "Uncertain dispatch remains blocked even after new producer activity")
  equal(catalog.lifetimeVerified, 0, "Neither refused nor uncertain operations earn cleanup credit")
}

/// Use the existing owned sleep control: a forged cached Gradle classification
/// must fail real Monitor preflight, preserve the process and write no-stop proof.
func ownerMonitorPreflightRefusalProof(monitor: Monitor, ownedFixture: Observation) async throws {
  let now = Date()
  let evidence: GradleDaemonEvidence = try ownerDecode([
    "member": ownerObject(Member(ownedFixture)), "daemonUID": UUID().uuidString,
    "gradleHome": "/fixture/not-a-gradle-owner", "distribution": "/fixture/not-a-distribution", "version": "8.14.6",
    "state": "IDLE", "residentBytes": ownedFixture.rss, "cpuTimeNS": 0, "nativeChildren": [], "childrenVisibilityComplete": true,
    "checkedAt": now.timeIntervalSinceReferenceDate, "lastBusy": now.addingTimeInterval(-900).timeIntervalSinceReferenceDate,
    "evidenceFingerprint": "untrusted-cached-fixture", "eligible": true, "reason": "Negative cached classification control"])
  _ = try await monitor.startOwnerStop(evidence, rationale: "Negative fixture must refuse a non-producer before any stop is sent.", callerPID: getpid())
  var receipt: CleanupEvent?
  for _ in 0..<200 {
    receipt = await monitor.snapshot().catalog.events.last { $0.ownerProtocol == true && $0.targets.contains(Member(ownedFixture)) }
    if let receipt, receipt.outcome != "prepared" { break }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  equal(receipt?.outcome, "refused", "Actual Monitor read-only preflight failure must not poison this identity as uncertain")
  equal(Native().ownerState(ownedFixture.identity), .alive, "Preflight refusal must preserve the owned control")
  let state = await monitor.snapshot()
  equal(state.catalog.lifetimeVerified, 0)
  // No live producer RPC is possible with an expired/no-record request.
  do { _ = try GradleDaemon.requestGracefulStop(evidence, records: [:]); failTest("Missing-record owner request escaped preflight") }
  catch { equal(OwnerStopFailure.receiptOutcome(for: error), "refused", "Production Gradle preflight must emit typed no-dispatch evidence") }
}

private final class CollectorGate: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private let release = DispatchSemaphore(value: 0)
  var count: Int { lock.withLock { calls } }
  func unblock() { release.signal() }
  func collect(_ policy: DiskPolicy) throws -> BuildKitCache.Inventory {
    let ordinal = lock.withLock { calls += 1; return calls }
    if ordinal == 1 { _ = release.wait(timeout: .now() + 2) }
    return try ownerInventory(policy)
  }
}
private func waitForOwner(_ condition: () -> Bool, _ message: String) async throws {
  for _ in 0..<200 {
    if condition() { return }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  check(condition(), message)
}
private func collectorGenerationProof(store: Store) async throws {
  var policy = DiskPolicy(); policy.mode = "recommend"
  let first = CollectorGate()
  defer { first.unblock() }
  let collector = OwnerMaintenance(store: store, processCollector: { _, _, _ in ([], []) },
    cacheCollector: { try first.collect($0) }, accessCheck: fixtureAccess)
  let now = Date()
  collector.tick(records: [:], policy: policy, complete: true, now: now)
  try await waitForOwner({ first.count == 1 }, "Initial owned cache collection did not start")
  policy.keepNewest += 1
  collector.tick(records: [:], policy: policy, complete: true, now: now.addingTimeInterval(1))
  first.unblock()
  try await waitForOwner({ collector.snapshot().checkedAt != nil }, "Old-generation collection did not finish")
  isNil(collector.snapshot().cache)
  collector.tick(records: [:], policy: policy, complete: true, now: now.addingTimeInterval(2))
  try await waitForOwner({ collector.snapshot().cache?.policyRevision == policy.revision }, "Policy change must refresh without waiting scanHours")
  equal(first.count, 2)
  policy.mode = "off"
  collector.tick(records: [:], policy: policy, complete: true, now: now.addingTimeInterval(3))
  isNil(collector.snapshot().cache)
  equal(first.count, 2, "Off policy must not start another owner inventory")

  policy.mode = "recommend"
  let second = CollectorGate(); defer { second.unblock() }
  let invalidated = OwnerMaintenance(store: store, processCollector: { _, _, _ in ([], []) },
    cacheCollector: { try second.collect($0) }, accessCheck: fixtureAccess)
  invalidated.tick(records: [:], policy: policy, complete: true, now: now)
  try await waitForOwner({ second.count == 1 }, "Invalidation fixture did not start")
  invalidated.invalidateCache(); second.unblock()
  try await waitForOwner({ invalidated.snapshot().checkedAt != nil }, "Invalidated collection did not finish")
  isNil(invalidated.snapshot().cache)
  invalidated.tick(records: [:], policy: policy, complete: true, now: now.addingTimeInterval(1))
  try await waitForOwner({ invalidated.snapshot().cache != nil }, "Cleanup invalidation must request fresh owner facts")
  equal(second.count, 2)
}

private func ownerWatchProof() {
  equal(Verification.ownerWatch(elapsed: 30, targets: [.alive], partialScan: false, elapsedSinceExit: nil), .waiting)
  equal(Verification.ownerWatch(elapsed: 899, targets: [.alive], partialScan: false, elapsedSinceExit: nil), .waiting)
  equal(Verification.ownerWatch(elapsed: 900, targets: [.alive], partialScan: false, elapsedSinceExit: nil), .unverified)
  equal(Verification.ownerWatch(elapsed: 300, targets: [.gone], partialScan: false, elapsedSinceExit: nil), .observedExit)
  equal(Verification.ownerWatch(elapsed: 301, targets: [.gone], partialScan: false, elapsedSinceExit: 1), .verify(elapsedSinceExit: 1))
  equal(Verification.outcome(elapsed: 1, targets: [.gone], recurrence: false, partialScan: false), "verifying")
  equal(Verification.outcome(elapsed: 120, targets: [.gone], recurrence: false, partialScan: false), "verified")
  equal(Verification.ownerWatch(elapsed: 60, targets: [.alive], partialScan: true, elapsedSinceExit: nil), .unverified)
  equal(Verification.ownerWatch(elapsed: 60, targets: [.unknown], partialScan: false, elapsedSinceExit: nil), .unverified)
  equal(Verification.ownerWatch(elapsed: 60, targets: [.alive], partialScan: false, elapsedSinceExit: 1), .unverified)
  equal(Verification.ownerWatch(elapsed: 60, targets: [.gone], partialScan: false, elapsedSinceExit: -1), .unverified)
  var catalog = Catalog()
  var interrupted = CleanupEvent(leaseID: UUID(), label: "Owner watch", date: Date(), targets: [],
    residentBefore: 0, outcome: "verifying", detail: "Controlled fixture")
  interrupted.ownerProtocol = true; interrupted.ownerExitObservedAt = Date()
  catalog.events = [interrupted]; catalog.resetContinuity()
  equal(catalog.events[0].outcome, "unverified", "Restart must not count elapsed wall time as observed exit coverage")
}
