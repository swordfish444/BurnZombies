import BurnCore
import Darwin
import Foundation

func lifecycleProof() async throws {
  let root = URL(fileURLWithPath: "/tmp/bz-work-" + UUID().uuidString.prefix(8))
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = try Monitor(root: root), worker = Process()
  worker.executableURL = URL(fileURLWithPath: "/bin/sleep"); worker.arguments = ["120"]
  try worker.run()
  defer { if worker.isRunning { worker.terminate() }; worker.waitUntilExit() }
  let service = AgentService(monitor: monitor)
  func call(_ request: AgentRequest) async -> AgentReply {
    var r = request; r.callerPID = getpid(); return await service.call(r)
  }
  let inspected = await call(AgentRequest("inspect", pids: [worker.processIdentifier]))
  let ids = inspected.processes.map(\.id)
  let register = AgentRequest("lifecycle", processIDs: ids, label: "Owned preview helper",
    rationale: "This test owns a disposable helper still needed by its preview operation.",
    action: "register", completionCondition: "Preview completes and every consumer releases the helper.")
  let unknown = await service.call(register)
  checkFalse(unknown.ok, "unauthenticated ownership accepted")
  let owned = await call(register), shared = await call(register)
  guard let first = owned.workToken, let second = shared.workToken else { throw StoreError.message(owned.message + shared.message) }
  check(first != second)
  equal(shared.activeWorkCount, 2, "lifecycle reply reported stale ownership counts")
  let store = try Store(root: root)
  equal(try store.load().workEvidence?.count, 2, "ownership not durable")
  let read = await call(AgentRequest("work"))
  let encoded = try read.json()
  checkFalse(encoded.contains(first) || encoded.contains(second) || encoded.contains("tokenHash"), "readback exposed an update capability")
  let previewRequest = AgentRequest("preview", processIDs: ids, label: "Lifecycle proof",
    rationale: "Owned fixture completion is supported by the task's durable release evidence.")
  let blocked = await call(previewRequest)
  checkFalse(blocked.ok, "active owner did not block preview")
  let forged = await call(AgentRequest("lifecycle", rationale: "Invented completion must not change someone else's claim.",
    action: "release", workToken: String(repeating: "x", count: 72)))
  checkFalse(forged.ok)
  func transition(_ token: String, _ action: String) async -> AgentReply {
    await call(AgentRequest("lifecycle", rationale: "Preview result was received and saved; this task has no remaining consumer.", action: action, workToken: token))
  }
  let released = await transition(first, "release"); check(released.ok, released.message)
  let sharedBlocked = await call(previewRequest); checkFalse(sharedBlocked.ok, "one owner released another's shared helper")
  let quiet = await call(AgentRequest("status")); equal(quiet.releasedWorkCount, 0)
  let released2 = await transition(second, "release"); check(released2.ok)
  let ready = await call(AgentRequest("status")); equal(ready.releasedWorkCount, 2)
  check(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-request").path), "release did not queue review")
  let preview = await call(previewRequest)
  guard let previewToken = preview.previewToken else { throw StoreError.message(preview.message) }
  let retained = await transition(first, "retain"); check(retained.ok)
  let race = await call(AgentRequest("burn", previewToken: previewToken))
  checkFalse(race.ok, "new active consumer after preview was killed")
  check(worker.isRunning)
  let claims = try store.load().workEvidence ?? []
  check(WorkEvidence.blocking(claims, identity: ids[0]))
  checkFalse(WorkEvidence.blocking(claims, identity: ids[0] + "-reused"), "PID-only protection crossed birth identity")
  // A persistent active claim never becomes released simply because its owner is stale or gone.
  var old = claims[0]; old.updated = .distantPast; old.created = .distantPast
  check(WorkEvidence.blocking([old], identity: ids[0]), "old owner silently expired")
  var descendant = claims[0].members[0].identity; descendant.pid += 1
  let child = Record(Observation(identity: descendant, parent: worker.processIdentifier))
  let parent = Record(Observation(identity: claims[0].members[0].identity))
  check(WorkEvidence.blockingTree(claims, record: child, records: [child.id: child, parent.id: parent]), "retained parent did not protect its child")
  let invalid = "{\"action\":\"release\",\"work_token\":\"\(first)\",\"evidence\":\"Actual observed completion with no remaining work.\",\"process_ids\":[]}".data(using: .utf8)!
  throwsError(try LifecycleInput.request(invalid))
  let missing = await call(AgentRequest("lifecycle", processIDs: [ids[0] + "-old"], label: "stale",
    rationale: "This stale identity must never acquire ownership of a new process.", action: "register", completionCondition: "This operation finishes successfully."))
  checkFalse(missing.ok)
  // Fail-closed persistence: a failed disk checkpoint must not publish a release.
  let catalog = root.appendingPathComponent("catalog.bzcat"), backup = root.appendingPathComponent("saved.bzcat")
  try FileManager.default.moveItem(at: catalog, to: backup)
  try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
  let failed = await transition(first, "release")
  checkFalse(failed.ok, "failed persistence published release")
  try FileManager.default.removeItem(at: catalog)
  try FileManager.default.moveItem(at: backup, to: catalog)
  let stillBlocked = await call(previewRequest); checkFalse(stillBlocked.ok)
  check(worker.isRunning)
}
