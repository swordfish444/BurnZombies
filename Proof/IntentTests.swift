import BurnCore
import Foundation

func intentProof() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-intent-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let now = Date()
  let ledger = try IntentLedger(root: root)
  func proposal(_ resource: String, revision: String = "one", action: CleanupAction = .ownerStop)
    -> CleanupProposal
  {
    .init(
      action: action, resources: [resource], revision: revision, title: "Fixture worker",
      detail: "Exact completed fixture owner; no continuing consumer.",
      workflow: "fixture-repository:owner-v1",
      recovery: "Owner recreates this worker", ready: true, fixture: true, now: now)
  }
  let first = try ledger.present(proposal("worker-one"))
  throwsError(try ledger.check(first))
  try ledger.decide(first.id, revision: first.revision, decision: "snooze")
  throwsError(try ledger.check(first))
  try ledger.decide(first.id, revision: first.revision, decision: "keep")
  let alternative = try ledger.present(proposal("worker-one", action: .process))
  throwsError(try ledger.veto(alternative.resources))
  try ledger.decide(first.id, revision: first.revision, decision: "clear-keep")
  try ledger.decide(first.id, revision: first.revision, decision: "approve")
  try ledger.check(first)
  let changed = try ledger.present(proposal("worker-one", revision: "two"))
  throwsError(try ledger.check(changed))
  throwsError(try ledger.decide(first.id, revision: first.revision, decision: "approve"))
  try ledger.decide(changed.id, revision: changed.revision, decision: "approve")
  try ledger.reserve(changed, operationID: "native-one")
  throwsError(try ledger.reserve(changed, operationID: "native-one"))
  throwsError(try ledger.reserve(changed, operationID: "native-two"))
  throwsError(try ledger.decide(changed.id, revision: changed.revision, decision: "keep"))
  let restarted = try IntentLedger(root: root)
  throwsError(try restarted.check(changed))
  // Missing native history cannot certify non-dispatch, even after 31 days and
  // more than the old catalog's 500-receipt bound.
  for i in 0..<510 {
    let p = try restarted.present(proposal("later-\(i)"))
    try restarted.decide(p.id, revision: p.revision, decision: "approve")
    try restarted.reserve(p, operationID: "later-native-\(i)")
    try restarted.project(operationID: "later-native-\(i)", outcome: "verified")
  }
  let afterMonth = try IntentLedger(root: root, now: { now.addingTimeInterval(31 * 86400) })
  throwsError(try afterMonth.check(changed))
  equal(try afterMonth.snapshot().operations.first { $0.id == "native-one" }?.outcome, "uncertain")
  try afterMonth.project(operationID: "native-one", outcome: "verified")
  throwsError(try afterMonth.reserve(changed, operationID: "native-one"))
  equal(try afterMonth.snapshot().operations.count, 511)

  let other = try ledger.present(proposal("worker-next"))
  let rule = try ledger.grant(
    other.id, revision: other.revision, maximumPerDay: 2, expires: now.addingTimeInterval(86400))
  try ledger.reserve(other, operationID: "canary")
  let second = try ledger.present(proposal("worker-next-two"))
  throwsError(try ledger.check(second))
  try ledger.project(operationID: "canary", outcome: "verified")
  try ledger.check(second)
  try ledger.reserve(second, operationID: "second")
  try ledger.project(operationID: "second", outcome: "verified")
  let third = try ledger.present(proposal("worker-next-three"))
  throwsError(try ledger.check(third))
  try ledger.pauseRule(rule.id)
  throwsError(try ledger.check(third))
  var crossRepo = proposal("unfamiliar")
  crossRepo.workflow = "different-repository:owner-v1"
  _ = try ledger.present(crossRepo)
  throwsError(try ledger.check(crossRepo))
  equal(
    try ledger.snapshot().rules.first { $0.id == rule.id }?.maximumPerDay, 2,
    "Verified successes never expand a rule cap")
  let pending = try ledger.snapshot().operations.filter { $0.outcome == "uncertain" }
  equal(pending.count, 0)
  let decisions = try ledger.snapshot().decisions
  check(decisions.allSatisfy { $0.fixture })
  // Resolved history must not turn the 10,000-row storage guard into a global
  // inbox/approval outage, or hide an older unresolved native reservation.
  let historyRoot = root.appendingPathComponent("large-history")
  let history = try IntentLedger(root: historyRoot)
  let uncertain = try history.present(proposal("pending-old"))
  try history.decide(uncertain.id, revision: uncertain.revision, decision: "approve")
  try history.reserve(uncertain, operationID: "pending-old-operation")
  let historyDB = try WorktreeStore(root: historyRoot, databaseName: "intent.sqlite")
  let template = try history.snapshot().operations[0]
  try historyDB.transaction {
    for i in 0..<10005 {
      let old = proposal("historical-\(i)")
      try historyDB.put(old, kind: "proposal", id: old.id)
      var receipt = template
      receipt.id = "history-\(i)"
      receipt.proposal = old.id
      receipt.resources = old.resources
      receipt.outcome = "verified"
      receipt.ruleID = nil
      try historyDB.put(receipt, kind: "operation", id: receipt.id)
    }
  }
  let current = try history.present(proposal("current"))
  equal(try history.snapshot().totalProposals, 10007)
  equal(try history.snapshot().proposals.count, 1000)
  equal(try history.pendingOperationIDs().contains("pending-old-operation"), true)
  try history.decide(current.id, revision: current.revision, decision: "approve")
  try history.check(current)
  try history.decide(current.id, revision: current.revision, decision: "keep")
  throwsError(try history.check(current))
  throwsError(try history.check(uncertain))
  let lastApproval = try history.present(proposal("over-limit-approved"))
  try history.decide(lastApproval.id, revision: lastApproval.revision, decision: "approve")
  try history.decide(current.id, revision: current.revision, decision: "needed")
  throwsError(try history.check(lastApproval))
  print("PASS workflow suspension revokes approval beyond 10,000 historical proposals")
  // A verified canary never permits continuing through a later unknown outcome.
  let ruleRoot = root.appendingPathComponent("uncertain-rule")
  let limited = try IntentLedger(root: ruleRoot)
  let canary = try limited.present(proposal("canary"))
  _ = try limited.grant(
    canary.id, revision: canary.revision, maximumPerDay: 3, expires: now.addingTimeInterval(86400))
  try limited.reserve(canary, operationID: "first-canary")
  try limited.project(operationID: "first-canary", outcome: "verified")
  let next = try limited.present(proposal("uncertain-second"))
  try limited.reserve(next, operationID: "uncertain-second")
  let last = try limited.present(proposal("third"))
  throwsError(try limited.check(last))
  try limited.project(operationID: "uncertain-second", outcome: "uncertain")
  throwsError(try IntentLedger(root: ruleRoot).check(last))
  equal(try limited.snapshot().rules.first?.enabled, false)
  let migrationRoot = root.appendingPathComponent("fresh")
  let configuration = MachineReviewConfiguration(
    harness: "codex", executable: "/fixture/codex", launcher: "/fixture/burnzombies",
    server: "/fixture/mcp")
  let fresh = try IntentLedger.migrate(root: migrationRoot)
  equal(try fresh.snapshot().legacyAuthority, false)
  try configuration.save(root: migrationRoot)
  try Store(root: migrationRoot).save(Catalog())
  equal(
    try IntentLedger.migrate(root: migrationRoot).snapshot().legacyAuthority, false,
    "Setup and later inventory must never turn a fresh install into legacy authority")
  let legacyRoot = root.appendingPathComponent("previously-installed")
  try configuration.save(root: legacyRoot)
  try Store(root: legacyRoot).save(Catalog())
  let legacy = try IntentLedger.migrate(root: legacyRoot)
  equal(try legacy.snapshot().legacyAuthority, true)
  let completed = try legacy.present(proposal("old-worker", action: .process))
  try legacy.reserve(completed, operationID: "old-operation", legacy: true)
  try legacy.project(operationID: "old-operation", outcome: "verified")
  let queued = try legacy.present(proposal("queued-worker"))
  try legacy.decide(queued.id, revision: queued.revision, decision: "approve")
  try legacy.decide(completed.id, revision: completed.revision, decision: "needed")
  throwsError(try legacy.check(queued, legacy: true))
  let newWorker = try legacy.present(proposal("new-worker"))
  throwsError(try legacy.check(newWorker, legacy: true))
  try legacy.decide(newWorker.id, revision: newWorker.revision, decision: "approve")
  try legacy.check(newWorker, legacy: true)  // A new exact human decision may reconsider one instance.
  var unavailable = newWorker
  unavailable.ready = false
  _ = try legacy.present(unavailable)
  let availableAgain = try legacy.present(newWorker)
  throwsError(try legacy.check(availableAgain, legacy: true))
  // An unreadable preference record cannot prevent recovery, and cannot be
  // silently bypassed by a restart or another otherwise authorized workflow.
  let badStore = try WorktreeStore(root: legacyRoot, databaseName: "intent.sqlite")
  try badStore.put("malformed proposal fixture", kind: "proposal", id: "corruption")
  check(legacy.recordRecovery(operationID: "old-operation") != nil)
  throwsError(try legacy.check(completed, legacy: true))
  let afterFailure = try IntentLedger(root: legacyRoot, legacyAuthority: true)
  throwsError(try afterFailure.veto(["unrelated-resource"]))
  try badStore.remove(kind: "proposal", id: "corruption")
  try afterFailure.reconcileRecoveryFeedback()
  try afterFailure.veto(["unrelated-resource"])
  let scopeRoot = root.appendingPathComponent("migration-loss")
  _ = try IntentLedger.migrate(root: scopeRoot)
  try FileManager.default.removeItem(at: scopeRoot.appendingPathComponent("intent.sqlite"))
  throwsError(try IntentLedger.migrate(root: scopeRoot))
  let truncatedRoot = root.appendingPathComponent("migration-truncated")
  do {
    let migrated = try IntentLedger.migrate(root: truncatedRoot)
    let pending = try migrated.present(proposal("lost-reservation"))
    try migrated.decide(pending.id, revision: pending.revision, decision: "approve")
    try migrated.reserve(pending, operationID: "must-not-replay")
  }
  try Data().write(to: truncatedRoot.appendingPathComponent("intent.sqlite"))
  throwsError(try IntentLedger.migrate(root: truncatedRoot))
  // An interrupted first migration resumes without adopting new authority.
  let interruptedRoot = root.appendingPathComponent("migration-pending")
  _ = try IntentLedger.migrate(root: interruptedRoot)
  let receiptURL = interruptedRoot.appendingPathComponent("intent-migration.json")
  var receipt =
    try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
  receipt["phase"] = "pending"
  try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL)
  equal(try IntentLedger.migrate(root: interruptedRoot).snapshot().legacyAuthority, false)
  throwsError(
    try limited.grant(
      last.id, revision: last.revision, maximumPerDay: 10, expires: now.addingTimeInterval(86400)))
  _ = try ledger.grant(
    third.id, revision: third.revision, maximumPerDay: 2, expires: now.addingTimeInterval(86400))
  throwsError(try ledger.check(third))
  let diskRoot = root.appendingPathComponent("native-disk-grant")
  let diskLedger = try IntentLedger.migrate(root: diskRoot)
  var diskPolicy = DiskPolicy()
  diskPolicy.mode = "automatic"
  try diskPolicy.save(Store(root: diskRoot))
  let diskCandidate = try diskLedger.present(proposal("exact-output", action: .disk))
  throwsError(try diskLedger.check(diskCandidate, legacy: true))
  try diskLedger.authorizeNativeDiskPolicy(diskPolicy)
  try diskLedger.check(diskCandidate, legacy: true)
  diskPolicy.maximumGBPerDay += 1
  try diskPolicy.save(Store(root: diskRoot))
  throwsError(try diskLedger.check(diskCandidate, legacy: true))
  let inboxRoot = root.appendingPathComponent("old-active-finding")
  let inbox = try IntentLedger(root: inboxRoot, now: { now })
  var oldest = proposal("old-visible")
  oldest.fixture = false
  let longstanding = try inbox.present(oldest)
  let inboxDB = try WorktreeStore(root: inboxRoot, databaseName: "intent.sqlite")
  try inboxDB.transaction {
    for i in 0..<1001 {
      var absent = proposal("absent-\(i)")
      absent.state = "absent"
      absent.ready = false
      try inboxDB.put(absent, kind: "proposal", id: absent.id)
    }
  }
  equal(
    try inbox.snapshot().proposals.first?.id, longstanding.id,
    "Resolved history buried actionable work")
  let initialDigest = try inbox.notificationCandidate()!
  try inbox.delivered(initialDigest)
  let later = now.addingTimeInterval(3601)
  oldest.observed = later
  _ = try inbox.present(oldest)
  equal(try inbox.notificationCandidate(now: later)?.id, longstanding.id)
  let afterRetention = try IntentLedger(
    root: inboxRoot, now: { now.addingTimeInterval(100 * 86400) })
  equal(try afterRetention.snapshot().totalProposals, 1, "Unbound absent history was not pruned")
  // Notification cadence cannot turn absence of response into permission.
  let noticeRoot = root.appendingPathComponent("notifications")
  let notices = try IntentLedger(root: noticeRoot, now: { now })
  var visible = proposal("visible")
  visible.fixture = false
  let shown = try notices.present(visible)
  let digest = try notices.notificationCandidate(now: now)!
  equal(digest.id, "digest")
  try notices.delivered(digest)
  isNil(try notices.notificationCandidate(now: now))
  throwsError(try notices.check(shown))
  let fixtureOnly = try IntentLedger(root: root.appendingPathComponent("fixture-notices"))
  _ = try fixtureOnly.present(proposal("private-fixture"))
  isNil(try fixtureOnly.notificationCandidate())
  var blocked = visible
  blocked.resources = ["blocked"]
  blocked.id = "blocked"
  blocked.ready = false
  _ = try notices.present(blocked)
  let future = now.addingTimeInterval(3601)
  var refreshed = shown
  refreshed.observed = future
  _ = try notices.present(refreshed)
  equal(try notices.notificationCandidate(now: future)?.id, shown.id)
  let shadowRoot = root.appendingPathComponent("shadow")
  let shadows = try IntentLedger(root: shadowRoot)
  let match = try shadows.present(visible)
  _ = try shadows.grant(
    match.id, revision: match.revision, maximumPerDay: 1, expires: now.addingTimeInterval(86400),
    shadow: true)
  throwsError(try shadows.check(match, legacy: true))
  try shadows.decide(match.id, revision: match.revision, decision: "approve")
  equal(try shadows.history(workflow: match.workflow!).count, 1)
  try shadows.forget(workflow: match.workflow!)
  equal(try shadows.history(workflow: match.workflow!).count, 0)
  throwsError(try shadows.check(match))
  try notices.resolveAbsent(actions: [.ownerStop], present: [])
  equal(try notices.proposal(shown.id)?.state, "absent")
  print(
    "PASS durable approvals, cross-action Keep, revision/replay refusal, restart/31-day/510-event uncertainty, explicit canary/cap and cross-repository refusal"
  )
}
