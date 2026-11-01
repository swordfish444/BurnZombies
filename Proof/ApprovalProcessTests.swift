import BurnCore
import Darwin
import Foundation

/// Exercise the native human-decision journey with fresh-install authority,
/// independent live helpers, released claims, an ended lease and an active control.
func approvalProcessProof() async throws {
  let root = URL(fileURLWithPath: "/private/tmp/bz-process-approval-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = try Monitor(
    legacyAuthority: false, discoveryHome: nil, root: root, accessCheck: fixtureAccess)
  let service = AgentService(monitor: monitor)
  var workers: [Process] = []
  defer { for worker in workers where worker.isRunning { worker.terminate() } }
  for _ in 0..<4 {
    let worker = Process()
    worker.executableURL = URL(fileURLWithPath: "/bin/sleep")
    worker.arguments = ["300"]
    try worker.run()
    workers.append(worker)
  }
  func call(_ request: AgentRequest) async -> AgentReply {
    var request = request
    request.callerPID = getpid()
    return await service.call(request)
  }
  _ = await monitor.refresh()
  let inspected = await call(AgentRequest("inspect", pids: workers.map(\.processIdentifier)))
  let all = inspected.processes
  guard all.count == 4 else { throw StoreError.message("Missing process approval fixtures") }
  let grouped = all.filter {
    [workers[0].processIdentifier, workers[1].processIdentifier].contains($0.pid)
  }.map(\.id)
  let leased = all.first { $0.pid == workers[2].processIdentifier }!
  let active = all.first { $0.pid == workers[3].processIdentifier }!
  func register(_ ids: [String]) async -> AgentReply {
    await call(
      AgentRequest(
        "lifecycle", processIDs: ids, label: "Disposable approval fixture",
        rationale:
          "This test owns these sleeping helpers and retains their work until explicitly released.",
        action: "register",
        completionCondition: "The fixture task completes and its owning test releases the helper."))
  }
  let owned = await register(grouped)
  let retained = await register([active.id])
  check(retained.ok)
  guard let token = owned.workToken else { throw StoreError.message(owned.message) }
  let release = await call(
    AgentRequest(
      "lifecycle",
      rationale: "The fixture task completed and its output was saved; no consumer remains.",
      action: "release", workToken: token))
  check(release.ok)
  guard let activeToken = retained.workToken else {
    throw StoreError.message("Missing control ownership")
  }
  _ = await call(
    AgentRequest(
      "lifecycle",
      rationale:
        "The control task is temporarily complete for the readiness withdrawal regression.",
      action: "release", workToken: activeToken))
  let previouslyReady = await monitor.snapshot().inbox.proposals.first {
    $0.resources == [active.id]
  }!
  check(previouslyReady.ready)
  try await monitor.decideFinding(
    previouslyReady.id, revision: previouslyReady.revision, decision: "approve")
  _ = await call(
    AgentRequest(
      "lifecycle",
      rationale: "The control task resumed and actively requires this exact helper again.",
      action: "retain", workToken: activeToken))
  for _ in 0..<2 { _ = await monitor.snapshot() }
  let withdrawn = await monitor.snapshot().inbox.proposals.first { $0.id == previouslyReady.id }!
  checkFalse(withdrawn.ready)
  isNil(withdrawn.approvedRevision)
  let store = try Store(root: root)
  guard case .found(let leasedObservation) = Native().probe(workers[2].processIdentifier) else {
    throw StoreError.message("Lease target disappeared")
  }
  var lease = Lease(
    label: "Ended fixture lease", owner: ProcessIdentity(pid: 999999, seconds: 1),
    members: [Member(leasedObservation)], allowCleanup: true)
  lease.ended = Date()
  try store.saveLease(lease)
  let preview = await call(
    AgentRequest(
      "preview", processIDs: grouped, label: "Grouped released fixtures",
      rationale:
        "Exact released fixture owners have completed their work; request native permission review."
    ))
  check(
    preview.previewToken == nil && preview.failureKind == "approval_required",
    "A fresh-install ledger bypassed human approval")
  for _ in 0..<2 {
    _ = await monitor.refresh()
    _ = await monitor.snapshot()
  }
  let inbox = await monitor.snapshot().inbox
  guard let group = inbox.proposals.first(where: { Set($0.resources) == Set(grouped) }),
    group.ready,
    let ended = inbox.proposals.first(where: { $0.resources == [leased.id] }), ended.ready
  else {
    throw StoreError.message("Released-claim group or ended-lease finding disappeared")
  }
  checkFalse(inbox.proposals.contains { $0.resources == [active.id] && $0.ready })
  for p in [group, ended] {
    try await monitor.decideFinding(p.id, revision: p.revision, decision: "approve")
  }
  for _ in 0..<2 {
    _ = await monitor.refresh()
    _ = await monitor.snapshot()
  }
  for p in [group, ended] {
    _ = try await monitor.executeApprovedFinding(p.id, revision: p.revision)
  }
  let deadline = Date().addingTimeInterval(145)
  while Date() < deadline {
    _ = await monitor.refresh()
    if await monitor.snapshot().catalog.lifetimeVerified == 3 { break }
    check(workers[3].isRunning, "Retained active control was stopped")
    try await Task.sleep(for: .seconds(2))
  }
  let finished = await monitor.snapshot()
  equal(finished.catalog.lifetimeVerified, 3)
  equal(finished.catalog.events.filter { $0.outcome == "verified" }.count, 2)
  check(workers[3].isRunning)
  equal(Set(finished.inbox.operations.map(\.authority)), Set(["Explicit approval once"]))
  check(
    finished.inbox.proposals.filter { $0.resources.count == 1 && grouped.contains($0.resources[0]) }
      .allSatisfy { !$0.ready || $0.state == "absent" })
  print(
    "PASS fresh-install released-claim group and ended-lease findings survive observation, explicit approvals execute and verify three exits, active control survives"
  )
}
