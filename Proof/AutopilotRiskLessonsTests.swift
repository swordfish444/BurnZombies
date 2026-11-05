import BurnCore
import Foundation

/// What a card's risks teach (R31, R36, R37): a Yes covers only the risks its card showed; things
/// under the same pattern with a risk no card showed are asked about again, with the risk named;
/// and a No to such a card keeps those things without cancelling the earlier Yes.
func riskLessonsProof() async throws {
  try await answerRisksProof()
  try await reaskProof()
  try await keepNewRisksProof()
  try await keepEveryMemberProof()
}

/// R31: an owner's Yes covers only the risks shown on that card, kept within them the way BZ's own
/// act is. A Yes to clean copies doesn't teach "even with unsaved work"; a Yes to a card that showed
/// small unsaved changes covers small ones and no more. A question from before cards named their
/// risks teaches what it always did.
private func answerRisksProof() async throws {
  let now = Date()
  /// A copy untouched for a week. Clean unless told otherwise: its work is on GitHub and nothing is
  /// unsaved.
  func aged(_ name: String, changes: String = "none") -> AutopilotItem {
    AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, bytes: 600_000_000,
      facts: [
        "repo": "web-app", "place": "patrol6", "saved": "pushed", "changes": changes,
        "stale": "week", "inUse": "no", "thread": "none",
      ], lastUsed: now.addingTimeInterval(-10 * 86_400))
  }
  /// The owner's Yes to the first card about copies, once its burns are done.
  func yes(_ name: String, _ world: TellWorld) async throws
    -> (Autopilot, AutopilotStore, URL, AutopilotQuestion)
  {
    let (engine, store, root) = try tellEngine(name, world, AutopilotMemory())
    guard let card = await engine.tick(now: now).questions.first(where: { $0.kind == .worktree })
    else {
      failTest("\(name): a card about the copies")
      throw StoreError.message("no card")
    }
    let count = world.copies.count
    _ = try await engine.apply(.answer(questionID: card.id, answer: .yes), now: now)
    await eventually { world.burns.all.count == count }
    equal(world.burns.all.count, count, "\(name): the Yes burns the copies on the card")
    return (engine, store, root, card)
  }

  // A clean card. Its Yes teaches nothing about unsaved work.
  let cleanWorld = TellWorld(copies: [aged("fix-login"), aged("dark-mode")])
  let (clean, cleanStore, cleanRoot, cleanCard) = try await yes("yes-clean", cleanWorld)
  defer { try? FileManager.default.removeItem(at: cleanRoot) }
  equal(cleanCard.risks, [], "the card showed no risk")
  guard let cleanLesson = try cleanStore.memory().rules.first(where: { $0.questionID == cleanCard.id })
  else { return failTest("the clean Yes teaches a lesson") }
  equal(cleanLesson.match["changes"], ["none"], "nothing unsaved")
  equal(cleanLesson.match["saved"], ["pushed", "merged"], "work on GitHub")
  equal(cleanLesson.match["inUse"], ["no"])
  equal(cleanLesson.match["stale"], ["week", "month", "older"], "a week or more, as before")
  let cleanSentence = AutopilotPolicy.lessonGroups(try cleanStore.memory()).first?.sentence
  equal(
    cleanSentence,
    "Copies nobody touched for a week are done once their work is on GitHub and nothing is unsaved.",
    "the Got it! sentence says what the card showed")
  cleanWorld.add(aged("big-rewrite", changes: "large"))
  let afterClean = await clean.tick(now: now.addingTimeInterval(60))
  checkFalse(
    cleanWorld.burns.all.contains("worktree:big-rewrite"),
    "a later same-age copy with large unsaved changes isn't burned")
  equal(
    afterClean.entries.first { $0.item.id == "worktree:big-rewrite" }?.status, .unsure,
    "it stays unsure")

  // A card that showed small unsaved changes. Its Yes covers small ones, and not large ones.
  let smallWorld = TellWorld(copies: [aged("tidy-footer"), aged("wip-search", changes: "small")])
  let (small, smallStore, smallRoot, smallCard) = try await yes("yes-small", smallWorld)
  defer { try? FileManager.default.removeItem(at: smallRoot) }
  equal(smallCard.risks, ["changes=small"], "the card showed small unsaved changes")
  let smallLesson = try smallStore.memory().rules.first { $0.questionID == smallCard.id }
  equal(smallLesson?.match["changes"], ["small", "none"], "small unsaved changes and none")
  equal(
    AutopilotPolicy.lessonGroups(try smallStore.memory()).first?.sentence,
    "Copies nobody touched for a week are done once their work is on GitHub, even with a few unsaved changes.",
    "a lesson that covers small changes only says so")
  smallWorld.add(aged("half-done", changes: "small"))
  smallWorld.add(aged("rewrite", changes: "large"))
  _ = await small.tick(now: now.addingTimeInterval(60))
  check(smallWorld.burns.all.contains("worktree:half-done"), "a later copy with small changes burns")
  checkFalse(
    smallWorld.burns.all.contains("worktree:rewrite"), "a later copy with large changes doesn't")

  // A question from before cards named their risks teaches what it always did.
  var legacy = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["week"]],
    question: "Can I burn old project copies untouched for a week?", why: "", examples: [],
    count: 2, bytes: 1_200_000_000, asked: now)
  legacy.cautions = nil
  isNil(legacy.risks)
  let legacyLesson = AutopilotPolicy.lesson(for: legacy, verdict: .burn, created: now)
  equal(
    legacyLesson.match, AutopilotPolicy.lessonMatch(.worktree, ["stale": ["week"]], verdict: .burn),
    "the general lesson, unnarrowed")
  equal(legacyLesson.match, ["stale": ["week", "month", "older"]])
  let legacyWorld = TellWorld(copies: [aged("old-a"), aged("old-b")])
  let (legacyEngine, legacyStore, legacyRoot) = try tellEngine(
    "yes-legacy", legacyWorld, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: legacyRoot) }
  try legacyStore.updateMemory { $0.questions = [legacy] }
  _ = try await legacyEngine.apply(.answer(questionID: legacy.id, answer: .yes), now: now)
  let taught = try legacyStore.memory().rules.first { $0.questionID == legacy.id }
  equal(taught?.match, legacyLesson.match, "the engine teaches it the same")
  legacyWorld.add(aged("old-rewrite", changes: "large"))
  _ = await legacyEngine.tick(now: now.addingTimeInterval(60))
  await eventually { legacyWorld.burns.all.contains("worktree:old-rewrite") }
  check(
    legacyWorld.burns.all.contains("worktree:old-rewrite"),
    "and it still burns what it always did")
}

/// R36: a native question's identity includes the risks its card shows, so a pattern the owner
/// answered for one set of risks is asked again when things under it carry a risk that card didn't
/// show, and the new card names it. An answer from before cards named their risks keeps its
/// pattern answered, as before. The 1 GB minimum still holds, and the guess leans yes but isn't
/// sure of a risk the owner never said yes to.
private func reaskProof() async throws {
  let now = Date()
  /// A Java program idle for `idle`; a server when `listening`.
  func java(_ name: String, idle: String, listening: Bool, bytes: UInt64) -> AutopilotItem {
    AutopilotItem(
      id: "process:" + name, kind: .process, name: name, bytes: bytes,
      facts: [
        "family": "java", "orphaned": "maybe", "thread": "none", "idle": idle,
        "listening": listening ? "yes" : "no", "agent": "codex",
      ], processKey: name)
  }
  let pattern: [String: [String]] = ["family": ["java"], "idle": ["10m"]]
  let key: String = AutopilotRule.key(kind: .process, match: pattern)
  let servers: [AutopilotItem] = [
    java("gradle-daemon", idle: "10m", listening: true, bytes: 500_000_000),
    java("kotlin-daemon", idle: "10m", listening: true, bytes: 500_000_000),
    java("jetty-dev", idle: "1h", listening: true, bytes: 500_000_000),
  ]

  // The owner says yes to Java programs that serve nothing, while BZ already trusts itself on
  // them: the card's id names the one risk it showed.
  let world = TellWorld(
    programs: [
      java("maven-build", idle: "10m", listening: false, bytes: 600_000_000),
      java("test-runner", idle: "1h", listening: false, bytes: 600_000_000),
    ])
  var trusted = AutopilotMemory()
  trusted.scores = (0..<AutopilotPolicy.trustStreak).map { i in
    AutopilotScore(
      questionID: "java-\(i)", subject: "process:java", guess: .yes, answer: .yes, right: true,
      date: now.addingTimeInterval(Double(i - 10)), replayed: true)
  }
  let (engine, store, root) = try tellEngine("reask", world, trusted)
  defer { try? FileManager.default.removeItem(at: root) }
  guard let first = await engine.tick(now: now).questions.first(where: { $0.kind == .process })
  else { return failTest("a question about the Java programs") }
  equal(first.match, pattern)
  equal(first.risks, ["idle=10m"])
  equal(first.id, key + ":idle=10m", "the id names the risks its card shows")
  _ = try await engine.apply(.answer(questionID: first.id, answer: .yes), now: now)
  await eventually { world.burns.all.count == 2 }
  equal(world.burns.all.count, 2, "the yes burns both")

  // Three Java servers show up, idle 10 minutes to an hour. The yes kept to programs that serve
  // nothing, so they are unsure, and asked about under the same pattern.
  for server in servers { world.add(server) }
  let later = await engine.tick(now: now.addingTimeInterval(60))
  check(later.tells.isEmpty, "BZ is trusted on Java programs, but a server is new: it asks")
  guard let again = later.questions.first(where: { $0.kind == .process }) else {
    return failTest("the Java servers are asked about")
  }
  equal(again.match, pattern, "the same pattern")
  equal(again.count, 3)
  equal(again.risks, ["idle=10m", "listening=yes"])
  equal(again.id, key + ":idle=10m,listening=yes", "a question of its own")
  let card = AutopilotPolicy.card(again)
  check(
    card.cautions.contains("3 are still running a server"),
    "the card names the new risk: \(card.cautions)")
  equal(again.guess?.answer, .yes, "BZ leans yes")
  equal(again.guess?.sure, false, "but isn't sure of a server the owner never said yes to")
  _ = try await engine.apply(.answer(questionID: again.id, answer: .yes), now: now)
  await eventually { world.burns.all.count == 5 }
  equal(Set(world.burns.all), Set(world.programs.map(\.id)), "the yes burns the servers too")
  let lessons = try store.memory().rules.filter { $0.kind == .process }
  equal(lessons.count, 1, "the wider lesson takes the first one in")
  equal(
    Set(lessons.first.map(AutopilotPolicy.questionIDs) ?? []), [first.id, again.id],
    "with both answers behind it")
  equal(lessons.first?.match["listening"], ["yes", "no"], "servers and programs serving nothing")

  // Straight from the policy: an answer from before cards named their risks keeps its pattern
  // answered, as before, so nothing is asked again.
  var legacy = AutopilotQuestion(
    kind: .process, match: pattern, question: "Can I burn leftover Java and Gradle helpers?",
    why: "", examples: [], count: 2, bytes: 1_200_000_000, asked: now)
  legacy.answer = .yes
  legacy.answered = now
  isNil(legacy.risks)
  equal(legacy.id, key, "a legacy id has no risk suffix")
  var before = AutopilotMemory()
  before.questions = [legacy]
  let none = AutopilotPolicy.proposeQuestions(servers, memory: before, now: now)
  checkFalse(none.contains { $0.kind == .process }, "a legacy answer keeps its pattern answered")
  var shown = legacy
  shown.risks = ["idle=10m"]
  var newer = AutopilotMemory()
  newer.questions = [shown]
  let asked = AutopilotPolicy.proposeQuestions(servers, memory: newer, now: now)
  equal(asked.map(\.id), [key + ":idle=10m,listening=yes"], "a newer answer covers what it showed")
  // A card whose risks changed while it was open keeps the id it was made with. A question asked
  // again never takes the id of one the owner answered: the answer would land on the old one.
  var shrunk = shown
  shrunk.id = key + ":idle=10m,listening=yes"
  var renamed = AutopilotMemory()
  renamed.questions = [shrunk]
  let numbered = AutopilotPolicy.proposeQuestions(servers, memory: renamed, now: now)
  equal(numbered.map(\.id), [key + ":idle=10m,listening=yes#2"], "a fresh id")
  // The 1 GB minimum still holds: one server alone isn't worth a question.
  let alone = AutopilotPolicy.proposeQuestions([servers[0]], memory: newer, now: now)
  equal(alone.count, 0, "half a GB isn't worth asking about")
  // Sure only of risks the owner said yes to before: a yes on servers idle an hour approved them.
  if var question = asked.first {
    var approved = newer
    var hour = AutopilotQuestion(
      kind: .process, match: ["family": ["java"], "idle": ["1h"]], question: "", why: "",
      examples: [], count: 1, bytes: 1_000_000_000, asked: now)
    hour.answer = .yes
    hour.answered = now
    hour.risks = ["listening=yes"]
    approved.questions.append(hour)
    approved.scores = trusted.scores
    question.guess = AutopilotPolicy.guess(question, memory: approved)
    equal(question.guess?.sure, true, "with servers approved before and trust earned, BZ is sure")
  } else {
    failTest("a question to guess")
  }

  // A clean card's yes: copies with large unsaved changes at the same age are asked about next,
  // and their card says so.
  func aged(_ name: String, changes: String) -> AutopilotItem {
    AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, bytes: 600_000_000,
      facts: [
        "repo": "web-app", "place": "patrol6", "saved": "pushed", "changes": changes,
        "stale": "week", "inUse": "no", "thread": "none",
      ], lastUsed: now.addingTimeInterval(-10 * 86_400))
  }
  let week: [String: [String]] = ["stale": ["week"]]
  var clean = AutopilotQuestion(
    kind: .worktree, match: week, question: "", why: "", examples: [], count: 2,
    bytes: 1_200_000_000, asked: now)
  clean.answer = .yes
  clean.answered = now
  clean.risks = []
  var cleanYes = AutopilotMemory()
  cleanYes.questions = [clean]
  let rewrites = [aged("rewrite-a", changes: "large"), aged("rewrite-b", changes: "large")]
  let copies = AutopilotPolicy.proposeQuestions(rewrites, memory: cleanYes, now: now)
  equal(
    copies.map(\.id), [AutopilotRule.key(kind: .worktree, match: week) + ":changes=large"],
    "asked again about the copies with unsaved changes")
  equal(copies.first?.cautions, ["2 have lots of unsaved changes"], "and the card says so")
  // Copies BZ couldn't check are a risk the clean card didn't show either, and their card says so.
  var unchecked = aged("unchecked-a", changes: "none")
  unchecked.facts["saved"] = "unknown"
  var unread = aged("unchecked-b", changes: "unknown")
  unread.facts["saved"] = "unknown"
  let unknowns = AutopilotPolicy.proposeQuestions([unchecked, unread], memory: cleanYes, now: now)
  equal(
    unknowns.map(\.id),
    [AutopilotRule.key(kind: .worktree, match: week) + ":changes=unknown,saved=unknown"],
    "asked again about the copies BZ couldn't check")
  equal(unknowns.first?.cautions, ["2 couldn't be checked"], "and the card says so")
}

/// R37: a No to a card asked again for new risks keeps only the things carrying them. A wide keep
/// would also cover the things the owner already said yes to at that age, and keeps beat burns.
private func keepNewRisksProof() async throws {
  let now = Date()
  /// A Java helper idle for an hour; a server when `listening`.
  func helper(_ name: String, listening: Bool, bytes: UInt64) -> AutopilotItem {
    AutopilotItem(
      id: "process:" + name, kind: .process, name: name, bytes: bytes,
      facts: [
        "family": "java", "orphaned": "maybe", "thread": "none", "idle": "1h",
        "listening": listening ? "yes" : "no", "agent": "codex",
      ], processKey: name)
  }
  let pattern: [String: [String]] = ["family": ["java"], "idle": ["1h"]]
  let key: String = AutopilotRule.key(kind: .process, match: pattern)
  let world = TellWorld(
    programs: [
      helper("gradle-a", listening: false, bytes: 600_000_000),
      helper("gradle-b", listening: false, bytes: 600_000_000),
    ])
  let (engine, store, root) = try tellEngine("keep-new-risks", world, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: root) }

  // Yes to clean Java helpers idle an hour.
  guard let clean = await engine.tick(now: now).questions.first(where: { $0.kind == .process })
  else { return failTest("a question about the clean Java helpers") }
  equal(clean.match, pattern)
  equal(clean.risks, [], "nothing risky about them")
  _ = try await engine.apply(.answer(questionID: clean.id, answer: .yes), now: now)
  await eventually { world.burns.all.count == 2 }
  equal(world.burns.all.count, 2, "the yes burns them")

  // Three servers at the same age are asked about again, and the owner says No.
  let servers: [AutopilotItem] = ["jetty-a", "jetty-b", "jetty-c"].map {
    helper($0, listening: true, bytes: 500_000_000)
  }
  for server in servers { world.add(server) }
  let asked = await engine.tick(now: now.addingTimeInterval(60))
  guard let again = asked.questions.first(where: { $0.kind == .process }) else {
    return failTest("the servers are asked about again")
  }
  equal(again.id, key + ":listening=yes")
  check(
    AutopilotPolicy.card(again).cautions.contains("3 are still running a server"),
    "the card says they serve a port")
  let answered = try await engine.apply(.answer(questionID: again.id, answer: .no), now: now)
  for server in servers {
    equal(
      answered.entries.first { $0.item.id == server.id }?.status, .keep,
      "\(server.name) serves a port and is kept")
  }
  let keeps = try store.memory().rules.filter { $0.questionID == again.id }
  equal(keeps.count, 1, "one keep for the one risk the card showed for the first time")
  equal(keeps.first?.verdict, .keep)
  equal(keeps.first?.match["listening"], ["yes"], "only things serving a port")
  let sentence: String? = AutopilotPolicy.lessonGroups(try store.memory()).first {
    $0.verdict == .keep
  }?.sentence
  equal(sentence, "Java helpers serving a port stay while idle less than 6 hours.")

  // Clean helpers at that age still burn under the earlier Yes; no server burns.
  world.add(helper("gradle-c", listening: false, bytes: 600_000_000))
  world.add(helper("gradle-d", listening: false, bytes: 600_000_000))
  _ = await engine.tick(now: now.addingTimeInterval(120))
  check(
    world.burns.all.contains("process:gradle-c") && world.burns.all.contains("process:gradle-d"),
    "clean helpers at that age still burn under the earlier Yes: \(world.burns.all)")
  checkFalse(world.burns.all.contains { $0.hasPrefix("process:jetty") }, "no server burns")

  // Two risks shown for the first time: the No keeps copies carrying either one, each by a keep of
  // its own, and they read and are forgotten as one lesson. A clean copy at that age still burns.
  func aged(_ name: String, saved: String, changes: String) -> AutopilotItem {
    AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, bytes: 600_000_000,
      facts: [
        "repo": "web-app", "place": "patrol6", "saved": saved, "changes": changes,
        "stale": "week", "inUse": "no", "thread": "none",
      ], lastUsed: now.addingTimeInterval(-10 * 86_400))
  }
  let copies = TellWorld(
    copies: [
      aged("fix-login", saved: "pushed", changes: "none"),
      aged("dark-mode", saved: "merged", changes: "none"),
    ])
  let (copyEngine, copyStore, copyRoot) = try tellEngine("keep-two-risks", copies, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: copyRoot) }
  guard let first = await copyEngine.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("a question about the clean copies") }
  _ = try await copyEngine.apply(.answer(questionID: first.id, answer: .yes), now: now)
  await eventually { copies.burns.all.count == 2 }
  copies.add(aged("local-draft", saved: "local", changes: "none"))
  copies.add(aged("big-rewrite", saved: "pushed", changes: "large"))
  let risky = await copyEngine.tick(now: now.addingTimeInterval(60))
  guard let twice = risky.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("the risky copies are asked about again")
  }
  equal(twice.risks, ["changes=large", "saved=local"])
  let refused = try await copyEngine.apply(.answer(questionID: twice.id, answer: .no), now: now)
  for id in ["worktree:local-draft", "worktree:big-rewrite"] {
    equal(refused.entries.first { $0.item.id == id }?.status, .keep, "\(id) is kept")
  }
  let copyMemory = try copyStore.memory()
  let copyKeeps = copyMemory.rules.filter { $0.questionID == twice.id }
  equal(
    Set(copyKeeps.map { $0.match.filter { $0.key != "stale" } }),
    [["saved": ["local"]], ["changes": ["large"]]], "a keep per new risk")
  let keepGroups = AutopilotPolicy.lessonGroups(copyMemory).filter { $0.verdict == .keep }
  equal(keepGroups.count, 1, "read as one lesson")
  equal(
    keepGroups.first?.sentence,
    "Copies used in the last month stay: Work only on this Mac, Has unsaved changes.")
  equal(Set(keepGroups.first?.ruleIDs ?? []), Set(copyKeeps.map(\.id)))
  copies.add(aged("tidy-footer", saved: "pushed", changes: "none"))
  _ = await copyEngine.tick(now: now.addingTimeInterval(120))
  check(copies.burns.all.contains("worktree:tidy-footer"), "a clean copy at that age still burns")
  checkFalse(
    copies.burns.all.contains("worktree:local-draft")
      || copies.burns.all.contains("worktree:big-rewrite"), "the kept copies stay")
  // Forgetting either keep forgets the answer and both keeps.
  guard let one = copyKeeps.first else { return failTest("a keep to forget") }
  _ = try await copyEngine.apply(.forgetRule(ruleID: one.id), now: now)
  let forgotten = try copyStore.memory()
  checkFalse(forgotten.rules.contains { $0.questionID == twice.id }, "both keeps are forgotten")
  checkFalse(forgotten.questions.contains { $0.id == twice.id }, "with the answer")
}

/// R38: a No keeps every thing on its card at the card's age. When the keeps for its new risks
/// would leave one out, the No keeps the things carrying any risk the card showed, and failing that
/// everything at that age. An Undo of BZ's own call follows the same rule. Either way a clean copy
/// at that age still burns under the owner's earlier Yes.
private func keepEveryMemberProof() async throws {
  let now = Date()
  /// A copy untouched for a week.
  func aged(_ name: String, saved: String, changes: String) -> AutopilotItem {
    AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, bytes: 600_000_000,
      facts: [
        "repo": "web-app", "place": "patrol6", "saved": saved, "changes": changes,
        "stale": "week", "inUse": "no", "thread": "none",
      ], lastUsed: now.addingTimeInterval(-10 * 86_400))
  }
  func status(_ snapshot: AutopilotSnapshot, _ name: String) -> AutopilotStatus? {
    snapshot.entries.first { $0.item.id == "worktree:" + name }?.status
  }
  let world = TellWorld(
    copies: [
      aged("local-a", saved: "local", changes: "none"),
      aged("local-b", saved: "local", changes: "none"),
    ])
  let (engine, _, root) = try tellEngine("keep-every-member", world, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: root) }

  // L1: yes to copies with work only on this Mac and nothing unsaved.
  guard let q1 = await engine.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("a question about the copies with work only on this Mac") }
  equal(q1.risks, ["saved=local"])
  _ = try await engine.apply(.answer(questionID: q1.id, answer: .yes), now: now)
  await eventually { world.burns.all.count == 2 }
  // L2: copies with small unsaved changes are asked about again, and the owner says yes.
  world.add(aged("small-a", saved: "pushed", changes: "small"))
  world.add(aged("small-b", saved: "merged", changes: "small"))
  guard
    let q2 = await engine.tick(now: now.addingTimeInterval(60)).questions.first(where: {
      $0.kind == .worktree
    })
  else { return failTest("the copies with small unsaved changes are asked about again") }
  equal(q2.risks, ["changes=small"])
  _ = try await engine.apply(.answer(questionID: q2.id, answer: .yes), now: now)
  await eventually { world.burns.all.count == 4 }
  equal(world.burns.all.count, 4)

  // m1 carries both risks the owner said yes to, never together; m2 has large unsaved changes.
  // Only large changes are new, so a keep for them alone would leave m1 unkept.
  world.add(aged("m1", saved: "local", changes: "small"))
  world.add(aged("m2", saved: "pushed", changes: "large"))
  guard
    let q3 = await engine.tick(now: now.addingTimeInterval(120)).questions.first(where: {
      $0.kind == .worktree
    })
  else { return failTest("m1 and m2 are asked about") }
  equal(q3.risks, ["changes=large", "changes=small", "saved=local"])
  let refused = try await engine.apply(.answer(questionID: q3.id, answer: .no), now: now)
  equal(status(refused, "m1"), .keep, "the No keeps m1")
  equal(status(refused, "m2"), .keep, "and m2")
  world.add(aged("clean", saved: "pushed", changes: "none"))
  _ = await engine.tick(now: now.addingTimeInterval(180))
  check(world.burns.all.contains("worktree:clean"), "a clean copy at that age still burns")
  checkFalse(
    world.burns.all.contains("worktree:m1") || world.burns.all.contains("worktree:m2"),
    "the copies the owner said no to stay")

  // An Undo of BZ's own call follows the same rule. The owner said yes to clean copies untouched
  // for a week and to copies with work only on this Mac untouched for a month, and BZ trusts
  // itself on copies: copies with work only on this Mac untouched for a week are asked about again,
  // and BZ answers yes itself.
  func owned(_ match: [String: [String]], risks: [String]) -> AutopilotQuestion {
    var question = AutopilotQuestion(
      kind: .worktree, match: match, question: "Can I burn these old copies?", why: "",
      examples: [], count: 2, bytes: 1_200_000_000, asked: now.addingTimeInterval(-86_400))
    question.answer = .yes
    question.answered = now.addingTimeInterval(-86_400)
    question.risks = risks
    return question
  }
  var memory = AutopilotMemory()
  memory.questions = [
    owned(["stale": ["week"]], risks: []),
    owned(["saved": ["local"], "stale": ["month"]], risks: ["saved=local"]),
  ]
  for question in memory.questions {
    AutopilotPolicy.learn(
      AutopilotPolicy.lesson(for: question, verdict: .burn, created: now), into: &memory.rules)
  }
  memory.scores = (0..<AutopilotPolicy.trustStreak).map { i in
    AutopilotScore(
      questionID: "replayed-\(i)", subject: "worktree:", guess: .yes, answer: .yes, right: true,
      date: now.addingTimeInterval(Double(i - 10)), replayed: true)
  }
  let actWorld = TellWorld(
    copies: [
      aged("draft-a", saved: "local", changes: "none"),
      aged("draft-b", saved: "local", changes: "none"),
    ])
  let (actEngine, actStore, actRoot) = try tellEngine("undo-every-member", actWorld, memory)
  defer { try? FileManager.default.removeItem(at: actRoot) }
  guard let tell = await actEngine.tick(now: now).tells.first else {
    return failTest("BZ acts on the copies with work only on this Mac")
  }
  equal(actWorld.burns.all.count, 2)
  _ = try await actEngine.apply(.tellUndo(id: tell.id), now: now)
  let undone = try actStore.memory().rules.filter { $0.questionID == tell.questionID }
  equal(undone.map(\.verdict), [.keep], "the Undo teaches one keep")
  equal(undone.first?.match["saved"], ["local"], "for copies with work only on this Mac")
  actWorld.add(aged("tidy", saved: "pushed", changes: "none"))
  actWorld.add(aged("draft-c", saved: "local", changes: "none"))
  let after = await actEngine.tick(now: now.addingTimeInterval(60))
  check(actWorld.burns.all.contains("worktree:tidy"), "a clean copy at that age still burns")
  equal(status(after, "draft-c"), .keep, "a copy with work only on this Mac at that age is kept")
}

