import BurnCore
import Darwin
import Foundation

/// Private adversarial worker. Only dispatched by the proof runner, never the app.
func diskWalkFixture() throws -> Never {
  let args = CommandLine.arguments
  guard args.count == 5, UUID(uuidString: args[3]) != nil else { exit(64) }
  let root = args[2], runID = args[3], output = URL(fileURLWithPath: args[4])
  guard root.hasPrefix(WorkspaceSafety.canonical(NSTemporaryDirectory()) + "/bz-disk-worker-proof-"),
    output.lastPathComponent == "disk-worker-" + runID else { exit(64) }
  alarm(15)
  let mode = URL(fileURLWithPath: root).lastPathComponent
  if mode == "hang" || mode == "churn" { signal(SIGTERM, SIG_IGN) }
  try Data(String(getpid()).utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("worker.pid"))
  func publish(sequence: UInt64, complete: Bool) throws {
    let node = DiskSpaceNode(path: root, scanRoot: root, allocated: 4096, unshared: 4096,
      files: 1, complete: complete, measured: Date())
    let finished = DiskSpaceNode(path: root + "/finished", scanRoot: root, allocated: 4096,
      unshared: 4096, files: 1, complete: true, measured: Date())
    let snapshot = DiskWalkCheckpoint(runID: runID, root: root, sequence: sequence, entries: 1,
      complete: complete, nodes: complete ? [node] : [node, finished])
    let path = output.appendingPathComponent("checkpoint.json")
    try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
    guard chmod(path.path, 0o600) == 0 else { exit(74) }
  }
  try publish(sequence: 1, complete: mode == "healthy")
  if mode == "healthy" { exit(0) }
  if mode == "churn" {
    // New timestamps/sequences without traversing another entry are not progress.
    var sequence: UInt64 = 1
    while true {
      Thread.sleep(forTimeInterval: 0.05)
      sequence += 1
      try publish(sequence: sequence, complete: false)
    }
  }
  while true { pause() }
}

private func diskWorkerWait(_ condition: () -> Bool, _ message: String) async throws {
  let deadline = Date().addingTimeInterval(10)
  while !condition() {
    guard Date() < deadline else { throw StoreError.message(message) }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

func diskWorkerProof() async throws {
  let base = URL(fileURLWithPath: WorkspaceSafety.canonical(NSTemporaryDirectory()))
    .appendingPathComponent("bz-disk-worker-proof-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: base) }
  let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  func directory(_ name: String) throws -> URL {
    let path = base.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return path
  }
  let hang = try directory("hang"), healthy = try directory("healthy"), churn = try directory("churn")
  let temporary = try directory("private-state")
  let runner = DiskWalkRunner(executable: executable, argumentPrefix: ["--disk-walk-fixture"],
    progressTimeout: 0.8, rootTimeout: 3, teardownTimeout: 0.5)
  let control = Process(); control.executableURL = executable; control.arguments = ["--passive-child"]
  try control.run()
  defer { if control.isRunning { control.terminate() }; control.waitUntilExit() }

  var published: [DiskSpaceNode] = []
  let started = Date()
  let stalled = runner.run(root: hang.path, temporaryParent: temporary, publish: { nodes, _ in published = nodes })
  equal(stalled.status, "stalled", "An owned worker stuck in a syscall must time out")
  check(Date().timeIntervalSince(started) < 5, "A stuck root cannot hold the observer indefinitely")
  check(stalled.childReaped, "Supervisor must reap its exact child even when SIGTERM is ignored")
  guard let childPID = stalled.childPID else { throw StoreError.message("Missing supervised worker PID") }
  var status: Int32 = 0
  errno = 0
  equal(waitpid(childPID, &status, WNOHANG), -1, "No supervisor-owned child may remain unreaped")
  equal(errno, ECHILD, "The completed supervisor owns and reaps the child")
  check(control.isRunning, "An unrelated live control must survive worker teardown")
  check(!stalled.nodes.isEmpty && !published.isEmpty, "Useful partial measurements survive timeout")
  check(stalled.nodes.contains { $0.path == hang.path && !$0.complete }, "Partial root cannot be advertised as complete")
  check(stalled.nodes.contains { $0.path == hang.path + "/finished" && $0.complete },
    "A finished subtree remains useful even when a different branch of its parent stalls")
  let next = runner.run(root: healthy.path, temporaryParent: temporary)
  equal(next.status, "complete"); check(next.childReaped)
  check(next.nodes.contains { $0.path == healthy.path && $0.complete }, "A healthy next root is still measured")

  let churnStarted = Date()
  let churned = runner.run(root: churn.path, temporaryParent: temporary)
  check(["stalled", "failed"].contains(churned.status), "Checkpoint churn must fail or time out, never complete")
  check(Date().timeIntervalSince(churnStarted) < 2.5, "Checkpoint rewrites alone cannot refresh traversal progress")
  check(churned.childReaped)

  var cancel = false
  let cancelled = runner.run(root: hang.path, temporaryParent: temporary,
    shouldContinue: { !cancel }, publish: { _, _ in cancel = true })
  equal(cancelled.status, "cancelled"); check(cancelled.childReaped)
  check(control.isRunning, "Policy cancellation preserves unrelated processes")

  let runID = UUID().uuidString
  func snapshot(root requestedRoot: String? = nil, id: String? = nil, sequence: UInt64 = 1,
                nodePath: String? = nil, nodeRoot: String? = nil) throws -> Data {
    let root = requestedRoot ?? healthy.path
    let node = DiskSpaceNode(path: nodePath ?? root, scanRoot: nodeRoot ?? root,
      allocated: 4096, unshared: 4096, files: 1, complete: false, measured: Date())
    return try JSONEncoder().encode(DiskWalkCheckpoint(runID: id ?? runID, root: root,
      sequence: sequence, entries: 1, complete: false, nodes: [node]))
  }
  let valid = try snapshot()
  let prior = try DiskWalkRunner.decode(data: valid, root: healthy.path, runID: runID)
  equal(prior.nodes.count, 1)
  throwsError(try DiskWalkRunner.decode(data: Data("{".utf8), root: healthy.path, runID: runID))
  throwsError(try DiskWalkRunner.decode(data: snapshot(id: UUID().uuidString), root: healthy.path, runID: runID))
  throwsError(try DiskWalkRunner.decode(data: snapshot(root: hang.path), root: healthy.path, runID: runID))
  throwsError(try DiskWalkRunner.decode(data: snapshot(nodePath: hang.path), root: healthy.path, runID: runID))
  throwsError(try DiskWalkRunner.decode(data: snapshot(nodeRoot: hang.path), root: healthy.path, runID: runID))
  throwsError(try DiskWalkRunner.decode(data: valid, root: healthy.path, runID: runID, previous: prior))
  throwsError(try DiskWalkRunner.decode(data: Data(repeating: 32, count: 8_388_609), root: healthy.path, runID: runID))

  // Actual native worker traverses only a tiny owned tree through this same runner.
  let nativeRoot = try directory("native")
  try Data(repeating: 37, count: 4096).write(to: nativeRoot.appendingPathComponent("owned.bin"))
  let nativeRunner = DiskWalkRunner(executable: executable, progressTimeout: 2, rootTimeout: 5, teardownTimeout: 0.5)
  let native = nativeRunner.run(root: nativeRoot.path, temporaryParent: temporary)
  equal(native.status, "complete", "Production native worker outcome: \(native.status), reaped=\(native.childReaped), nodes=\(native.nodes.count)")
  check(native.childReaped)
  check(native.nodes.contains { $0.path == nativeRoot.path && $0.files == 1 && $0.complete },
    "Production native worker returns the exact owned tree's complete measurement")

  let discoveryStore = try Store(root: base.appendingPathComponent("discovery-state"))
  var oldGroup = DiskSpaceNode(path: hang.path + "/old-group", scanRoot: hang.path,
    allocated: 8192, unshared: 8192, files: 2, complete: true, measured: Date().addingTimeInterval(-60))
  oldGroup.members = [hang.path + "/finished", hang.path + "/unfinished"]
  var missingGroup = oldGroup
  missingGroup.path = hang.path + "/missing-group"
  missingGroup.members = [hang.path + "/unseen-a", hang.path + "/unseen-b"]
  var oldState = DiskDiscoveryState(); oldState.nodes = [oldGroup, missingGroup]
  try oldState.save(discoveryStore)
  let discovery = try DiskDiscovery(store: discoveryStore, roots: [hang.path, healthy.path], walker: runner, accessCheck: fixtureAccess)
  var policy = DiskPolicy(); policy.mode = "recommend"
  discovery.tick(policy: policy)
  try await diskWorkerWait({
    let state = discovery.snapshot()
    return state.running == nil && state.queue.isEmpty && state.nodes.contains { $0.path == healthy.path && $0.complete }
  }, "A timed-out root starved the next discovery root")
  let mapped = discovery.snapshot()
  check(mapped.unavailable?.contains(hang.path) == true, "Timed-out root remains an explicit coverage gap")
  check(mapped.nodes.contains { $0.path == hang.path && !$0.complete }, "Discovery retains incomplete partial evidence")
  check(mapped.nodes.contains { $0.id == oldGroup.id && !$0.complete }, "A grouped result cannot retain stale completeness when a member is missing")
  check(mapped.nodes.contains { $0.id == missingGroup.id && !$0.complete }, "A group wholly absent from current partial coverage cannot remain complete")
  check(control.isRunning)

  let cancelStore = try Store(root: base.appendingPathComponent("cancel-state"))
  let cancelDiscovery = try DiskDiscovery(store: cancelStore, roots: [hang.path], walker: runner, accessCheck: fixtureAccess)
  cancelDiscovery.tick(policy: policy)
  try await diskWorkerWait({ cancelDiscovery.snapshot().nodes.contains { $0.path == hang.path } }, "Cancellation fixture never published its partial progress")
  policy.mode = "off"
  cancelDiscovery.tick(policy: policy)
  try await diskWorkerWait({ cancelDiscovery.snapshot().running == nil }, "Turning discovery off did not cancel its owned worker")
  check(cancelDiscovery.snapshot().nodes.filter { $0.path == hang.path }.allSatisfy { !$0.complete }, "Cancelled root traversal cannot gain completion authority")
  check(control.isRunning)
  print("PASS disk worker hard timeout/reaping, unrelated control preservation, bounded scoped checkpoints, partial coverage, next-root progress and policy cancellation")
}
