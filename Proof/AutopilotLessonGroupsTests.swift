import BurnCore
import Foundation

private let groupsStart = Date(timeIntervalSinceReferenceDate: 815_000_000)

/// A lesson and the answered question that taught it, both added to `memory`.
@discardableResult private func teach(
  _ memory: inout AutopilotMemory, _ kind: AutopilotKind, _ match: [String: [String]],
  _ verdict: AutopilotVerdict = .burn, by: String? = nil
) -> AutopilotRule {
  var question = AutopilotQuestion(
    kind: kind, match: match, question: "", why: "", examples: [], count: 1,
    bytes: 1_000_000_000, asked: groupsStart)
  question.answer = verdict == .burn ? .yes : .no
  question.answered = groupsStart
  question.answeredBy = by
  memory.questions.append(question)
  let rule = AutopilotRule(
    kind: kind, match: match, verdict: verdict, source: .operator, title: "",
    questionID: question.id)
  memory.rules.append(rule)
  return rule
}

private func group(_ groups: [AutopilotLessonGroup], _ id: String) -> AutopilotLessonGroup? {
  groups.first { $0.id == id }
}

/// The sentence of the one projects group made from these copies lessons.
private func projects(_ matches: [[String: [String]]]) -> String? {
  var memory = AutopilotMemory()
  for match in matches { teach(&memory, .worktree, match) }
  return group(AutopilotPolicy.lessonGroups(memory), "worktree:burn:projects")?.sentence
}

/// What Settings shows: lessons as plain sentences with their evidence, and How I'm doing.
func groupsProof() async throws {
  let history = try teachHistory()
  let memory = AutopilotPolicy.migrate(teachHistoryVersion1(history), receipts: [])
  let groups = AutopilotPolicy.lessonGroups(memory)
  let sentences = groups.map(\.sentence)
  for sentence in [
    "Copies nobody touched since yesterday are done, even with unsaved work, work only on this Mac, or work I couldn't check.",
    "Copies are done the same day once their work is on GitHub and nothing is unsaved.",
    "Leftover programs can stop once idle: Node after 10 minutes, Java helpers after an hour.",
    "Java helpers serving a port stay while idle less than an hour.",
  ] {
    check(sentences.contains(sentence), "a lesson reads: \(sentence) Got: \(sentences)")
  }
  let folders = sentences.first { $0.hasPrefix("Rebuildable folders untouched since yesterday can go: ") }
  check(folders != nil, "the folder lessons read as one sentence")
  let anyAge = group(groups, "worktree:burn:projects")
  check(anyAge?.sentence.hasPrefix("In project-") == true, "copies of named projects")
  // Worked out by hand from the fixture.
  equal(
    anyAge?.sentence,
    "In project-1, project-2 and 3 more projects, copies are done at any age once their work is on GitHub and no chat is using them.",
    "the projects most lessons name come first, then the rest are counted")
  equal(
    folders, "Rebuildable folders untouched since yesterday can go: build folders, node_modules, tool caches.",
    "with nothing burned yet, folders go by name")
  equal(
    groups.map(\.id),
    [
      "worktree:burn:today", "worktree:burn:day", "worktree:burn:projects", "process:burn",
      "disk:burn:day", "rule:" + TeachLessons.javaKeepID,
    ], "copies by how recently they were used, then programs, folders and keeps")
  let keep = group(groups, "rule:" + TeachLessons.javaKeepID)
  equal(keep?.kind, .process)
  equal(keep?.verdict, .keep)
  equal(keep?.ruleIDs, [TeachLessons.javaKeepID])
  equal(keep?.evidence, "From 1 answer", "the java keep was taught by one answer")
  equal(group(groups, "worktree:burn:day")?.kind, .worktree)
  equal(group(groups, "worktree:burn:day")?.verdict, .burn)
  equal(
    group(groups, "worktree:burn:day")?.evidence,
    "From 11 answers · burned 0 copies, 0 MB · undone 0", "11 answers behind the day lessons")
  equal(
    group(groups, "process:burn")?.evidence, "From 3 answers · stopped 0 programs, 0 MB of memory")
  equal(group(groups, "disk:burn:day")?.evidence, "From 3 answers · deleted 0 folders, 0 MB")

  // Every operator lesson is in exactly one group.
  let grouped = groups.flatMap(\.ruleIDs)
  equal(grouped.count, Set(grouped).count, "no lesson in two groups")
  equal(Set(grouped), Set(memory.rules.map(\.id)), "and none left out")
  equal(grouped.count, 17)

  // Tallies show in the evidence, and order the folders by what they freed.
  let tallied = AutopilotPolicy.migrate(
    teachHistoryVersion1(history), receipts: teachHistoryReceipts())
  equal(
    group(AutopilotPolicy.lessonGroups(tallied), "worktree:burn:day")?.evidence,
    "From 11 answers · burned 3 copies, 7.0 GB · undone 1", "what the day lessons burned")
  var freed = memory
  let caches = TeachLessons.id(.disk, TeachLessons.caches, .burn)
  let modules = TeachLessons.id(.disk, TeachLessons.modules, .burn)
  freed.tallies[caches] = AutopilotTally(count: 1, bytes: 5_000_000_000)
  freed.tallies[modules] = AutopilotTally(count: 2, bytes: 2_000_000_000)
  let freedFolders = group(AutopilotPolicy.lessonGroups(freed), "disk:burn:day")
  equal(
    freedFolders?.sentence,
    "Rebuildable folders untouched since yesterday can go: tool caches, node_modules, build folders.",
    "the folders that freed the most first")
  equal(freedFolders?.evidence, "From 3 answers · deleted 3 folders, 7.0 GB")

  // How I'm doing, just after the last answer, with nothing burned.
  let last = history.compactMap(\.answered).max() ?? groupsStart
  let progress = AutopilotPolicy.progress(
    memory, receipts: [], impact: nil, now: last.addingTimeInterval(60))
  equal(
    progress.lines,
    [
      "I guessed 9 of your last 10 answers right.",
      "This week: 30 questions, 0 MB burned on my own.",
      "Replaying your 27 answers, I'd have asked 17 and handled the other 10 on my own the way you would have.",
    ], "the 14 replayed scores miss only the 7th; nothing was burned")
  let text = sentences + groups.map(\.evidence) + progress.lines
  check(text.allSatisfy { !$0.contains("%") }, "plain counts, no percentages")

  templateProof()
  progressProof()
  try await snapshotProof(history)
}

/// The sentence templates, one case at a time.
private func templateProof() {
  // Copies by recency: "once" for what every lesson requires, "even with" for what any covers.
  var copies = AutopilotMemory()
  teach(&copies, .worktree, ["saved": ["pushed", "merged"], "stale": ["week", "month", "older"]])
  teach(
    &copies, .worktree,
    ["changes": ["none"], "saved": ["local", "pushed", "merged"], "stale": ["month", "older"]])
  teach(&copies, .worktree, ["changes": ["none"], "saved": ["merged"], "stale": ["older"]])
  var starter = AutopilotPolicy.starterRules[1]
  starter.id = "a-starter-rule"
  copies.rules.append(starter)
  let byAge = AutopilotPolicy.lessonGroups(copies)
  equal(
    group(byAge, "worktree:burn:week")?.sentence,
    "Copies nobody touched for a week are done once their work is on GitHub, even with unsaved work or work I couldn't check.",
    "two risks join with or")
  equal(
    group(byAge, "worktree:burn:month")?.sentence,
    "Copies nobody touched for a month are done once nothing is unsaved, even with work only on this Mac.")
  equal(
    group(byAge, "worktree:burn:older")?.sentence,
    "Copies nobody touched for 3 months are done once their work is on GitHub and nothing is unsaved.")
  check(!byAge.flatMap(\.ruleIDs).contains("a-starter-rule"), "starter rules are listed apart")

  // Copies at any age, by project.
  let merged: [String: [String]] = ["saved": ["merged"], "thread": ["none", "ended"]]
  equal(
    projects([merged]),
    "For some projects, copies are done at any age once their work is on GitHub and no chat is using them.")
  equal(
    projects([["repo": ["api"], "saved": ["local"]]]), "In api, copies are done at any age.",
    "only what every lesson requires")
  equal(
    projects([
      ["repo": ["web"], "saved": ["merged"], "thread": ["none"]],
      ["repo": ["api"], "saved": ["pushed"], "thread": ["ended"]],
    ]), "In api and web, copies are done at any age once their work is on GitHub and no chat is using them.")
  equal(
    projects([
      ["repo": ["web", "api"], "thread": ["none"]], ["repo": ["api"], "thread": ["none"]],
      ["repo": ["cli"], "thread": ["ended"]],
    ]), "In api, cli and 1 more project, copies are done at any age once no chat is using them.",
    "most named first, then by name")

  // Programs: each family once, at its lowest idle floor.
  var programs = AutopilotMemory()
  teach(&programs, .process, ["family": ["python"], "idle": ["1d"]])
  teach(&programs, .process, ["family": ["ruby"], "idle": ["1d"]])
  teach(&programs, .process, ["family": ["shell"], "idle": ["6h", "1d"]])
  teach(&programs, .process, ["family": ["browser"], "idle": ["10m", "1h", "6h", "1d"]])
  teach(&programs, .process, ["family": ["node"], "idle": ["6h", "1d"]])
  teach(&programs, .process, ["family": ["node"], "idle": ["1h", "6h", "1d"], "listening": ["no"]])
  let build = teach(
    &programs, .process, ["family": ["build"], "idle": ["active", "10m", "1h", "6h", "1d"]])
  programs.tallies[build.id] = AutopilotTally(count: 1, bytes: 500_000_000)
  let stops = group(AutopilotPolicy.lessonGroups(programs), "process:burn")
  equal(
    stops?.sentence,
    "Leftover programs can stop once idle: Build tools right away, Robot browsers after 10 minutes, Node after an hour, Scripts after 6 hours, Python after a day, Ruby after a day.")
  equal(stops?.evidence, "From 7 answers · stopped 1 program, 500 MB of memory")
  equal(stops?.ruleIDs.count, 7)

  // Keeps, one each. Copies and folders say how recently they were used: up to the bucket after
  // the most recent age kept, and no bound once every age is kept.
  var keeps = AutopilotMemory()
  let node = teach(&keeps, .process, ["family": ["node"], "idle": ["active", "10m", "1h"]], .keep)
  let python = teach(
    &keeps, .process,
    ["family": ["python"], "idle": ["active", "10m", "1h", "6h", "1d"], "listening": ["yes"]], .keep)
  let drafts = teach(
    &keeps, .worktree,
    ["saved": ["local"], "changes": ["large", "small"], "stale": ["today", "day"]], .keep)
  let modules = teach(
    &keeps, .disk, ["folder": ["node_modules"], "home": ["repo"], "stale": ["today", "day"]], .keep)
  let today = teach(&keeps, .worktree, ["repo": ["api"], "stale": ["today"]], .keep)
  let edits = teach(
    &keeps, .worktree, ["changes": ["large"], "stale": ["today", "day", "week", "month"]], .keep)
  let local = teach(
    &keeps, .worktree, ["saved": ["local"], "stale": ["today", "day", "week", "month", "older"]],
    .keep)
  let caches = teach(
    &keeps, .disk, ["folder": ["package-cache"], "stale": ["today", "day", "week"]], .keep)
  let kept = AutopilotPolicy.lessonGroups(keeps)
  equal(
    group(kept, "rule:" + node.id)?.sentence, "Node programs stay while idle less than 6 hours.",
    "no port: not serving one")
  equal(group(kept, "rule:" + python.id)?.sentence, "Python programs serving a port stay.")
  equal(
    group(kept, "rule:" + drafts.id)?.sentence,
    "Copies used in the last week stay: Work only on this Mac, Has unsaved changes.")
  equal(
    group(kept, "rule:" + modules.id)?.sentence,
    "node_modules folders used in the last week stay: Inside your projects.")
  equal(group(kept, "rule:" + today.id)?.sentence, "Copies of api used in the last day stay.")
  equal(
    group(kept, "rule:" + edits.id)?.sentence,
    "Copies used in the last 3 months stay: Has lots of unsaved changes.")
  equal(
    group(kept, "rule:" + local.id)?.sentence, "Copies stay: Work only on this Mac.",
    "kept at every age: no bound")
  equal(group(kept, "rule:" + caches.id)?.sentence, "Tool caches used in the last month stay.")

  // A keep narrowed to the risks a card showed names every value it keeps, so it never reads as
  // keeping everything: what BZ couldn't check, a few or lots of unsaved changes, joined with "or".
  let week: [String] = ["today", "day", "week"]
  let narrow: [(match: [String: [String]], sentence: String)] = [
    (["saved": ["unknown"]], "Where its work is saved couldn't be checked"),
    (["inUse": ["unknown"]], "Couldn't check if it's in use"),
    (["changes": ["unknown"]], "Unsaved changes couldn't be checked"),
    (["changes": ["large"]], "Has lots of unsaved changes"),
    (["changes": ["small"]], "Has a few unsaved changes"),
    (["changes": ["large", "small"]], "Has unsaved changes"),
    (
      ["saved": ["unknown", "local"]],
      "Work only on this Mac or where its work is saved couldn't be checked"
    ),
    (
      ["changes": ["unknown", "large"]],
      "Has lots of unsaved changes or unsaved changes couldn't be checked"
    ),
    (["saved": ["local", "pushed"]], "Work only on this Mac or saved on GitHub"),
    (["saved": ["unknown", "local", "pushed", "merged"]], ""),
  ]
  for (facts, words) in narrow {
    var one = AutopilotMemory()
    var match: [String: [String]] = facts
    match["stale"] = week
    _ = teach(&one, .worktree, match, .keep)
    let expected: String =
      words.isEmpty
      ? "Copies used in the last month stay." : "Copies used in the last month stay: " + words + "."
    equal(AutopilotPolicy.lessonGroups(one).first?.sentence, expected, "a keep of \(facts)")
  }
  let programKeeps: [(listening: [String], sentence: String)] = [
    (["unknown"], "Java helpers whose port couldn't be checked stay while idle less than 6 hours."),
    (
      ["unknown", "yes"],
      "Java helpers serving a port or whose port couldn't be checked stay while idle less than 6 hours."
    ),
    (["yes", "no"], "Java helpers stay while idle less than 6 hours."),
  ]
  for (listening, sentence) in programKeeps {
    var one = AutopilotMemory()
    let match: [String: [String]] = [
      "family": ["java"], "idle": ["active", "10m", "1h"], "listening": listening,
    ]
    _ = teach(&one, .process, match, .keep)
    equal(AutopilotPolicy.lessonGroups(one).first?.sentence, sentence, "a keep of \(listening)")
  }
  equal(group(kept, "rule:" + drafts.id)?.verdict, .keep)
  equal(group(kept, "rule:" + drafts.id)?.kind, .worktree)
  equal(group(kept, "rule:" + drafts.id)?.evidence, "From 1 answer", "keeps have no tally part")

  // Evidence: BZ's own calls are counted apart, and answers no longer in memory not at all.
  var calls = AutopilotMemory()
  var lesson = teach(&calls, .worktree, ["saved": ["merged"], "stale": ["week", "month", "older"]])
  let own = teach(
    &calls, .worktree, ["saved": ["pushed", "merged"], "stale": ["month", "older"]], by: "bz")
  calls.rules.removeAll { $0.id == own.id }
  lesson.from = [own.questionID ?? "", "forgotten"]
  calls.rules[0] = lesson
  calls.tallies[lesson.id] = AutopilotTally(count: 1, bytes: 1_000_000_000)
  equal(
    group(AutopilotPolicy.lessonGroups(calls), "worktree:burn:week")?.evidence,
    "From 1 answer and 1 of my own calls · burned 1 copy, 1.0 GB · undone 0")
  // Made only from BZ's own calls, a lesson says so instead of "From 0 answers and …".
  var alone = AutopilotMemory()
  let once = teach(
    &alone, .worktree, ["saved": ["merged"], "stale": ["week", "month", "older"]], by: "bz")
  alone.tallies[once.id] = AutopilotTally(count: 1, bytes: 1_000_000_000)
  equal(
    group(AutopilotPolicy.lessonGroups(alone), "worktree:burn:week")?.evidence,
    "From my own call · burned 1 copy, 1.0 GB · undone 0", "one call of BZ's own")
  let twice = teach(
    &alone, .worktree, ["saved": ["pushed"], "stale": ["week", "month", "older"]], by: "bz")
  alone.tallies[twice.id] = AutopilotTally(count: 2, bytes: 2_000_000_000)
  let aloneEvidence = group(AutopilotPolicy.lessonGroups(alone), "worktree:burn:week")?.evidence
  equal(
    aloneEvidence, "From 2 of my own calls · burned 3 copies, 3.0 GB · undone 0",
    "two calls of BZ's own")
  check(aloneEvidence?.contains("0 answers") == false, "never \"From 0 answers\"")
  var folder = AutopilotMemory()
  let cache = teach(&folder, .disk, ["folder": ["package-cache"], "stale": ["week", "month", "older"]])
  folder.tallies[cache.id] = AutopilotTally(count: 1, bytes: 2_000_000_000)
  let deleted = group(AutopilotPolicy.lessonGroups(folder), "disk:burn:week")
  equal(deleted?.sentence, "Rebuildable folders untouched for a week can go: tool caches.")
  equal(deleted?.evidence, "From 1 answer · deleted 1 folder, 2.0 GB")
}

/// A question asked at `asked`, answered by the owner (or by BZ, with `by: "bz"`) at `answered`.
private func asked(
  _ kind: AutopilotKind, _ match: [String: [String]], _ answer: AutopilotAnswer?, asked: Date,
  answered: Date? = nil, by: String? = nil
) -> AutopilotQuestion {
  var question = AutopilotQuestion(
    kind: kind, match: match, question: "", why: "", examples: [], count: 1,
    bytes: 1_000_000_000, asked: asked)
  question.answer = answer
  question.answered = answered ?? (answer == nil ? nil : asked)
  question.answeredBy = by
  return question
}

private func score(_ right: Bool, _ n: Int) -> AutopilotScore {
  AutopilotScore(
    questionID: "q\(n)", subject: "worktree:", guess: .yes, answer: right ? .yes : .no,
    right: right, date: groupsStart.addingTimeInterval(Double(n)))
}

private func receipt(
  _ authority: String, _ outcome: String, gigabytes: UInt64, at date: Date,
  kind: AutopilotKind = .worktree
) -> AutopilotReceipt {
  AutopilotReceipt(
    itemID: kind.rawValue + ":" + UUID().uuidString, kind: kind, name: "fixture",
    authority: authority, outcome: outcome, detail: "", bytes: gigabytes * 1_000_000_000,
    date: date)
}

/// An impact tally: copies burned and still gone, and copies the owner restored.
private func tally(_ worktrees: Int, restored: Int) -> AutopilotImpact {
  var impact = AutopilotImpact()
  impact.worktrees = worktrees
  impact.restored = restored
  return impact
}

/// How I'm doing, one line at a time.
private func progressProof() {
  let now = groupsStart.addingTimeInterval(90 * 86_400)
  func lines(
    _ memory: AutopilotMemory, _ receipts: [AutopilotReceipt] = [], impact: AutopilotImpact? = nil
  ) -> [String] {
    AutopilotPolicy.progress(memory, receipts: receipts, impact: impact, now: now).lines
  }
  equal(lines(AutopilotMemory()), [], "nothing to say yet")

  // Guesses: the last 10 scores, and a single one in words.
  var guessed = AutopilotMemory()
  guessed.scores = [score(true, 0)]
  equal(lines(guessed), ["I guessed your last answer right."])
  guessed.scores = [score(false, 0)]
  equal(lines(guessed), ["I missed your last answer."])
  guessed.scores = [score(true, 0), score(false, 1)]
  equal(lines(guessed), ["I guessed 1 of your last 2 answers right."])
  guessed.scores = [score(false, 0)] + (1...10).map { score($0 != 4, $0) }
  equal(lines(guessed), ["I guessed 9 of your last 10 answers right."], "only the last 10")

  // This week and last week: questions shown to the owner, and what BZ burned on its own.
  var weeks = AutopilotMemory()
  let day: TimeInterval = 86_400
  weeks.questions = [
    asked(.worktree, ["stale": ["week"]], nil, asked: now.addingTimeInterval(-2 * day)),
    asked(
      .worktree, ["stale": ["month"]], .yes, asked: now.addingTimeInterval(-3 * day), by: "bz"),
    asked(.disk, ["folder": ["node_modules"]], .no, asked: now.addingTimeInterval(-10 * day)),
    asked(.process, ["family": ["node"]], .yes, asked: now.addingTimeInterval(-20 * day)),
  ]
  let burns = [
    receipt("rule:lesson", "burned", gigabytes: 2, at: now.addingTimeInterval(-1 * day)),
    receipt("operator", "burned", gigabytes: 5, at: now.addingTimeInterval(-1 * day)),
    receipt("rule:lesson", "restored", gigabytes: 4, at: now.addingTimeInterval(-1 * day)),
    receipt("rule:lesson", "refused", gigabytes: 16, at: now.addingTimeInterval(-1 * day)),
    receipt("starter:a", "burned", gigabytes: 1, at: now.addingTimeInterval(-9 * day)),
    receipt("ai:0.95", "burned", gigabytes: 8, at: now.addingTimeInterval(-15 * day)),
    receipt(
      "rule:folders", "burned", gigabytes: 3, at: now.addingTimeInterval(-1 * day), kind: .disk),
    receipt(
      "rule:programs", "burned", gigabytes: 32, at: now.addingTimeInterval(-1 * day),
      kind: .process),
  ]
  equal(
    lines(weeks, burns).first,
    "This week: 1 question, 5.0 GB burned on my own. Last week: 1 question, 1.0 GB.",
    "disk freed by copies and folders; not the owner's own burns, restored ones, program memory or BZ's own answers")
  var quiet = weeks
  quiet.questions = [weeks.questions[0]]
  equal(
    lines(quiet, Array(burns.prefix(1))), ["This week: 1 question, 2.0 GB burned on my own."],
    "last week is left out when it had nothing")

  // Undo: the copies the owner restored, out of the copies BZ burned. Both come from the impact
  // tally, which keeps them for good; receipts.json keeps only the latest.
  let old = now.addingTimeInterval(-60 * day)
  let restores = [
    receipt("rule:lesson", "restored", gigabytes: 1, at: old),
    receipt("rule:lesson", "restored", gigabytes: 1, at: old),
  ]
  equal(
    lines(AutopilotMemory(), restores, impact: tally(40, restored: 1)),
    ["You undid 1 of the 41 copies I burned."], "from the tally, not the receipts")
  equal(
    lines(AutopilotMemory(), [], impact: tally(1, restored: 0)),
    ["You undid 0 of the 1 copy I burned."])
  equal(
    lines(AutopilotMemory(), [], impact: tally(0, restored: 1)),
    ["You undid 1 of the 1 copy I burned."])
  equal(lines(AutopilotMemory(), [], impact: tally(0, restored: 0)), [], "no copies burned yet")
  equal(lines(AutopilotMemory(), restores), [], "without the tally there is no undo line")

  // The replay, once there are 5 answers.
  var replayed = AutopilotMemory()
  func answer(_ kind: AutopilotKind, _ match: [String: [String]], _ yes: Bool, _ minute: Double)
    -> AutopilotQuestion
  {
    let when = old.addingTimeInterval(minute * 60)
    return asked(kind, match, yes ? .yes : .no, asked: when, answered: when)
  }
  replayed.questions = [
    answer(.worktree, ["stale": ["week"]], true, 1),
    answer(.process, ["family": ["node"], "idle": ["1h"]], true, 2),
    answer(.disk, ["folder": ["node_modules"], "stale": ["day"]], true, 3),
    answer(.process, ["family": ["java"], "idle": ["1h"]], true, 4),
  ]
  equal(lines(replayed), [], "4 answers are too few to replay")
  replayed.questions.append(answer(.worktree, ["saved": ["merged"], "stale": ["month"]], false, 5))
  equal(
    lines(replayed),
    [
      "Replaying your 5 answers, I'd have asked 4 and handled the other 1 on my own, 1 of them not the way you would have."
    ], "the earlier yes would have burned what the owner kept")
}

/// The snapshot carries both, with burns counted from the impact tally rather than receipts.
private func snapshotProof(_ history: [AutopilotQuestion]) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-groups-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AutopilotStore(root: root)
  let last = history.compactMap(\.answered).max() ?? groupsStart
  let lesson = "rule:" + TeachLessons.q04ID
  let burned = [1, 2, 4].map { gigabytes in
    receipt(lesson, "burned", gigabytes: UInt64(gigabytes), at: last.addingTimeInterval(30))
  }
  for receipt in burned { try store.append(receipt) }
  try store.updateReceipts { all in
    if let i = all.firstIndex(where: { $0.id == burned[2].id }) { all[i].outcome = "restored" }
  }
  // 38 more copies burned long ago, whose receipts are gone; only the tally remembers them.
  var impact = try store.impact()
  equal(impact.worktrees, 2, "the tally counts copies that weren't undone")
  equal(impact.restored, 1, "and the one that was")
  impact.worktrees += 38
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  try encoder.encode(impact).write(to: store.directory.appendingPathComponent("impact.json"))
  try JSONEncoder().encode(teachHistoryVersion1(history)).write(
    to: store.directory.appendingPathComponent("memory.json"))
  let engine = try Autopilot(root: root, sources: AutopilotSources())
  let snapshot = await engine.snapshot(now: last.addingTimeInterval(60))
  let day = snapshot.lessons.first { $0.id == "worktree:burn:day" }
  equal(day?.evidence, "From 11 answers · burned 3 copies, 7.0 GB · undone 1")
  check(
    snapshot.lessons.contains { $0.sentence == "Java helpers serving a port stay while idle less than an hour." },
    "the snapshot lists the lessons")
  equal(
    snapshot.progress.lines,
    [
      "I guessed 9 of your last 10 answers right.",
      "This week: 30 questions, 3.0 GB burned on my own.",
      "You undid 1 of the 41 copies I burned.",
      "Replaying your 27 answers, I'd have asked 17 and handled the other 10 on my own the way you would have.",
    ], "40 copies the tally counts, plus the 1 undone")
}
