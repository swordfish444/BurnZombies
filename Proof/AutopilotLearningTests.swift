import BurnCore
import Foundation

/// What answers teach, how BZ guesses before asking, and the replay that shows it improving.
func autopilotLearningProof() async throws {
  try await lessonsProof()
}

private func copy(_ id: String, _ facts: [String: String], bytes: UInt64 = 1 << 30)
  -> AutopilotItem
{
  AutopilotItem(id: "worktree:" + id, kind: .worktree, name: id, bytes: bytes, facts: facts)
}

/// An operator lesson of old copies, taught by the question `questionID`.
private func lesson(
  _ questionID: String, _ match: [String: [String]], _ verdict: AutopilotVerdict = .burn
) -> AutopilotRule {
  AutopilotRule(
    kind: .worktree, match: match, verdict: verdict, source: .operator, title: "",
    created: Date(timeIntervalSinceReferenceDate: 0), questionID: questionID)
}

private func encoded(_ rule: AutopilotRule) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(rule)
}

func lessonsProof() async throws {
  // With recency pinned, an answer teaches why and not which project, place, maker or size.
  equal(
    AutopilotPolicy.generalize(
      .worktree,
      [
        "repo": ["api"], "place": ["codex"], "size": ["large"], "saved": ["merged"],
        "stale": ["day"],
      ]),
    ["saved": ["merged"], "stale": ["day"]], "copies leave out repo, place and size")
  equal(
    AutopilotPolicy.generalize(
      .process, ["family": ["java"], "idle": ["10m"], "agent": ["codex"], "listening": ["yes"]]),
    ["family": ["java"], "idle": ["10m"], "listening": ["yes"]],
    "programs leave out the agent and keep their family")
  // Without known recency a general pattern would cover things used an hour ago.
  let unpinned: [[String: [String]]] = [
    ["repo": ["api"], "saved": ["merged"], "thread": ["none"]],
    ["repo": ["api"], "stale": ["unknown"]],
    ["repo": ["api"], "stale": ["day", "unknown"]],
  ]
  for match in unpinned {
    equal(AutopilotPolicy.generalize(.worktree, match), match, "kept exactly as asked")
  }
  check(
    AutopilotPolicy.pinsRecency(.disk, ["folder": ["node_modules"], "stale": ["week"]]),
    "folders pin how long they sat untouched")
  checkFalse(AutopilotPolicy.pinsRecency(.worktree, ["stale": []]), "an empty recency pins nothing")
  checkFalse(
    AutopilotPolicy.pinsRecency(.process, ["family": ["node"], "stale": ["day"]]),
    "programs pin how long they sat idle, not stale")
  equal(
    AutopilotPolicy.lessonMatch(
      .worktree, ["repo": ["api"], "stale": ["day"], "saved": ["merged"]], verdict: .burn),
    ["saved": ["merged"], "stale": ["day", "week", "month", "older"]],
    "a yes covers copies left longer")
  equal(
    AutopilotPolicy.lessonMatch(
      .process, ["agent": ["codex"], "family": ["java"], "idle": ["10m"], "listening": ["yes"]],
      verdict: .keep),
    ["family": ["java"], "idle": ["active", "10m"], "listening": ["yes"]],
    "a no covers busier programs")

  // A wide lesson subsumes a narrow one when it matches everything the narrow one matches.
  check(
    AutopilotPolicy.subsumes(
      ["stale": ["day", "week", "month", "older"]],
      ["stale": ["week", "month", "older"], "saved": ["merged"]]), "wider covers narrower")
  checkFalse(
    AutopilotPolicy.subsumes(
      ["stale": ["week", "month", "older"], "saved": ["merged"]],
      ["stale": ["day", "week", "month", "older"]]), "narrower never covers wider")
  checkFalse(
    AutopilotPolicy.subsumes(["saved": ["merged"]], ["stale": ["day"]]),
    "a fact the narrow pattern leaves open")
  check(
    AutopilotPolicy.overlaps(
      ["stale": ["today", "day"], "listening": ["yes"]], ["stale": ["day", "week"]]),
    "a shared value on every shared fact")
  checkFalse(
    AutopilotPolicy.overlaps(["stale": ["today"]], ["stale": ["week"], "saved": ["merged"]]),
    "no shared value")
  check(
    AutopilotPolicy.overlaps(["saved": ["local"]], ["stale": ["week"]]),
    "patterns with no fact in common overlap")

  // Absorb: a wider lesson takes in the narrower ones, with their answers and ids.
  let a = lesson("q1", ["stale": ["week", "month", "older"]])
  let b = lesson("q2", ["stale": ["day", "week", "month", "older"]])
  var rules = [a]
  equal(AutopilotPolicy.learn(b, into: &rules), b.id, "the wider lesson is the one kept")
  equal(rules.map(\.id), [b.id], "it absorbs the narrower one")
  equal(rules.first?.from, ["q1"], "with the answer that taught it")
  equal(rules.first?.formerIDs, [a.id], "and the id it had")
  // Join: an answer a lesson already covers adds to it instead of making a new rule.
  let c = lesson("q3", ["stale": ["week", "month", "older"], "saved": ["merged"]])
  equal(AutopilotPolicy.learn(c, into: &rules), b.id, "the covering lesson's id")
  equal(rules.count, 1, "no new rule")
  check(rules.first?.from?.contains("q3") == true, "the answer counts toward the lesson")
  equal(
    rules.first.map(AutopilotPolicy.questionIDs), ["q2", "q1", "q3"],
    "every answer the lesson was made from")
  // A rule that doesn't pin recency is never absorbed, joined or rewritten.
  let x = lesson("qx", ["repo": ["api"], "saved": ["merged"], "thread": ["none", "ended"]])
  let before = try encoded(x)
  var anyAge = [x]
  AutopilotPolicy.learn(b, into: &anyAge)
  equal(anyAge.count, 2, "the any-age rule stays beside the lesson")
  equal(try anyAge.first(where: { $0.id == x.id }).map(encoded), before, "byte for byte")
  var covered = [x]
  let y = lesson(
    "qy",
    [
      "repo": ["api"], "saved": ["merged"], "thread": ["none"],
      "stale": ["week", "month", "older"],
    ])
  equal(AutopilotPolicy.learn(y, into: &covered), y.id, "nothing joins an any-age rule")
  equal(covered.count, 2)
  equal(try covered.first(where: { $0.id == x.id }).map(encoded), before, "still byte for byte")
  // Burn and keep lessons never merge.
  let keep = lesson("qk", ["stale": ["week", "month", "older"]], .keep)
  var kept = [keep]
  AutopilotPolicy.learn(b, into: &kept)
  equal(Set(kept.map(\.id)), Set([keep.id, b.id]), "a burn lesson never absorbs a keep")
  var burned = [b]
  equal(AutopilotPolicy.learn(keep, into: &burned), keep.id, "a keep never joins a burn lesson")
  equal(burned.count, 2)

  // The general lesson from an AI question about one project burns the same kind of copy in
  // another project.
  var memory = AutopilotMemory()
  let aiMatch: [String: [String]] = [
    "repo": ["api"], "place": ["codex"], "saved": ["merged"], "stale": ["day"],
  ]
  let general = AutopilotRule(
    kind: .worktree, match: AutopilotPolicy.lessonMatch(.worktree, aiMatch, verdict: .burn),
    verdict: .burn, source: .operator, title: "",
    questionID: AutopilotRule.key(kind: .worktree, match: aiMatch))
  let lessonID = AutopilotPolicy.learn(general, into: &memory.rules)
  equal(
    lessonID,
    AutopilotRule.key(
      kind: .worktree, match: ["saved": ["merged"], "stale": ["day", "week", "month", "older"]])
      + ":burn")
  let elsewhere = copy(
    "web-app-fix",
    [
      "repo": "web-app", "place": "patrol6", "saved": "merged", "stale": "week",
      "changes": "none", "inUse": "no", "thread": "none",
    ])
  let decided = AutopilotPolicy.decide(elsewhere, memory: memory)
  equal(decided.status, .burn, "the lesson reaches another project")
  equal(decided.authority, "rule:" + lessonID)

  try await lessonEngineProof()
}

/// The engine teaches lessons from answers, and Forget forgets every answer behind one.
private func lessonEngineProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-lessons-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AutopilotStore(root: root)
  let ai = AutopilotQuestion(
    kind: .worktree,
    match: ["repo": ["api"], "place": ["codex"], "saved": ["merged"], "stale": ["day"]],
    question: "Can I burn 3 old copies of api?", why: "", examples: [], count: 3,
    bytes: 3_000_000_000, source: "ai")
  let week = AutopilotQuestion(
    kind: .worktree, match: ["saved": ["merged"], "stale": ["week"]],
    question: "Can I burn old project copies already merged, untouched for a week?", why: "",
    examples: [], count: 2, bytes: 2_000_000_000)
  let pushed = AutopilotQuestion(
    kind: .worktree, match: ["saved": ["pushed"], "stale": ["day"]],
    question: "Can I burn old project copies already on GitHub, untouched since yesterday?",
    why: "", examples: [], count: 4, bytes: 4_000_000_000)
  let node = AutopilotQuestion(
    kind: .process, match: ["family": ["node"], "idle": ["1h"]],
    question: "Can I burn leftover Node programs that sat idle for over an hour?", why: "",
    examples: [], count: 1, bytes: 1_500_000_000)
  try store.updateMemory { $0.questions = [ai, week, pushed, node] }
  let engine = try Autopilot(root: root, sources: AutopilotSources())

  let snapshot = try await engine.apply(.answer(questionID: ai.id, answer: .yes))
  var memory = try store.memory()
  let mergedLesson: [String: [String]] = [
    "saved": ["merged"], "stale": ["day", "week", "month", "older"],
  ]
  equal(memory.rules.map(\.match), [mergedLesson], "a yes teaches the general lesson")
  let title = "Burn: Old project copies · Already merged · Unused since yesterday"
  equal(memory.rules.first?.title, title, "titled without the project or its maker")
  equal(
    snapshot.rules.first { $0.source == .operator }?.title, title, "and shown that way")

  _ = try await engine.apply(.answer(questionID: week.id, answer: .yes))
  memory = try store.memory()
  equal(memory.rules.map(\.match), [mergedLesson], "an answer the lesson covers joins it")
  equal(memory.rules.first?.from, [week.id], "the joined answer counts toward it")

  _ = try await engine.apply(.answer(questionID: pushed.id, answer: .yes))
  memory = try store.memory()
  equal(
    memory.rules.map(\.match),
    [["saved": ["pushed", "merged"], "stale": ["day", "week", "month", "older"]]],
    "a wider answer absorbs the lesson")
  equal(memory.rules.first?.questionID, pushed.id, "the wider answer teaches it")
  equal(
    Set(memory.rules.first.map(AutopilotPolicy.questionIDs) ?? []),
    Set([pushed.id, ai.id, week.id]), "with every answer behind it")

  // Forget removes the lesson and every answer it was made from, so they can be asked again.
  guard let taught = memory.rules.first else { return failTest("a lesson to forget") }
  _ = try await engine.apply(.forgetRule(ruleID: taught.id))
  memory = try store.memory()
  equal(memory.rules.count, 0, "lesson forgotten")
  equal(memory.questions.map(\.id), [node.id], "with all three answers, and nothing else")
}
