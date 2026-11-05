import BurnCore
import Foundation

/// The question card: which things a question is about, when they were last used, what is safe
/// and what is risky about them, in words an owner can decide on. Day and time words are read in a
/// fixed calendar and time zone, so the proof says the same on any Mac.
private let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

private func cardDate(
  _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
  calendar: Calendar = utc
) -> Date {
  let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
  return calendar.date(from: parts) ?? .distantPast
}

/// Tuesday 3 November 2026, 9:39 in the morning.
private let cardNow = cardDate(2026, 11, 3, 9, 39)

private func daysBefore(_ days: Int, _ date: Date = cardNow) -> Date {
  utc.date(byAdding: .day, value: -days, to: date) ?? .distantPast
}

/// An old copy with the facts a card reads.
private func copyItem(
  _ id: String, title: String?, repo: String = "web-app", bytes: UInt64, used: Date?,
  saved: String = "pushed", changes: String = "none", thread: String = "none",
  stale: String = "day"
) -> AutopilotItem {
  let facts: [String: String] = [
    "place": "codex", "repo": repo, "saved": saved, "changes": changes, "stale": stale,
    "inUse": "no", "thread": thread,
  ]
  return AutopilotItem(
    id: "worktree:" + id, kind: .worktree, name: id, bytes: bytes, facts: facts, lastUsed: used,
    title: title)
}

private func programItem(
  _ id: String, repo: String = "api", agent: String = "codex", listening: String = "no",
  orphaned: String = "yes", bytes: UInt64 = 1_500_000_000, idle: String = "1h", used: Date?
) -> AutopilotItem {
  let facts: [String: String] = [
    "program": "node", "family": "node", "orphaned": orphaned, "thread": "none",
    "agent": agent, "idle": idle, "listening": listening, "repo": repo,
  ]
  // Named the way a real program is: by its name, and by its project when it has one.
  let name = repo == "none" ? "node" : "node in " + repo
  return AutopilotItem(
    id: "process:" + id, kind: .process, name: name, bytes: bytes, facts: facts, lastUsed: used)
}

private func folderItem(_ id: String, bytes: UInt64, used: Date?) -> AutopilotItem {
  let facts: [String: String] = ["folder": "node_modules", "home": "repo", "stale": "week"]
  return AutopilotItem(
    id: "disk:" + id, kind: .disk, name: "node_modules in " + id, bytes: bytes, facts: facts,
    lastUsed: used)
}

func cardProof() async throws {
  try ownerCardProof()
  calendarWordsProof()
  clockProof()
  programWordsProof()
  rowsAndLinesProof()
  humanizeProof()
  try storedFieldsProof()
  try await cardEngineProof()
}

// MARK: The card the owner complained about

/// Five copies used the afternoon before: the card names them and says when.
private func ownerCardProof() throws {
  let items = [
    copyItem(
      "a", title: "fix login selector", bytes: 1_000_000_000, used: cardDate(2026, 11, 2, 17),
      saved: "merged"),
    copyItem(
      "b", title: "add dark mode toggle", bytes: 700_000_000, used: cardDate(2026, 11, 2, 13)),
    copyItem(
      "c", title: "tidy the footer", repo: "docs", bytes: 500_000_000,
      used: cardDate(2026, 11, 2, 19)),
    copyItem("d", title: nil, bytes: 300_000_000, used: cardDate(2026, 11, 1, 10)),
    copyItem(
      "e", title: "rename settings", repo: "api", bytes: 253_368_064,
      used: cardDate(2026, 10, 31, 8)),
  ]
  let proposed = AutopilotPolicy.proposeQuestions(items, memory: AutopilotMemory(), now: cardNow)
  guard let question = proposed.first, proposed.count == 1 else {
    return failTest("one question about the five copies")
  }
  equal(question.count, 5)
  equal(question.bytes, 2_753_368_064)
  let rows = [
    AutopilotQuestionRow(
      title: "fix login selector", subtitle: "web-app", bytes: 1_000_000_000,
      lastUsed: cardDate(2026, 11, 2, 17)),
    AutopilotQuestionRow(
      title: "add dark mode toggle", subtitle: "web-app", bytes: 700_000_000,
      lastUsed: cardDate(2026, 11, 2, 13)),
    AutopilotQuestionRow(
      title: "tidy the footer", subtitle: "docs", bytes: 500_000_000,
      lastUsed: cardDate(2026, 11, 2, 19)),
  ]
  equal(question.rows, rows, "the three biggest, biggest first")
  equal(question.newest, cardDate(2026, 11, 2, 19), "the most recent use among all five")
  equal(question.risks, [], "nothing risky: stored as none, not left unknown")
  equal(question.line, "Their work is on GitHub. Nothing is unsaved.")
  equal(question.examples.count, 3, "examples stay for older readers")

  let card = AutopilotPolicy.card(question, now: cardNow, calendar: utc)
  equal(card.headline, "Burn 5 copies you used yesterday?")
  equal(card.frees, "Frees 2.8 GB")
  equal(card.line, "Their work is on GitHub. Nothing is unsaved.")
  equal(card.rows.map(\.title), ["fix login selector", "add dark mode toggle", "tidy the footer"])
  equal(card.rows.map(\.subtitle), ["web-app", "web-app", "docs"])
  equal(card.rows.map(\.when), ["yesterday 5 pm", "yesterday 1 pm", "yesterday 7 pm"])
  // A tell words its rows through the same public function, so it reads as a question card does.
  equal(
    AutopilotPolicy.cardRows(question.rows ?? [], kind: .worktree, now: cardNow, calendar: utc),
    card.rows, "stored rows give the card's rows")
  let programRows = AutopilotPolicy.cardRows(
    [
      AutopilotQuestionRow(
        title: "node in api", subtitle: "started by Codex", bytes: 1,
        lastUsed: cardNow.addingTimeInterval(-40 * 60)),
      AutopilotQuestionRow(title: "node", bytes: 1),
    ], kind: .process, now: cardNow, calendar: utc)
  equal(programRows.map(\.when), ["idle 40 min", ""], "a program says how long it sat idle")
  equal(programRows.map(\.subtitle), ["started by Codex", nil], "no date, no time")
  equal(card.more, 2)
  equal(card.facts, [], "how long they sat unused is in the headline, not listed again")
  equal(card.cautions, [])
  equal(card.note, "Each one is backed up first, so you can undo it.")
  equal([card.yes, card.no], ["Yes, burn them", "No, keep them"])

  // The words are worked out when the card is shown: the same question reads differently later.
  let later = AutopilotPolicy.card(question, now: cardNow.addingTimeInterval(86_400), calendar: utc)
  equal(later.headline, "Burn 5 copies untouched since Monday?")
  equal(later.rows.map(\.when), ["Mon 5 pm", "Mon 1 pm", "Mon 7 pm"])

  // A question about one project names it; one copy reads in the singular.
  var pinned = question
  pinned.match = ["repo": ["api"], "stale": ["day"]]
  pinned.count = 1
  let pinnedCard = AutopilotPolicy.card(pinned, now: cardNow, calendar: utc)
  equal(pinnedCard.headline, "Burn 1 copy of api you used yesterday?", "a project named")
  pinned.count = 2
  equal(
    AutopilotPolicy.card(pinned, now: cardNow, calendar: utc).headline,
    "Burn 2 copies of api you used yesterday?")
  pinned.match = ["repo": ["api", "docs"], "stale": ["day"]]
  equal(
    AutopilotPolicy.card(pinned, now: cardNow, calendar: utc).headline,
    "Burn 2 copies you used yesterday?", "two projects name neither")
  pinned.match = ["repo": ["none"], "stale": ["day"]]
  equal(
    AutopilotPolicy.card(pinned, now: cardNow, calendar: utc).headline,
    "Burn 2 copies you used yesterday?", "no project is no project")

  // Risks come from every copy a question covers, not only the three shown as rows.
  let risky = [
    copyItem(
      "r1", title: "draft one", bytes: 900_000_000, used: daysBefore(3), saved: "local",
      changes: "small"),
    copyItem("r2", title: "draft two", bytes: 800_000_000, used: daysBefore(4), changes: "large"),
    copyItem("r3", title: "done", bytes: 700_000_000, used: daysBefore(5), saved: "merged"),
  ]
  guard
    let riskyQuestion = AutopilotPolicy.proposeQuestions(
      risky, memory: AutopilotMemory(), now: cardNow
    ).first
  else { return failTest("a question about the risky copies") }
  equal(riskyQuestion.risks, ["changes=large", "changes=small", "saved=local"])
  equal(riskyQuestion.line, nil, "nothing is shared by all three, so nothing is promised")
  equal(riskyQuestion.newest, daysBefore(3))
  let riskyCard = AutopilotPolicy.card(riskyQuestion, now: cardNow, calendar: utc)
  equal(riskyCard.headline, "Burn 3 copies untouched since Saturday?")
  equal(
    riskyCard.cautions,
    ["1 has work only on this Mac", "1 has unsaved changes", "1 has lots of unsaved changes"],
    "counted cautions stay, small and large changes apart, without the age the headline says")
  equal(riskyCard.facts, riskyCard.cautions)
}

// MARK: Days

private func calendarWordsProof() {
  func words(_ newest: Date?, _ match: [String: [String]] = ["stale": ["day"]]) -> String {
    AutopilotPolicy.when(
      .worktree, newest: newest, match: match, now: cardNow, calendar: utc)
  }
  // Calendar days between the day it was used and today, not hours.
  equal(words(cardDate(2026, 11, 3, 0, 10)), "you used today", "ten past midnight is today")
  equal(words(cardDate(2026, 11, 3, 12, 0)), "you used today", "a clock a little ahead is today")
  equal(words(cardDate(2026, 11, 2, 23, 50)), "you used yesterday", "ten to midnight is yesterday")
  equal(words(cardDate(2026, 11, 2, 0, 0)), "you used yesterday")
  let table: [(Int, String)] = [
    (2, "untouched since Sunday"), (3, "untouched since Saturday"),
    (4, "untouched since Friday"), (5, "untouched since Thursday"),
    (6, "untouched since Wednesday"), (7, "untouched for a week"),
    (13, "untouched for a week"), (14, "untouched for 2 weeks"),
    (20, "untouched for 2 weeks"), (21, "untouched for 3 weeks"),
    (28, "untouched for 4 weeks"), (29, "untouched for 4 weeks"),
    (30, "untouched for a month"), (59, "untouched for a month"),
    (60, "untouched for 2 months"), (89, "untouched for 2 months"),
    (90, "untouched for 3+ months"), (95, "untouched for 3+ months"),
    (400, "untouched for 3+ months"),
  ]
  for (days, expected) in table {
    equal(words(daysBefore(days)), expected, "\(days) days ago")
  }
  // Folders read the same way.
  equal(
    AutopilotPolicy.when(
      .disk, newest: daysBefore(6), match: ["folder": ["node_modules"]], now: cardNow,
      calendar: utc), "untouched since Wednesday", "folders too")
  // The same moment is a different day in another time zone.
  var pacific = Calendar(identifier: .gregorian)
  pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  let late = cardDate(2026, 11, 3, 2, 0)
  equal(words(late), "you used today", "2 am in London is today")
  equal(
    AutopilotPolicy.when(
      .worktree, newest: late, match: ["stale": ["day"]], now: cardNow, calendar: pacific),
    "you used yesterday", "but 6 pm the evening before in California")

  // Without a date, the age bucket the question is about, in the same voice.
  equal(words(nil), "unused since yesterday")
  equal(words(nil, ["stale": ["week"]]), "unused for a week")
  equal(words(nil, ["stale": ["month"]]), "unused for a month")
  equal(words(nil, ["stale": ["older"]]), "unused for 3+ months")
  equal(words(nil, ["stale": ["today"]]), "used in the last day")
  equal(
    words(nil, ["stale": ["week", "day"]]), "unused since yesterday",
    "the most recent age the question covers")
  equal(words(nil, ["saved": ["merged"]]), "", "no age, no words")
  equal(
    AutopilotPolicy.when(
      .process, newest: nil, match: ["family": ["node"], "idle": ["1d"]], now: cardNow,
      calendar: utc), "", "programs have no age bucket to fall back on")
  // A card with no date reads from its pattern.
  var undated = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["day"]], question: "", why: "", examples: [], count: 3,
    bytes: 3_000_000_000)
  equal(
    AutopilotPolicy.card(undated, now: cardNow, calendar: utc).headline,
    "Burn 3 copies unused since yesterday?")
  undated.match = ["stale": ["today", "day"]]
  equal(
    AutopilotPolicy.card(undated, now: cardNow, calendar: utc).headline,
    "Burn 3 copies used in the last day?")
  equal(
    AutopilotPolicy.card(undated, now: cardNow, calendar: utc).facts, [],
    "an age in the headline is not listed again, even one read from the pattern")
  equal(AutopilotPolicy.card(undated, now: cardNow, calendar: utc).cautions, [])
  // The phrase for things used today is still how a rule's title says it.
  equal(
    AutopilotPolicy.ruleTitle(undated, answer: .yes),
    "Burn: Old project copies · Used in the last day")
  // With no age at all there is nothing to leave out.
  let ageless = AutopilotQuestion(
    kind: .worktree, match: ["saved": ["merged"]], question: "", why: "", examples: [], count: 3,
    bytes: 3_000_000_000)
  equal(AutopilotPolicy.card(ageless, now: cardNow, calendar: utc).headline, "Burn 3 copies?")
  equal(AutopilotPolicy.card(ageless, now: cardNow, calendar: utc).facts, ["Already merged"])
  var tools = AutopilotQuestion(
    kind: .disk, match: ["folder": ["package-cache"], "stale": ["month"]], question: "", why: "",
    examples: [], count: 4, bytes: 4_000_000_000)
  equal(
    AutopilotPolicy.card(tools, now: cardNow, calendar: utc).headline,
    "Burn 4 tool caches unused for a month?")
  tools.newest = daysBefore(45)
  equal(
    AutopilotPolicy.card(tools, now: cardNow, calendar: utc).headline,
    "Burn 4 tool caches untouched for a month?")
}

// MARK: Rows' clock

private func clockProof() {
  func clock(_ date: Date, now: Date = cardNow, calendar: Calendar = utc) -> String {
    AutopilotPolicy.clock(date, now: now, calendar: calendar)
  }
  equal(clock(cardDate(2026, 11, 3, 9, 15)), "today 9 am", "no minutes")
  equal(clock(cardDate(2026, 11, 3, 0, 30)), "today 12 am", "just after midnight")
  equal(clock(cardDate(2026, 11, 3, 12, 0)), "today 12 pm", "noon")
  equal(clock(cardDate(2026, 11, 2, 17, 0)), "yesterday 5 pm")
  equal(clock(cardDate(2026, 11, 2, 23, 59)), "yesterday 11 pm")
  equal(clock(cardDate(2026, 11, 1, 0, 30)), "Sun 12 am", "two days ago")
  equal(clock(cardDate(2026, 10, 31, 13, 5)), "Sat 1 pm")
  equal(clock(cardDate(2026, 10, 28, 8, 0)), "Wed 8 am", "six days ago")
  equal(clock(cardDate(2026, 10, 27, 17, 0)), "Oct 27", "a week ago: the day, not the hour")
  equal(clock(cardDate(2026, 10, 12, 10, 0)), "Oct 12")
  equal(clock(cardDate(2026, 1, 5, 10, 0)), "Jan 5", "this year")
  equal(clock(cardDate(2025, 10, 12, 10, 0)), "Oct 12, 2025", "another year")
  equal(clock(cardDate(2025, 12, 31, 23, 0)), "Dec 31, 2025", "last year")
  // A week-day name only reaches back six days, whichever year they fall in.
  let january = cardDate(2026, 1, 3, 10, 0)
  equal(clock(cardDate(2025, 12, 28, 17, 0), now: january), "Sun 5 pm")
  equal(clock(cardDate(2025, 12, 20, 17, 0), now: january), "Dec 20, 2025")
  // California: the evening before, though it is already the next day in London.
  var pacific = Calendar(identifier: .gregorian)
  pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  equal(clock(cardDate(2026, 11, 3, 2, 0), calendar: pacific), "yesterday 6 pm")
  equal(clock(cardDate(2026, 11, 3, 2, 0)), "today 2 am")
  // The words are English and Gregorian whatever calendar the Mac prefers.
  var buddhist = Calendar(identifier: .buddhist)
  buddhist.timeZone = TimeZone(identifier: "UTC")!
  equal(clock(cardDate(2025, 10, 12, 10, 0), calendar: buddhist), "Oct 12, 2025")
  equal(clock(cardDate(2026, 11, 1, 0, 30), calendar: buddhist), "Sun 12 am")
}

// MARK: Programs

private func programWordsProof() {
  func idle(_ seconds: TimeInterval) -> String {
    AutopilotPolicy.when(
      .process, newest: cardNow.addingTimeInterval(-seconds),
      match: ["family": ["node"], "idle": ["1h"]], now: cardNow, calendar: utc)
  }
  equal(idle(30), "idle for under a minute")
  equal(idle(60), "idle for a minute")
  equal(idle(40 * 60), "idle for 40 minutes")
  equal(idle(59 * 60 + 59), "idle for 59 minutes")
  equal(idle(60 * 60), "idle for an hour")
  equal(idle(119 * 60), "idle for an hour")
  equal(idle(120 * 60), "idle for 2 hours")
  equal(idle(3 * 3600), "idle for 3 hours")
  equal(idle(47 * 3600 + 3000), "idle for 47 hours", "under 48 hours it is hours")
  equal(idle(48 * 3600), "idle for 2 days")
  equal(idle(10 * 86_400), "idle for 10 days")
  equal(idle(-5), "idle for under a minute", "a clock a little behind is not negative")
  func text(_ seconds: TimeInterval) -> String {
    AutopilotPolicy.idleText(cardNow.addingTimeInterval(-seconds), now: cardNow)
  }
  equal(text(10), "idle <1 min")
  equal(text(40 * 60), "idle 40 min")
  equal(text(59 * 60 + 59), "idle 59 min")
  equal(text(60 * 60), "idle 1 h")
  equal(text(3 * 3600), "idle 3 h")
  equal(text(47 * 3600 + 3000), "idle 47 h")
  equal(text(48 * 3600), "idle 2 d")
  equal(text(5 * 86_400), "idle 5 d")

  // A question about programs: when each was last busy, and who started it.
  let programs = [
    programItem("p1", used: cardNow.addingTimeInterval(-3 * 3600)),
    programItem(
      "p2", repo: "web", agent: "claude", bytes: 1_200_000_000,
      used: cardNow.addingTimeInterval(-5 * 3600)),
    programItem(
      "p3", repo: "none", agent: "none", bytes: 1_000_000_000,
      used: cardNow.addingTimeInterval(-9 * 3600)),
  ]
  guard
    let question = AutopilotPolicy.proposeQuestions(
      programs, memory: AutopilotMemory(), now: cardNow
    ).first
  else { return failTest("a question about the programs") }
  equal(question.newest, cardNow.addingTimeInterval(-3 * 3600), "the least idle of them")
  equal(question.line, "None is serving anything. Their apps are gone.")
  let card = AutopilotPolicy.card(question, now: cardNow, calendar: utc)
  equal(card.headline, "Burn 3 leftover Node programs idle for 3 hours?")
  equal(card.frees, "Frees 3.7 GB of memory")
  equal(
    card.rows.map(\.title), ["node in api", "node in web", "node"],
    "each row is the program's name, with its project")
  equal(card.rows.map(\.subtitle), ["started by Codex", "started by Claude", nil])
  equal(card.rows.map(\.when), ["idle 3 h", "idle 5 h", "idle 9 h"])
  equal(card.more, 0, "never below zero")
  equal(card.note, "They just get asked to quit.")
  equal(card.facts, [], "how long they sat idle is in the headline, not listed again")
  equal(card.cautions, [])

  // Without a date the headline has no age, so the idle phrase stays, in amber when it warns.
  var idleOnly = AutopilotQuestion(
    kind: .process, match: ["family": ["node"], "idle": ["10m"]], question: "", why: "",
    examples: [], count: 2, bytes: 2_000_000_000)
  var idleCard = AutopilotPolicy.card(idleOnly, now: cardNow, calendar: utc)
  equal(idleCard.headline, "Burn 2 leftover Node programs?")
  equal(idleCard.facts, ["Idle 10+ minutes"])
  equal(idleCard.cautions, ["Idle 10+ minutes"])
  idleOnly.newest = cardNow.addingTimeInterval(-40 * 60)
  idleCard = AutopilotPolicy.card(idleOnly, now: cardNow, calendar: utc)
  equal(idleCard.headline, "Burn 2 leftover Node programs idle for 40 minutes?")
  equal(idleCard.facts, [], "with a date the headline says it")
  equal(idleCard.cautions, [])
}

// MARK: Rows and the safe line

private func rowsAndLinesProof() {
  // Only the things every member shares are promised.
  let finished = (0..<3).map {
    copyItem(
      "f\($0)", title: nil, bytes: 1 << 30, used: nil, saved: $0 == 0 ? "merged" : "pushed",
      thread: "ended")
  }
  equal(
    AutopilotPolicy.safeLine(.worktree, finished),
    "Their work is on GitHub. Nothing is unsaved. Their chats are finished.")
  equal(
    AutopilotPolicy.safeLine(.worktree, [finished[0]]),
    "Its work is on GitHub. Nothing in it is unsaved. Its chat is finished.")
  var mixed = finished
  mixed[1].facts["saved"] = "local"
  equal(
    AutopilotPolicy.safeLine(.worktree, mixed), "Nothing is unsaved. Their chats are finished.")
  mixed[2].facts["changes"] = "small"
  mixed[0].facts["thread"] = "none"
  equal(AutopilotPolicy.safeLine(.worktree, mixed), nil, "nothing is shared by all")
  var unknown = finished
  unknown[0].facts["saved"] = "unknown"
  equal(
    AutopilotPolicy.safeLine(.worktree, unknown), "Nothing is unsaved. Their chats are finished.",
    "unchecked work is not promised")
  equal(AutopilotPolicy.safeLine(.worktree, []), nil, "no members, no promise")

  let programs = [programItem("a", used: nil), programItem("b", used: nil)]
  equal(
    AutopilotPolicy.safeLine(.process, programs),
    "None is serving anything. Their apps are gone.")
  equal(
    AutopilotPolicy.safeLine(.process, [programs[0]]),
    "It isn't serving anything. Its app is gone.")
  var serving = programs
  serving[1].facts["listening"] = "yes"
  equal(AutopilotPolicy.safeLine(.process, serving), "Their apps are gone.")
  serving[0].facts["orphaned"] = "maybe"
  equal(AutopilotPolicy.safeLine(.process, serving), nil)
  serving[1].facts["listening"] = "unknown"
  serving[0].facts["listening"] = "no"
  equal(AutopilotPolicy.safeLine(.process, serving), nil, "a server BZ couldn't check")
  equal(
    AutopilotPolicy.safeLine(.disk, [folderItem("api", bytes: 1 << 30, used: nil)]), nil,
    "folders promise nothing")

  // A row says what the owner would call a thing, and where it lives.
  func subtitle(_ item: AutopilotItem) -> String? {
    let proposed = AutopilotPolicy.proposeQuestions(
      [item], memory: AutopilotMemory(), now: cardNow)
    return proposed.first?.rows?.first?.subtitle
  }
  let tidy = copyItem("t", title: nil, repo: "none", bytes: 2 << 30, used: daysBefore(3))
  equal(subtitle(tidy), nil, "a copy with no project")
  let named = copyItem("t", title: nil, repo: "", bytes: 2 << 30, used: daysBefore(3))
  equal(subtitle(named), nil, "an empty project")
  let cursor = programItem("c", agent: "cursor", bytes: 2 << 30, used: daysBefore(1))
  equal(subtitle(cursor), "started by Cursor")
  let proposed = AutopilotPolicy.proposeQuestions(
    [tidy], memory: AutopilotMemory(), now: cardNow)
  equal(proposed.first?.rows?.first?.title, "t", "the folder's name when nothing names the task")
  let folders = AutopilotPolicy.proposeQuestions(
    [folderItem("api", bytes: 2 << 30, used: daysBefore(10))], memory: AutopilotMemory(),
    now: cardNow)
  equal(folders.first?.rows?.first?.title, "node_modules in api")
  equal(folders.first?.rows?.first?.subtitle, nil, "folders carry no project fact")
  var inProject = folderItem("web", bytes: 2 << 30, used: daysBefore(10))
  inProject.facts["repo"] = "web"
  equal(subtitle(inProject), nil, "and a folder's name already says its project")
  equal(folders.first?.line, nil)
  let folderCard = AutopilotPolicy.card(folders[0], now: cardNow, calendar: utc)
  equal(folderCard.headline, "Burn 1 node_modules folder untouched for a week?")
  equal(folderCard.rows.map(\.when), ["Oct 24"], "10 days ago: the day")

  // When any copy a question covers has no date, its most recent use is unknown: the card falls
  // back to the age the question is about, and the undated copy shows no time.
  let partly = AutopilotPolicy.proposeQuestions(
    [
      copyItem("m1", title: "dated", bytes: 1_200_000_000, used: daysBefore(3)),
      copyItem("m2", title: "undated", bytes: 1_100_000_000, used: nil),
    ], memory: AutopilotMemory(), now: cardNow)
  guard let partial = partly.first else { return failTest("a question about a partly dated pair") }
  isNil(partial.newest)
  let partialCard = AutopilotPolicy.card(partial, now: cardNow, calendar: utc)
  equal(partialCard.headline, "Burn 2 copies unused since yesterday?")
  equal(partialCard.rows.map(\.when), ["Sat 9 am", ""])
  // Equal sizes keep a fixed order, and a very long title is kept in part.
  let tied = AutopilotPolicy.proposeQuestions(
    [
      copyItem("tie-b", title: "second", bytes: 1_500_000_000, used: daysBefore(3)),
      copyItem("tie-a", title: "first", bytes: 1_500_000_000, used: daysBefore(3)),
      copyItem(
        "long", title: String(repeating: "x", count: 300), bytes: 1_400_000_000,
        used: daysBefore(3)),
    ], memory: AutopilotMemory(), now: cardNow)
  equal(tied.first?.rows?.map(\.title), ["first", "second", String(repeating: "x", count: 100)])

  // An older question has no rows: its example names stand in, with no time.
  var older = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["week"]], question: "", why: "", examples: ["x", "y"],
    count: 9, bytes: 9_000_000_000)
  var card = AutopilotPolicy.card(older, now: cardNow, calendar: utc)
  equal(card.rows.map(\.title), ["x", "y"])
  equal(card.rows.map(\.when), ["", ""])
  equal(card.rows.map(\.subtitle), [nil, nil])
  equal(card.more, 7)
  equal(card.line, nil)
  older.rows = []
  equal(
    AutopilotPolicy.card(older, now: cardNow, calendar: utc).rows.map(\.title), ["x", "y"],
    "empty rows are no rows")
  // More rows than the count never makes "more" negative; a row with no date has no time.
  older.rows = [
    AutopilotQuestionRow(title: "x", subtitle: nil, bytes: 1, lastUsed: nil),
    AutopilotQuestionRow(title: "y", subtitle: "api", bytes: 1, lastUsed: nil),
    AutopilotQuestionRow(title: "z", subtitle: nil, bytes: 1, lastUsed: daysBefore(3)),
  ]
  older.count = 2
  card = AutopilotPolicy.card(older, now: cardNow, calendar: utc)
  equal(card.more, 0)
  equal(card.rows.map(\.when), ["", "", "Sat 9 am"])
  // An older question says what it did before, except how long it sat unused: that is in the
  // headline now.
  let agent = AutopilotQuestion(
    kind: .worktree, match: ["saved": ["pushed"], "stale": ["week"], "place": ["patrol6"]],
    question: "", why: "", examples: [], count: 92, bytes: 14_390_000_000)
  let agentCard = AutopilotPolicy.card(agent, now: cardNow, calendar: utc)
  equal(agentCard.headline, "Burn 92 copies unused for a week?")
  equal(agentCard.facts, ["Saved on GitHub", "Made by Patrol6 agents"])
  equal(agentCard.more, 92, "no rows to show, all of them more")
}

// MARK: Branch names

private func humanizeProof() {
  equal(AutopilotPolicy.humanize(branch: "codex/fix-login-selector"), "fix login selector")
  equal(AutopilotPolicy.humanize(branch: "claude/happy-otter-1a2b3c"), "happy otter 1a2b3c")
  equal(AutopilotPolicy.humanize(branch: "feature/add_dark_mode"), "add dark mode")
  equal(AutopilotPolicy.humanize(branch: "users/dev/fix-bug"), "fix bug", "after the last slash")
  equal(AutopilotPolicy.humanize(branch: "main"), "main")
  equal(AutopilotPolicy.humanize(branch: "fix--login__selector"), "fix login selector", "runs collapse")
  equal(AutopilotPolicy.humanize(branch: "x/-fix-"), "fix", "no spaces at either end")
  equal(AutopilotPolicy.humanize(branch: "/"), nil)
  equal(AutopilotPolicy.humanize(branch: ""), nil)
  equal(AutopilotPolicy.humanize(branch: "codex/"), nil, "nothing after the slash")
  equal(AutopilotPolicy.humanize(branch: "-"), nil)
  equal(AutopilotPolicy.humanize(branch: "a/ _-_ "), nil)
}

// MARK: What a question stores

private func storedFieldsProof() throws {
  // New fields are optional: a question from before them still loads, and nothing changes in it.
  let history = try teachHistory()
  check(
    history.allSatisfy { $0.rows == nil && $0.newest == nil && $0.line == nil },
    "answers from before the card have no rows, newest or line")
  var full = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["day"]], question: "Can I?", why: "", examples: ["a"],
    count: 2, bytes: 2_000_000_000, asked: cardNow)
  full.rows = [
    AutopilotQuestionRow(
      title: "fix login selector", subtitle: "web-app", bytes: 1_000_000_000,
      lastUsed: cardDate(2026, 11, 2, 17)),
    AutopilotQuestionRow(title: "folder", subtitle: nil, bytes: 5, lastUsed: nil),
  ]
  full.newest = cardDate(2026, 11, 2, 19)
  full.line = "Their work is on GitHub."
  full.risks = []
  let decoded = try JSONDecoder().decode(
    AutopilotQuestion.self, from: JSONEncoder().encode(full))
  equal(decoded, full, "rows, newest and line round-trip")
  equal(decoded.risks, [], "an empty list of risks is not unknown")
  let oldJSON =
    #"{"id":"q","kind":"disk","match":{},"question":"","why":"","examples":[],"count":0,"bytes":0,"asked":0,"source":"native"}"#
  let old = try JSONDecoder().decode(AutopilotQuestion.self, from: Data(oldJSON.utf8))
  check(
    old.rows == nil && old.newest == nil && old.line == nil && old.risks == nil,
    "a question saved before them still loads")

  // Items too: the new fields don't change what an AI judgment is bound to.
  let plain = AutopilotItem(
    id: "worktree:x", kind: .worktree, name: "x", facts: ["saved": "merged"], observedAt: cardNow)
  let dated = AutopilotItem(
    id: "worktree:x", kind: .worktree, name: "x", facts: ["saved": "merged"], observedAt: cardNow,
    lastUsed: cardNow, title: "fix login selector")
  equal(dated.revision, plain.revision, "a date and a title are not facts")
  check(dated != plain, "but they are part of the item")
  equal(
    try JSONDecoder().decode(AutopilotItem.self, from: JSONEncoder().encode(dated)), dated,
    "items round-trip with them")
  let before = try JSONEncoder().encode(plain)
  let beforeObject = (try JSONSerialization.jsonObject(with: before) as? [String: Any]) ?? [:]
  check(beforeObject["lastUsed"] == nil && beforeObject["title"] == nil, "nothing written when nil")
  equal(
    try JSONDecoder().decode(AutopilotItem.self, from: before), plain,
    "a catalog from before them still loads")
}

// MARK: The engine keeps questions current

/// Copies an engine sees, changeable between ticks.
private final class CardWorld: @unchecked Sendable {
  var copies: [AutopilotItem] = []
}

private func cardEngineProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-card-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let world = CardWorld()
  world.copies = [
    copyItem("a", title: "fix login selector", bytes: 1_200_000_000, used: daysBefore(2)),
    copyItem(
      "b", title: "add dark mode", bytes: 1_100_000_000, used: daysBefore(9), stale: "week"),
    copyItem(
      "c", title: "tidy the footer", repo: "docs", bytes: 900_000_000, used: daysBefore(12),
      stale: "week"),
    copyItem(
      "d", title: "rename settings", repo: "api", bytes: 500_000_000, used: daysBefore(40),
      stale: "month"),
  ]
  let engine = try Autopilot(
    root: root, sources: AutopilotSources(worktrees: { _, _, d in (world.copies, d) }))
  let first = await engine.tick(now: cardNow)
  guard let asked = first.questions.first, first.questions.count == 1 else {
    return failTest("one question about the four copies: \(first.questions.count)")
  }
  equal(asked.count, 4)
  equal(asked.rows?.map(\.title), ["fix login selector", "add dark mode", "tidy the footer"])
  equal(asked.rows?.map(\.subtitle), ["web-app", "web-app", "docs"])
  equal(asked.newest, daysBefore(2), "the engine asks with what the items say")
  equal(asked.risks, [])
  equal(asked.line, "Their work is on GitHub. Nothing is unsaved.")
  equal(
    AutopilotPolicy.card(asked, now: cardNow, calendar: utc).headline,
    "Burn 4 copies untouched since Sunday?")

  // A later tick: one copy was worked in, another has work only here, and one is gone.
  world.copies[0] = copyItem(
    "a", title: "fix login selector", bytes: 1_200_000_000, used: daysBefore(1))
  world.copies[2] = copyItem(
    "c", title: "tidy the footer", repo: "docs", bytes: 900_000_000, used: daysBefore(12),
    saved: "local", changes: "small", stale: "week")
  world.copies.removeLast()
  let second = await engine.tick(now: cardNow.addingTimeInterval(60))
  guard let refreshed = second.questions.first else {
    return failTest("the question stays open while 3 copies are worth asking about")
  }
  equal(refreshed.id, asked.id, "the same question")
  equal(refreshed.count, 3, "count follows")
  equal(refreshed.bytes, 3_200_000_000, "bytes follow")
  equal(refreshed.rows?.map(\.title), ["fix login selector", "add dark mode", "tidy the footer"])
  equal(refreshed.rows?.first?.lastUsed, daysBefore(1), "rows are refreshed")
  equal(refreshed.newest, daysBefore(1), "newest too")
  equal(refreshed.risks, ["changes=small", "saved=local"], "and risks")
  equal(refreshed.line, nil, "and the line: one copy has work only here")
  equal(refreshed.cautions, ["1 has work only on this Mac", "1 has unsaved changes"])

  // An answer to that question is kept as it was asked: later ticks leave it alone.
  _ = try await engine.apply(.answer(questionID: refreshed.id, answer: .no))
  world.copies.removeAll()
  _ = await engine.tick(now: cardNow.addingTimeInterval(120))
  let store = try AutopilotStore(root: root)
  let answered = try store.memory().questions.first { $0.id == refreshed.id }
  equal(answered?.rows?.map(\.title), ["fix login selector", "add dark mode", "tidy the footer"])
  equal(answered?.risks, ["changes=small", "saved=local"], "an answered question keeps its risks")
  equal(answered?.newest, daysBefore(1))

  // The AI's own question is filled the same way.
  let askRoot = root.appendingPathComponent("ask")
  let askWorld = CardWorld()
  askWorld.copies = [
    copyItem("a", title: "fix login selector", bytes: 1_200_000_000, used: daysBefore(2)),
    copyItem(
      "b", title: "add dark mode", bytes: 1_100_000_000, used: daysBefore(9), stale: "week"),
    copyItem(
      "c", title: "tidy the footer", repo: "docs", bytes: 900_000_000, used: daysBefore(12),
      saved: "local", stale: "week"),
    copyItem(
      "d", title: "rename settings", repo: "api", bytes: 500_000_000, used: daysBefore(40),
      stale: "month"),
  ]
  let askEngine = try Autopilot(
    root: askRoot, sources: AutopilotSources(worktrees: { _, _, d in (askWorld.copies, d) }))
  let native = await askEngine.tick(now: cardNow)
  guard let open = native.questions.first else { return failTest("a native question to replace") }
  var request = AutopilotRequest(tool: "ask")
  request.question = AutopilotQuestionInput(
    kind: .worktree, match: ["stale": ["week"]],
    question: "Can I burn the old copies nobody used this week?")
  request.replace = open.id
  let (ok, json) = await askEngine.handle(request)
  check(ok, json)
  let after = await askEngine.snapshot()
  guard let ai = after.questions.first(where: { $0.source == "ai" }) else {
    return failTest("the AI's question is open: \(json)")
  }
  equal(ai.count, 3, "the week and older")
  equal(ai.rows?.map(\.title), ["add dark mode", "tidy the footer", "rename settings"])
  equal(ai.rows?.map(\.subtitle), ["web-app", "docs", "api"])
  equal(ai.newest, daysBefore(9))
  equal(ai.risks, ["saved=local"])
  equal(ai.line, "Nothing is unsaved.", "changes are the one thing all three share")
  equal(ai.examples.count, 3, "examples are still kept")
  equal(
    AutopilotPolicy.card(ai, now: cardNow, calendar: utc).headline,
    "Burn 3 copies untouched for a week?")
}
