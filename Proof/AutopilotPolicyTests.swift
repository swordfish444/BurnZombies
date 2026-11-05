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

  // Ages name their lower bound, so the words match what a "yes" covers.
  equal(
    AutopilotPolicy.wording(kind: .worktree, match: ["saved": ["merged"], "stale": ["week"]]),
    "Can I burn old project copies already merged, untouched for a week?")
  equal(
    AutopilotPolicy.wording(kind: .worktree, match: ["saved": ["merged"], "stale": ["day"]]),
    "Can I burn old project copies already merged, untouched since yesterday?")
  equal(
    AutopilotPolicy.wording(kind: .worktree, match: ["saved": ["merged"], "stale": ["older"]]),
    "Can I burn old project copies already merged, untouched for 3 months?")
  equal(
    AutopilotPolicy.wording(
      kind: .disk,
      match: ["folder": ["package-cache"], "home": ["global-cache"], "stale": ["week"]]),
    "Can I delete tool caches on your Mac that weren't touched in a week? They get rebuilt when needed."
  )
  equal(
    AutopilotPolicy.widen(["stale": ["day"]], verdict: .burn)["stale"],
    ["day", "week", "month", "older"], "a yes also covers copies left longer")

  // Only things worth it are assessed: 100 MB or more, or a program keeping a CPU busy.
  check(AutopilotPolicy.worthAssessing(copy("big", [:], bytes: 150_000_000)), "150 MB copy")
  checkFalse(AutopilotPolicy.worthAssessing(copy("small", [:], bytes: 20_000_000)), "20 MB copy")
  checkFalse(AutopilotPolicy.worthAssessing(copy("unmeasured", [:], bytes: 0)), "unmeasured copy")
  checkFalse(AutopilotPolicy.worthAssessing(junk("crumbs", [:], bytes: 99_000_000)), "99 MB folder")
  checkFalse(
    AutopilotPolicy.worthAssessing(process("calm", ["cpu": "calm"], bytes: 30 << 20)),
    "small quiet program")
  check(
    AutopilotPolicy.worthAssessing(process("hot", ["cpu": "busy"], bytes: 30 << 20)),
    "small program keeping a CPU busy")

  // Questions go where the space is, and a pattern freeing under 1 GB isn't worth one.
  let finishedFacts = [
    "place": "sibling", "saved": "merged", "changes": "none", "stale": "month", "thread": "none",
  ]
  var pushedFacts = finishedFacts
  pushedFacts["saved"] = "pushed"
  let many = (0..<30).map { copy("many\($0)", finishedFacts, bytes: 150_000_000) }
  let few = (0..<2).map { copy("few\($0)", pushedFacts, bytes: 5_000_000_000) }
  let crumbs = (0..<5).map {
    junk("crumbs\($0)", ["folder": "node_modules", "home": "repo", "stale": "month"], bytes: 150_000_000)
  }
  // A question reads as a short headline, what it frees, a few short facts and one line
  // of reassurance: little to read and easy to decide.
  let agentCopies = AutopilotQuestion(
    kind: .worktree, match: ["saved": ["pushed"], "stale": ["week"], "place": ["patrol6"]],
    question: "Can I burn old project copies made by Patrol6 agents?", why: "", examples: [],
    count: 92, bytes: 14_390_000_000)
  let copiesCard = AutopilotPolicy.card(agentCopies)
  equal(copiesCard.headline, "Burn 92 copies unused for a week?")
  equal(copiesCard.frees, "Frees 14.4 GB")
  equal(
    copiesCard.facts, ["Saved on GitHub", "Made by Patrol6 agents"],
    "how long they sat unused is in the headline")
  equal(copiesCard.note, "Each one is backed up first, so you can undo it.")
  equal([copiesCard.yes, copiesCard.no], ["Yes, burn them", "No, keep them"])
  equal(copiesCard.cautions, [], "nothing risky about pushed copies left a week")
  let draftCopies = AutopilotQuestion(
    kind: .worktree, match: ["saved": ["local"], "changes": ["small"], "stale": ["day"]],
    question: "", why: "", examples: [], count: 2, bytes: 57_300_000_000)
  equal(
    AutopilotPolicy.card(draftCopies).cautions,
    ["Work only on this Mac", "Has unsaved changes"], "what makes burning riskier stands out")
  let lonelyServer = AutopilotQuestion(
    kind: .process, match: ["family": ["node"], "idle": ["1d"], "listening": ["yes"]],
    question: "", why: "", examples: [], count: 1, bytes: 3_200_000_000)
  let serverCard = AutopilotPolicy.card(lonelyServer)
  equal(serverCard.headline, "Burn 1 leftover Node program?")
  equal(serverCard.frees, "Frees 3.2 GB of memory")
  equal(serverCard.facts, ["Still running a server", "Idle 1+ day"])
  equal(serverCard.note, "It just gets asked to quit.")
  equal([serverCard.yes, serverCard.no], ["Yes, burn it", "No, keep it"])
  let caches = AutopilotQuestion(
    kind: .disk, match: ["folder": ["package-cache"], "home": ["global-cache"], "stale": ["day"]],
    question: "", why: "", examples: [], count: 5, bytes: 20_290_000_000)
  let cachesCard = AutopilotPolicy.card(caches)
  equal(cachesCard.headline, "Burn 5 tool caches unused since yesterday?")
  equal(cachesCard.facts, [], "its age is in the headline")
  equal(cachesCard.note, "Your tools rebuild them when needed.")
  equal(
    AutopilotPolicy.ruleTitle(agentCopies, answer: .yes),
    "Burn: Old project copies · Saved on GitHub · Unused for a week · Made by Patrol6 agents")
  equal(
    AutopilotPolicy.ruleTitle(lonelyServer, answer: .no),
    "Keep: Leftover Node programs · Still running a server · Idle 1+ day")
  // A question about one project names it, so the owner knows which copies or programs.
  let gameCopies = AutopilotQuestion(
    kind: .worktree,
    match: ["repo": ["frontier-rpg"], "changes": ["large"], "stale": ["day"], "place": ["other"]],
    question: "", why: "", examples: [], count: 2, bytes: 3_200_000_000)
  equal(
    AutopilotPolicy.card(gameCopies).headline,
    "Burn 2 copies of frontier-rpg unused since yesterday?")
  equal(
    AutopilotPolicy.ruleTitle(gameCopies, answer: .yes),
    "Burn: Old copies of frontier-rpg · Has lots of unsaved changes · Unused since yesterday")
  let orbitServers = AutopilotQuestion(
    kind: .process, match: ["family": ["node"], "repo": ["orbit-web"], "idle": ["1d"]],
    question: "", why: "", examples: [], count: 3, bytes: 3_000_000_000)
  equal(AutopilotPolicy.card(orbitServers).headline, "Burn 3 leftover Node programs in orbit-web?")
  let modules = AutopilotQuestion(
    kind: .disk, match: ["folder": ["node_modules"], "stale": ["day"], "home": ["repo"]],
    question: "", why: "", examples: [], count: 9, bytes: 4_000_000_000)
  equal(
    AutopilotPolicy.ruleTitle(modules, answer: .yes),
    "Burn: node_modules folders · Unused since yesterday · Inside your projects",
    "a folder's real name keeps its case")

  let valued = AutopilotPolicy.proposeQuestions(many + few + crumbs, memory: AutopilotMemory())
  equal(valued.map(\.count), [32], "all old copies in one question")
  checkFalse(valued.contains { $0.kind == .disk }, "750 MB of folders isn't worth a question")

  // One question per subject, as broad as it can be: three kinds of old copies make one
  // question, and what makes some of them riskier shows as counts on its card.
  let mixed =
    (0..<6).map {
      copy(
        "merged-\($0)",
        ["place": "sibling", "saved": "merged", "changes": "none", "stale": "day", "thread": "none"])
    }
    + (0..<3).map {
      copy(
        "pushed-\($0)",
        ["place": "patrol6", "saved": "pushed", "changes": "none", "stale": "week", "thread": "none"])
    }
    + (0..<2).map {
      copy(
        "draft-\($0)",
        ["place": "other", "saved": "local", "changes": "small", "stale": "month", "thread": "none"])
    }
  let single = AutopilotPolicy.proposeQuestions(mixed, memory: AutopilotMemory())
  equal(single.count, 1, "old project copies get one question")
  equal(single.first?.match, ["stale": ["day"]], "as broad as it can be")
  equal(single.first?.count, 11, "a yes covers every copy left at least a day")
  equal(single.first?.cautions, ["2 have work only on this Mac", "2 have unsaved changes"])
  let singleCard = AutopilotPolicy.card(single.first!)
  equal(singleCard.headline, "Burn 11 copies unused since yesterday?")
  equal(singleCard.facts, ["2 have work only on this Mac", "2 have unsaved changes"])
  equal(singleCard.cautions, singleCard.facts, "both need care")
  // A no keeps the recent ones; the next question is about the older copies only.
  var declined = AutopilotMemory()
  declined.questions = single
  declined.questions[0].answer = .no
  declined.rules = [
    AutopilotRule(
      kind: .worktree, match: AutopilotPolicy.widen(single[0].match, verdict: .keep),
      verdict: .keep, source: .operator, title: "")
  ]
  let narrower = AutopilotPolicy.proposeQuestions(
    mixed.filter { AutopilotPolicy.decide($0, memory: declined).status == .unsure },
    memory: declined)
  equal(narrower.map(\.match), [["stale": ["week"]]], "older copies only")
  equal(narrower.first?.count, 5)
  // Programs: one question per kind of program, by how long they sat idle.
  let javas =
    (0..<2).map {
      process(
        "java-\($0)",
        [
          "family": "java", "orphaned": "yes", "thread": "none", "idle": "10m", "listening": "yes",
          "agent": "codex",
        ], bytes: 1 << 30)
    } + [
      process(
        "java-old",
        [
          "family": "java", "orphaned": "yes", "thread": "none", "idle": "1h", "listening": "no",
          "agent": "none",
        ], bytes: 1 << 30)
    ]
  let javaQuestions = AutopilotPolicy.proposeQuestions(javas, memory: AutopilotMemory())
  equal(javaQuestions.map(\.match), [["family": ["java"], "idle": ["10m"]]])
  equal(javaQuestions.first?.cautions, ["2 are still running a server"])

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
          "thread": "ended", "inUse": "no",
        ], bytes: 2 << 30))
  }
  for i in 0..<10 {
    unsure.append(
      process(
        "py-\(i)",
        [
          "family": "python", "orphaned": "yes", "thread": "none", "idle": "1h",
          "listening": "yes", "agent": "none",
        ], bytes: 200 << 20))
  }
  for i in 0..<5 {
    unsure.append(junk("cache-\(i)", ["folder": "package-cache", "home": "repo", "stale": "week"]))
  }
  var questions = AutopilotPolicy.proposeQuestions(unsure, memory: memory)
  equal(questions.count, 3, "three questions")
  equal(Set(questions.map(\.kind)), Set(AutopilotKind.allCases), "one per cluster")
  let copies = questions.first { $0.kind == .worktree }!
  equal(copies.count, 40, "covers the whole cluster")
  equal(copies.match, ["stale": ["older"]], "as broad as it can be")
  check(copies.question.hasPrefix("Can I burn old project copies"), copies.question)
  check(copies.question.contains("untouched"), "questions state recency: " + copies.question)
  check(copies.question.count <= 120, "kid-short: " + copies.question)
  check(copies.why.contains("40"), copies.why)
  equal(copies.examples.count, 3)
  let processQuestion = questions.first { $0.kind == .process }!
  check(processQuestion.question.contains("Python"), processQuestion.question)
  memory.questions = questions
  equal(
    AutopilotPolicy.proposeQuestions(unsure, memory: memory).count, 0, "no slots while 3 open")
  var oneOpen = AutopilotMemory()
  oneOpen.questions = [questions.first { $0.kind == .worktree }!]
  checkFalse(
    AutopilotPolicy.proposeQuestions(unsure, memory: oneOpen).contains { $0.kind == .worktree },
    "no second question about copies an open question covers")
  var busy = unsure
  busy.append(
    copy("today", ["place": "patrol6", "saved": "local", "changes": "none", "stale": "today", "thread": "none"]))
  check(
    AutopilotPolicy.proposeQuestions([busy.last!], memory: AutopilotMemory()).isEmpty,
    "nothing touched today is asked about")
  memory.questions[0].answer = .yes
  memory.questions[0].answered = Date()
  // The Yes teaches its lesson, as the engine does, and the lesson covers the copies.
  memory.rules = [
    AutopilotPolicy.lesson(for: memory.questions[0], verdict: .burn, created: Date())
  ]
  let modulesLeft = (0..<3).map {
    junk("modules-\($0)", ["folder": "node_modules", "home": "repo", "stale": "month"])
  }
  let next = AutopilotPolicy.proposeQuestions(unsure + modulesLeft, memory: memory)
  equal(next.map(\.kind), [.disk], "one slot reopens, for another subject")
  checkFalse(next.map(\.id).contains(questions[0].id), "answered pattern never re-asked")
  check(
    AutopilotPolicy.proposeQuestions(unsure, memory: memory).isEmpty,
    "the copies were asked about: no second question about them")
  // An answer settles only what its lessons cover: copies they leave unsure are asked about again,
  // under an id of their own.
  var untaught = memory
  untaught.rules = []
  let again = AutopilotPolicy.proposeQuestions(unsure, memory: untaught).first {
    $0.kind == .worktree
  }
  equal(again?.id, questions[0].id + "#2", "copies no lesson covers are asked again")
  memory.questions[1].answer = .skip
  memory.questions[1].snoozedUntil = Date().addingTimeInterval(86400)
  checkFalse(
    AutopilotPolicy.proposeQuestions(unsure, memory: memory).map(\.id).contains(questions[1].id),
    "skipped pattern hidden until its snooze ends")
  // Asked again once the snooze ends, under an id of its own: an answer must land on the new card,
  // never on the skipped one.
  let reasked: [String] = AutopilotPolicy.proposeQuestions(
    unsure, memory: memory, now: Date().addingTimeInterval(2 * 86400)
  ).map(\.id)
  check(reasked.contains(questions[1].id + "#2"), "snooze expiry allows re-asking: \(reasked)")
  checkFalse(reasked.contains(questions[1].id), "never under the skipped question's id")

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

  // An answer from a caller that doesn't say what its card showed, as the command line sends one,
  // still decodes; one that does keeps the risks.
  let bare = Data(#"{"answer":{"questionID":"q","answer":"yes"}}"#.utf8)
  equal(
    try JSONDecoder().decode(AutopilotCommand.self, from: bare),
    .answer(questionID: "q", answer: .yes, risks: nil))
  let shown = AutopilotCommand.answer(questionID: "q", answer: .no, risks: ["saved=local"])
  equal(try JSONDecoder().decode(AutopilotCommand.self, from: JSONEncoder().encode(shown)), shown)

  // Rule titles are plain English.
  let title = AutopilotPolicy.ruleTitle(copies, answer: .yes)
  check(title.hasPrefix("Burn: Old project copies"), title)

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

  autopilotDetailsProof()
}
