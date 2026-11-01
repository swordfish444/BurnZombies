import BurnCore
import Foundation

func nativeWorktreeRediscoveryProof() async throws {
  let initialFailures = failures
  let base = URL(fileURLWithPath: "/private/tmp/bz-rediscovery-" + UUID().uuidString)
  let repo = base.appendingPathComponent("repository")
  let checkout = base.appendingPathComponent("checkout")
  let root = base.appendingPathComponent("state")
  let stub = base.appendingPathComponent("stub.json")
  let wrapper = base.appendingPathComponent("worker")
  let fm = FileManager.default
  defer { try? fm.removeItem(at: base) }
  try fm.createDirectory(at: repo, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repo.path, ["init", "--initial-branch=main"])
  try Data("disposable rediscovery fixture\n".utf8).write(to: repo.appendingPathComponent("source"))
  _ = try WorktreeGit.run(repo.path, ["add", "."])
  let commit = Process()
  commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  commit.arguments = [
    "-C", repo.path, "-c", "user.name=Proof", "-c",
    "user.email=proof@example.invalid", "commit", "-m", "fixture",
  ]
  let old = Date().addingTimeInterval(-21 * 86400)
  var env = ProcessInfo.processInfo.environment
  env["GIT_AUTHOR_DATE"] = "@\(Int(old.timeIntervalSince1970)) +0000"
  env["GIT_COMMITTER_DATE"] = env["GIT_AUTHOR_DATE"]
  commit.environment = env
  commit.standardOutput = FileHandle.nullDevice
  commit.standardError = FileHandle.nullDevice
  try commit.run()
  commit.waitUntilExit()
  equal(commit.terminationStatus, 0)
  _ = try WorktreeGit.run(repo.path, ["worktree", "add", "--detach", checkout.path])
  for path in [
    checkout, checkout.appendingPathComponent("source"), checkout.appendingPathComponent(".git"),
  ] {
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
  }
  func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  let script =
    "#!/bin/sh\nif [ -e " + quote(stub.path) + " ]; then exec /usr/bin/python3 -c "
    + quote(
      "import json,sys;print(json.dumps({'run':sys.argv[1],'complete':False,'record':json.load(open(sys.argv[2]))}),flush=True);print(json.dumps({'run':sys.argv[1],'complete':True}),flush=True)"
    )
    + " \"$2\" " + quote(stub.path) + "; fi\nexec "
    + quote(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path) + " \"$@\"\n"
  try Data(script.utf8).write(to: wrapper)
  try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
  let ledger = try IntentLedger(root: root)
  let service = try WorktreeService(
    root: root, access: fixtureAccess,
    scanRunner: WorktreeScanRunner(executable: wrapper), intent: ledger)
  do {
    _ = try await service.request(.init("add_root", path: base.path), caller: "fixture")
    _ = try await service.scan()
    let before = try await service.snapshot().records.first { $0.path == checkout.path }!
    check(!before.revision.isEmpty && before.gaps.isEmpty && before.consumer == "none observed")
    let proposals = try ledger.snapshot().proposals
    let proposal = proposals.first { $0.resources == ["worktree:" + before.id] }!
    check(proposal.ready && proposal.notificationEligible == true)
    var registration = before
    registration.revision = ""
    registration.gaps = ["Detailed inspection pending."]
    registration.observedAt = Date()
    try JSONEncoder().encode(registration).write(to: stub)
    _ = try await service.scan()
    let after = try await service.snapshot().records.first { $0.id == before.id }!
    equal(after.revision, before.revision)
    equal(after.observedAt, before.observedAt, "Rediscovery fabricated a fresh inspection")
    equal(after.gaps, [], "A full-scan stub degraded a completed inspection")
    let updated = try ledger.snapshot().proposals.first { $0.id == proposal.id }!
    check(updated.ready, "Rediscovery removed a ready finding from the inbox")
    let db = try WorktreeStore(root: root, databaseName: "intent.sqlite")
    let notifications = try db.notificationProposals(now: Date())
    check(
      notifications.contains { $0.id == proposal.id },
      "Rediscovery suppressed a previously eligible notification")
    let records = try WorktreeStore(root: root)
    var legacy = before
    legacy.gaps = ["Detailed inspection pending."]
    try records.put(legacy, kind: "record", id: legacy.id)
    _ = try await service.scan()
    let repaired = try await service.snapshot().records.first { $0.id == before.id }!
    equal(repaired.gaps, [], "An older build's synthetic pending marker remained stuck")
    equal(repaired.observedAt, before.observedAt)
    let repairedProposal = try ledger.snapshot().proposals.first { $0.id == proposal.id }!
    check(repairedProposal.ready, "Repair did not restore readiness")
    let repairedNotifications = try db.notificationProposals(now: Date())
    check(
      repairedNotifications.contains { $0.id == proposal.id },
      "Repair did not restore notification eligibility")
    legacy.gaps.append("Real consumer visibility gap")
    legacy.consumer = "unknown"
    try records.put(legacy, kind: "record", id: legacy.id)
    _ = try await service.scan()
    let protected = try await service.snapshot().records.first { $0.id == before.id }!
    equal(protected.gaps, ["Real consumer visibility gap"])
    equal(protected.consumer, "unknown")
    let protectedProposal = try ledger.snapshot().proposals.first { $0.id == proposal.id }!
    checkFalse(protectedProposal.ready)
    try records.put(before, kind: "record", id: before.id)
    _ = try WorktreeGit.run(repo.path, ["worktree", "lock", checkout.path])
    let registrations = try WorktreeDiscovery.parse(
      WorktreeGit.run(repo.path, ["worktree", "list", "--porcelain", "-z"]),
      repository: before.repository)
    var locked = registrations.first { $0.id == before.id }!
    check(locked.locked && locked.head == before.head)
    locked.gaps = ["Detailed inspection pending."]
    try JSONEncoder().encode(locked).write(to: stub)
    _ = try await service.scan()
    let newlyProtected = try await service.snapshot().records.first { $0.id == before.id }!
    check(
      newlyProtected.locked && newlyProtected.revision.isEmpty,
      "Same-HEAD rediscovery discarded newly observed Git protection")
    let lockedProposal = try ledger.snapshot().proposals.first { $0.id == proposal.id }!
    checkFalse(lockedProposal.ready)
    let lockedNotifications = try db.notificationProposals(now: Date())
    checkFalse(lockedNotifications.contains { $0.id == proposal.id })
    await service.shutdown()
  } catch {
    await service.shutdown()
    throw error
  }
  if failures == initialFailures {
    print(
      "PASS full-scan rediscovery preserves completed evidence, original observation time, ready inbox and notification eligibility without pretending a new inspection"
    )
  } else {
    print("FAIL rediscovery checks: \(failures - initialFailures) failures")
  }
}
