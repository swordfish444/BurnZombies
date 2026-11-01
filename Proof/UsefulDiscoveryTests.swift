import BurnCore
import Foundation

func passiveCoverageProbe() throws {
  let native = Native()
  let scan = native.scan()
  let byPID = Dictionary(uniqueKeysWithValues: scan.observations.map { ($0.identity.pid, $0) })
  var counts = [String: Int]()
  var sessions = [String: URL]()
  let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    ".codex/sessions")
  if let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
    for case let path as URL in paths where path.pathExtension == "jsonl" {
      let id = String(path.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
      if UUID(uuidString: id) != nil { sessions[id] = path }
    }
  }
  for process in scan.observations where process.name != "codex" {
    var parent = process.parent
    var seen = Set<Int32>()
    var ownerFound = false
    for _ in 0..<64 {
      guard parent > 1, seen.insert(parent).inserted, let owner = byPID[parent] else { break }
      if owner.name == "codex" {
        ownerFound = true
        break
      }
      parent = owner.parent
    }
    guard ownerFound else { continue }
    counts["codexDescendants", default: 0] += 1
    let marker = native.codexSessionEvidence(process)
    guard let id = marker.id else {
      counts[marker.status, default: 0] += 1
      continue
    }
    guard let path = sessions[id] else {
      counts["noMatchingLocalSessionFile", default: 0] += 1
      continue
    }
    let f = try FileHandle(forReadingFrom: path)
    let size = try f.seekToEnd()
    try f.seek(toOffset: size > 262144 ? size - 262144 : 0)
    let data = try f.read(upToCount: 262144) ?? Data()
    try f.close()
    var session = PassiveSession(provider: "codex", id: id)
    for line in data.split(separator: 10) {
      if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
        session.ingest(object)
      }
    }
    guard let started = session.started else {
      counts["startOutsideBoundedTail", default: 0] += 1
      continue
    }
    let born = Double(process.identity.seconds) + Double(process.identity.micros) / 1e6
    if born < started.timeIntervalSince1970 {
      counts["predatesCurrentTurn", default: 0] += 1
    } else {
      counts["currentTurnBindingPossible", default: 0] += 1
    }
  }
  print("PASSIVE COVERAGE (metadata counts only): \(counts.sorted { $0.key < $1.key })")
}

func usefulDiscoveryProof() async throws {
  try await proactiveWorktreeFreshnessProof()
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-roots-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: base) }
  let home = base.appendingPathComponent("home")
  let root = base.appendingPathComponent("custom-state")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  let first = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess, discoveryHome: home)
  equal(try await first.snapshot().policy.roots.count, 0)
  let late = home.appendingPathComponent(".codex/worktrees")
  try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
  _ = try await first.tick()
  let runtimeRoots = try await first.snapshot().policy.roots
  check(
    runtimeRoots.contains(WorkspaceSafety.canonical(late.path)),
    "Runtime tick missed the newly created harness root")
  print(
    "PASS runtime observer discovers a harness root created after launch without restart or Hunt")
  let second = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess, discoveryHome: home)
  let secondRoots = try await second.snapshot().policy.roots
  check(
    secondRoots.contains(WorkspaceSafety.canonical(late.path)),
    "Harness folder created after install was not discovered")
  _ = try await second.request(
    .init("remove_root", path: WorkspaceSafety.canonical(late.path)), caller: "fixture")
  let third = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess, discoveryHome: home)
  let thirdRoots = try await third.snapshot().policy.roots
  checkFalse(
    thirdRoots.contains(WorkspaceSafety.canonical(late.path)),
    "Explicitly removed discovery root was re-added")
  let now = Date()
  let evidence = ReviewEvidence(id: "owner-process:fixture", revision: "one", processCount: 0)
  var state = MachineReviewState()
  let signal = HarnessHook.Signal(
    observedAt: now, processCount: 1, residentBytes: 1,
    pressure: "Low", reviewEvidence: [evidence])
  state.begin([evidence], now: now)
  equal(
    state.pending(signal, now: now).count, 1,
    "Starting a review must not acknowledge evidence before a successful outcome")
  check(
    DiskCandidate.minimumReviewBytes <= 100_000_000,
    "Useful smaller output folders must not disappear behind the old 10 GB floor")
  var hunt = HuntSnapshot(startedAt: now)
  var catalog = Catalog()
  catalog.worktreeEvidence = [
    .init(
      id: "worktree-advice:fixture", revision: "one",
      processCount: 0, recommendationOnly: true)
  ]
  hunt.includeReceipts(catalog)
  // Native candidates must be visible even if no model or cleanup preview ever runs.
  check(
    hunt.log.contains { $0.kind == "detected" },
    "Native worktree discovery must be visible before deletion eligibility")
  equal(hunt.burned, 0, "Discovery cannot fabricate cleanup credit")
  equal(hunt.worktreesCleaned, 0)
  hunt.phase = "completed"
  hunt.finishedAt = now
  let before = hunt.log.count
  catalog.worktreeEvidence = [
    .init(id: "worktree-advice:later", revision: "two", processCount: 0, recommendationOnly: true)
  ]
  hunt.includeReceipts(catalog)
  equal(hunt.log.count, before, "Later discovery cannot be attributed to a completed hunt")
  var failed = MachineReviewState()
  failed.begin([evidence], now: now)
  failed.deferReview([evidence], reason: "Instrumented timeout before any mutation", now: now)
  checkFalse(failed.retryDue(signal, now: now.addingTimeInterval(30)))
  check(failed.retryDue(signal, now: now.addingTimeInterval(61)))
  var gone = signal
  gone.reviewEvidence = []
  checkFalse(
    failed.retryDue(gone, now: now.addingTimeInterval(61)),
    "Gone evidence cannot schedule a retry loop")
  failed.deferReview([evidence], reason: "Second timeout", now: now)
  failed.deferReview([evidence], reason: "Third timeout", now: now)
  checkFalse(failed.retryDue(signal, now: now.addingTimeInterval(179)))
  equal(failed.pending(signal, now: now.addingTimeInterval(179)).count, 0)
  var fresh = signal
  fresh.reviewEvidence?[0].revision = "changed-producer-evidence"
  equal(
    failed.pending(fresh, now: now).count, 1,
    "New producer evidence can be considered after retry exhaustion")
}

private func proactiveWorktreeFreshnessProof() async throws {
  let base = URL(fileURLWithPath: "/private/tmp/bz-proactive-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: base) }
  let home = base.appendingPathComponent("home")
  let repository = home.appendingPathComponent("git/project")
  let checkout = home.appendingPathComponent("git/review-checkout")
  let root = base.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repository.path, ["init", "--initial-branch=main"])
  try Data("sacrificial\n".utf8).write(to: repository.appendingPathComponent("source"))
  _ = try WorktreeGit.run(repository.path, ["add", "."])
  _ = try WorktreeGit.run(
    repository.path,
    [
      "-c", "user.name=Proof", "-c",
      "user.email=proof@example.invalid", "commit", "-m", "fixture",
    ])
  _ = try WorktreeGit.run(repository.path, ["worktree", "add", "--detach", checkout.path])
  let ledger = try IntentLedger(root: root)
  let service = try WorktreeService(
    root: root, visibility: { _ in 0 },
    access: fixtureAccess, discoveryHome: home, intent: ledger)
  _ = try await service.tick()  // Ordinary observation only: no add_root or Hunt.
  var row = try await service.snapshot().records.first { $0.path == checkout.path }!
  checkFalse(row.ownerManaged)
  let digest = try ledger.notificationCandidate()!
  try ledger.delivered(digest)
  let intentDB = try WorktreeStore(root: root, databaseName: "intent.sqlite")
  // Model the preceding notification 55 minutes before this scan, then six
  // minutes passing. Persisted timestamps avoid a one-hour wall-clock sleep.
  try intentDB.put(
    Date().addingTimeInterval(-55 * 60), kind: "delivery",
    id: digest.id + ":" + digest.revision)
  isNil(try ledger.notificationCandidate())
  let native = try WorktreeStore(root: root)
  row.observedAt = Date().addingTimeInterval(-6 * 60)
  try native.put(row, kind: "record", id: row.id)
  _ = try await service.snapshot()
  try intentDB.put(
    Date().addingTimeInterval(-61 * 60), kind: "delivery",
    id: digest.id + ":" + digest.revision)
  isNil(try ledger.notificationCandidate())
  _ = try await service.tick()
  _ = try await service.snapshot()
  let refreshed = try ledger.notificationCandidate()!
  equal(refreshed.resources, ["worktree:" + row.id])
  check(refreshed.ready && refreshed.observed > Date().addingTimeInterval(-60))
  try ledger.decide(refreshed.id, revision: refreshed.revision, decision: "approve")
  let extra = home.appendingPathComponent("Developer")
  try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
  _ = try await service.tick()
  _ = try await service.snapshot()
  equal(
    try ledger.proposal(refreshed.id)?.approvedRevision, refreshed.revision,
    "Discovery-only roots invalidated an exact decision")
  await service.shutdown()
  print(
    "PASS default-root worktree stays actionable between scans and survives notification cooldown after one bounded observer tick; discovery roots preserve approval"
  )
}
