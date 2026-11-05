import BurnCore
import Foundation

/// What answers teach, how BZ guesses before asking, the replay that shows it improving, the
/// question card an owner decides on, and what BZ does on its own once it is sure.
func autopilotLearningProof() async throws {
  try await lessonsProof()
  try guessProof()
  try await migrationProof()
  try await groupsProof()
  try await cardProof()
  try await tellProof()
  try await evalRequestProof()
  try await simulatedOwnersProof()
}

/// Simulated owners (spec 4.3): three owners with fixed policies over 8 rounds of a Mac that gains
/// new copies, programs and folders every round. From a cold start BZ never burns what an owner
/// would keep, asks less, and handles more without asking, in the last four rounds than in the
/// first four. The liberal owner's general lessons settle every subject, so its questions fall to
/// none (R35a). A liberal owner with history, as a Mac has it after migration, gets tells; after
/// they undo one in round 6, BZ tells nothing more on that subject in round 7 (R35b, R3).
func simulatedOwnersProof() async throws {
  let liberal = try await simulateOwner(.liberal)
  let cautious = try await simulateOwner(.cautious)
  let keeper = try await simulateOwner(.serverKeeper)
  for run in [liberal, cautious, keeper] {
    print("  owner \(run.line)")
    print("    asked: " + run.askedLine)
    print("    subjects: " + run.subjects.joined(separator: "; "))
    equal(run.wrong, [], "\(run.persona): BZ never burns what the owner would keep, tells included")
    let early: Int = run.questions(1...4)
    let late: Int = run.questions(5...8)
    check(late < early, "\(run.persona): fewer questions in rounds 5-8 (\(late)) than 1-4 (\(early))")
    // Spec 4.3: what BZ handles without asking rises.
    let before: UInt64 = run.handled(1...4)
    let after: UInt64 = run.handled(5...8)
    check(after > before, "\(run.persona): more handled without asking in rounds 5-8 than 1-4")
  }
  // R35a: lessons handle it. The liberal owner's questions fall to none within rounds 5-8 and
  // stay there.
  let lastAsked: Int = liberal.rounds.filter { $0.questions > 0 }.map(\.round).max() ?? 0
  check(
    lastAsked < 8,
    "liberal: questions fall to 0 within rounds 5-8 and stay there (last asked in round \(lastAsked))")

  // R35b: a liberal owner with history. Earlier yes answers on copies cover every risk this owner
  // takes, and BZ's replay guessed the last 5 right, so BZ acts on copies and tells the owner, who
  // leaves what BZ did for later and undoes it in round 6.
  let earlier: Date = Date().addingTimeInterval(-30 * 86_400)
  let seasoned = try await simulateOwner(
    .liberal, undoRound: 6, history: ownerHistory(at: earlier), judgesTells: false)
  print("  owner \(seasoned.line) (with history)")
  print("    asked: " + seasoned.askedLine)
  print("    subjects: " + seasoned.subjects.joined(separator: "; "))
  equal(
    seasoned.wrong, [],
    "liberal with history: BZ never burns what the owner would keep, acts included")
  check(
    seasoned.tells > 0, "liberal with history: BZ tells the owner what it did on its own by round 8")
  guard let undone = seasoned.undone else {
    return failTest("liberal with history: a tell to undo in round 6")
  }
  equal(undone.round, 6, "liberal with history: the Undo is in round 6")
  let seventh: [String] = seasoned.rounds.first { $0.round == 7 }?.tellSubjects ?? []
  checkFalse(
    seventh.contains(undone.subject),
    "liberal with history: no tell on \(undone.subject) in round 7, after the Undo")
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
  equal(rules.first?.formerIDs, [a.id, c.id], "and the joined answer's id")
  // Merging carries everything along: a lesson's earlier answers and earlier ids, whichever
  // side of the merge it is on, as when old rules are learned again.
  var older = lesson("q5", ["stale": ["month", "older"]])
  older.from = ["q4"]
  older.formerIDs = ["old-q5"]
  var wider = lesson("q6", ["stale": ["week", "month", "older"]])
  wider.from = ["q7"]
  var pile = [older]
  equal(AutopilotPolicy.learn(wider, into: &pile), wider.id)
  equal(pile.first?.from, ["q7", "q5", "q4"], "its own answers, then the absorbed lesson's")
  equal(pile.first?.formerIDs, [older.id, "old-q5"], "the absorbed lesson's id and former ids")
  var relearned = lesson("q8", ["saved": ["merged"], "stale": ["month", "older"]])
  relearned.from = ["q9"]
  relearned.formerIDs = ["old-q8"]
  equal(AutopilotPolicy.learn(relearned, into: &pile), wider.id, "joins the covering lesson")
  equal(pile.first?.from, ["q7", "q5", "q4", "q8", "q9"], "with every answer it was made from")
  equal(
    pile.first?.formerIDs, [older.id, "old-q5", relearned.id, "old-q8"],
    "and every id it had")
  // An id another rule still holds stays that rule's, as when memory from before lessons holds a
  // wide rule and a narrow one side by side.
  let wide = lesson("qw", ["stale": ["day", "week", "month", "older"]])
  let narrow = lesson("qn", ["saved": ["merged"], "stale": ["week", "month", "older"]])
  var sideBySide = [wide, narrow]
  let again = lesson("qa", ["saved": ["merged"], "stale": ["week", "month", "older"]])
  equal(again.id, narrow.id, "the same lesson as the narrow rule")
  equal(AutopilotPolicy.learn(again, into: &sideBySide), wide.id, "the first covering lesson")
  equal(sideBySide.first?.from, ["qa"])
  check(sideBySide.first?.formerIDs == nil, "the narrow rule's id isn't taken from it")
  equal(sideBySide.count, 2)
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
  try await riskLessonsProof()
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

  // The same answer again, as from a double click, changes nothing: the merged lesson keeps the
  // answers and ids it took in.
  let merged = memory
  equal(merged.rules.first?.from?.count, 2, "the merged lesson took in two answers")
  equal(merged.rules.first?.formerIDs?.count, 2, "and two ids")
  _ = try await engine.apply(.answer(questionID: pushed.id, answer: .yes))
  memory = try store.memory()
  equal(memory, merged, "a repeated answer is a no-op")
  equal(memory.rules.first?.from, merged.rules.first?.from, "from survives")
  equal(memory.rules.first?.formerIDs, merged.rules.first?.formerIDs, "formerIDs survive")
  // A different answer to an answered question is refused, and nothing changes.
  for different: AutopilotAnswer in [.no, .skip] {
    do {
      _ = try await engine.apply(.answer(questionID: pushed.id, answer: different))
      failTest("a different answer to an answered question is refused: \(different)")
    } catch {
      equal(error.localizedDescription, "That question is already answered.")
    }
    equal(try store.memory(), merged, "the rules stay as they were after a refused \(different)")
  }

  // Forget removes the lesson and every answer it was made from, so they can be asked again.
  guard let taught = memory.rules.first else { return failTest("a lesson to forget") }
  _ = try await engine.apply(.forgetRule(ruleID: taught.id))
  memory = try store.memory()
  equal(memory.rules.count, 0, "lesson forgotten")
  equal(memory.questions.map(\.id), [node.id], "with all three answers, and nothing else")

  // A skipped question can still be answered Yes or No, and that teaches its lesson.
  _ = try await engine.apply(.answer(questionID: node.id, answer: .skip))
  _ = try await engine.apply(.answer(questionID: node.id, answer: .yes))
  memory = try store.memory()
  equal(memory.questions.first?.answer, .yes, "skip, then yes")
  equal(memory.rules.map(\.questionID), [node.id], "the yes teaches a lesson")
}

private let replayStart = Date(timeIntervalSinceReferenceDate: 815_000_000)

/// A question the owner (or BZ, with `by: "bz"`) already answered.
private func answered(
  _ kind: AutopilotKind, _ match: [String: [String]], _ answer: AutopilotAnswer,
  risks: [String]? = nil, by: String? = nil, at minute: Double
) -> AutopilotQuestion {
  var question = AutopilotQuestion(
    kind: kind, match: match, question: "", why: "", examples: [], count: 2,
    bytes: 2_000_000_000, asked: replayStart)
  question.answer = answer
  question.answered = replayStart.addingTimeInterval(minute * 60)
  question.risks = risks
  question.answeredBy = by
  return question
}

/// Scores on one subject, oldest first.
private func scores(_ subject: String, _ rights: [Bool]) -> [AutopilotScore] {
  rights.enumerated().map { i, right in
    AutopilotScore(
      questionID: subject + "-\(i)", subject: subject, guess: .yes, answer: right ? .yes : .no,
      right: right, date: replayStart.addingTimeInterval(Double(i)))
  }
}

func guessProof() throws {
  // Risks are the risky facts among the things a question covers, anything unknown included.
  equal(
    AutopilotPolicy.risks(
      .worktree,
      [
        copy("draft", ["saved": "local", "changes": "small"]),
        copy("odd", ["saved": "unknown", "changes": "none"]),
      ]), ["changes=small", "saved=local", "saved=unknown"])
  // Older questions name theirs in their pattern and their caution text.
  var drafts = AutopilotQuestion(
    kind: .worktree,
    match: [
      "changes": ["small", "large"], "saved": ["local", "pushed"], "stale": ["day", "week"],
    ],
    question: "", why: "", examples: [], count: 4, bytes: 7_000_000_000)
  drafts.cautions = ["3 have work only on this Mac", "4 have unsaved changes"]
  equal(
    AutopilotPolicy.risks(of: drafts), ["changes=large", "changes=small", "saved=local"],
    "risks from the pattern")
  var servers = AutopilotQuestion(
    kind: .process, match: ["family": ["node"], "idle": ["10m"]], question: "", why: "",
    examples: [], count: 1, bytes: 5_000_000_000)
  servers.cautions = ["1 is still running a server"]
  equal(AutopilotPolicy.risks(of: servers), ["idle=10m", "listening=yes"], "and from cautions")
  drafts.risks = ["saved=unknown"]
  equal(AutopilotPolicy.risks(of: drafts), ["saved=unknown"], "stored risks are used as they are")

  // Trust takes five right guesses in a row on a subject; one miss ends it.
  let fiveRight = scores("worktree:", [true, true, true, true, true])
  check(AutopilotPolicy.trusted("worktree:", scores: fiveRight), "5 right")
  checkFalse(
    AutopilotPolicy.trusted("worktree:", scores: scores("worktree:", [true, true, true, true])),
    "4 right")
  checkFalse(
    AutopilotPolicy.trusted(
      "worktree:", scores: scores("worktree:", [true, true, true, true, true, false])),
    "a miss ends trust")
  check(
    AutopilotPolicy.trusted(
      "worktree:", scores: scores("worktree:", [false, true, true, true, true, true])),
    "five right after a miss earn it back")
  checkFalse(
    AutopilotPolicy.trusted(
      "worktree:",
      scores: scores("worktree:", [true, true, true, true]) + scores("process:node", [true])),
    "another subject's right guess doesn't count")
  check(
    AutopilotPolicy.trusted(
      "worktree:",
      scores: fiveRight + scores("process:node", [false])),
    "nor does its miss")

  // Guess: the owner's usual answer on the subject, sure only when trust is earned and nothing
  // about the question is new to the owner.
  let copies = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["week"]], question: "", why: "", examples: [], count: 3,
    bytes: 1_200_000_000)
  check(AutopilotPolicy.guess(copies, memory: AutopilotMemory()) == nil, "nothing to go on")
  var memory = AutopilotMemory()
  memory.questions = [
    answered(
      .worktree, ["saved": ["local"], "stale": ["month"]], .yes, risks: ["saved=local"], at: 1),
    answered(
      .worktree, ["changes": ["small"], "stale": ["month"]], .yes, risks: ["changes=small"], at: 2),
  ]
  let early = AutopilotPolicy.guess(copies, memory: memory)
  equal(early?.answer, .yes, "two yes answers on copies")
  equal(early?.sure, false, "but no trust yet")
  equal(early?.source, "native")
  equal(early?.why, "You said yes to 2 like these.")
  memory.scores = scores("worktree:", [true, true, true, true, true])
  var seen = copies
  seen.risks = ["changes=small", "saved=local"]
  let trusted = AutopilotPolicy.guess(seen, memory: memory)
  equal(trusted?.answer, .yes)
  equal(trusted?.sure, true, "trusted, and every risk was said yes to before")
  equal(
    trusted?.why,
    "You said yes to 2 like these, including ones with work only on this Mac and unsaved changes.")
  var serving = copies
  serving.risks = ["listening=yes", "saved=local"]
  equal(AutopilotPolicy.guess(serving, memory: memory)?.answer, .yes)
  equal(AutopilotPolicy.guess(serving, memory: memory)?.sure, false, "a risk never said yes to")
  var careful = memory
  careful.rules = [
    AutopilotRule(
      kind: .worktree, match: ["stale": ["today", "day"]], verdict: .keep, source: .operator,
      title: "")
  ]
  equal(AutopilotPolicy.guess(seen, memory: careful)?.sure, true, "a keep for newer copies only")
  careful.rules[0].match = ["changes": ["large", "small"], "stale": ["today", "day", "week"]]
  equal(AutopilotPolicy.guess(seen, memory: careful)?.sure, false, "a keep lesson overlaps it")
  // A program family nobody answered leans on other programs, but is never sure.
  var programs = AutopilotMemory()
  programs.questions = [
    answered(.process, ["family": ["node"], "idle": ["1h"]], .yes, at: 1),
    answered(.process, ["family": ["python"], "idle": ["1d"]], .yes, at: 2),
  ]
  programs.scores = scores("process:ruby", [true, true, true, true, true])
  let ruby = AutopilotQuestion(
    kind: .process, match: ["family": ["ruby"], "idle": ["1h"]], question: "", why: "",
    examples: [], count: 1, bytes: 1_500_000_000)
  equal(AutopilotPolicy.guess(ruby, memory: programs)?.answer, .yes, "leans on other programs")
  equal(AutopilotPolicy.guess(ruby, memory: programs)?.sure, false, "never sure on a new family")
  // Only the owner's own answers count, a tie is no guess, and a No lean is never sure.
  var own = AutopilotMemory()
  own.questions = [answered(.worktree, ["stale": ["month"]], .yes, by: "bz", at: 1)]
  check(AutopilotPolicy.guess(copies, memory: own) == nil, "BZ's own calls don't count")
  var split = AutopilotMemory()
  split.questions = [
    answered(.worktree, ["stale": ["month"]], .yes, at: 1),
    answered(.worktree, ["saved": ["local"], "stale": ["day"]], .no, at: 2),
  ]
  check(AutopilotPolicy.guess(copies, memory: split) == nil, "a tie is no guess")
  split.questions.append(answered(.worktree, ["changes": ["small"], "stale": ["day"]], .no, at: 3))
  split.scores = scores("worktree:", [true, true, true, true, true])
  let keeps = AutopilotPolicy.guess(copies, memory: split)
  equal(keeps?.answer, .no, "two no answers to one yes")
  equal(keeps?.sure, false, "BZ never acts on a No")
  equal(keeps?.why, "You said no to 2 like these.")
  split.questions = [answered(.worktree, ["stale": ["month"]], .yes, at: 1)]
  equal(AutopilotPolicy.guess(copies, memory: split)?.why, "You said yes to 1 like this.")

  // Memory from before scores existed still loads, and scores round-trip.
  let older =
    #"{"judgments":{},"keptItems":[],"questions":[],"rules":[],"starterDisabled":[],"version":1}"#
  equal(
    try JSONDecoder().decode(AutopilotMemory.self, from: Data(older.utf8)).scores, [],
    "memory without scores")
  var scored = AutopilotMemory()
  scored.scores = scores("worktree:", [true, false])
  equal(
    try JSONDecoder().decode(AutopilotMemory.self, from: JSONEncoder().encode(scored)), scored,
    "scores round-trip")

  // The replay eval over the owner's anonymized history, matching the spec's reference replay.
  let history = try JSONDecoder().decode(
    [AutopilotQuestion].self, from: Data(teachHistoryJSON.utf8))
  let replay = AutopilotEval.replay(history)
  var expected = AutopilotEval.Summary()
  expected.answers = 27
  expected.settled = 3
  expected.acted = 7
  expected.asked = 17
  expected.guesses = 14
  expected.right = 13
  expected.wrongSettled = 0
  expected.wrongActed = 0
  expected.handledBytes = 126_591_930_368
  expected.lessons = 17
  equal(replay.summary, expected, "the owner's history")
  equal(replay.scores.count, 14, "a score for each guess on an asked question")
  check(replay.scores.allSatisfy { $0.replayed == true }, "all marked replayed")
  let outcomes: [String] = [
    "asked", "asked", "asked", "asked", "asked", "asked", "asked", "asked", "asked", "asked",
    "settled", "asked", "acted", "asked", "asked", "asked", "asked", "acted", "acted", "asked",
    "acted", "asked", "acted", "settled", "acted", "acted", "settled",
  ]
  equal(replay.steps.map(\.outcome), outcomes, "step by step as the reference replay")
  let unguessed = replay.steps.filter { $0.guess == nil }.map(\.questionID)
  equal(unguessed, ["q01", "q03", "q15"], "no guess where nothing was answered on the kind")
  let missed = replay.steps.filter { $0.matched == false }.map(\.questionID)
  equal(missed, ["q12"], "the only miss: the busy Java helpers kept, asked about")
  equal(replay.scores.map(\.right).firstIndex(of: false), 6, "the 7th score")
  equal(AutopilotEval.replay(Array(history.reversed())).summary, expected, "in the order answered")
  var mixed = history
  var bzCall = history[3]
  bzCall.id = "bz-call"
  bzCall.answeredBy = "bz"
  mixed.append(bzCall)
  equal(AutopilotEval.replay(mixed).summary, expected, "BZ's own calls aren't replayed")

  // The CLI report: a line per answer, then the summary.
  let report = AutopilotEval.report(replay)
  let lines = report.split(separator: "\n").map(String.init)
  equal(lines.count, 28, "27 answers and a summary")
  let summary = lines.last ?? ""
  check(summary.contains("27 answers"), summary)
  check(summary.contains("17 asked"), summary)
  check(summary.contains("13 of 14"), summary)
  check(lines[8].contains("process:java") && lines[8].contains("3.1 GB"), lines[8])
}

/// `burnzombies autopilot eval [--json]` asks the running app for the replay of the owner's answers,
/// the same way as the other autopilot commands, and prints it as lines or as JSON. Reading it
/// starts no tick.
func evalRequestProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-eval-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let history = try teachHistory()
  try AutopilotStore(root: root).updateMemory { $0.questions = history }
  let engine = try Autopilot(root: root, sources: AutopilotSources())
  let (ok, json) = await engine.handle(AutopilotRequest(tool: "eval"))
  check(ok, json)
  let replay = try AutopilotEval.replay(json: Data(json.utf8))
  equal(replay.summary, AutopilotEval.replay(history).summary, "the owner's replay")
  equal(replay.steps.count, 27)
  let lines = AutopilotEval.report(replay).split(separator: "\n")
  equal(lines.count, 28, "27 step lines and a summary")
  check(lines.last?.contains("27 answers: 3 settled, 7 acted, 17 asked.") == true, "the summary")
  isNil(await engine.sweepState().lastTick)
  // Memory that can't be read is an error, not "0 answers".
  let broken = root.appendingPathComponent("broken")
  let brokenStore = try AutopilotStore(root: broken)
  try Data("not memory".utf8).write(
    to: brokenStore.directory.appendingPathComponent("memory.json"))
  let brokenEngine = try Autopilot(root: broken, sources: AutopilotSources())
  let (brokenOK, brokenJSON) = await brokenEngine.handle(AutopilotRequest(tool: "eval"))
  checkFalse(brokenOK, "unreadable memory is an error: \(brokenJSON)")
  check(brokenJSON.contains("\"error\""), brokenJSON)
}
