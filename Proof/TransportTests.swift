import BurnCore
import CBurn
import Darwin
import Foundation

private final class TransportGate: @unchecked Sendable {
  private let lock = NSLock()
  private var entered = false
  func enter() { lock.withLock { entered = true } }
  var ready: Bool { lock.withLock { entered } }
}

private final class AnalysisCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  func enter() { lock.withLock { calls += 1 } }
  var count: Int { lock.withLock { calls } }
}

func transportProof() async throws {
  let root = URL(fileURLWithPath: "/private/tmp/bz-transport-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  print(
    "Transport cooperative-pool strict mode: "
      + (ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] ?? "unset"))
  try await transportStage("parallel-storage-status", root: root) {
    try await independentRequestsProof(root: root)
  }
  let preview = root.appendingPathComponent("preview")
  try await transportStage("worktree-preview-deadline", root: preview) {
    try await worktreePreviewDeadlineProof(root: preview)
  }
  let idle = root.appendingPathComponent("idle")
  try await transportStage("idle-client-shutdown", root: idle) {
    try await idleTransportProof(root: idle)
  }
  let supplementary = root.appendingPathComponent("supplement")
  try await transportStage("supplementary-inspection", root: supplementary) {
    try await supplementaryInspectionProof(root: supplementary)
  }
  let service = root.appendingPathComponent("service")
  try await transportStage("production-service-routing", root: service) {
    try await concurrentServiceProof(root: service)
  }
  let bounded = root.appendingPathComponent("bounded")
  try await transportStage("bounded-clients-and-overflow", root: bounded) {
    try await boundedTransportProof(root: bounded)
  }
  let analysis = root.appendingPathComponent("analysis-limit")
  try await transportStage("bounded-analysis", root: analysis) {
    try await boundedAnalysisProof(root: analysis)
  }
}

func worktreePreviewDeadlineProof(root: URL) async throws {
  let gate = TransportGate()
  let listener = try AgentListener(root: root) { request in
    if request.operation == "workspace_preview" {
      gate.enter()
      try? await Task.sleep(nanoseconds: 6_000_000_000)
    }
    return AgentReply(message: "fixture " + request.operation)
  }
  let preview = Task {
    try await AgentConnection.callAsync(.init("workspace_preview"), root: root)
  }
  for _ in 0..<100 where !gate.ready { try await Task.sleep(nanoseconds: 10_000_000) }
  check(gate.ready, "Slow native preview entered its request handler")
  let began = ProcessInfo.processInfo.systemUptime
  let status = try await AgentConnection.callAsync(.init("status"), root: root)
  check(status.contains("fixture status"))
  check(ProcessInfo.processInfo.systemUptime - began < 0.4, "Status waited behind a native preview")
  do {
    let reply = try await preview.value
    check(reply.contains("fixture workspace_preview"))
  } catch {
    failTest(
      "Valid native worktree preview exceeded the unrelated status deadline: "
        + error.localizedDescription)
  }
  await listener.stop()
}

private func transportStage(_ name: String, root: URL, operation: () async throws -> Void)
  async throws
{
  print("Transport stage: " + name)
  do { try await operation() } catch {
    // Operation names/timings only; never dump request arguments or file contents.
    let receipts =
      (try? JSONDecoder().decode(
        [AgentTransportReceipt].self,
        from: Data(contentsOf: root.appendingPathComponent("agent-transport.json")))) ?? []
    let timing = receipts.suffix(8).map {
      "\($0.operation):\($0.status):frame=\($0.frameMilliseconds)ms:handler=\($0.handlerMilliseconds)ms:total=\($0.totalMilliseconds)ms"
    }.joined(separator: "; ")
    throw StoreError.message(
      "Transport stage \(name): \(error.localizedDescription). Receipts: \(timing.isEmpty ? "none" : timing)"
    )
  }
}

private func independentRequestsProof(root: URL) async throws {
  let gate = TransportGate()
  let listener = try AgentListener(root: root) { request in
    if request.operation == "disk_inspect" {
      gate.enter()
      try? await Task.sleep(nanoseconds: 900_000_000)
    }
    return AgentReply(message: "fixture " + request.operation)
  }
  let slow = Task.detached {
    try await AgentConnection.callAsync(AgentRequest("disk_inspect"), root: root)
  }
  for _ in 0..<100 where !gate.ready { try await Task.sleep(nanoseconds: 10_000_000) }
  check(gate.ready, "Storage fixture entered the request handler")
  let start = Date()
  let fast = try await AgentConnection.callAsync(AgentRequest("status"), root: root)
  check(fast.contains("fixture status"))
  check(
    Date().timeIntervalSince(start) < 0.4,
    "An unrelated status request must not wait behind storage inspection")
  _ = try await slow.value
  await listener.stop()

  let records = try JSONDecoder().decode(
    [AgentTransportReceipt].self,
    from: Data(contentsOf: root.appendingPathComponent("agent-transport.json")))
  check(records.contains { $0.operation == "disk_inspect" && $0.handlerMilliseconds >= 800 })
  check(records.contains { $0.operation == "status" && $0.handlerMilliseconds < 400 })
  check(records.allSatisfy { $0.status == "ok" })
}

private func idleTransportProof(root idleRoot: URL) async throws {
  // An idle/trickling connection must neither block others nor delay shutdown.
  let idleListener = try AgentListener(root: idleRoot) { _ in AgentReply(message: "responsive") }
  let idle = bz_agent_connect(AgentListener.socketPath(idleRoot))
  check(idle >= 0)
  defer { if idle >= 0 { close(idle) } }
  let began = Date()
  let response = try await AgentConnection.callAsync(AgentRequest("status"), root: idleRoot)
  check(response.contains("responsive"))
  check(Date().timeIntervalSince(began) < 0.4, "An idle client cannot monopolize the listener")
  let stopping = Date()
  await idleListener.stop()
  check(Date().timeIntervalSince(stopping) < 0.4, "Shutdown interrupts a waiting request frame")
  checkFalse(AgentConnection.isAvailable(root: idleRoot))
}

private func supplementaryInspectionProof(root: URL) async throws {
  let store = try Store(root: root.appendingPathComponent("state"))
  let source = root.appendingPathComponent("unfamiliar-producer")
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  let file = source.appendingPathComponent("manifest.json")
  let payload = Data("{\"generatedBy\":\"isolated producer\",\"complete\":true}".utf8)
  try payload.write(to: file)
  // Synthetic measurement exercises the large-branch route; only the tiny payload exists.
  let node = DiskSpaceNode(
    path: source.path, scanRoot: source.path, allocated: 15_000_000_000,
    unshared: 15_000_000_000, files: 1, complete: true, measured: Date())
  var saved = DiskDiscoveryState()
  saved.nodes = [node]
  try saved.save(store)
  let count = AnalysisCounter()
  let analyzer = MoleAnalyzer { path, _, _ in
    count.enter()
    Thread.sleep(forTimeInterval: 0.8)
    let output: [String: Any] = ["path": path, "scan_status": "partial", "entries": []]
    return try? MoleEvidence.decode(JSONSerialization.data(withJSONObject: output), root: path)
  }
  let discovery = try DiskDiscovery(
    store: store, roots: [source.path], moleAnalyzer: analyzer, walker: fixtureWalker(),
    accessCheck: fixtureAccess)
  let started = Date()
  let first = try discovery.inspect(node.id, allowed: [node.id])
  check(
    Date().timeIntervalSince(started) < 0.4,
    "Inspection returns native facts without waiting for supplementary analysis")
  equal(first.node.allocated, 15_000_000_000)
  equal(first.moleState, "queued")
  isNil(first.mole)
  check(
    first.consumerState.contains("Incomplete"),
    "A read-only inspection must preserve unknown visibility")
  check(first.producerEvidence.values.contains { $0.contains("isolated producer") })
  for _ in 0..<10 { _ = try discovery.inspect(node.id, allowed: [node.id]) }
  for _ in 0..<150 where discovery.snapshot().nodes[0].revision == node.revision {
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  notEqual(discovery.snapshot().nodes[0].revision, node.revision)
  let ready = try discovery.inspect(node.id, allowed: [node.id])
  equal(ready.moleState, "cached")
  equal(ready.mole?.scanStatus, "partial")
  equal(
    count.count, 1, "Repeated inspection is single-flight and reuses a completed analyzer result")
  equal(
    try Data(contentsOf: file), payload, "Read-only supplementary inspection preserves source bytes"
  )
  await discovery.stopSupplementary()
}

private func concurrentServiceProof(root: URL) async throws {
  let source = root.appendingPathComponent("owned-data")
  let store = try Store(root: root)
  try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
  let payload = Data("Keep this isolated producer's accepted result.\n".utf8)
  let evidence = source.appendingPathComponent("retention.md")
  try payload.write(to: evidence)
  let node = DiskSpaceNode(
    path: source.path, scanRoot: source.path, allocated: 15_000_000_000,
    unshared: 15_000_000_000, files: 1, complete: true, measured: Date())
  var saved = DiskDiscoveryState()
  saved.nodes = [node]
  try saved.save(store)
  // No refresh/scan: test saved discovery through the actual service and Monitor routing.
  let monitor = try Monitor(
    root: root, discoveryRoots: [source.path], accessCheck: fixtureAccess,
    discoveryWalker: fixtureWalker())
  let service = AgentService(monitor: monitor)
  let gate = TransportGate()
  let listener = try AgentListener(root: root) { request in
    if request.operation == "disk_inspect" {
      gate.enter()
      try? await Task.sleep(nanoseconds: 900_000_000)
    }
    return await service.call(request)
  }
  let slow = Task.detached {
    try await AgentConnection.callAsync(
      .init("disk_inspect", findingID: node.id, reviewIDs: [node.id]), root: root)
  }
  for _ in 0..<100 where !gate.ready { try await Task.sleep(nanoseconds: 10_000_000) }
  let start = Date()
  let retained = try await AgentConnection.callAsync(
    .init(
      "disk_evidence", findingID: node.id,
      reviewIDs: [node.id], workspacePath: "retention.md"), root: root)
  check(
    Date().timeIntervalSince(start) < 0.4,
    "Production evidence route remains responsive during unrelated storage work")
  check(retained.contains("accepted result"))
  let reply = try JSONDecoder().decode(AgentReply.self, from: Data(try await slow.value.utf8))
  check(reply.ok)
  equal(reply.diskInspection?.node.allocated, 15_000_000_000)
  check(reply.diskInspection?.consumerState.contains("Incomplete") == true)
  let state = await monitor.snapshot()
  isNil(state.catalog.lastSample)
  equal(
    state.processCount, 0,
    "Read-only storage requests must not trigger unrelated whole-machine scans")
  equal(try Data(contentsOf: evidence), payload)
  await listener.stop()
}

private func boundedTransportProof(root: URL) async throws {
  let count = AnalysisCounter()
  let listener = try AgentListener(root: root) { _ in
    count.enter()
    try? await Task.sleep(nanoseconds: 10_000_000_000)
    return AgentReply(message: "fixture")
  }
  let pending = (0..<8).map { _ in
    Task.detached {
      try? await AgentConnection.callAsync(AgentRequest("disk_inspect"), root: root)
    }
  }
  for _ in 0..<150 where count.count < 8 { try await Task.sleep(nanoseconds: 10_000_000) }
  equal(count.count, 8)
  let overflow = try await AgentConnection.callAsync(
    AgentRequest("private argument must not enter receipt"), root: root)
  check(
    overflow.contains("capacity reached"),
    "Connection pressure is rejected instead of creating unbounded workers")
  let idleOverflow = bz_agent_connect(AgentListener.socketPath(root))
  guard idleOverflow >= 0 else {
    throw StoreError.message("Idle overflow fixture could not connect")
  }
  defer { close(idleOverflow) }
  // Confirm the ninth connection reached rejection, rather than racing stop
  // against accept and accidentally testing only the original eight handlers.
  var rejectionStarted = false
  for _ in 0..<100 where !rejectionStarted {
    if let bytes = try? Data(contentsOf: root.appendingPathComponent("agent-transport.json")),
      let entries = try? JSONDecoder().decode([AgentTransportReceipt].self, from: bytes)
    {
      rejectionStarted = entries.contains { $0.status == "rejecting" }
    }
    if !rejectionStarted { try await Task.sleep(nanoseconds: 5_000_000) }
  }
  check(rejectionStarted, "Idle ninth client entered bounded rejection")
  let stop = Date()
  await listener.stop()
  check(
    Date().timeIntervalSince(stop) < 0.5,
    "Cancellation interrupts an idle overflow client as well as the eight request workers")
  equal(count.count, 8, "Overflow never starts a ninth handler")
  for work in pending { _ = await work.value }
  let text = try String(
    contentsOf: root.appendingPathComponent("agent-transport.json"), encoding: .utf8)
  checkFalse(
    text.contains("private argument"), "Transport receipts never include untrusted args or prose")
  let records = try JSONDecoder().decode([AgentTransportReceipt].self, from: Data(text.utf8))
  check(records.count <= 64)
  check(records.contains { $0.status == "busy" })
  check(records.contains { $0.status == "cancelled" })
}

private func boundedAnalysisProof(root: URL) async throws {
  let store = try Store(root: root.appendingPathComponent("state"))
  let count = AnalysisCounter()
  let analyzer = MoleAnalyzer { _, _, _ in
    count.enter()
    Thread.sleep(forTimeInterval: 0.5)
    return nil
  }
  var paths: [String] = []
  for i in 0..<10 {
    let path = root.appendingPathComponent("owned-\(i)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    paths.append(path.path)
  }
  equal(analyzer.request(paths[0], store: store, protected: []).status, "queued")
  for _ in 0..<100 where count.count == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
  equal(count.count, 1)
  for path in paths[1...8] {
    equal(analyzer.request(path, store: store, protected: []).status, "queued")
  }
  equal(analyzer.request(paths[9], store: store, protected: []).status, "deferred")
  let stop = Date()
  await analyzer.stop()
  check(Date().timeIntervalSince(stop) < 0.8)
  equal(
    count.count, 1, "Stopping a supplementary worker cancels queued work rather than draining scans"
  )
  equal(analyzer.request(paths[9], store: store, protected: []).status, "unavailable")
}
