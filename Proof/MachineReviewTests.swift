import BurnCore
import Darwin
import Foundation

func machineReviewProof() async throws {
  let now = Date()
  var signal = HarnessHook.Signal(observedAt: now, processCount: 10, residentBytes: 100, pressure: "Low")
  var state = MachineReviewState()
  checkFalse(state.due(signal, requested: false, now: now), "Empty scans never invoke a model")
  state.lastStarted = now; state.signal = signal
  checkFalse(state.due(signal, requested: false, now: now.addingTimeInterval(30)))
  signal.observedAt = now.addingTimeInterval(601)
  checkFalse(state.due(signal, requested: false, now: signal.observedAt), "Unchanged scans do not repeatedly invoke models")
  signal.processCount += 20
  checkFalse(state.due(signal, requested: false, now: signal.observedAt), "Process churn alone is not review evidence")
  signal.reviewEvidence = [.init(id: "work", revision: "released")]
  state.pendingSince = now
  checkFalse(state.due(signal, requested: true, now: signal.observedAt), "Release cannot bypass the hourly batch interval")
  signal.observedAt = now.addingTimeInterval(3600)
  check(state.due(signal, requested: false, now: signal.observedAt))
  state.reviewedEvidence = ["work": "released"]
  checkFalse(state.due(signal, requested: true, now: signal.observedAt), "Unchanged evidence is not rereviewed, even on manual request")
  state.reviewedEvidence = [:]
  state.phase = "paused"
  checkFalse(state.due(signal, requested: true, now: signal.observedAt), "Requests do not bypass a quota/error pause")
  state.phase = "observing"
  checkFalse(state.due(signal, requested: true, now: signal.observedAt.addingTimeInterval(181)), "Stale scans cannot dispatch reviews")
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-machine-proof-" + UUID().uuidString)
  let store = try Store(root: root)
  defer { try? FileManager.default.removeItem(at: root) }
  let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("burnzombies").path
  let server = URL(fileURLWithPath: cli).deletingLastPathComponent().appendingPathComponent("burnzombies-mcp").path
  var config = MachineReviewConfiguration(harness: "claude", executable: "/usr/bin/true", launcher: cli, server: server)
  try config.save(root: root)
  try HarnessHook.publish(.init(observedAt: now, processCount: 10, residentBytes: 100, pressure: "Low",
    reviewEvidence: [.init(id: "first", revision: "one")]), store: store)
  try HarnessHook.requestCleanup(root: root)
  let hook = try HarnessHook.response(client: "codex", event: "PostToolUse", input: ["tool_name": "Bash"], root: root)
  check(hook.isEmpty, "Legacy hooks stay inert when machine reviewer owns scheduling")
  check(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-request").path))
  let reviewer = try MachineReviewer(root: root, accessCheck: fixtureAccess)
  await reviewer.tick(now: now)
  let queued = await reviewer.snapshot()
  check(queued.lastStarted == nil, "New releases are batched for two minutes")
  async let first: Void = reviewer.tick(now: now.addingTimeInterval(120))
  async let concurrent: Void = reviewer.tick(now: now.addingTimeInterval(120))
  _ = await (first, concurrent)
  let completed = await reviewer.snapshot()
  equal(completed.phase, "observing"); check(completed.lastFinished != nil)
  let start = completed.lastStarted
  await reviewer.tick(now: now.addingTimeInterval(120))
  equal(await reviewer.snapshot().lastStarted, start, "Identical observations do not trigger a second invocation")
  config.executable = "/usr/bin/false"; try config.save(root: root)
  try HarnessHook.publish(.init(observedAt: now.addingTimeInterval(3700), processCount: 10, residentBytes: 100, pressure: "Low",
    reviewEvidence: [.init(id: "second", revision: "one")]), store: store)
  await reviewer.tick(now: now.addingTimeInterval(3700))
  await reviewer.tick(now: now.addingTimeInterval(3820))
  equal(await reviewer.snapshot().phase, "paused", "Harness failure pauses instead of retrying or switching providers")
  let failed = await reviewer.snapshot().lastStarted
  await reviewer.tick(now: now.addingTimeInterval(7400))
  equal(await reviewer.snapshot().lastStarted, failed)
  let toolFailure = root.appendingPathComponent("failed-tool")
  try Data("#!/bin/sh\nprintf '%s\\n' '{\"type\":\"bz.tool\",\"name\":\"burnzombies_status\",\"status\":\"failed\"}'\n".utf8).write(to: toolFailure)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolFailure.path)
  var failingToolConfig = config; failingToolConfig.executable = toolFailure.path
  throwsError(try MachineReviewer.execute(failingToolConfig, root: root, prompt: "fixture", accessCheck: fixtureAccess))
  let deferredAttempt = UUID()
  try ReviewProgress(attempt: deferredAttempt, selected: ["space:fixture"]).save(store)
  try ReviewProgress.record(store: store, attempt: deferredAttempt, operation: "disk_recommend", id: "space:fixture", succeeded: false)
  try Data("#!/bin/sh\nprintf '%s\\n' '{\"type\":\"bz.tool\",\"name\":\"burnzombies_disk_recommend\",\"status\":\"failed\"}'\n".utf8).write(to: toolFailure)
  try MachineReviewer.execute(failingToolConfig, root: root, prompt: "fixture", lane: .discovery, attempt: deferredAttempt, accessCheck: fixtureAccess)
  let rejectedProgress = try ReviewProgress.load(store)
  check(rejectedProgress.completed.isEmpty, "A rejected recommendation never acknowledges work")
  throwsError(try MachineReviewer.execute(failingToolConfig, root: root, prompt: "fixture", lane: .discovery, attempt: UUID(), accessCheck: fixtureAccess))
  let refusalLine = "{\"type\":\"bz.tool\",\"name\":\"burnzombies_disk_recommend\",\"status\":\"failed\"}"
  try Data("#!/bin/sh\nprintf '%s\\n' '\(refusalLine)' '\(refusalLine)'\n".utf8).write(to: toolFailure)
  throwsError(try MachineReviewer.execute(failingToolConfig, root: root, prompt: "fixture", lane: .discovery, attempt: deferredAttempt, accessCheck: fixtureAccess))
  try Data("#!/bin/sh\nprintf '%s\\n' '{\"type\":\"error\",\"error\":\"quota fixture\"}'\n".utf8).write(to: toolFailure)
  throwsError(try MachineReviewer.execute(failingToolConfig, root: root, prompt: "fixture", lane: .discovery, attempt: deferredAttempt, accessCheck: fixtureAccess))
  let slowRoot = URL(fileURLWithPath: "/private/tmp/bz-slow-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: slowRoot) }
  let slow = try AgentListener(root: slowRoot) { _ in
    try? await Task.sleep(nanoseconds: 6_000_000_000)
    return AgentReply(message: "Bounded inspection completed.")
  }
  let slowResult = try await AgentConnection.callAsync(AgentRequest("disk_inspect"), root: slowRoot)
  check(slowResult.contains("Bounded inspection completed"), "An inspection longer than the ordinary five-second frame deadline completes")
  await slow.stop()
  for harness in MachineReviewConfiguration.harnesses {
    config.harness = harness
    let args = try MachineReviewer.arguments(config, directory: root, root: root, prompt: "Review this computer")
    checkFalse(args.contains("--yolo")); checkFalse(args.contains("--force"))
    checkFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
    checkFalse(args.contains("--resume")); checkFalse(args.contains("--continue"))
    if harness == "codex" {
      check(args.contains("features.apps=false")); check(args.contains("features.plugins=false"))
      check(args.contains("features.skip_host_skill_discovery=true"))
      check(args.contains("memories.use_memories=false")); check(args.contains("features.shell_tool=false"))
    }
  }
  let ledger = try ReviewLedger.load(store: store)
  equal(ledger.entries.count, 2, "Every attempt has a durable receipt, including failure")
  var exhausted = ReviewLedger()
  for _ in 0..<8 { _ = exhausted.reserve(harness: "codex", evidenceCount: 1, now: now) }
  let usage = ReviewUsage.parse(Data("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":80,\"output_tokens\":5}}\n".utf8))
  equal(usage?.inputTokens, 100); equal(usage?.cachedInputTokens, 80)
  equal(usage?.outputTokens, 5)
  check(ReviewUsage.parse(Data("{}".utf8)) == nil, "Missing usage is unknown, not zero")
  exhausted.entries[0].usage = .init(inputTokens: 200_000, cachedInputTokens: 190_000, outputTokens: 1)
  try exhausted.save(store: store)
  // A real coordinator invocation must proceed above the former cap, not just a helper assertion.
  config.harness = "claude"; config.executable = "/usr/bin/true"; try config.save(root: root)
  var fresh = MachineReviewState(); fresh.pendingSince = now.addingTimeInterval(-120)
  try store.write(JSONEncoder().encode(fresh), to: root.appendingPathComponent("machine-review-state.json"), limit: 65536)
  try HarnessHook.publish(.init(observedAt: now, processCount: 1, residentBytes: 1, pressure: "Low",
    reviewEvidence: [.init(id: "above-old-cap", revision: "new")]), store: store)
  let uncapped = try MachineReviewer(root: root, accessCheck: fixtureAccess)
  await uncapped.tick(now: now)
  let uncappedState = await uncapped.snapshot()
  equal(uncappedState.phase, "observing")
  check(uncappedState.lastStarted != nil, "Useful evidence launches above 200k recorded input")
  equal(try ReviewLedger.load(store: store).entries.count, 9, "Useful evidence continues after eight reviews")

  let branches = (0..<3).map { ReviewEvidence(id: "space:\($0)", revision: "v1", processCount: 0, recommendationOnly: true) }
  var queue = MachineReviewState()
  queue.reviewedEvidence = ["space:0": "v1", "work": "released"]
  queue.migrateProgress()
  check(queue.reviewedEvidence?["space:0"] == nil, "Repair old offered-but-uninspected discovery acknowledgments")
  equal(queue.reviewedEvidence?["work"], "released", "Migration must not retry uncertain cleanup mutations")
  var diskSignal = HarnessHook.Signal(observedAt: now, processCount: 1, residentBytes: 1, pressure: "Low", reviewEvidence: branches)
  let selected = queue.pending(diskSignal, now: now)
  equal(selected.map(\.id), ["space:0", "space:1"], "Offer no more branches than can be inspected")
  queue.begin(selected, now: now)
  let attempt = UUID()
  try ReviewProgress(attempt: attempt, selected: selected.map(\.id)).save(store)
  try ReviewProgress.record(store: store, attempt: attempt, operation: "disk_inspect", id: "space:0")
  queue.complete(selected, progress: try ReviewProgress.load(store))
  check(queue.reviewedEvidence?["space:0"] == nil, "Inspection alone is not a saved decision")
  try ReviewProgress.record(store: store, attempt: UUID(), operation: "disk_recommend", id: "space:0")
  try ReviewProgress.record(store: store, attempt: attempt, operation: "disk_recommend", id: "space:2")
  let refusedProgress = try ReviewProgress.load(store)
  check(refusedProgress.completed.isEmpty, "Wrong attempt and out-of-scope IDs cannot acknowledge work")
  try ReviewProgress.record(store: store, attempt: attempt, operation: "disk_recommend", id: "space:0")
  queue.complete(selected, progress: try ReviewProgress.load(store))
  equal(queue.reviewedEvidence?["space:0"], "v1")
  check(queue.reviewedEvidence?["space:1"] == nil)
  equal(queue.pending(diskSignal, now: now.addingTimeInterval(3600)).map(\.id), ["space:2", "space:1"], "Untouched work precedes deferred work; neither is lost")
  queue.begin([branches[1]], now: now.addingTimeInterval(3600))
  equal(queue.pending(diskSignal, now: now.addingTimeInterval(7200)).map(\.id), ["space:2"], "Repeated no-progress evidence backs off without blocking fresh evidence")
  diskSignal.reviewEvidence = [.init(id: "space:1", revision: "v2", processCount: 0, recommendationOnly: true)]
  equal(queue.pending(diskSignal, now: now.addingTimeInterval(7200)).count, 1, "New evidence supersedes backoff")
  let roundTrip = try JSONDecoder().decode(MachineReviewState.self, from: JSONEncoder().encode(queue))
  equal(roundTrip.pending(diskSignal, now: now.addingTimeInterval(7200)).count, 1)
  check(ReviewLane.discovery.instructions.utf8.count < MachineReviewer.prompt.utf8.count / 2, "Discovery instructions exclude unrelated playbooks")
  checkFalse(ReviewLane.discovery.tools.contains("burnzombies_burn"))
  equal(ReviewLane.discovery.tools.count, 5)
  equal(ReviewLane.process.tools.count, 4)
  var simulation = MachineReviewState()
  let backlog = (0..<40).map { ReviewEvidence(id: "space:backlog-\($0)", revision: "v1", processCount: 0, recommendationOnly: true) }
  var completedIDs = Set<String>(), starts = 0
  for hour in 0..<24 {
    let at = now.addingTimeInterval(Double(hour * 3600))
    let current = HarnessHook.Signal(observedAt: at, processCount: 1, residentBytes: 1, pressure: "Low", reviewEvidence: backlog)
    simulation.pendingSince = at.addingTimeInterval(-120)
    guard simulation.due(current, requested: false, now: at) else { continue }
    let batch = simulation.pending(current, now: at)
    check(Set(batch.map(\.id)).isDisjoint(with: completedIDs), "Completed evidence must never be reviewed twice")
    simulation.lastStarted = at; simulation.begin(batch, now: at)
    let token = UUID()
    try ReviewProgress(attempt: token, selected: batch.map(\.id)).save(store)
    for item in batch {
      try ReviewProgress.record(store: store, attempt: token, operation: "disk_recommend", id: item.id)
      completedIDs.insert(item.id)
    }
    simulation.complete(batch, progress: try ReviewProgress.load(store))
    starts += 1
  }
  equal(completedIDs.count, 40, "A day-long backlog keeps progressing beyond the former eight-review limit")
  equal(starts, 20, "No empty reviews after finishing a forty-branch backlog")
  var facts = Catalog()
  let record = SafetyTests().record()
  facts.records[record.id] = record
  let member = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Member(record.latest)))
  var claim = try JSONDecoder().decode(WorkEvidence.self, from: JSONSerialization.data(withJSONObject: [
    "id": "owned", "tokenHash": "private", "members": [member], "anchors": [], "label": "fixture",
    "purpose": "fixture", "completionCondition": "fixture completed", "created": now.timeIntervalSinceReferenceDate,
    "updated": now.timeIntervalSinceReferenceDate, "state": "active", "evidence": "fixture completion"
  ]))
  facts.workEvidence = [claim]
  check(ReviewEvidence.pending(in: facts).isEmpty, "Active work must not wake the reviewer")
  claim.state = "released"; facts.workEvidence = [claim]
  let initialEvidence = ReviewEvidence.pending(in: facts)
  equal(initialEvidence.count, 1)
  facts.records[record.id]?.latest.rss += 1024
  facts.records[record.id]?.latest.cpuNS += 1_000_000
  equal(ReviewEvidence.pending(in: facts), initialEvidence, "Resource churn must not spend more tokens")
  let child = Observation(identity: .init(pid: 9999, seconds: 2), parent: record.latest.identity.pid)
  facts.records[child.identity.key] = Record(child)
  notEqual(ReviewEvidence.pending(in: facts), initialEvidence)
  facts.records.removeValue(forKey: child.identity.key)
  var shared = claim; shared.id = "other-owner"; shared.state = "active"
  facts.workEvidence = [claim, shared]
  check(ReviewEvidence.pending(in: facts).isEmpty, "Another active consumer prevents model dispatch")
  facts.workEvidence = [claim]; facts.records[record.id]?.missingSince = now
  check(ReviewEvidence.pending(in: facts).isEmpty, "Already exited helpers cost no model calls")
  var replay = MachineReviewState(); var reviewCount = 0
  for minute in 0..<1440 {
    let at = now.addingTimeInterval(Double(minute * 60))
    let noisy = HarnessHook.Signal(observedAt: at, processCount: 500 + minute, residentBytes: UInt64(minute) * 1024 * 1024 * 1024, pressure: "High", reviewEvidence: [])
    if replay.due(noisy, requested: true, now: at) { reviewCount += 1 }
  }
  equal(reviewCount, 0, "24-hour idle/churn simulation launches zero reviews")
  replay.reviewedEvidence = ["owned": initialEvidence[0].revision]
  let restoredState = try JSONDecoder().decode(MachineReviewState.self, from: JSONEncoder().encode(replay))
  signal.reviewEvidence = initialEvidence
  check(restoredState.pending(signal).isEmpty, "Restart preserves reviewed evidence")
  let scan = Native().scan()
  let outside = Process(); outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
  outside.arguments = ["30"]; outside.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
  try outside.run(); defer { if outside.isRunning { outside.terminate() }; outside.waitUntilExit() }
  let monitor = try Monitor(root: root.appendingPathComponent("observation"), accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  let observed = await monitor.refresh()
  check(observed.catalog.records.values.contains { $0.latest.identity.pid == outside.processIdentifier })
  check(observed.processCount >= scan.observations.count - 100, "Observation is computer-wide, not restricted to reviewer descendants")
  if case .found(let process) = Native().probe(outside.processIdentifier) {
    check(Native().workingDirectory(process)?.hasSuffix("/tmp") == true)
  } else { failTest("Cross-project control disappeared") }
}
