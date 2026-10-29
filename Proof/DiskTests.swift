import BurnCore
import Foundation
import Darwin

func diskProof() async throws {
  let root = URL(fileURLWithPath: WorkspaceSafety.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("bz-disk-proof-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repo = root.appendingPathComponent("repo"), state = root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  try WorkspaceSafety.git(repo.path, ["init"])
  try Data("build/\nartifacts/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
  try Data("precious source".utf8).write(to: repo.appendingPathComponent("source.txt"))
  try WorkspaceSafety.git(repo.path, ["add", "source.txt", ".gitignore"])
  let build = repo.appendingPathComponent("build"); try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
  let output = build.appendingPathComponent("output.bin")
  try Data(repeating: 17, count: 2_097_152).write(to: output)
  let old = Date().addingTimeInterval(-3*86400)
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: output.path)
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: build.path)
  var policy = DiskPolicy(); policy.roots = [repo.path]; policy.minimumAgeDays = 2; policy.minimumCandidateMB = 1
  policy.targetFreeGB = 1000; policy.mode = "automatic"
  let store = try Store(root: state)
  var inventory = DiskInventory.scan(policy: policy, previous: .init(), visibility: { _ in 0 })
  guard let first = inventory.candidates.first(where: { $0.path == build.path }) else { throw StoreError.message("Generated fixture not discovered") }
  checkFalse(first.reviewable, "Ignored output cannot create its own deletion permission")
  checkFalse(first.pendingReview, "Small folders never enter AI review")
  try await diskAdviceProof(first, root: root, policy: policy)
  policy.rules = [.init(path: build.path, disposition: "regenerable")]
  inventory = DiskInventory.scan(policy: policy, previous: inventory, visibility: { _ in -1 })
  checkFalse(inventory.candidates.first!.reviewable, "Incomplete visibility remains a hard stop")
  inventory = DiskInventory.scan(policy: policy, previous: inventory, visibility: { _ in 1 })
  checkFalse(inventory.candidates.first!.reviewable, "Active consumer remains a hard stop")
  inventory = DiskInventory.scan(policy: policy, previous: inventory, visibility: { _ in 0 })
  guard let candidate = inventory.candidates.first(where: { $0.path == build.path && $0.reviewable }) else { throw StoreError.message("Released regenerable fixture should qualify: \(inventory.candidates.map(\.guardReason))") }
  var protectedPolicy = policy; protectedPolicy.protectedPaths = [output.path]
  throwsError(try DiskInventory.check(candidate, policy: protectedPolicy, visibility: { _ in 0 }))
  let lock = repo.appendingPathComponent(".git/index.lock")
  try Data().write(to: lock)
  throwsError(try DiskInventory.check(candidate, policy: policy, visibility: { _ in 0 }))
  try FileManager.default.removeItem(at: lock)
  let artifacts = repo.appendingPathComponent("artifacts")
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
  var evidencePaths = [String]()
  for day in [3, 4, 5] {
    let run = artifacts.appendingPathComponent("run-\(day)")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
    let file = run.appendingPathComponent("replaceable.bin")
    try Data(repeating: 19, count: 1_048_576).write(to: file)
    let date = Date().addingTimeInterval(-Double(day)*86400)
    for path in [file.path, run.path] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    evidencePaths.append(run.path)
  }
  var retention = policy; retention.keepNewest = 2
  retention.rules += evidencePaths.map { .init(path: $0, disposition: "regenerable") }
  let retained = DiskInventory.scan(policy: retention, previous: .init(), visibility: { _ in 0 })
  equal(retained.candidates.filter { $0.kind == "evidence" && $0.reviewable }.map(\.path), [evidencePaths[2]], "Newest evidence retention must keep two full runs")
  let link = build.appendingPathComponent("external")
  try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: output.path)
  let linked = try DiskInventory.manifest(build.path)
  check(linked.unsafe || !linked.complete, "Symlink inspection must fail closed")
  try FileManager.default.removeItem(at: link)
  try Data("private".utf8).write(to: build.appendingPathComponent(".env.production"))
  throwsError(try DiskInventory.check(candidate, policy: policy, visibility: { _ in 0 }))
  try FileManager.default.removeItem(at: build.appendingPathComponent(".env.production"))
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: build.path)
  try policy.save(store)
  let monitor = try Monitor(root: state, workspaceVisibility: { _ in 0 }, accessCheck: fixtureAccess, discoveryWalker: fixtureWalker()), service = AgentService(monitor: monitor)
  func call(_ request: AgentRequest) async -> AgentReply { var r = request; r.callerPID = getpid(); return await service.call(r) }
  func awaitInventory(revision: String) async throws -> DiskSnapshot {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let snapshot = try DiskSnapshot.load(store)
      if snapshot.policyRevision == revision,
        snapshot.candidates.contains(where: { $0.path == build.path }) { return snapshot }
      // Wait for the actual saved result of the one owned-root scan. Status no
      // longer performs blocking filesystem work, and polling must not start more scans.
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw StoreError.message("Owned asynchronous disk inventory did not complete within its test deadline")
  }
  _ = await monitor.refresh()
  let completedInventory = try await awaitInventory(revision: policy.revision)
  let listed = await call(AgentRequest("status"))
  check(listed.disk.isEmpty, "Disk review must hide items smaller than 10 GB")
  guard let id = completedInventory.candidates.first(where: { $0.path == build.path })?.id else { throw StoreError.message("Private fixture missing from completed inventory") }
  let rationale = "The test created this exact disposable build output, preserved source, completed the build and has no remaining consumer."
  let preview = await call(AgentRequest("disk_preview", findingID: id, rationale: rationale))
  guard let token = preview.previewToken else { throw StoreError.message(preview.message) }
  policy.rules[0].disposition = "keep"; try policy.save(store)
  let protected = await call(AgentRequest("disk_clean", previewToken: token))
  checkFalse(protected.ok, "New keep rule after preview did not block removal")
  check(FileManager.default.fileExists(atPath: output.path))
  policy.rules[0].disposition = "regenerable"; try policy.save(store)
  _ = await monitor.refresh()
  _ = try await awaitInventory(revision: policy.revision)
  let fresh = await call(AgentRequest("disk_preview", findingID: id, rationale: rationale))
  guard let next = fresh.previewToken else { throw StoreError.message(fresh.message) }
  let removed = await call(AgentRequest("disk_clean", previewToken: next))
  check(removed.ok, removed.message)
  checkFalse(FileManager.default.fileExists(atPath: build.path))
  check(FileManager.default.fileExists(atPath: repo.appendingPathComponent("source.txt").path))
  let replay = await call(AgentRequest("disk_clean", previewToken: next)); checkFalse(replay.ok)
  let saved = try store.load()
  equal(saved.diskReceipts?.filter { $0.outcome == "verified" }.count, 1)
  equal(saved.lifetimeWorktreesCleaned ?? 0, 0, "Generated output cannot count as a cleaned worktree")
  check((saved.lifetimeDiskReclaimedBytes ?? 0) <= 2_097_152)
  let today = ImpactNumbers.make(catalog: saved, period: .today)
  equal(today.disk, saved.lifetimeDiskReclaimedBytes ?? 0)
  var preset = DiskPolicy(); preset.preset("proactive"); equal(preset.minimumAgeDays, 2); equal(preset.keepNewest, 2)
  preset.roots = [NSHomeDirectory()]; throwsError(try preset.validate())
  print("PASS exact disk opt-in, active/unknown visibility refusal, sensitive files, policy-change race, single-use removal, untouched source and verified byte accounting (isolated complete-visibility fixture)")
}

/// Large metadata fixtures exercise advice without allocating 10 GB or granting
/// removal permission. Native removal must still reject these private fixtures.
private func diskAdviceProof(_ seed: DiskCandidate, root: URL, policy original: DiskPolicy) async throws {
  let store = try Store(root: root.appendingPathComponent("advice-state"))
  var policy = original; policy.mode = "recommend"; policy.rules = []; try policy.save(store)
  var candidate = seed
  candidate.bytes = DiskCandidate.minimumReviewBytes; candidate.recommendationEligible = true
  candidate.policyRevision = policy.revision; candidate.recommendationPolicyRevision = "preferences"
  check(candidate.pendingReview, "10 GB is included even without deletion permission")
  var small = candidate; small.bytes -= 1
  checkFalse(small.pendingReview, "Anything below 10 GB is excluded")
  var changed = candidate; changed.fingerprint = "new metadata"; changed.bytes += 4096
  equal(changed.queueRevision, candidate.queueRevision, "Tiny file churn must not resubmit read-only advice")
  changed.policyRevision = "unrelated folder preference"
  equal(changed.queueRevision, candidate.queueRevision, "Unrelated preferences must not spend more tokens")
  changed.recommendationPolicyRevision = "different retention"
  notEqual(changed.queueRevision, candidate.queueRevision)
  changed = candidate; changed.userRule = "regenerable"
  notEqual(changed.queueRevision, candidate.queueRevision)
  changed = candidate; changed.guardReason = "Inside your minimum retention period."
  notEqual(changed.queueRevision, candidate.queueRevision)
  changed = candidate; changed.recommendationEligible = false
  notEqual(changed.queueRevision, candidate.queueRevision)
  var catalog = Catalog(); catalog.diskCandidates = [small, candidate]
  let pending = ReviewEvidence.pending(in: catalog)
  equal(pending.count, 1); equal(pending.first?.recommendationOnly, true)
  var signal = HarnessHook.Signal(observedAt: Date(), processCount: 0, residentBytes: 0, pressure: "Low")
  signal.reviewEvidence = (0..<5).map { .init(id: "disk:\($0)", revision: "advice", processCount: 0, recommendationOnly: true) }
  equal(MachineReviewState().pending(signal).count, 3, "Read-only advice batches at most three folders")
  signal.reviewEvidence?.append(.init(id: "worktree:fixture", revision: "release", processCount: 0))
  equal(MachineReviewState().pending(signal).map(\.id), ["worktree:fixture"], "Released work takes priority without mixing in advice")
  signal.reviewEvidence?.insert(.init(id: "worktree:cleanup", revision: "ready", processCount: 0), at: 0)
  equal(MachineReviewState().pending(signal).map(\.id), ["worktree:cleanup"], "One cleanup does not mix with advice batches")
  equal(ReviewLane.lane(for: .init(id: "unknown-queue-type", revision: "ready", processCount: 0)), .unsupported)
  var snapshot = DiskSnapshot(); snapshot.date = Date(); snapshot.policyRevision = policy.revision
  snapshot.freeBytes = 1; snapshot.candidates = [candidate]; try snapshot.save(store)
  let monitor = try Monitor(root: store.root, workspaceVisibility: { _ in -1 }, accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  _ = await monitor.refresh()
  let service = AgentService(monitor: monitor)
  func call(_ request: AgentRequest) async -> AgentReply { var r = request; r.callerPID = getpid(); return await service.call(r) }
  let status = await call(.init("status"))
  equal(status.disk.count, 1, "Recommendation visible before destructive eligibility")
  checkFalse(status.disk.first?.reviewable == true)
  let rationale = "This generated folder needs a reproducible build before approval. Keep it until its owner confirms completed use."
  let preview = await call(.init("disk_preview", findingID: candidate.id, rationale: rationale))
  checkFalse(preview.ok, "Read-only advice must never mint a removal token")
  let saved = try await monitor.diskDecision(candidate.id, decision: "recommend", rationale: rationale)
  check(saved.contains("Nothing removed"))
  equal(try DiskSnapshot.load(store).candidates.first?.rationale, rationale)
  equal(try DiskSnapshot.load(store).candidates.first?.decisionRevision, candidate.queueRevision)
  equal((await call(.init("status"))).disk.count, 0, "A recommendation is not sent back on every observation")
  check(FileManager.default.fileExists(atPath: candidate.path), "Advice must preserve the exact folder")
  let restored = try DiskSnapshot.load(store)
  checkFalse(restored.candidates.first?.pendingReview == true, "Saved advice remains settled after reload")
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
  legacy.removeValue(forKey: "recommendationVersion")
  let old = try JSONDecoder().decode(DiskSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
  isNil(old.recommendationVersion)
  print("PASS 10 GB threshold, advice without deletion permission, durable recommendations, stable token queue and three-item batching")
}
