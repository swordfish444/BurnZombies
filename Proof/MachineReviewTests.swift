import BurnCore
import Darwin
import Foundation

func machineReviewProof() async throws {
  let now = Date()
  var signal = HarnessHook.Signal(observedAt: now, processCount: 10, residentBytes: 100, pressure: "Low")
  var state = MachineReviewState()
  check(state.due(signal, requested: false, now: now), "No chat event is needed for initial review")
  state.lastStarted = now; state.signal = signal
  checkFalse(state.due(signal, requested: false, now: now.addingTimeInterval(30)))
  signal.observedAt = now.addingTimeInterval(601)
  checkFalse(state.due(signal, requested: false, now: signal.observedAt), "Unchanged scans do not repeatedly invoke models")
  signal.processCount += 20
  check(state.due(signal, requested: false, now: signal.observedAt))
  state.phase = "paused"
  checkFalse(state.due(signal, requested: true, now: signal.observedAt), "Requests do not bypass a quota/error pause")
  state.phase = "observing"
  checkFalse(state.due(signal, requested: true, now: signal.observedAt.addingTimeInterval(181)), "Stale scans cannot dispatch reviews")
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-machine-proof-" + UUID().uuidString)
  let store = try Store(root: root)
  defer { try? FileManager.default.removeItem(at: root) }
  let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("burnzombies").path
  let server = URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("burnzombies-mcp").path
  var config = MachineReviewConfiguration(harness: "codex", executable: "/usr/bin/true", launcher: cli, server: server)
  try config.save(root: root)
  try HarnessHook.publish(.init(observedAt: Date(), processCount: 10, residentBytes: 100, pressure: "Low"), store: store)
  try HarnessHook.requestCleanup(root: root)
  let hook = try HarnessHook.response(client: "codex", event: "PostToolUse", input: ["tool_name": "Bash"], root: root)
  check(hook.isEmpty, "Legacy hooks stay inert when machine reviewer owns scheduling")
  check(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-request").path))
  let reviewer = try MachineReviewer(root: root)
  async let first: Void = reviewer.tick()
  async let concurrent: Void = reviewer.tick()
  _ = await (first, concurrent)
  let completed = await reviewer.snapshot()
  equal(completed.phase, "observing"); check(completed.lastFinished != nil)
  let start = completed.lastStarted
  await reviewer.tick()
  equal(await reviewer.snapshot().lastStarted, start, "Identical observations do not trigger a second invocation")
  config.executable = "/usr/bin/false"; try config.save(root: root)
  try HarnessHook.publish(.init(observedAt: now.addingTimeInterval(3700), processCount: 10, residentBytes: 100, pressure: "Low"), store: store)
  await reviewer.tick(now: now.addingTimeInterval(3700))
  equal(await reviewer.snapshot().phase, "paused", "Harness failure pauses instead of retrying or switching providers")
  let failed = await reviewer.snapshot().lastStarted
  await reviewer.tick(now: now.addingTimeInterval(7400))
  equal(await reviewer.snapshot().lastStarted, failed)
  for harness in MachineReviewConfiguration.harnesses {
    config.harness = harness
    let args = try MachineReviewer.arguments(config, directory: root, root: root, prompt: "Review this computer")
    checkFalse(args.contains("--yolo")); checkFalse(args.contains("--force"))
    checkFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
    checkFalse(args.contains("--resume")); checkFalse(args.contains("--continue"))
  }
  let scan = Native().scan()
  let outside = Process(); outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
  outside.arguments = ["30"]; outside.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
  try outside.run(); defer { if outside.isRunning { outside.terminate() }; outside.waitUntilExit() }
  let monitor = try Monitor(root: root.appendingPathComponent("observation"))
  let observed = await monitor.refresh()
  check(observed.catalog.records.values.contains { $0.latest.identity.pid == outside.processIdentifier })
  check(observed.processCount >= scan.observations.count - 100, "Observation is computer-wide, not restricted to reviewer descendants")
  if case .found(let process) = Native().probe(outside.processIdentifier) {
    check(Native().workingDirectory(process)?.hasSuffix("/tmp") == true)
  } else { failTest("Cross-project control disappeared") }
}
