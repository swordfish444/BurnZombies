import BurnCore
import Darwin
import Foundation

func agentBridgeProof() async throws {
  let root = URL(fileURLWithPath: "/tmp/bz-" + UUID().uuidString.prefix(8))
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = try Monitor(root: root)
  let service = AgentService(monitor: monitor)
  let listener = try AgentListener(root: root) { await service.call($0) }
  let status = try await Task.detached { try AgentConnection.call(AgentRequest("status"), root: root) }.value
  let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
  let reply = try decoder.decode(AgentReply.self, from: Data(status.utf8))
  check(reply.ok && reply.observedProcesses > 0, "agent did not reach the live monitor")
  equal(reply.verifiedHelpers, 0)
  check(reply.findings.allSatisfy { $0.id.isEmpty || UUID(uuidString: $0.id) != nil }, "private group path leaked")
  let refused = await service.call(AgentRequest("preview", findingID: UUID().uuidString))
  checkFalse(refused.ok, "unknown work received cleanup permission")
  let forged = await service.call(AgentRequest("burn", previewToken: UUID().uuidString))
  checkFalse(forged.ok, "forged preview token accepted")
  let unknown = await service.call(AgentRequest("delete"))
  checkFalse(unknown.ok)
  func call(_ request: AgentRequest) async throws -> AgentReply {
    let raw = try await Task.detached { try AgentConnection.call(request, root: root) }.value
    return try decoder.decode(AgentReply.self, from: Data(raw.utf8))
  }
  let inspected = try await call(AgentRequest("inspect", pids: [getpid()]))
  equal(inspected.processes.count, 1)
  check(inspected.processes.first?.protectedReason != nil, "authenticated caller ancestry was not protected")
  let ownPreview = try await call(AgentRequest("preview", processIDs: inspected.processes.map(\.id),
    label: "self", rationale: "Test must not allow terminating the requesting harness."))
  checkFalse(ownPreview.ok)

  let disposable = Process(), active = Process()
  for process in [disposable, active] {
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["300"]
    try process.run()
  }
  defer {
    for process in [disposable, active] {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
  }
  let tree = try await call(AgentRequest("inspect", pids: [getpid()]))
  check(tree.processes[0].liveChildCount >= 2)
  check(tree.processes[0].liveChildren.contains { $0.identity.pid == disposable.processIdentifier })
  let targets = try await call(AgentRequest("inspect", pids: [disposable.processIdentifier]))
  equal(targets.processes.count, 1)
  equal(targets.processes[0].liveChildCount, 0)
  let noPeer = await service.call(AgentRequest("preview", processIDs: targets.processes.map(\.id),
    label: "Unknown peer", rationale: "An unauthenticated peer must not receive a cleanup preview."))
  checkFalse(noPeer.ok, "missing peer PID did not fail closed")
  check(disposable.isRunning && active.isRunning, "observation stopped work")
  let preview = try await call(AgentRequest("preview", processIDs: targets.processes.map(\.id),
    label: "Owned sacrificial fixture", rationale: "The test created this exact disposable process; its job is finished. The separate active control is excluded."))
  guard let token = preview.previewToken else { throw StoreError.message(preview.message) }
  check(disposable.isRunning, "preview stopped work")
  let burned = try await call(AgentRequest("burn", previewToken: token))
  check(burned.ok, burned.message)
  equal(burned.verifiedHelpers, 0, "pending request credited as verified")
  disposable.waitUntilExit()
  check(active.isRunning, "active control was killed")
  let replay = try await call(AgentRequest("burn", previewToken: token))
  checkFalse(replay.ok, "single-use token replay accepted")
  let stale = try await call(AgentRequest("preview", processIDs: targets.processes.map(\.id),
    label: "Expired identity", rationale: "The selected process already exited and must be rejected."))
  checkFalse(stale.ok, "exited identity accepted")

  let hookTime = Date()
  let store = try Store(root: root)
  try HarnessHook.publish(.init(observedAt: hookTime, processCount: 10, residentBytes: 1024, pressure: "Low"), store: store)
  let firstHook = try HarnessHook.response(client: "claude", event: "PostToolUse", input: [:], root: root, now: hookTime)
  check(firstHook.isEmpty, "quiet baseline interrupted a session")
  let later = hookTime.addingTimeInterval(700)
  try HarnessHook.publish(.init(observedAt: later, processCount: 10, residentBytes: 1024, pressure: "Low"), store: store)
  let hookResult1 = try HarnessHook.response(client: "codex", event: "PostToolUse", input: [:], root: root, now: later)
  check(hookResult1.isEmpty,
    "unchanged machine triggered a repeated review")
  try HarnessHook.publish(.init(observedAt: later, processCount: 35, residentBytes: 1024, pressure: "Low"), store: store)
  let hookResult2 = try HarnessHook.response(client: "claude", event: "PostToolUse", input: [:], root: root, now: later)
  check(hookResult2["hookSpecificOutput"] != nil)
  let hookResult3 = try HarnessHook.response(client: "codex", event: "PostToolUse", input: [:], root: root, now: later)
  check(hookResult3.isEmpty,
    "simultaneous harnesses caused a review storm")
  try HarnessHook.requestCleanup(root: root)
  let hookResult4 = try HarnessHook.response(client: "codex", event: "Stop", input: [:], root: root, now: later)
  check(hookResult4.isEmpty,
    "hygiene prevented a turn from ending")
  let hookResult5 = try HarnessHook.response(client: "codex", event: "PostToolUse", input: ["tool_name": "mcp__burnzombies__status"], root: root, now: later)
  check(hookResult5.isEmpty,
    "hygiene triggered itself")
  let requestedHook = try HarnessHook.response(client: "codex", event: "PostToolUse", input: [:], root: root, now: later)
  check(requestedHook["hookSpecificOutput"] != nil)
  check(requestedHook["decision"] == nil, "checkpoint must never block")
  try HarnessHook.requestCleanup(root: root)
  let hookResult6 = try HarnessHook.response(client: "codex", event: "PostToolUse", input: [:], root: root, now: later.addingTimeInterval(181))
  check(hookResult6.isEmpty,
    "stale observations triggered a review")
  throwsError(try AgentListener(root: root) { _ in AgentReply(message: "wrong owner") })
  var metadata = stat()
  equal(lstat(AgentListener.socketPath(root), &metadata), 0)
  equal(metadata.st_mode & 0o777, 0o600)
  check(AgentConnection.isAvailable(root: root), "second listener broke the first")
  await listener.stop()
  checkFalse(AgentConnection.isAvailable(root: root))
  let target = root.appendingPathComponent("preserved")
  try Data("keep".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(atPath: AgentListener.socketPath(root), withDestinationPath: target.path)
  throwsError(try AgentListener(root: root) { _ in AgentReply(message: "unsafe") })
  equal(try String(contentsOf: target, encoding: .utf8), "keep")
}

func runAgentFixture(root: URL) async throws {
  let monitor = try Monitor(root: root)
  let service = AgentService(monitor: monitor)
  let listener = try AgentListener(root: root) { request in
    let allowlist = root.appendingPathComponent("allowed-processes.json")
    if ["preview", "lifecycle"].contains(request.operation), let ids = request.processIDs,
      FileManager.default.fileExists(atPath: allowlist.path) {
      guard let data = try? Data(contentsOf: allowlist), data.count < 4096,
        let pids = try? JSONDecoder().decode([Int32].self, from: data),
        ids.allSatisfy({ id in pids.contains { pid in
          if case .found(let o) = Native().probe(pid) { return o.identity.key == id }; return false
        } }) else { return AgentReply(ok: false, message: "Acceptance fixture refuses targets outside its test-owned allowlist.") }
    }
    return await service.call(request)
  }
  print("READY"); fflush(stdout)
  _ = FileHandle.standardInput.readDataToEndOfFile()
  await listener.stop()
}
