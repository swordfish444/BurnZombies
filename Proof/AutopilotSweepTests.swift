import BurnCore
import Foundation

/// What fake sources were asked to do, in order. Shared by the Autopilot engine proofs.
final class Calls: @unchecked Sendable {
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
  let unsureItem = AutopilotItem(
    id: "process:u", kind: .process, name: "u", facts: ["family": "node"])
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
  check(
    AutopilotSweeper.aiDue(fresh, snapshot: unsureSnapshot, now: now, manual: false), "new work")
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
  // A new install looks every minute for its first half hour, so what its first inventory finds
  // is burned or asked about as soon as it arrives; on a real Mac nothing showed for 15 minutes.
  var newcomer = AutopilotSweepState()
  newcomer.firstTick = now.addingTimeInterval(-5 * 60)
  newcomer.lastTick = now.addingTimeInterval(-60)
  check(AutopilotSweeper.nativeDue(newcomer, now: now), "a new install looks every minute")
  newcomer.lastTick = now.addingTimeInterval(-30)
  checkFalse(AutopilotSweeper.nativeDue(newcomer, now: now), "but not twice a minute")
  newcomer.firstTick = now.addingTimeInterval(-31 * 60)
  newcomer.lastTick = now.addingTimeInterval(-60)
  checkFalse(AutopilotSweeper.nativeDue(newcomer, now: now), "after half an hour, every 15 minutes")
  // Its first AI sweep waits for that first look instead of judging a half-empty catalog.
  newcomer.firstTick = now.addingTimeInterval(-5 * 60)
  checkFalse(
    AutopilotSweeper.aiDue(newcomer, snapshot: unsureSnapshot, now: now, manual: false),
    "the first AI sweep waits for a complete first look")
  check(
    AutopilotSweeper.aiDue(newcomer, snapshot: unsureSnapshot, now: now, manual: true),
    "a hunt the owner asks for never waits")
  newcomer.firstTick = now.addingTimeInterval(-10 * 60)
  check(
    AutopilotSweeper.aiDue(newcomer, snapshot: unsureSnapshot, now: now, manual: false),
    "ten minutes in, the first AI sweep starts")
  // Only the very first tick starts the warm-up; an install that ticked before never gets one.
  let warmRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-warmup-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: warmRoot) }
  let warmEngine = try Autopilot(root: warmRoot, sources: AutopilotSources())
  _ = await warmEngine.tick(now: now)
  _ = await warmEngine.tick(now: now.addingTimeInterval(60))
  equal(await warmEngine.sweepState().firstTick, now, "the first tick starts the warm-up")
  let olderRoot = warmRoot.appendingPathComponent("older")
  try AutopilotStore(root: olderRoot).updateSweep { $0.lastTick = now.addingTimeInterval(-3600) }
  let olderEngine = try Autopilot(root: olderRoot, sources: AutopilotSources())
  _ = await olderEngine.tick(now: now)
  // An install that ticked before gets no warm-up.
  isNil(await olderEngine.sweepState().firstTick)
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
  checkFalse(claude.contains("Read,Glob,Grep"), "file reads go through scoped native evidence")
  check(claude.contains("Bash"), "Bash explicitly disallowed")
  equal(claude.firstIndex(of: "--max-turns").map { claude[$0 + 1] }, "40")
  // Claude Code still loads the owner's own settings, whose `env` outranks `--effort`: an
  // interactive CLAUDE_CODE_EFFORT_LEVEL=max spent six minutes on one sweep decision, and a short
  // MCP_TOOL_TIMEOUT cut burns off mid-call. Settings passed with `--settings` outrank the owner's.
  func pinned(_ args: [String]) -> [String: String] {
    guard let i = args.firstIndex(of: "--settings"),
      let settings = try? JSONSerialization.jsonObject(with: Data(args[i + 1].utf8))
        as? [String: Any]
    else { return [:] }
    check(settings["disableAllHooks"] as? Bool == true, "hooks stay off")
    return settings["env"] as? [String: String] ?? [:]
  }
  equal(pinned(claude)["CLAUDE_CODE_EFFORT_LEVEL"], "medium", "sweep effort by default")
  equal(pinned(claude)["MCP_TOOL_TIMEOUT"], "900000", "a burn may take the whole sweep")
  config.reasoningEffort = "high"
  let chosen = try AutopilotHarness.arguments(config, directory: directory, root: directory)
  equal(pinned(chosen)["CLAUDE_CODE_EFFORT_LEVEL"], "high", "the owner's choice in BZ wins")
  equal(chosen.firstIndex(of: "--effort").map { chosen[$0 + 1] }, "high")
  config.reasoningEffort = nil
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
    id: "process:server", kind: .process, name: "vite", bytes: 3 << 30,
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

  // A real Mac's backlog outlasts every sweep: one that judged things before its time ran out
  // did its job, and must not back off as if the AI had failed.
  let busy = AutopilotCoordinator(
    root: root, engine: engine, configuration: { config },
    runner: { _, root in
      try AutopilotStore(root: root).updateMemory {
        $0.judgments[copy.id] = AutopilotJudgment(
          itemID: copy.id, revision: copy.revision, verdict: .keep, confidence: 0.9,
          label: "Atlas fix", why: "Someone may still need it.")
      }
      throw StoreError.message("The AI sweep ran out of time.")
    })
  let busyStart = Date()
  _ = await busy.tick(now: busyStart, manual: true)
  await busy.waitForAI()
  sweep = await engine.sweepState()
  equal(sweep.failures, 0, "a sweep that judged things before running out of time did its job")
  isNil(sweep.retryAfter)
  check((sweep.lastAISweep ?? .distantPast) >= busyStart, "the sweep counts as done")

  // Ticks that pile up behind a slow catalog resume together; only one may start a sweep. On
  // a real Mac four started at once.
  let pileRoot = directory.appendingPathComponent("pile")
  let pileEngine = try Autopilot(
    root: pileRoot, sources: AutopilotSources(processes: { _ in [server] }))
  let pileSweeps = Calls()
  let pile = AutopilotCoordinator(
    root: pileRoot, engine: pileEngine, configuration: { config },
    runner: { _, _ in
      pileSweeps.add("sweep")
      Thread.sleep(forTimeInterval: 0.3)
      return "{}"
    })
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<4 { group.addTask { _ = await pile.tick(now: Date(), manual: true) } }
  }
  await pile.waitForAI()
  equal(pileSweeps.all.count, 1, "overlapping ticks start one sweep")

  // The app quit in the middle of a sweep: a fresh app must not wait for it forever.
  await engine.updateSweep { $0.running = true }
  let relaunched = Calls()
  let afterRestart = AutopilotCoordinator(
    root: root, engine: engine, configuration: { config },
    runner: { _, _ in
      relaunched.add("sweep")
      return "{}"
    })
  _ = await afterRestart.tick(now: Date(), manual: true)
  await afterRestart.waitForAI()
  equal(relaunched.all, ["sweep"], "an interrupted sweep doesn't block the next one")
  let restarted = await engine.sweepState()
  checkFalse(restarted.running, "not stuck running after a restart")

  // While BZ asks about something, the AI may reword that question but not add a second one
  // about the same things.
  let askEngine = try Autopilot(
    root: directory.appendingPathComponent("ask"),
    sources: AutopilotSources(processes: { _ in [server] }))
  let before = await askEngine.tick(now: Date())
  guard let native = before.questions.first(where: { $0.source == "native" }) else {
    failTest("a native question exists for the unsure server")
    return
  }
  var aiAsk = AutopilotRequest(tool: "ask")
  aiAsk.question = AutopilotQuestionInput(
    kind: .process, match: ["family": ["node"], "listening": ["yes"], "agent": ["none"]],
    question: "Can I stop the dev servers left behind by chats that finished?")
  let (secondOK, secondJSON) = await askEngine.handle(aiAsk)
  checkFalse(secondOK, "no second question about the same server")
  check(secondJSON.contains("already asking"), secondJSON)
  var reword = AutopilotRequest(tool: "ask")
  var input = AutopilotQuestionInput(
    kind: native.kind, match: native.match,
    question: "Can I stop the dev servers left behind by chats that finished?")
  input.why = "They hold ports nobody uses."
  reword.question = input
  let (rewordOK, rewordJSON) = await askEngine.handle(reword)
  check(rewordOK, rewordJSON)
  let after = await askEngine.snapshot()
  equal(after.questions.count, 1, "still one question")
  equal(after.questions.first?.source, "ai", "AI wording kept")

  // Commands.
  snapshot = try await engine.apply(.setInterval(minutes: 30))
  equal(snapshot.sweep.intervalMinutes, 30)
  do {
    _ = try await engine.apply(.setInterval(minutes: 7))
    failTest("odd intervals refused")
  } catch {}
  snapshot = try await engine.apply(
    .setStarter(ruleID: "starter-leftover-programs", enabled: false))
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
  // A real Mac's full snapshot is bigger than a bridge reply may be.
  var command = AutopilotRequest(tool: "command")
  command.command = .setInterval(minutes: 15)
  let (commandOK, commandJSON) = await engine.handle(command)
  check(commandOK && commandJSON.contains("\"counts\""), commandJSON)
  checkFalse(commandJSON.contains("\"entries\""), "commands reply with the compact summary")
  var ask = AutopilotRequest(tool: "ask")
  ask.question = AutopilotQuestionInput(
    kind: .worktree, match: ["saved": ["nothing-matches"]], question: "Can I burn nothing?")
  let (askOK, askJSON) = await engine.handle(ask)
  checkFalse(askOK, "a question must match unsure items")
  check(askJSON.contains("No unsure items"), askJSON)

  // Small things are not part of the assessment: not shown, asked about, judged or burned.
  func finishedCopy(_ name: String, bytes: UInt64) -> AutopilotItem {
    AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, bytes: bytes,
      facts: [
        "place": "sibling", "saved": "merged", "changes": "none", "stale": "older", "inUse": "no",
        "thread": "none",
      ])
  }
  let tinyCopy = finishedCopy("tiny", bytes: 20_000_000)
  let bigCopy = finishedCopy("big", bytes: 2_000_000_000)
  let valueBurns = Calls()
  let valueEngine = try Autopilot(
    root: directory.appendingPathComponent("value"),
    sources: AutopilotSources(
      worktrees: { _, _, d in ([tinyCopy, bigCopy], d) },
      retireWorktree: { item, authority in
        valueBurns.add(item.id)
        return AutopilotReceipt(
          itemID: item.id, kind: .worktree, name: item.name, authority: authority,
          outcome: "burned", detail: "", bytes: item.bytes)
      }))
  let valued = await valueEngine.tick(now: now)
  checkFalse(valued.entries.contains { $0.item.id == tinyCopy.id }, "a 20 MB copy isn't shown")
  equal(valueBurns.all, [bigCopy.id], "only the big finished copy burns")
  let modest = AutopilotItem(
    id: "process:modest", kind: .process, name: "vite", bytes: 300 << 20,
    facts: [
      "family": "node", "orphaned": "yes", "thread": "none", "idle": "1d", "listening": "yes",
      "agent": "none",
    ], processKey: "modest")
  let modestEngine = try Autopilot(
    root: directory.appendingPathComponent("modest"),
    sources: AutopilotSources(processes: { _ in [modest] }))
  let modestly = await modestEngine.tick(now: now)
  equal(modestly.count(.unsure), 1, "a 300 MB program is assessed")
  equal(modestly.questions.count, 0, "but 300 MB isn't worth a question")
  var smallAsk = AutopilotRequest(tool: "ask")
  smallAsk.question = AutopilotQuestionInput(
    kind: .process, match: ["family": ["node"], "listening": ["yes"]],
    question: "Can I stop the small dev servers?")
  let (smallOK, smallJSON) = await modestEngine.handle(smallAsk)
  checkFalse(smallOK, "a pattern freeing under 1 GB isn't worth a question")
  check(smallJSON.contains("1 GB"), smallJSON)
  // A fact BZ hasn't checked yet can't be part of a question: the answer would stop applying
  // as soon as it is checked.
  var uncheckedAsk = AutopilotRequest(tool: "ask")
  uncheckedAsk.question = AutopilotQuestionInput(
    kind: .process, match: ["family": ["node"], "listening": ["unknown"]],
    question: "Can I stop the dev servers I couldn't check?")
  let (uncheckedOK, uncheckedJSON) = await askEngine.handle(uncheckedAsk)
  checkFalse(uncheckedOK, "a question can't rest on an unchecked fact")
  check(uncheckedJSON.contains("checked"), uncheckedJSON)

  // The AI asks by BZ's own rules: one question per subject at a time, saying how long things
  // sat unused, never about things used today. On a real Mac it opened three questions about
  // old copies, two of them about copies used that day.
  func unsureCopy(_ name: String, saved: String, stale: String, gigabytes: UInt64)
    -> AutopilotItem
  {
    AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, bytes: gigabytes * 1_000_000_000,
      facts: [
        "place": "codex", "saved": saved, "changes": "small", "stale": stale, "inUse": "no",
        "thread": "none",
      ])
  }
  let localWeek = unsureCopy("local-week", saved: "local", stale: "week", gigabytes: 3)
  let mergedDay = unsureCopy("merged-day", saved: "merged", stale: "day", gigabytes: 5)
  let mergedToday = unsureCopy("merged-today", saved: "merged", stale: "today", gigabytes: 4)
  let localWeekMatch = ["saved": ["local"], "stale": ["week"]]
  let mergedDayMatch = ["saved": ["merged"], "stale": ["day"]]
  let mergedTodayMatch = ["saved": ["merged"], "stale": ["today"]]
  // Questions the AI opened before these rules held.
  func copiesEngine(_ name: String, _ copies: [AutopilotItem], open: [[String: [String]]])
    throws -> Autopilot
  {
    let root = directory.appendingPathComponent(name)
    try AutopilotStore(root: root).updateMemory { memory in
      memory.questions += open.map {
        AutopilotQuestion(
          kind: .worktree, match: $0, question: "Can I burn these old copies?", why: "",
          examples: [], count: 0, bytes: 0, source: "ai")
      }
    }
    return try Autopilot(
      root: root, sources: AutopilotSources(worktrees: { _, _, d in (copies, d) }))
  }
  func askAbout(_ engine: Autopilot, _ match: [String: [String]]) async -> (Bool, String) {
    var request = AutopilotRequest(tool: "ask")
    request.question = AutopilotQuestionInput(
      kind: .worktree, match: match, question: "Can I burn these old copies?")
    return await engine.handle(request)
  }

  let subjectEngine = try copiesEngine(
    "ask-subject", [localWeek, mergedDay], open: [localWeekMatch])
  _ = await subjectEngine.tick(now: now)
  let (otherOK, otherJSON) = await askAbout(subjectEngine, mergedDayMatch)
  checkFalse(otherOK, "no second question about old copies while one is open")
  check(otherJSON.contains("old project copies"), otherJSON)
  let stillOne = await subjectEngine.snapshot()
  equal(stillOne.questions.map(\.match), [localWeekMatch], "one question about old copies")

  let todayEngine = try copiesEngine("ask-today", [mergedToday], open: [])
  _ = await todayEngine.tick(now: now)
  let (todayOK, todayJSON) = await askAbout(todayEngine, mergedTodayMatch)
  checkFalse(todayOK, "no question about copies used today")
  check(todayJSON.contains("today"), todayJSON)
  let (agelessOK, agelessJSON) = await askAbout(todayEngine, ["saved": ["merged"]])
  checkFalse(agelessOK, "a question says how long things sat unused")
  check(agelessJSON.contains("unused"), agelessJSON)

  let cleanEngine = try copiesEngine(
    "ask-clean", [localWeek, mergedDay, mergedToday],
    open: [localWeekMatch, mergedDayMatch, mergedTodayMatch])
  let cleaned = await cleanEngine.tick(now: now)
  equal(
    cleaned.questions.map(\.match), [mergedDayMatch],
    "questions opened before the rules: one per subject, the biggest about quiet copies")

  let skipEngine = try copiesEngine("ask-skip", [localWeek, mergedDay], open: [localWeekMatch])
  let skipping = await skipEngine.tick(now: now)
  guard let skippedQuestion = skipping.questions.first else {
    failTest("an open question about old copies to skip")
    return
  }
  _ = try await skipEngine.apply(.answer(questionID: skippedQuestion.id, answer: .skip))
  let (afterSkipOK, afterSkipJSON) = await askAbout(skipEngine, mergedDayMatch)
  checkFalse(afterSkipOK, "no new question about old copies the day the owner skipped one")
  check(afterSkipJSON.contains("old project copies"), afterSkipJSON)

  // An open question whose matches shrink below 1 GB stops being worth asking.
  let shrinking = Calls()
  let shrinkEngine = try Autopilot(
    root: directory.appendingPathComponent("shrink"),
    sources: AutopilotSources(processes: { _ in
      var big = modest
      big.bytes = shrinking.all.isEmpty ? 3 << 30 : 300 << 20
      return [big]
    }))
  let asked = await shrinkEngine.tick(now: now)
  equal(asked.questions.count, 1, "a 3 GB program is worth a question")
  shrinking.add("burned most of it")
  let shrunk = await shrinkEngine.tick(now: now.addingTimeInterval(900))
  equal(shrunk.questions.count, 0, "at 300 MB the question goes away")

  // Rules show the same short words as the question that taught them, even rules taught
  // before the words changed.
  let titleRoot = directory.appendingPathComponent("titles")
  let titleEngine = try Autopilot(
    root: titleRoot, sources: AutopilotSources(processes: { _ in [server] }))
  let titled = await titleEngine.tick(now: now)
  guard let serverQuestion = titled.questions.first else {
    failTest("a question for the 3 GB server")
    return
  }
  _ = try await titleEngine.apply(.answer(questionID: serverQuestion.id, answer: .no))
  try AutopilotStore(root: titleRoot).updateMemory { memory in
    for i in memory.rules.indices { memory.rules[i].title = "Keep: An old, long sentence" }
  }
  let retitled = await titleEngine.snapshot()
  equal(
    retitled.rules.first { $0.source == .operator }?.title,
    AutopilotPolicy.ruleTitle(serverQuestion, answer: .no), "short words for an older rule")
  equal(
    retitled.entries.first { $0.item.id == server.id }?.why,
    "You told me to keep things like this.", "the reason is a plain sentence")

  // Something burned since the catalog was built is gone: it is never tried again from the
  // same catalog, whether by another pass, the AI or the owner, nor after a restart.
  let onceCopy = finishedCopy("once", bytes: 2_000_000_000)
  let onceRetired = Calls()
  let onceSources = AutopilotSources(
    worktrees: { _, _, d in ([onceCopy], d) },
    retireWorktree: { item, authority in
      onceRetired.add(item.id)
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: authority,
        outcome: "burned", detail: "", bytes: item.bytes)
    })
  let onceRoot = directory.appendingPathComponent("once")
  let once = try Autopilot(root: onceRoot, sources: onceSources)
  _ = await once.tick(now: Date())
  equal(onceRetired.all, [onceCopy.id], "burned once by the starter rule")
  let again = await once.burn([onceCopy.id])
  equal(again.first?.outcome, "refused", "the AI can't burn it twice")
  let relaunchedEngine = try Autopilot(root: onceRoot, sources: onceSources)
  do {
    _ = try await relaunchedEngine.apply(.burnNow(itemID: onceCopy.id))
    failTest("burned a copy already burned since the saved catalog")
  } catch {}
  equal(onceRetired.all.count, 1, "never attempted twice")

  // A real Mac's first sweep spent nine minutes reading before it burned anything.
  equal(AutopilotSweeper.aiTimeout, 900, "the AI gets the review worker's full limit")

  // A refusal stands for the facts it saw: twenty refusals don't use up the burn allowance,
  // and unchanged refused copies are not retried every tick.
  func finished(_ n: Int) -> AutopilotItem {
    AutopilotItem(
      id: "worktree:r\(n)", kind: .worktree, name: "copy-\(n)", bytes: 1 << 30,
      facts: [
        "place": "sibling", "saved": "merged", "changes": "none", "stale": "older", "inUse": "no",
        "thread": "none",
      ])
  }
  let stubborn = (0..<Autopilot.maximumBurns[.worktree]!).map(finished)
  let willing = finished(99)
  let attempts = Calls()
  let retired = Calls()
  let refusing = try Autopilot(
    root: directory.appendingPathComponent("refusals"),
    sources: AutopilotSources(
      worktrees: { _, _, d in
        ((stubborn + [willing]).filter { !retired.all.contains($0.id) }, d)
      },
      retireWorktree: { item, authority in
        attempts.add(item.id)
        guard item.id == willing.id else {
          return .refused(item, authority: authority, "This copy changed since I last looked.")
        }
        retired.add(item.id)
        return AutopilotReceipt(
          itemID: item.id, kind: .worktree, name: item.name, authority: authority,
          outcome: "burned", detail: "", bytes: item.bytes)
      }))
  _ = await refusing.tick(now: now)
  equal(retired.all, [willing.id], "refusals don't use up the burn allowance")
  let firstAttempts = attempts.all.count
  _ = await refusing.tick(now: now.addingTimeInterval(900))
  equal(attempts.all.count, firstAttempts, "unchanged refused copies wait")
  try AutopilotStore(root: directory.appendingPathComponent("refusals")).updateMemory {
    $0.rules.append(
      AutopilotRule(
        kind: .worktree, match: ["place": ["sibling"]], verdict: .burn, source: .operator,
        title: "Burn sibling copies"))
  }
  _ = await refusing.tick(now: now.addingTimeInterval(1800))
  equal(attempts.all.count, firstAttempts * 2 - 1, "a new answer is tried right away")
  _ = await refusing.tick(now: now.addingTimeInterval(7 * 3600))
  equal(attempts.all.count, firstAttempts * 3 - 2, "refused copies are retried after a while")

  // Refusals never push out a burn the owner may want to restore.
  let receiptStore = try AutopilotStore(root: directory.appendingPathComponent("receipts"))
  let keeper = AutopilotReceipt(
    itemID: "worktree:keep", kind: .worktree, name: "keep", authority: "operator",
    outcome: "burned", detail: "", bytes: 1)
  try receiptStore.append(keeper)
  for n in 0...AutopilotStore.maximumRefusals {
    try receiptStore.append(.refused(finished(n), authority: "ai:0.90", "refusal \(n)"))
  }
  let kept = try receiptStore.receipts()
  let refusals = kept.filter { $0.outcome == "refused" }
  equal(refusals.count, AutopilotStore.maximumRefusals, "refusals stay bounded")
  equal(refusals.first?.detail, "refusal 1", "the oldest refusal goes first")
  check(kept.contains { $0.id == keeper.id }, "a restorable burn outlives a stream of refusals")

  // A full history of burns never erases a refusal. On a Mac with 500 burns, the same few
  // copies were refused again on every tick.
  let fullRoot = directory.appendingPathComponent("full")
  let fullStore = try AutopilotStore(root: fullRoot)
  for n in 0..<AutopilotStore.maximumReceipts {
    try fullStore.append(
      AutopilotReceipt(
        itemID: "worktree:old\(n)", kind: .worktree, name: "old-\(n)", authority: "operator",
        outcome: "burned", detail: "", bytes: 1))
  }
  let unchecked = finished(7)
  let uncheckedAttempts = Calls()
  let full = try Autopilot(
    root: fullRoot,
    sources: AutopilotSources(
      worktrees: { _, _, d in ([unchecked], d) },
      retireWorktree: { item, authority in
        uncheckedAttempts.add(item.id)
        return .refused(
          item, authority: authority,
          "I hadn't finished checking this copy, so I'll judge it again.")
      }))
  _ = await full.tick(now: now)
  _ = await full.tick(now: now.addingTimeInterval(900))
  equal(uncheckedAttempts.all.count, 1, "a refusal is remembered when receipts are full of burns")
  equal(
    try fullStore.receipts().filter { $0.outcome == "burned" }.count,
    AutopilotStore.maximumReceipts, "every restorable burn is kept")

  // The AI's burns wait after a refusal too. On a real Mac every sweep burned the same four
  // copies the app kept refusing for unchanged facts and answers: each try spent up to minutes
  // in Git and added a line to the owner's activity log.
  @Sendable func stuckCopy(stale: String) -> AutopilotItem {
    AutopilotItem(
      id: "worktree:stuck", kind: .worktree, name: "stuck", bytes: 1 << 30,
      facts: [
        "place": "sibling", "saved": "merged", "changes": "none", "stale": stale, "inUse": "no",
        "thread": "none",
      ])
  }
  let reason = "I could not check it safely, so I left it alone."
  let stuckAttempts = Calls()
  let touched = Calls()
  let waitRoot = directory.appendingPathComponent("ai-refusals")
  let waitStore = try AutopilotStore(root: waitRoot)
  let waiting = try Autopilot(
    root: waitRoot,
    sources: AutopilotSources(
      worktrees: { _, _, d in ([stuckCopy(stale: touched.all.isEmpty ? "older" : "month")], d) },
      retireWorktree: { item, authority in
        stuckAttempts.add(item.id)
        return .refused(item, authority: authority, reason)
      }))
  _ = await waiting.tick(now: now, burn: false)
  let firstTry = await waiting.burn(["worktree:stuck"])
  equal(firstTry.first?.detail, reason, "the first burn runs every check")
  let receiptCount = try waitStore.receipts().count
  let logCount = try waitStore.sweep().log.count
  let retry = await waiting.burn(["worktree:stuck"])
  equal(stuckAttempts.all.count, 1, "an unchanged copy refused for the same answer waits: no Git")
  equal(retry.first?.outcome, "refused")
  check(retry.first?.detail.contains(reason) == true, "the AI hears the recorded reason at once")
  check(
    retry.first?.detail.hasPrefix("Waiting after a refusal") == true,
    "and that the copy is waiting: \(retry.first?.detail ?? "")")
  equal(try waitStore.receipts().count, receiptCount, "a waiting copy adds no receipt")
  equal(try waitStore.sweep().log.count, logCount, "nor a line in the owner's activity log")
  let listed = await waiting.catalogPage(status: "burn", kind: nil, offset: 0, limit: 10)
  check(
    listed.items.first?.why?.hasPrefix("Waiting after a refusal") == true
      && listed.items.first?.why?.contains(reason) == true,
    "the catalog says the copy is waiting, and why: \(listed.items.first?.why ?? "")")
  _ = await waiting.tick(now: now.addingTimeInterval(900))
  equal(stuckAttempts.all.count, 1, "the native pass waits after the AI's refusal")
  // Changed facts or a new answer are tried right away; unchanged ones once the wait is over.
  touched.add("changed")
  _ = await waiting.tick(now: now.addingTimeInterval(1800), burn: false)
  _ = await waiting.burn(["worktree:stuck"])
  equal(stuckAttempts.all.count, 2, "a copy whose facts changed is tried right away")
  try waitStore.updateMemory {
    $0.rules.append(
      AutopilotRule(
        kind: .worktree, match: ["place": ["sibling"]], verdict: .burn, source: .operator,
        title: "Burn sibling copies"))
  }
  _ = await waiting.burn(["worktree:stuck"])
  equal(stuckAttempts.all.count, 3, "so is one a new answer allows")
  try waitStore.updateReceipts { all in
    for i in all.indices { all[i].date.addTimeInterval(-Autopilot.retryRefusalsAfter - 60) }
  }
  _ = await waiting.burn(["worktree:stuck"])
  equal(stuckAttempts.all.count, 4, "and an unchanged one once the wait is over")

  // A check for programs using it that couldn't finish says nothing about the copy, so the next
  // look tries once more. A second one in a row waits like any other refusal.
  let uncheckedUse = "I could not check whether something is using it, so I left it alone."
  let uncheckedTries = Calls()
  let unsure = try Autopilot(
    root: directory.appendingPathComponent("unchecked-use"),
    sources: AutopilotSources(
      worktrees: { _, _, d in ([stuckCopy(stale: "older")], d) },
      retireWorktree: { item, authority in
        uncheckedTries.add(item.id)
        return .refused(item, authority: authority, uncheckedUse)
      }))
  for minute in 0..<4 { _ = await unsure.tick(now: now.addingTimeInterval(Double(minute) * 60)) }
  equal(uncheckedTries.all.count, 2, "a check that couldn't finish is tried once more, then waits")

  // One burn per item at a time. Two retires of the same copy write the same restore ref, so the
  // second could replace the backup the first had just verified. The native pass skipped an item
  // that was burning; the AI's burns and the owner's Burn now went straight in.
  let busyCopy = AutopilotItem(
    id: "worktree:busy", kind: .worktree, name: "busy", bytes: 1 << 30,
    facts: [
      "place": "sibling", "saved": "merged", "changes": "none", "stale": "older", "inUse": "no",
      "thread": "none",
    ])
  let busyRetires = Calls()
  let busyRelease = Calls()
  let busyRoot = directory.appendingPathComponent("in-flight")
  let busyStore = try AutopilotStore(root: busyRoot)
  let inFlight = try Autopilot(
    root: busyRoot,
    sources: AutopilotSources(
      worktrees: { _, _, d in ([busyCopy], d) },
      retireWorktree: { item, authority in
        busyRetires.add(item.id)
        // The first retire stays in Git until the proof lets it go.
        let first = busyRetires.all.count == 1
        let deadline = Date().addingTimeInterval(10)
        while first, busyRelease.all.isEmpty, Date() < deadline {
          Thread.sleep(forTimeInterval: 0.01)
        }
        return AutopilotReceipt(
          itemID: item.id, kind: .worktree, name: item.name, authority: authority,
          outcome: "burned", detail: "", bytes: item.bytes)
      }))
  _ = await inFlight.tick(now: now, burn: false)
  let nativePass = Task { await inFlight.tick(now: now.addingTimeInterval(60)) }
  let started = Date().addingTimeInterval(10)
  while busyRetires.all.isEmpty, Date() < started {
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  equal(busyRetires.all.count, 1, "the native pass is retiring the copy")
  let duringAI = await inFlight.burn([busyCopy.id])
  equal(duringAI.first?.outcome, "refused")
  equal(duringAI.first?.detail, "I'm already burning it.", "the AI hears it is already burning")
  do {
    _ = try await inFlight.apply(.burnNow(itemID: busyCopy.id))
    failTest("Burn now started a second retire of a copy already burning")
  } catch {
    equal(error.localizedDescription, "I'm already burning it.", "and so does the owner")
  }
  equal(busyRetires.all.count, 1, "no second retire while the first runs")
  busyRelease.add("done")
  _ = await nativePass.value
  equal(busyRetires.all.count, 1, "the copy is retired once")
  equal(try busyStore.receipts().map(\.outcome), ["burned"], "with one receipt")
  equal(
    try busyStore.sweep().log.filter { $0.message.contains("busy") }.count, 1,
    "and one line in the owner's activity log")

  try await aiBriefProof()
}

/// The AI works from the owner's lessons and says how it expects the owner to answer (spec 2.6).
private func aiBriefProof() async throws {
  // The prompt names the lessons as the owner's intent, before the procedure, and asks for a guess.
  let prompt = AutopilotHarness.prompt
  let brief =
    "The owner's lessons (catalog `lessons`) are their intent and your brief: judge unsure items by why they burn or keep things, ask only where no lesson reaches, never contradict one."
  check(prompt.contains(brief), "the lessons are the AI's brief")
  let briefStart: String.Index? = prompt.range(of: brief)?.lowerBound
  let procedureStart: String.Index? = prompt.range(of: "Procedure (")?.lowerBound
  var briefFirst = false
  if let briefStart, let procedureStart { briefFirst = briefStart < procedureStart }
  check(briefFirst, "before the procedure")
  check(
    prompt.contains("Include `guess` (yes or no): what you think the owner will answer."),
    "the AI guesses the owner's answer")
  check(prompt.contains("lessons") && prompt.contains("guess"))

  // The catalog carries every lesson the owner taught, worded as Settings shows it, with what it
  // rests on and what it did.
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-brief-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AutopilotStore(root: root.appendingPathComponent("lessons"))
  for receipt in teachHistoryReceipts() { try store.append(receipt) }
  try JSONEncoder().encode(teachHistoryVersion1(try teachHistory())).write(
    to: store.directory.appendingPathComponent("memory.json"))
  let engine = try Autopilot(
    root: root.appendingPathComponent("lessons"), sources: AutopilotSources())
  let page = await engine.catalogPage(status: nil, kind: nil, offset: 0, limit: 10)
  let memory = try store.memory()
  let taught = Set(memory.rules.filter { $0.source == .operator }.map(\.id))
  equal(Set(page.lessons.flatMap(\.ids)), taught, "every lesson the owner taught")
  equal(
    page.lessons.map(\.sentence), AutopilotPolicy.lessonGroups(memory).map(\.sentence),
    "one per group, worded as Settings shows it")
  guard let day = page.lessons.first(where: { $0.ids.contains(TeachLessons.copiesDayID) }) else {
    return failTest("the lesson most answers rest on")
  }
  equal(day.kind, .worktree)
  equal(day.verdict, .burn)
  equal(day.matches.count, day.ids.count, "an exact match per lesson")
  check(day.matches.contains(TeachLessons.copiesDay), "with the lesson's own match")
  equal(day.answers, 11, "the owner's 11 answers behind the day lessons")
  equal(day.burned, 3)
  equal(day.bytes, 7_000_000_000)
  equal(day.undone, 1)
  let (catalogOK, catalogJSON) = await engine.handle(AutopilotRequest(tool: "catalog"))
  check(catalogOK && catalogJSON.contains("\"lessons\""), "over the bridge too")

  // The AI's question records its guess. Every check that refused a question still does.
  func pushed(_ name: String) -> AutopilotItem {
    AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, bytes: 500_000_000,
      facts: [
        "place": "codex", "saved": "pushed", "changes": "none", "stale": "week", "inUse": "no",
        "thread": "none",
      ])
  }
  let copies = [pushed("one"), pushed("two"), pushed("three")]
  let askEngine = try Autopilot(
    root: root.appendingPathComponent("ask"),
    sources: AutopilotSources(worktrees: { _, _, d in (copies, d) }))
  guard let native = await askEngine.tick(now: Date()).questions.first else {
    return failTest("BZ's own question about the copies")
  }
  isNil(native.guess)
  func aiQuestion(_ match: [String: [String]]) -> AutopilotQuestion {
    AutopilotQuestion(
      kind: .worktree, match: match, question: "Can I burn the copies already on GitHub?",
      why: "", examples: [], count: 0, bytes: 0, source: "ai")
  }
  do {
    _ = try await askEngine.ask(
      aiQuestion(["saved": ["pushed"]]), replacing: native.id, guess: .yes)
    failTest("a question must say how long things sat unused")
  } catch {
    equal(
      error.localizedDescription,
      "Say how long they sat unused, and never ask about things used today or busy right now: a yes would also cover things still being worked on.",
      "the same refusal as before")
  }
  let guessedNo = try await askEngine.ask(
    aiQuestion(["saved": ["pushed"], "stale": ["week"]]), replacing: native.id, guess: .no)
  equal(guessedNo.guess?.source, "ai", "the AI's guess")
  equal(guessedNo.guess?.answer, .no)
  equal(guessedNo.guess?.sure, false, "never sure of a No")
  equal(guessedNo.guess?.why, "I think you'll say no.")
  equal(
    try AutopilotStore(root: root.appendingPathComponent("ask")).memory().questions.first {
      $0.id == guessedNo.id
    }?.guess?.answer, .no, "and stored")
  // Over the bridge, a guess that isn't yes or no is ignored, not refused.
  var maybe = AutopilotRequest(tool: "ask")
  var input = AutopilotQuestionInput(
    kind: .worktree, match: ["saved": ["pushed", "merged"], "stale": ["week"]],
    question: "Can I burn the copies already on GitHub?")
  input.guess = "maybe"
  maybe.question = input
  maybe.replace = guessedNo.id
  let (maybeOK, maybeJSON) = await askEngine.handle(maybe)
  check(maybeOK, "an odd guess is ignored: \(maybeJSON)")
  checkFalse(maybeJSON.contains("\"guess\""), "and no guess is recorded: \(maybeJSON)")
}

/// A private app-side endpoint for the MCP protocol proof: an Autopilot engine with
/// invented items behind the real agent socket. Burns are recorded, never executed, and
/// the copy burn deliberately takes longer than the ordinary five-second socket deadline.
func runAutopilotFixture(root: URL) async throws {
  let copy = AutopilotItem(
    id: "worktree:fixture-copy", kind: .worktree, name: "atlas-old", bytes: 3 << 30,
    facts: [
      "place": "other", "saved": "pushed", "changes": "none", "stale": "older", "inUse": "no",
      "thread": "none",
    ])
  let server = AutopilotItem(
    id: "process:fixture-server", kind: .process, name: "vite in atlas", bytes: 1536 << 20,
    facts: [
      "family": "node", "orphaned": "yes", "thread": "ended", "idle": "1d", "listening": "yes",
      "agent": "claude",
    ], processKey: "fixture-server")
  let engine = try Autopilot(
    root: root,
    sources: AutopilotSources(
      processes: { _ in [server] },
      worktrees: { _, _, d in ([copy], d) },
      retireWorktree: { item, authority in
        Thread.sleep(forTimeInterval: 7)
        return AutopilotReceipt(
          itemID: item.id, kind: .worktree, name: item.name, authority: authority,
          outcome: "burned", detail: "Fixture only; nothing removed.", bytes: item.bytes)
      },
      inspect: { _ in ["commandLine": "node vite --port 5173"] }))
  _ = try await engine.apply(.setStarter(ruleID: "starter-finished-copies", enabled: false))
  _ = await engine.tick()
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: root.appendingPathComponent("observation"),
    accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  let service = AgentService(monitor: monitor, autopilot: engine)
  let listener = try AgentListener(root: root) { await service.call($0) }
  print("READY")
  _ = FileHandle.standardInput.readDataToEndOfFile()
  withExtendedLifetime(listener) {}
}
