import BurnCore
import Foundation

private func process(_ id: String, _ facts: [String: String], bytes: UInt64 = 1 << 20)
  -> AutopilotItem
{
  AutopilotItem(id: "process:" + id, kind: .process, name: id, bytes: bytes, facts: facts)
}
private func copy(_ id: String, _ facts: [String: String], bytes: UInt64 = 1 << 30)
  -> AutopilotItem
{
  AutopilotItem(id: "worktree:" + id, kind: .worktree, name: id, bytes: bytes, facts: facts)
}
private func junk(_ id: String, _ facts: [String: String], bytes: UInt64 = 1 << 30) -> AutopilotItem
{
  AutopilotItem(id: "disk:" + id, kind: .disk, name: id, bytes: bytes, facts: facts)
}

func autopilotPolicyProof() throws {
  let orphan = process(
    "a",
    [
      "family": "node", "orphaned": "yes", "thread": "ended", "idle": "1d", "listening": "no",
      "agent": "claude",
    ])
  let finished = copy(
    "b",
    [
      "place": "patrol6", "saved": "merged", "changes": "none", "stale": "older", "inUse": "no",
      "thread": "none",
    ])
  let rebuildable = junk("c", ["folder": "node_modules", "home": "stale-worktree", "stale": "month"])
  var memory = AutopilotMemory()

  // Starter rules authorize the safe floor and switch off cleanly.
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .burn, "starter S1")
  equal(
    AutopilotPolicy.decide(orphan, memory: memory).authority, "starter:starter-leftover-programs")
  equal(AutopilotPolicy.decide(finished, memory: memory).status, .burn, "starter S2")
  equal(AutopilotPolicy.decide(rebuildable, memory: memory).status, .burn, "starter S3")
  memory.starterDisabled = Set(AutopilotPolicy.starterRules.map(\.id))
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .unsure, "S1 off")
  equal(AutopilotPolicy.decide(finished, memory: memory).status, .unsure, "S2 off")
  equal(AutopilotPolicy.decide(rebuildable, memory: memory).status, .unsure, "S3 off")

  // Starter S2 never covers owner-managed copies or copies with changes.
  memory = AutopilotMemory()
  var codex = finished
  codex.facts["place"] = "codex"
  equal(AutopilotPolicy.decide(codex, memory: memory).status, .unsure, "codex copy needs a rule")
  var dirty = finished
  dirty.facts["changes"] = "small"
  equal(AutopilotPolicy.decide(dirty, memory: memory).status, .unsure, "dirty copy needs a rule")

  // Keep beats burn, for rules and for the operator's own keeps.
  let burnAll = AutopilotRule(
    kind: .process, match: ["family": ["node"]], verdict: .burn, source: .operator,
    title: "Burn node")
  let keepAll = AutopilotRule(
    kind: .process, match: ["agent": ["claude"]], verdict: .keep, source: .operator,
    title: "Keep claude")
  memory.rules = [burnAll, keepAll]
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .keep, "keep rule wins")
  memory.rules = [burnAll]
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .burn, "operator burn rule")
  check(
    AutopilotPolicy.decide(orphan, memory: memory).authority?.hasPrefix("rule:") == true,
    "operator rule authority")
  memory.keptItems = [orphan.id]
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .keep, "kept item")
  memory = AutopilotMemory()

  // Protected items are never burned, even by a matching rule.
  var guarded = orphan
  guarded.protectedReason = "Its chat is still running."
  memory.rules = [burnAll]
  equal(AutopilotPolicy.decide(guarded, memory: memory).status, .protected, "rails first")
  memory = AutopilotMemory()

  // AI confidence authorizes only eligible items, for the current revision, above the floor.
  memory.starterDisabled = Set(AutopilotPolicy.starterRules.map(\.id))
  func judge(_ item: AutopilotItem, _ confidence: Double, revision: String? = nil) {
    memory.judgments[item.id] = AutopilotJudgment(
      itemID: item.id, revision: revision ?? item.revision, verdict: .burn,
      confidence: confidence, label: "Test runner", why: "Its chat ended a day ago.")
  }
  judge(orphan, 0.84)
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .unsure, "below floor")
  judge(orphan, 0.9)
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .burn, "confident AI")
  equal(AutopilotPolicy.decide(orphan, memory: memory).authority, "ai:0.90")
  judge(orphan, 0.95, revision: "older")
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .unsure, "stale revision")
  var server = orphan
  server.facts["listening"] = "yes"
  server = AutopilotItem(
    id: server.id, kind: .process, name: server.name, facts: server.facts)
  judge(server, 0.99)
  checkFalse(AutopilotPolicy.aiEligible(server), "listening servers need a rule")
  equal(AutopilotPolicy.decide(server, memory: memory).status, .unsure, "server stays unsure")
  checkFalse(AutopilotPolicy.aiEligible(codex), "owner-managed copies need a rule")
  checkFalse(
    AutopilotPolicy.aiEligible(junk("d", ["folder": "other", "home": "repo"])),
    "unknown folders need a rule")
  check(AutopilotPolicy.aiEligible(finished), "plain copy is AI-eligible")
  memory.judgments[orphan.id] = AutopilotJudgment(
    itemID: orphan.id, revision: orphan.revision, verdict: .keep, confidence: 0.9,
    label: "Dev server", why: "Looks like active work.")
  memory.rules = [burnAll]
  equal(AutopilotPolicy.decide(orphan, memory: memory).status, .keep, "AI keep beats burn rule")
  memory = AutopilotMemory()

  // Questions cover the biggest clusters, at most three, never repeating.
  var unsure = [AutopilotItem]()
  for i in 0..<40 {
    unsure.append(
      copy(
        "local-\(i)",
        [
          "place": "patrol6", "saved": "local", "changes": "none", "stale": "older",
          "thread": "ended",
        ], bytes: 2 << 30))
  }
  for i in 0..<10 {
    unsure.append(
      process(
        "py-\(i)",
        [
          "family": "python", "orphaned": "yes", "thread": "none", "idle": "1h",
          "listening": "yes", "agent": "none",
        ]))
  }
  for i in 0..<5 {
    unsure.append(junk("cache-\(i)", ["folder": "package-cache", "home": "repo", "stale": "week"]))
  }
  var questions = AutopilotPolicy.proposeQuestions(unsure, memory: memory)
  equal(questions.count, 3, "three questions")
  equal(Set(questions.map(\.kind)), Set(AutopilotKind.allCases), "one per cluster")
  let copies = questions.first { $0.kind == .worktree }!
  equal(copies.count, 40, "covers the whole cluster")
  equal(copies.match["saved"], ["local"], "primary fact included")
  check(copies.question.hasPrefix("Can I burn old copies"), copies.question)
  check(copies.why.contains("40"), copies.why)
  equal(copies.examples.count, 3)
  let processQuestion = questions.first { $0.kind == .process }!
  check(processQuestion.question.contains("Python"), processQuestion.question)
  memory.questions = questions
  equal(
    AutopilotPolicy.proposeQuestions(unsure, memory: memory).count, 0, "no slots while 3 open")
  memory.questions[0].answer = .yes
  memory.questions[0].answered = Date()
  let next = AutopilotPolicy.proposeQuestions(unsure, memory: memory)
  equal(next.count, 1, "one slot reopens")
  checkFalse(next.map(\.id).contains(questions[0].id), "answered pattern never re-asked")
  memory.questions[1].answer = .skip
  memory.questions[1].snoozedUntil = Date().addingTimeInterval(86400)
  checkFalse(
    AutopilotPolicy.proposeQuestions(unsure, memory: memory).map(\.id).contains(questions[1].id),
    "skipped pattern hidden until its snooze ends")
  check(
    AutopilotPolicy.proposeQuestions(
      unsure, memory: memory, now: Date().addingTimeInterval(2 * 86400)
    ).map(\.id).contains(questions[1].id), "snooze expiry allows re-asking")

  // Training progress and coverage.
  memory = AutopilotMemory()
  questions = (0..<6).map { i in
    var q = AutopilotQuestion(
      kind: .disk, match: ["folder": ["f\(i)"]], question: "q", why: "w", examples: [], count: 1,
      bytes: 1)
    q.answer = i % 2 == 0 ? .yes : .no
    return q
  }
  memory.questions = questions
  equal(AutopilotPolicy.trainingProgress(memory), 0.5, "6 of 12 answers")
  let entries = [
    AutopilotEntry(
      item: orphan, status: .burn, authority: nil, label: "", why: "", consequence: ""),
    AutopilotEntry(
      item: finished, status: .unsure, authority: nil, label: "", why: "", consequence: ""),
    AutopilotEntry(
      item: guarded, status: .protected, authority: nil, label: "", why: "", consequence: ""),
  ]
  equal(AutopilotPolicy.coverage(entries), 0.5, "protected items do not count")
  equal(AutopilotPolicy.coverage([]), 1.0, "empty is fully covered")

  // Answers widen toward safer values (yes) or riskier ones (no).
  let wideBurn = AutopilotPolicy.widen(
    ["family": ["node"], "idle": ["1h"], "saved": ["pushed"], "orphaned": ["maybe"]],
    verdict: .burn)
  equal(wideBurn["idle"], ["1h", "6h", "1d"], "idler is safer")
  equal(wideBurn["saved"], ["pushed", "merged"], "merged is safer than pushed")
  equal(wideBurn["orphaned"], ["maybe", "yes"], "a sure orphan is safer")
  equal(wideBurn["family"], ["node"], "categories never widen")
  let wideKeep = AutopilotPolicy.widen(["saved": ["pushed"], "changes": ["small"]], verdict: .keep)
  equal(wideKeep["saved"], ["local", "pushed"], "keeping pushed work keeps local work")
  equal(wideKeep["changes"], ["large", "small"], "keeping small changes keeps large ones")

  // Rule titles are plain English.
  let title = AutopilotPolicy.ruleTitle(copies, answer: .yes)
  check(title.hasPrefix("Burn: Old copies"), title)

  // The store round-trips memory and bounds receipts.
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-policy-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AutopilotStore(root: root)
  memory.rules = [burnAll]
  try store.save(memory: memory)
  let loaded = try store.memory()
  equal(loaded, memory, "memory round-trip")
  try store.updateMemory { $0.keptItems.insert("x") }
  let updated = try store.memory()
  check(updated.keptItems.contains("x"), "update in place")
  for i in 0..<520 {
    try store.append(
      AutopilotReceipt(
        itemID: "i\(i)", kind: .disk, name: "n", authority: "operator", outcome: "burned",
        detail: ""))
  }
  let receipts = try store.receipts()
  equal(receipts.count, AutopilotStore.maximumReceipts, "receipts capped")
  equal(receipts.last?.itemID, "i519", "newest kept")
  var permissions = stat()
  _ = lstat(store.directory.appendingPathComponent("memory.json").path, &permissions)
  equal(permissions.st_mode & 0o777, 0o600, "private file")
}
