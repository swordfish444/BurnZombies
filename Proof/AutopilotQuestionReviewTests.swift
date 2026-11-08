import BurnCore
import Foundation

/// Questions that stay true while they wait. The owner's card on 8 November 2026 said "Burn 1
/// leftover program idle for 21 minutes?" for a whole day: an Android emulator a chat had left
/// running since the morning before, whose system wakes every few minutes, so its idle time never
/// grew. Now a program's card says how long it has been running; a program BZ knows no family for
/// is asked about by name, so a Yes about it reaches it and no other program; and before a card is
/// shown, what exited or was deleted since the last look leaves it.
func questionReviewProof() async throws {
  runningWordsProof()
  try storedStartProof()
  unknownProgramsProof()
  try await unknownProgramsEngineProof()
  try await recheckProof()
}

private let reviewCalendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

/// Sunday 8 November 2026, 3:20 in the afternoon.
private let reviewNow: Date = {
  let parts = DateComponents(year: 2026, month: 11, day: 8, hour: 15, minute: 20)
  return reviewCalendar.date(from: parts) ?? .distantPast
}()

private func ago(_ seconds: TimeInterval) -> Date { reviewNow.addingTimeInterval(-seconds) }

private let qemu = "qemu-system-aarch64-headless"

/// A leftover program BZ knows no family for, such as an emulator a chat started: its app is gone
/// and it still serves a port.
private func unknownProgram(
  _ id: String, program: String = qemu, idle: String = "10m", bytes: UInt64 = 4_500_000_000,
  started: Date?, used: Date?
) -> AutopilotItem {
  let facts: [String: String] = [
    "program": program, "family": "other", "orphaned": "yes", "thread": "none",
    "agent": "claude", "idle": idle, "listening": "yes", "repo": "none", "memory": "large",
    "cpu": "calm",
  ]
  return AutopilotItem(
    id: "process:" + id, kind: .process, name: program, bytes: bytes, facts: facts,
    observedAt: reviewNow, processKey: id, lastUsed: used, started: started)
}

/// A leftover Node program nothing serves from.
private func nodeProgram(
  _ id: String, idle: String = "1h", bytes: UInt64 = 1_500_000_000, started: Date?, used: Date?
) -> AutopilotItem {
  let facts: [String: String] = [
    "program": "node", "family": "node", "orphaned": "yes", "thread": "none", "agent": "codex",
    "idle": idle, "listening": "no", "repo": "api", "memory": "large", "cpu": "calm",
  ]
  return AutopilotItem(
    id: "process:" + id, kind: .process, name: "node in api", bytes: bytes, facts: facts,
    observedAt: reviewNow, processKey: id, lastUsed: used, started: started)
}

private func subjects(_ questions: [AutopilotQuestion]) -> Set<String> {
  Set(questions.filter(\.isOpen).map { AutopilotPolicy.subject($0.kind, $0.match) })
}

// MARK: How long it has been running

private func runningWordsProof() {
  // The owner's card: one emulator quiet for 21 minutes, the other busy a minute ago.
  let started: Date = ago(23 * 3600 + 20 * 60)
  let quiet = unknownProgram("quiet", started: started, used: ago(21 * 60))
  let busy = unknownProgram(
    "busy", idle: "active", bytes: 6_800_000_000, started: ago(23 * 3600 + 44 * 60),
    used: ago(60))
  let asked = AutopilotPolicy.proposeQuestions([quiet, busy], memory: AutopilotMemory(), now: reviewNow)
  guard let question = asked.first, asked.count == 1 else {
    return failTest("one question about the quiet emulator: \(asked.count)")
  }
  equal(question.count, 1, "the busy one waits until it goes quiet")
  equal(question.started, started, "the question keeps when the program started")
  equal(question.newest, ago(21 * 60), "and when it was last busy")
  let card = AutopilotPolicy.card(question, now: reviewNow, calendar: reviewCalendar)
  equal(card.headline, "Burn 1 leftover qemu program running for 23 hours?")
  equal(card.frees, "Frees 4.5 GB of memory")
  equal(card.line, "Its app is gone.")
  equal(
    card.facts, ["Idle 10+ minutes", "1 is still running a server"],
    "the headline says how long it has run, so how long it sat idle stays among the facts")
  equal(card.cautions, ["Idle 10+ minutes", "1 is still running a server"])

  // A day later it woke up a minute ago, as an emulator does every few minutes. Its idle time is a
  // minute again, but the card says how long it has been running, and that only grows.
  var later = question
  later.newest = ago(-25 * 3600 + 60)
  let tomorrow: Date = reviewNow.addingTimeInterval(25 * 3600)
  equal(
    AutopilotPolicy.card(later, now: tomorrow, calendar: reviewCalendar).headline,
    "Burn 1 leftover qemu program running for 2 days?")

  // Several programs: the one that started last, so the words hold for all of them.
  let node: [AutopilotItem] = [
    nodeProgram("n1", started: ago(5 * 3600), used: ago(2 * 3600)),
    nodeProgram("n2", started: ago(9 * 3600), used: ago(3 * 3600)),
    nodeProgram("n3", started: ago(2 * 86_400), used: ago(7 * 3600)),
  ]
  guard
    let nodeQuestion = AutopilotPolicy.proposeQuestions(
      node, memory: AutopilotMemory(), now: reviewNow
    ).first
  else { return failTest("a question about the Node programs") }
  equal(nodeQuestion.started, ago(5 * 3600), "the youngest start")
  let nodeCard = AutopilotPolicy.card(nodeQuestion, now: reviewNow, calendar: reviewCalendar)
  equal(nodeCard.headline, "Burn 3 leftover Node programs running for 5 hours?")
  equal(nodeCard.facts, ["Idle 1+ hour"])
  equal(nodeCard.cautions, [], "an hour idle is no caution")

  // One BZ never saw start, such as an item saved before it kept starts: the card says how long
  // they sat idle, as it did before.
  var unknownStart = node
  unknownStart[2] = nodeProgram("n3", started: nil, used: ago(7 * 3600))
  guard
    let older = AutopilotPolicy.proposeQuestions(
      unknownStart, memory: AutopilotMemory(), now: reviewNow
    ).first
  else { return failTest("a question about Node programs, one without a start") }
  equal(older.started, nil, "a start is only promised when every program has one")
  equal(
    AutopilotPolicy.card(older, now: reviewNow, calendar: reviewCalendar).headline,
    "Burn 3 leftover Node programs idle for 2 hours?")

  // Copies and folders keep their own words: no start is kept for them.
  equal(nodeQuestion.kind, .process)

  // The details say both: how long it has been running and how long it sat idle.
  let entry = AutopilotEntry(
    item: quiet, status: .unsure, authority: nil, label: quiet.name, why: "", consequence: "")
  let details = AutopilotPolicy.details(
    question, entries: [entry], now: reviewNow, calendar: reviewCalendar)
  let facts: [String] = details.first?.facts.map { $0.label + ": " + $0.value } ?? []
  check(facts.contains("Running for: 23 hours"), "details say how long it has run: \(facts)")
  check(facts.contains("Idle for: 21 min"), "and how long it sat idle: \(facts)")
}

/// A start is kept with a program and its question, but it isn't a fact: it never changes what an
/// AI judgment is bound to, nothing is written while it is unknown, and saves from before load.
private func storedStartProof() throws {
  let plain = unknownProgram("p", started: nil, used: ago(60))
  let dated = unknownProgram("p", started: ago(3600), used: ago(60))
  equal(dated.revision, plain.revision, "a start is not a fact")
  check(dated != plain, "but it is part of the item")
  equal(
    try JSONDecoder().decode(AutopilotItem.self, from: JSONEncoder().encode(dated)), dated,
    "items round-trip with it")
  let saved = try JSONEncoder().encode(plain)
  let object = (try JSONSerialization.jsonObject(with: saved) as? [String: Any]) ?? [:]
  check(object["started"] == nil, "nothing written while unknown")
  equal(try JSONDecoder().decode(AutopilotItem.self, from: saved), plain, "old items still load")

  var question = AutopilotQuestion(
    kind: .process, match: ["family": ["node"], "idle": ["1h"]], question: "", why: "",
    examples: [], count: 1, bytes: 1)
  question.started = ago(3600)
  equal(
    try JSONDecoder().decode(AutopilotQuestion.self, from: JSONEncoder().encode(question)),
    question, "questions round-trip with it")
  let oldJSON =
    #"{"id":"q","kind":"process","match":{},"question":"","why":"","examples":[],"count":0,"bytes":0,"asked":0,"source":"native"}"#
  let old = try JSONDecoder().decode(AutopilotQuestion.self, from: Data(oldJSON.utf8))
  check(old.started == nil, "a question saved before it still loads")
}

// MARK: Programs BZ knows no family for

private func unknownProgramsProof() {
  let emulators: [AutopilotItem] = [
    unknownProgram("e1", started: ago(23 * 3600), used: ago(21 * 60)),
    unknownProgram("e2", bytes: 6_800_000_000, started: ago(24 * 3600), used: ago(15 * 60)),
  ]
  let database = unknownProgram(
    "db", program: "postgres", idle: "1h", bytes: 2_000_000_000, started: ago(3 * 3600),
    used: ago(2 * 3600))
  let asked = AutopilotPolicy.proposeQuestions(
    emulators + [database], memory: AutopilotMemory(), now: reviewNow)
  equal(asked.count, 2, "one question per program, not one for every program BZ doesn't know")
  equal(subjects(asked), ["process:other:" + qemu, "process:other:postgres"])
  guard let emulatorQuestion = asked.first(where: { $0.match["program"] == [qemu] }) else {
    return failTest("a question about the emulators")
  }
  equal(emulatorQuestion.count, 2, "both emulators")
  equal(emulatorQuestion.match["family"], ["other"])
  equal(
    emulatorQuestion.question,
    "Can I burn leftover qemu-system-aarch64-headless programs that sat idle for 10+ minutes?")
  equal(
    AutopilotPolicy.card(emulatorQuestion, now: reviewNow, calendar: reviewCalendar).headline,
    "Burn 2 leftover qemu programs running for 23 hours?",
    "a long name is called by its first part")

  // What a Yes to it covers: these emulators, never the database.
  let yes = AutopilotPolicy.coverage(emulatorQuestion.kind, emulatorQuestion.match)
  check(emulators.allSatisfy { AutopilotPolicy.matches(yes, $0) }, "a Yes covers both emulators")
  checkFalse(AutopilotPolicy.matches(yes, database), "and never the database")

  guard let databaseQuestion = asked.first(where: { $0.match["program"] == ["postgres"] }) else {
    return failTest("a question about the database")
  }
  equal(
    AutopilotPolicy.card(databaseQuestion, now: reviewNow, calendar: reviewCalendar).headline,
    "Burn 1 leftover postgres program running for 3 hours?")

  // A name too long to say, with no short first part, stays a program.
  let odd = unknownProgram(
    "odd", program: "x-the-helper-nobody-can-pronounce", started: ago(3600), used: ago(20 * 60))
  guard
    let oddQuestion = AutopilotPolicy.proposeQuestions(
      [odd], memory: AutopilotMemory(), now: reviewNow
    ).first
  else { return failTest("a question about the odd program") }
  equal(
    AutopilotPolicy.card(oddQuestion, now: reviewNow, calendar: reviewCalendar).headline,
    "Burn 1 leftover program running for an hour?")
  equal(oddQuestion.match["program"], ["x-the-helper-nobody-can-pronounce"], "still only that one")

  // Programs of a known family are one subject, whatever each is called, and an old question
  // about every unknown program keeps the subject its scores were kept under.
  equal(AutopilotPolicy.subject(.process, ["family": ["node"], "program": ["node"]]), "process:node")
  equal(AutopilotPolicy.subject(.process, ["family": ["other"]]), "process:other")
  equal(AutopilotPolicy.subject(.worktree, ["stale": ["week"]]), "worktree:")
}

/// Copies and programs an engine sees, changeable between looks.
private final class ReviewWorld: @unchecked Sendable {
  var programs: [AutopilotItem] = []
  var copies: [AutopilotItem] = []
}

private func reviewRoot(_ name: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-question-review-" + name + "-" + UUID().uuidString)
}

private func unknownProgramsEngineProof() async throws {
  let root = reviewRoot("unknown")
  defer { try? FileManager.default.removeItem(at: root) }
  let world = ReviewWorld()
  let emulators: [AutopilotItem] = [
    unknownProgram("e1", started: ago(23 * 3600), used: ago(21 * 60)),
    unknownProgram("e2", bytes: 6_800_000_000, started: ago(24 * 3600), used: ago(15 * 60)),
  ]
  let database = unknownProgram(
    "db", program: "postgres", idle: "1h", bytes: 2_000_000_000, started: ago(3 * 3600),
    used: ago(2 * 3600))
  world.programs = emulators + [database]

  // An open question asked the old way, about every program BZ doesn't know.
  let store = try AutopilotStore(root: root)
  let broad = AutopilotQuestion(
    kind: .process, match: ["family": ["other"], "idle": ["10m"]],
    question: "Can I burn leftover qemu-system-aarch64-headless programs that sat idle for 10+ minutes?",
    why: "", examples: [qemu], count: 1, bytes: 4_500_000_000, asked: ago(86_400))
  try store.updateMemory { $0.questions.append(broad) }

  let engine = try Autopilot(
    root: root, sources: AutopilotSources(processes: { _ in world.programs }))
  let first = await engine.tick(now: reviewNow)
  checkFalse(first.questions.contains { $0.id == broad.id }, "the broad question gives way")
  equal(subjects(first.questions), ["process:other:" + qemu, "process:other:postgres"])
  guard let emulatorQuestion = first.questions.first(where: { $0.match["program"] == [qemu] }) else {
    return failTest("the emulators' own question")
  }
  equal(emulatorQuestion.count, 2)

  // The owner's Yes teaches BZ about the emulators and nothing else.
  _ = try await engine.apply(.answer(questionID: emulatorQuestion.id, answer: .yes))
  let memory = try store.memory()
  for emulator in emulators {
    equal(AutopilotPolicy.decide(emulator, memory: memory).status, .burn, "a Yes covers \(emulator.id)")
  }
  equal(
    AutopilotPolicy.decide(database, memory: memory).status, .unsure,
    "a Yes about the emulators never reaches the database")
  let lesson = memory.rules.first { $0.verdict == .burn && $0.match["program"] == [qemu] }
  check(lesson != nil, "the lesson names the program: \(memory.rules.map(\.match))")

  // Settings names the lesson by its program, not "Other programs".
  let snapshot = await engine.snapshot(now: reviewNow)
  let programLessons = snapshot.lessons.filter { $0.kind == .process }.map(\.sentence)
  check(
    programLessons.contains { $0.contains("qemu programs") && !$0.contains("Other programs") },
    "the lesson reads as the program: \(programLessons)")

  // The AI may not ask about every unknown program at once either.
  var request = AutopilotRequest(tool: "ask")
  request.question = AutopilotQuestionInput(
    kind: .process, match: ["family": ["other"], "idle": ["1h"]],
    question: "Can I burn leftover programs that sat idle for an hour?")
  let (refused, why) = await engine.handle(request)
  checkFalse(refused, "a question about every unknown program is refused")
  check(why.contains("program"), "the refusal says to name the program: \(why)")

  // Named, it rewords BZ's own question about that program.
  guard let databaseQuestion = first.questions.first(where: { $0.match["program"] == ["postgres"] })
  else { return failTest("the database's own question") }
  request.question = AutopilotQuestionInput(
    kind: .process, match: databaseQuestion.match,
    question: "Can I stop the leftover postgres a chat started 3 hours ago?")
  let (reworded, json) = await engine.handle(request)
  check(reworded, "the AI's words for the database's question: \(json)")
  let after = try store.memory().questions.first { $0.id == databaseQuestion.id }
  equal(after?.question, "Can I stop the leftover postgres a chat started 3 hours ago?")
}

// MARK: Checked before it is shown

private func recheckProof() async throws {
  let root = reviewRoot("recheck")
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appendingPathComponent("copies/old-copy")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  let world = ReviewWorld()
  let emulator = unknownProgram("e1", started: ago(23 * 3600), used: ago(21 * 60))
  world.programs = [emulator]
  world.copies = [
    AutopilotItem(
      id: "worktree:old", kind: .worktree, name: "old-copy", path: folder.path,
      bytes: 2_000_000_000,
      facts: [
        "place": "codex", "repo": "api", "saved": "pushed", "changes": "none", "stale": "week",
        "inUse": "no", "thread": "none",
      ], observedAt: reviewNow, lastUsed: ago(9 * 86_400), title: "fix login")
  ]
  let engine = try Autopilot(
    root: root.appendingPathComponent("state"),
    sources: AutopilotSources(
      processes: { _ in world.programs }, worktrees: { _, _, d in (world.copies, d) }))
  let first = await engine.tick(now: reviewNow)
  equal(first.questions.filter(\.isOpen).count, 2, "a question about the emulator and the copy")

  // Nothing changed: the check leaves every question as it was.
  let same = await engine.recheck(now: reviewNow.addingTimeInterval(30))
  equal(same.questions, first.questions, "nothing to take away")

  // Since the look: the emulator exited, the copy's folder was deleted, and a new program started
  // and went quiet.
  world.programs = [
    nodeProgram("fresh", bytes: 5_000_000_000, started: ago(3 * 3600), used: ago(2 * 3600))
  ]
  try FileManager.default.removeItem(at: folder)
  let checked = await engine.recheck(now: reviewNow.addingTimeInterval(120))
  equal(checked.questions.filter(\.isOpen).count, 0, "no card about something already gone")
  checkFalse(checked.entries.contains { $0.id == emulator.id }, "the emulator left the catalog")
  checkFalse(checked.entries.contains { $0.id == "worktree:old" }, "and so did the copy")
  checkFalse(
    checked.entries.contains { $0.id == "process:fresh" },
    "the check only takes away: a new program waits for the next look")

  // The next look sees the new program and asks about it.
  let next = await engine.tick(now: reviewNow.addingTimeInterval(16 * 60))
  equal(subjects(next.questions), ["process:node"], "the next look asks about the new program")

  // A program busy again since the look comes back as it is now, so it leaves a card about
  // programs that sat idle.
  world.programs = [
    nodeProgram("fresh", idle: "active", bytes: 5_000_000_000, started: ago(3 * 3600), used: ago(30))
  ]
  let busy = await engine.recheck(now: reviewNow.addingTimeInterval(17 * 60))
  equal(busy.questions.filter(\.isOpen).count, 0, "a program busy again leaves its card")
  equal(
    busy.entries.first { $0.id == "process:fresh" }?.item.facts["idle"], "active",
    "and is listed as it is now")
}
