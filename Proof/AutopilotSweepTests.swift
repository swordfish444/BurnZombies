import BurnCore
import Foundation

private final class Calls: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ value: String) { lock.withLock { values.append(value) } }
  var all: [String] { lock.withLock { values } }
}

func autopilotSweepProof() async throws {
  // Scheduling and backoff.
  var state = AutopilotSweepState()
  let now = Date()
  check(AutopilotSweeper.nativeDue(state, now: now), "first tick is due")
  state.lastTick = now.addingTimeInterval(-10 * 60)
  checkFalse(AutopilotSweeper.nativeDue(state, now: now), "10 of 15 minutes")
  state.lastTick = now.addingTimeInterval(-15 * 60)
  check(AutopilotSweeper.nativeDue(state, now: now), "15 minutes")
  state.enabled = false
  check(AutopilotSweeper.nativeDue(state, now: now), "off still catalogs")
  checkFalse(
    AutopilotSweeper.aiDue(state, snapshot: AutopilotSnapshot(), now: now, manual: false),
    "off never starts the AI")
  // The AI wakes for unjudged unsure items, at most every 30 minutes, plus a 4-hour refresh.
  var fresh = AutopilotSweepState()
  var unsureSnapshot = AutopilotSnapshot()
  let unsureItem = AutopilotItem(id: "process:u", kind: .process, name: "u", facts: ["family": "node"])
  unsureSnapshot.entries = [
    AutopilotEntry(
      item: unsureItem, status: .unsure, authority: nil, label: "u", why: "", consequence: "")
  ]
  unsureSnapshot.counts = ["unsure": 1]
  check(AutopilotSweeper.aiDue(fresh, snapshot: unsureSnapshot, now: now, manual: false), "first")
  fresh.lastAISweep = now.addingTimeInterval(-10 * 60)
  checkFalse(
    AutopilotSweeper.aiDue(fresh, snapshot: unsureSnapshot, now: now, manual: false), "spacing")
  fresh.lastAISweep = now.addingTimeInterval(-31 * 60)
  check(AutopilotSweeper.aiDue(fresh, snapshot: unsureSnapshot, now: now, manual: false), "new work")
  fresh.lastAIDigest = AutopilotSweeper.digest(unsureSnapshot)
  checkFalse(
    AutopilotSweeper.aiDue(fresh, snapshot: unsureSnapshot, now: now, manual: false), "same work")
  unsureSnapshot.entries[0].judged = true
  fresh.lastAIDigest = nil
  checkFalse(
    AutopilotSweeper.aiDue(fresh, snapshot: unsureSnapshot, now: now, manual: false),
    "already judged")
  fresh.lastAISweep = now.addingTimeInterval(-4 * 3600 - 1)
  check(AutopilotSweeper.aiDue(fresh, snapshot: unsureSnapshot, now: now, manual: false), "refresh")
  check(
    AutopilotSweeper.aiDue(
      AutopilotSweepState(), snapshot: AutopilotSnapshot(), now: now, manual: true), "manual hunt")
  equal(AutopilotSweeper.backoff(failures: 1), 15 * 60)
  equal(AutopilotSweeper.backoff(failures: 2), 30 * 60)
  equal(AutopilotSweeper.backoff(failures: 3), 60 * 60)
  equal(AutopilotSweeper.backoff(failures: 9), 120 * 60)
  equal(AutopilotSweeper.backoff(failures: 1, accountProblem: true), 60 * 60)
  check(AutopilotSweeper.accountProblem("Please run /login"), "login")

  // Harness arguments.
  var config = MachineReviewConfiguration(
    harness: "claude", executable: "/bin/claude", launcher: "/bin/bz", server: "/bin/bz-mcp")
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-sweep-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let claude = try AutopilotHarness.arguments(config, directory: directory, root: directory)
  check(claude.contains("--mcp-config"), "MCP config")
  check(claude.joined(separator: " ").contains("BURNZOMBIES_AUTOPILOT"), "autopilot mode")
  check(claude.contains("sonnet"), "default model")
  check(claude.contains("Read,Glob,Grep"), "read-only built-ins")
  check(claude.contains("Bash"), "Bash explicitly disallowed")
  equal(claude.firstIndex(of: "--max-turns").map { claude[$0 + 1] }, "40")
  config.harness = "codex"
  let codex = try AutopilotHarness.arguments(config, directory: directory, root: directory)
  check(codex.contains("mcp_servers.burnzombies.env.BURNZOMBIES_AUTOPILOT=\"1\""), "codex mode")
  check(codex.contains("features.shell_tool=false"), "codex has no shell")
  config.harness = "gemini"
  throwsError(try AutopilotHarness.arguments(config, directory: directory, root: directory))

  // Engine: starter rules burn without AI, unsure items become questions, answers teach.
  let root = directory.appendingPathComponent("state")
  let calls = Calls()
  let safe = AutopilotItem(
    id: "process:safe", kind: .process, name: "vitest", bytes: 200 << 20,
    facts: [
      "family": "node", "orphaned": "yes", "thread": "ended", "idle": "1d", "listening": "no",
      "agent": "claude",
    ], processKey: "safe")
  let server = AutopilotItem(
    id: "process:server", kind: .process, name: "vite", bytes: 300 << 20,
    facts: [
      "family": "node", "orphaned": "yes", "thread": "none", "idle": "1d", "listening": "yes",
      "agent": "none",
    ], processKey: "server")
  let copy = AutopilotItem(
    id: "worktree:c", kind: .worktree, name: "atlas-fix", bytes: 2 << 30,
    facts: [
      "place": "patrol6", "saved": "pushed", "changes": "none", "stale": "older", "inUse": "no",
      "thread": "none",
    ])
  let gone = Calls()
  let sources = AutopilotSources(
    processes: { _ in [safe, server].filter { !gone.all.contains($0.id) } },
    worktrees: { _, _, d in ([copy].filter { !gone.all.contains($0.id) }, d) },
    burnProcess: { item, authority, _ in
      calls.add(item.id + "@" + authority)
      gone.add(item.id)
      return UUID()
    },
    processOutcome: { _ in ("verified", "") },
    retireWorktree: { item, authority in
      calls.add(item.id + "@" + authority)
      gone.add(item.id)
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: authority,
        outcome: "burned", detail: "", bytes: item.bytes)
    })
  let engine = try Autopilot(root: root, sources: sources)
  var snapshot = await engine.tick(now: now)
  equal(calls.all, ["process:safe@starter:starter-leftover-programs"], "starter burn, no AI")
  equal(snapshot.count(.unsure), 2, "server and pushed copy are unsure")
  check(snapshot.questions.count >= 1, "native question proposed")
  check(
    snapshot.questions.allSatisfy { $0.question.hasSuffix("?") && $0.count > 0 },
    "questions are answerable")

  // Off: catalog only, no burns, even for starter matches.
  let offRoot = directory.appendingPathComponent("off")
  let offCalls = Calls()
  let off = try Autopilot(
    root: offRoot,
    sources: AutopilotSources(
      processes: { _ in [safe] },
      burnProcess: { item, _, _ in
        offCalls.add(item.id)
        return UUID()
      }))
  _ = try await off.apply(.setEnabled(false))
  let offSnapshot = await off.tick(now: now)
  equal(offCalls.all.count, 0, "disabled autopilot never burns")
  equal(offSnapshot.count(.burn), 1, "but shows what it would burn")

  // The AI path: refused without a judgment, authorized with a confident one.
  let refused = await engine.burn([copy.id])
  equal(refused.first?.outcome, "refused")
  check(refused.first?.detail.contains("autopilot_ask") == true, "refusal teaches next step")
  let authorized = try await engine.decide([
    AutopilotJudgment(
      itemID: copy.id, revision: "", verdict: .burn, confidence: 0.92, label: "Old atlas copy",
      why: "Its work is on GitHub and nobody touched it in months.")
  ])
  equal(authorized, [copy.id], "confident AI verdict authorizes an eligible copy")
  let burned = await engine.burn([copy.id])
  equal(burned.first?.outcome, "burned")
  check(calls.all.contains("worktree:c@ai:0.92"), "AI authority recorded")
  let serverRefusal = await engine.burn([server.id])
  equal(serverRefusal.first?.outcome, "refused", "listening servers need the owner")

  // Answering yes teaches a rule that burns immediately.
  snapshot = await engine.tick(now: now.addingTimeInterval(60))
  guard let question = snapshot.questions.first(where: { $0.kind == .process }) else {
    failTest("server question")
    return
  }
  snapshot = try await engine.apply(.answer(questionID: question.id, answer: .yes))
  for _ in 0..<50 where !calls.all.contains(where: { $0.hasPrefix("process:server@rule:") }) {
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  check(calls.all.contains { $0.hasPrefix("process:server@rule:") }, "answer burned the server")
  equal(snapshot.answers, 1)
  check(snapshot.rules.contains { $0.source == .operator && $0.verdict == .burn }, "rule saved")
  check(snapshot.trainingProgress > 0, "training progresses")
  snapshot = await engine.tick(now: now.addingTimeInterval(120))
  check(snapshot.count(.burned) >= 2, "receipts finish as burned")

  // Coordinator: failures back off instead of pausing; unchanged work skips the AI.
  final class Runs: @unchecked Sendable { var count = 0 }
  let runs = Runs()
  let failing = AutopilotCoordinator(
    root: root, engine: engine, configuration: { config },
    runner: { _, _ in
      runs.count += 1
      throw StoreError.message("The AI sweep ran out of time.")
    })
  config.harness = "claude"
  _ = await failing.tick(now: Date(), manual: true)
  await failing.waitForAI()
  var sweep = await engine.sweepState()
  equal(runs.count, 1)
  equal(sweep.failures, 1)
  check((sweep.retryAfter ?? .distantPast) > Date().addingTimeInterval(14 * 60), "backoff")
  checkFalse(sweep.running, "not stuck running")
  check(sweep.enabled, "a failure never turns autopilot off")
  _ = await failing.tick(now: Date())
  await failing.waitForAI()
  equal(runs.count, 1, "no AI retry before the backoff ends")

  let succeeding = AutopilotCoordinator(
    root: root, engine: engine, configuration: { config }, runner: { _, _ in "{}" })
  _ = await succeeding.tick(now: Date(), manual: true)
  await succeeding.waitForAI()
  sweep = await engine.sweepState()
  equal(sweep.failures, 0, "success resets failures")
  isNil(sweep.retryAfter)
  check(sweep.lastAIDigest != nil, "digest remembered")

  // Commands.
  snapshot = try await engine.apply(.setInterval(minutes: 30))
  equal(snapshot.sweep.intervalMinutes, 30)
  do {
    _ = try await engine.apply(.setInterval(minutes: 7))
    failTest("odd intervals refused")
  } catch {}
  snapshot = try await engine.apply(.setStarter(ruleID: "starter-leftover-programs", enabled: false))
  equal(snapshot.rules.first { $0.id == "starter-leftover-programs" }?.enabled, false)
  let rule = snapshot.rules.first { $0.source == .operator }!
  snapshot = try await engine.apply(.forgetRule(ruleID: rule.id))
  checkFalse(snapshot.rules.contains { $0.id == rule.id }, "forgotten")
  snapshot = try await engine.apply(.resetTraining)
  equal(snapshot.answers, 0)

  // The bridge request shape the MCP server and CLI use.
  var request = AutopilotRequest(tool: "catalog")
  request.status = "all"
  let (ok, json) = await engine.handle(request)
  check(ok && json.contains("\"items\""), "catalog over the bridge")
  var ask = AutopilotRequest(tool: "ask")
  ask.question = AutopilotQuestionInput(
    kind: .worktree, match: ["saved": ["nothing-matches"]], question: "Can I burn nothing?")
  let (askOK, askJSON) = await engine.handle(ask)
  checkFalse(askOK, "a question must match unsure items")
  check(askJSON.contains("No unsure items"), askJSON)
}
