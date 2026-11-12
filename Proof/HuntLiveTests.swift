import BurnCore
import Foundation

/// The live hunt: Claude's streamed output, deep hunt arguments, the hunt's own record of what it
/// read, judged and burned as it happened, Stop, the spending limit and Keep hunting. Fake sources
/// and runners only: no model calls, no real burns.
func huntLiveProof() async throws {
  // Claude's stream-json, cut mid-line the way a pipe delivers it. Each message's usage arrives
  // with every content block as running totals, so a message counts once, at its latest.
  let usage1 =
    #""usage":{"input_tokens":2,"cache_creation_input_tokens":42940,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":42940},"output_tokens":6,"service_tier":"standard"}"#
  let usage1Later = usage1.replacingOccurrences(
    of: #""output_tokens":6"#, with: #""output_tokens":40"#)
  let stream = [
    #"{"type":"system","subtype":"init","session_id":"s"}"#,
    #"{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5-5","content":[{"type":"thinking","thinking":"hidden"}],"#
      + usage1 + "}}",
    #"{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Biggest first."}],"#
      + usage1Later + "}}",
    #"{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-5-5","content":[{"type":"tool_use","name":"mcp__burnzombies__autopilot_catalog","input":{}}],"usage":{"input_tokens":5,"cache_read_input_tokens":42940,"output_tokens":20}}}"#,
    "not json at all",
    #"{"type":"rate_limit_event"}"#,
    #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.123,"num_turns":2}"#,
  ].joined(separator: "\n")
  var reader = AutopilotStreamReader()
  let bytes = Data(stream.utf8)
  let cut = bytes.count / 3
  var events = reader.read(bytes.prefix(cut)) + reader.read(bytes.dropFirst(cut))
  events += reader.finish()
  equal(
    events.compactMap { if case .text(let t) = $0 { return t } else { return nil } },
    ["Biggest first."])
  equal(
    reader.tokens, (2 + 42940 + 40) + (5 + 42940 + 20), "each message counts once, at its latest")
  check((reader.estimatedUSD ?? 0) > 0, "priced at API rates")
  check(events.contains(.result(usd: 0.123, limitReached: false, isError: false)), "result")
  var capped = AutopilotStreamReader()
  let budget = capped.read(
    Data(
      #"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.0011,"terminal_reason":"budget_exhausted"}"#
        .utf8) + Data("\n".utf8))
  equal(budget, [.result(usd: 0.0011, limitReached: true, isError: true)], "Claude's own cap")
  let run = AutopilotRun()
  run.stop("limit")
  run.stop()
  equal(run.stopReason, "limit", "the first reason stands")

  // Arguments: every Claude run streams; a deep one is stronger, longer and capped.
  var config = MachineReviewConfiguration(
    harness: "claude", executable: "/bin/claude", launcher: "/bin/bz", server: "/bin/bz-mcp")
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-hunt-live-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  func value(_ args: [String], _ flag: String) -> String? {
    args.firstIndex(of: flag).map { args[$0 + 1] }
  }
  func effort(_ args: [String]) -> String? {
    guard let raw = value(args, "--settings"),
      let settings = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    else { return nil }
    return (settings["env"] as? [String: String])?["CLAUDE_CODE_EFFORT_LEVEL"]
  }
  let regular = try AutopilotHarness.arguments(config, directory: directory, root: directory)
  equal(value(regular, "--output-format"), "stream-json")
  check(regular.contains("--verbose"), "stream-json needs --verbose with -p")
  isNil(value(regular, "--max-budget-usd"))
  equal(value(regular, "--max-turns"), "40")
  equal(value(regular, "--model"), "sonnet")
  let deep = try AutopilotHarness.arguments(
    config, directory: directory, root: directory, prompt: AutopilotHarness.deepPrompt,
    options: HuntOptions(deep: true, limitUSD: 5))
  equal(value(deep, "--max-budget-usd"), "5.00")
  equal(value(deep, "--max-turns"), "300")
  equal(value(deep, "--model"), "opus")
  equal(value(deep, "--fallback-model"), "sonnet")
  equal(value(deep, "--effort"), "high")
  equal(effort(deep), "high", "the owner's own Claude settings can't lower it")
  equal(value(deep, "-p"), AutopilotHarness.deepPrompt)
  config.model = "sonnet"
  config.reasoningEffort = "low"
  let chosen = try AutopilotHarness.arguments(
    config, directory: directory, root: directory, options: HuntOptions(deep: true, limitUSD: 2))
  equal(value(chosen, "--model"), "opus", "a deep hunt uses a strong model")
  equal(value(chosen, "--effort"), "high", "and thinks at least this hard")
  config.model = "claude-opus-5-5"
  config.reasoningEffort = "max"
  let stronger = try AutopilotHarness.arguments(
    config, directory: directory, root: directory, options: HuntOptions(deep: true, limitUSD: 2))
  equal(value(stronger, "--model"), "claude-opus-5-5", "the owner's strong model stays")
  equal(value(stronger, "--effort"), "max", "and their harder thinking too")
  isNil(value(stronger, "--fallback-model"))
  config.model = nil
  config.reasoningEffort = nil
  let brief = AutopilotHarness.deepPrompt
  check(brief.contains("This is a deep hunt"), "deep brief")
  check(brief.contains("burn as you go"), "burns as it goes")
  check(brief.contains("Questions follow BZ's own rules"), "same question rules")
  check(brief.contains("What the app enforces"), "same rails")
  checkFalse(brief.contains("aim for about 20 tool calls"), "no small budget of calls")
  check(AutopilotHarness.prompt.contains("aim for about 20 tool calls"), "regular brief unchanged")

  // The hunt's record: what the owner's rules and the AI burn, as it happens.
  let root = directory.appendingPathComponent("state")
  let calls = Calls()
  let gone = Calls()
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
      "place": "agent", "saved": "pushed", "changes": "none", "stale": "older", "inUse": "no",
      "thread": "none",
    ])
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
    },
    processCount: { 2212 })
  let engine = try Autopilot(root: root, sources: sources)
  var opening = HuntSnapshot(startedAt: Date().addingTimeInterval(-1))
  opening.lane = "autopilot"
  opening.deep = true
  opening.limitUSD = 5
  opening.spentUSD = 0
  await engine.beginHunt(opening)
  _ = await engine.tick(now: Date())
  let waiting = await engine.startLanes()
  var hunt = await engine.currentHunt()
  check(
    hunt?.log.contains { $0.kind == "burn" && $0.message.hasPrefix("Burned vitest.") } == true,
    "the owner's rules burn first, in the feed")
  equal(hunt?.processCount, 2212, "every program counts as looked at")
  check(
    hunt?.log.contains { $0.message == "Looked over 2,212 running programs." } == true,
    "the first look counts up in the feed")
  equal(waiting, 2, "the server and the copy wait for the AI")
  let programs = hunt?.lanes?.first { $0.kind == "process" }
  equal(programs?.seen, 2212)
  equal(programs?.burned, 1)
  var read = AutopilotRequest(tool: "catalog")
  read.status = "unsure"
  _ = await engine.handle(read)
  var look = AutopilotRequest(tool: "inspect")
  look.id = copy.id
  _ = await engine.handle(look)
  var judge = AutopilotRequest(tool: "decide")
  judge.judgments = [
    AutopilotJudgmentInput(
      id: copy.id, verdict: .burn, confidence: 0.92, label: "Old atlas copy",
      why: "Its work is on GitHub and nobody touched it in months.")
  ]
  _ = await engine.handle(judge)
  var burn = AutopilotRequest(tool: "burn")
  burn.ids = [copy.id]
  let burned = await engine.handle(burn)
  check(burned.1.contains("\"outcome\":\"burned\""), "the AI's burn went through: \(burned.1)")
  var report = AutopilotRequest(tool: "report")
  report.text = "Burned one old copy."
  _ = await engine.handle(report)
  await engine.huntEvent(.text("Copies next.\n- **atlas-fix** is `pushed`"))
  await engine.huntEvent(.spend(tokens: 1200, usd: 0.4))
  await engine.huntEvent(.result(usd: 0.42, limitReached: false, isError: false))
  hunt = await engine.currentHunt()
  let lines = hunt?.log.map(\.message) ?? []
  check(lines.contains("Reading 2 things I'm unsure about, biggest first."), "catalog: \(lines)")
  check(lines.contains { $0.hasPrefix("Looking closely at atlas-fix, ") }, "inspect: \(lines)")
  check(lines.contains("Judged 1: 1 to burn."), "decide: \(lines)")
  check(lines.contains { $0.hasPrefix("Burned atlas-fix. Restore point saved.") }, "burn: \(lines)")
  check(lines.contains("Burned one old copy."), "report")
  check(lines.contains("Copies next. atlas-fix is pushed"), "the AI's words, plainly: \(lines)")
  check(hunt?.log.contains { $0.kind == "detected" } == true, "a verdict to burn wakes the scene")
  equal(hunt?.spentUSD, 0.42, "the run's own total wins")
  equal(hunt?.tokens, 1200)
  let copies = hunt?.lanes?.first { $0.kind == "worktree" }
  equal(copies?.judged, 1)
  equal(copies?.burned, 1)
  equal(copies?.bytes, 2 << 30)
  check(hunt?.focus?.hasPrefix("Old atlas copy · ") == true, "the ticker says what it judged")
  let saved = try HuntSnapshot.load(root: root)
  equal(saved.lanes, hunt?.lanes, "the window reads what the engine wrote")
  equal(saved.receiptEvidenceAvailable, true)
  equal(saved.burned, 2)
  await engine.finishHunt(failure: nil, stopReason: "stopped", questions: 1, interval: 15)
  let final = try HuntSnapshot.load(root: root)
  equal(final.phase, "stopped")
  equal(final.stopReason, "stopped")
  equal(final.burned, 2, "totals come from the receipts")
  check(
    final.detail.hasPrefix("Stopped. Everything burned stays burned: ")
      && final.detail.hasSuffix(" freed for $0.42 of AI."), final.detail)
  check(final.log.contains { $0.kind == "ask" && $0.message.hasPrefix("1 question waits") })
  let ended = await engine.currentHunt()
  isNil(ended)

  // The AI is sure about the server but may not burn it: it waits for the owner's OK, with why.
  var sure = AutopilotRequest(tool: "decide")
  sure.judgments = [
    AutopilotJudgmentInput(
      id: server.id, verdict: .burn, confidence: 0.95, label: "Dev server from a done chat",
      why: "Its chat ended a day ago and nothing has used it since.")
  ]
  _ = await engine.handle(sure)
  let waitingForOK = await engine.snapshot().entries.first { $0.id == server.id }
  equal(waitingForOK?.status, .unsure, "the AI alone can't burn a server")
  equal(waitingForOK?.needsOK, true, "so it waits for the owner's OK")
  equal(waitingForOK?.aiWhy, "Its chat ended a day ago and nothing has used it since.")
  equal(AutopilotPolicy.needsOK(server), "Serving a port")
  var claudeCopy = copy
  claudeCopy.facts["place"] = "claude"
  equal(AutopilotPolicy.needsOK(claudeCopy), "Made by Claude")

  // A deep hunt looks at small programs too, and only while it runs.
  let small = AutopilotItem(
    id: "process:small", kind: .process, name: "mcp-server", bytes: 50 << 20,
    facts: [
      "family": "node", "orphaned": "yes", "thread": "none", "idle": "1d", "listening": "yes",
      "agent": "none",
    ], processKey: "small")
  let smallEngine = try Autopilot(
    root: directory.appendingPathComponent("small"),
    sources: AutopilotSources(processes: { _ in [small] }))
  var looked = await smallEngine.tick(now: Date())
  checkFalse(looked.entries.contains { $0.id == small.id }, "a regular look leaves it out")
  var deepHunt = HuntSnapshot()
  deepHunt.lane = "autopilot"
  deepHunt.deep = true
  await smallEngine.beginHunt(deepHunt)
  looked = await smallEngine.tick(now: Date())
  check(looked.entries.contains { $0.id == small.id }, "a deep hunt looks at small programs")
  await smallEngine.finishHunt(failure: nil, stopReason: nil, questions: 0, interval: 15)
  looked = await smallEngine.tick(now: Date().addingTimeInterval(60))
  checkFalse(looked.entries.contains { $0.id == small.id }, "only while it runs")

  // Coordinator: a deep hunt runs at once with its options, and its events reach the record.
  let coordRoot = directory.appendingPathComponent("coordinator")
  let coordEngine = try Autopilot(
    root: coordRoot, sources: AutopilotSources(processes: { _ in [server] }))
  final class Seen: @unchecked Sendable {
    var options: HuntOptions?
    var started = false
  }
  let seen = Seen()
  let deepCoordinator = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { config },
    run: { _, _, run in
      seen.options = run.options
      run.events(.text("Looking at the biggest programs first."))
      run.events(.spend(tokens: 5000, usd: 0.75))
      run.events(.result(usd: 0.8, limitReached: false, isError: false))
      return "{}"
    })
  _ = await deepCoordinator.tick(
    now: Date(), manual: true, options: HuntOptions(deep: true, limitUSD: 2))
  await deepCoordinator.waitForAI()
  equal(seen.options, HuntOptions(deep: true, limitUSD: 2))
  let done = try HuntSnapshot.load(root: coordRoot)
  equal(done.phase, "completed")
  equal(done.deep, true)
  equal(done.limitUSD, 2)
  equal(done.spentUSD, 0.8)
  check(done.log.contains { $0.message == "Looking at the biggest programs first." }, "narration")
  check(done.detail.hasPrefix("Deep hunt complete: "), done.detail)
  var sweep = await coordEngine.sweepState()
  equal(sweep.failures, 0)
  checkFalse(sweep.running)

  // Stop: the run ends, nothing backs off, and the record says what stays.
  let stopping = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { config },
    run: { _, _, run in
      seen.started = true
      let deadline = Date().addingTimeInterval(10)
      while run.stopReason == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
      throw StoreError.message(AutopilotHarness.stoppedByOwner)
    })
  _ = await stopping.tick(now: Date(), manual: true, options: HuntOptions(deep: true, limitUSD: 5))
  for _ in 0..<250 where !seen.started { try await Task.sleep(nanoseconds: 20_000_000) }
  await stopping.stop()
  await stopping.waitForAI()
  let stopped = try HuntSnapshot.load(root: coordRoot)
  equal(stopped.phase, "stopped")
  equal(stopped.stopReason, "stopped")
  check(stopped.log.contains { $0.message == "Stopping. Everything I burned stays burned." })
  sweep = await coordEngine.sweepState()
  equal(sweep.failures, 0, "a stop is not a failure")
  isNil(sweep.retryAfter)

  // Claude's own spending cap ends the run as a stop at the limit.
  let limited = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { config },
    run: { _, _, _ in throw StoreError.message(AutopilotHarness.limitReached) })
  _ = await limited.tick(now: Date(), manual: true, options: HuntOptions(deep: true, limitUSD: 2))
  await limited.waitForAI()
  let atLimit = try HuntSnapshot.load(root: coordRoot)
  equal(atLimit.stopReason, "limit")
  check(atLimit.detail.hasPrefix("Reached your $2 limit"), atLimit.detail)
  sweep = await coordEngine.sweepState()
  equal(sweep.failures, 0, "reaching the limit is not a failure")

  // Near its limit the AI wraps up and Claude reports success: that run ended for the limit too.
  let wrapped = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { config },
    run: { _, _, run in
      run.events(.result(usd: 1.86, limitReached: false, isError: false))
      return "{}"
    })
  _ = await wrapped.tick(now: Date(), manual: true, options: HuntOptions(deep: true, limitUSD: 2))
  await wrapped.waitForAI()
  let nearLimit = try HuntSnapshot.load(root: coordRoot)
  equal(nearLimit.stopReason, "limit", "93% of the limit spent")
  equal(nearLimit.detail, "Reached your $2 limit before anything was safe to burn.")

  // Keep hunting: the same hunt goes on, with what it spent still counted.
  let again = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { config },
    run: { _, _, run in
      run.events(.spend(tokens: 10, usd: 0.5))
      return "{}"
    })
  _ = await again.tick(
    now: Date(), manual: true, options: HuntOptions(deep: true, limitUSD: 3, continuing: true))
  await again.waitForAI()
  let resumed = try HuntSnapshot.load(root: coordRoot)
  equal(resumed.id, nearLimit.id, "the same hunt goes on")
  equal(resumed.phase, "completed")
  equal(resumed.spentUSD, (nearLimit.spentUSD ?? 0) + 0.5)
  equal(resumed.limitUSD, (nearLimit.spentUSD ?? 0) + 3)
  equal(resumed.detail, "Deep hunt complete: nothing was safe to burn. It spent $2.36 of AI.")
  check(resumed.log.contains { $0.message.hasPrefix("Hunting again from where it stopped.") })

  // Deep hunts need Claude Code.
  config.harness = "codex"
  let codex = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { config },
    run: { _, _, _ in
      failTest("a deep hunt ran on Codex")
      return "{}"
    })
  _ = await codex.tick(now: Date(), manual: true, options: HuntOptions(deep: true, limitUSD: 2))
  await codex.waitForAI()
  sweep = await coordEngine.sweepState()
  equal(sweep.lastError, AutopilotCoordinator.deepNeedsClaude)
  config.harness = "claude"

  // From the command line: the request waits in the sweep state and the next tick starts it.
  _ = try await coordEngine.apply(.deepHunt(limitUSD: 2))
  sweep = await coordEngine.sweepState()
  equal(sweep.requestedDeep, 2)
  let picked = Seen()
  let cli = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { config },
    run: { _, _, run in
      picked.options = run.options
      return "{}"
    })
  _ = await cli.tick(now: Date())
  await cli.waitForAI()
  equal(picked.options?.deep, true)
  equal(picked.options?.limitUSD, 2)
  sweep = await coordEngine.sweepState()
  isNil(sweep.requestedDeep)
  _ = try await coordEngine.apply(.deepHunt(limitUSD: 500))
  sweep = await coordEngine.sweepState()
  equal(sweep.requestedDeep, 15, "the command line spends at most the window's top limit")
  await coordEngine.updateSweep {
    $0.requested = nil
    $0.requestedDeep = nil
  }

  // A hunt cut short when the app quit doesn't hunt forever in the window.
  var interrupted = try HuntSnapshot.load(root: coordRoot)
  interrupted.phase = "hunting"
  try interrupted.save(Store(root: coordRoot))
  let relaunched = AutopilotCoordinator(
    root: coordRoot, engine: coordEngine, configuration: { nil }, runner: { _, _ in "{}" })
  _ = await relaunched.tick(now: Date())
  let afterQuit = try HuntSnapshot.load(root: coordRoot)
  equal(afterQuit.phase, "stopped")
  check(afterQuit.detail.hasPrefix("The last hunt was cut short when the app quit."))

  // A hunt written by an older build still loads.
  var old = HuntSnapshot()
  old.phase = "completed"
  let encoded = try JSONEncoder().encode(old)
  var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
  for key in ["deep", "lanes", "focus", "spentUSD", "limitUSD", "tokens", "stopReason"] {
    object[key] = nil
  }
  let older = try JSONDecoder().decode(
    HuntSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
  equal(older.phase, "completed")
  isNil(older.lanes)
  checkFalse(older.isAutopilot)
  equal(HuntOptions.dollars(5), "$5")
  equal(HuntOptions.dollars(1.2), "$1.20")
}
