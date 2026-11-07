import BurnCore
import Foundation

/// Teach BZ's details: what a question's list holds and in what order, how each thing reads, the
/// filters, what Spare does to the card a Yes is answered from, and which tip comes next. Day and
/// time words are read in a fixed calendar, so the proof says the same on any Mac.
private let detailsCalendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

private func detailsDate(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
  let parts = DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)
  return detailsCalendar.date(from: parts) ?? .distantPast
}

/// Thursday 5 November 2026, 9:30 in the morning.
private let detailsNow = detailsDate(5, 9, 30)

private func detailsCopy(
  _ name: String, bytes: UInt64, used: Date, saved: String = "pushed", changes: String = "none",
  unsaved: Int? = nil, inUse: String = "no", protected: String? = nil
) -> AutopilotItem {
  let facts: [String: String] = [
    "repo": "web-app", "place": "codex", "saved": saved, "changes": changes, "stale": "day",
    "inUse": inUse, "thread": "none",
  ]
  return AutopilotItem(
    id: "worktree:" + name, kind: .worktree, name: name, path: "/tmp/bz-details/" + name,
    bytes: bytes, facts: facts, protectedReason: protected, lastUsed: used,
    title: name.replacingOccurrences(of: "-", with: " "), branch: "codex/" + name, unsaved: unsaved)
}

private func detailsEntry(
  _ item: AutopilotItem, _ status: AutopilotStatus, _ authority: String? = nil
) -> AutopilotEntry {
  AutopilotEntry(
    item: item, status: status, authority: authority, label: item.name, why: "",
    consequence: AutopilotPolicy.consequence(item))
}

/// A card about copies unused since yesterday: two unsure, one with work only here and unsaved
/// files, one unchecked, one the owner spared, one whose burn failed, and four that aren't its to
/// list: kept by a lesson, protected, a program and a copy used today.
private struct DetailsWorld {
  let login = detailsCopy(
    "fix-login", bytes: 2_000_000_000, used: detailsDate(4, 17), saved: "local", changes: "small",
    unsaved: 6)
  let dark = detailsCopy("dark-mode", bytes: 1_500_000_000, used: detailsDate(3, 16), saved: "merged")
  let footer = detailsCopy(
    "tidy-footer", bytes: 1_000_000_000, used: detailsDate(2, 9), changes: "unknown")
  let spared = detailsCopy("keep-me", bytes: 900_000_000, used: detailsDate(1, 12))
  let failed = detailsCopy("retry-me", bytes: 600_000_000, used: detailsDate(1, 10))
  let lesson = detailsCopy("lesson-kept", bytes: 800_000_000, used: detailsDate(1, 11))
  let main = detailsCopy(
    "main-folder", bytes: 700_000_000, used: detailsDate(1, 11),
    protected: "This is your main project folder.")
  var entries: [AutopilotEntry] {
    var today = detailsCopy("busy-today", bytes: 500_000_000, used: detailsDate(5, 9))
    today.facts["stale"] = "today"
    let program = AutopilotItem(
      id: "process:node", kind: .process, name: "node", bytes: 3_000_000_000,
      facts: ["family": "node", "idle": "1d", "listening": "no"])
    return [
      detailsEntry(login, .unsure), detailsEntry(dark, .unsure), detailsEntry(footer, .unsure),
      detailsEntry(spared, .keep, "operator"), detailsEntry(failed, .failed),
      detailsEntry(lesson, .keep, "rule:abc"), detailsEntry(main, .protected),
      detailsEntry(program, .unsure), detailsEntry(today, .unsure),
    ]
  }
  var question: AutopilotQuestion {
    var question = AutopilotQuestion(
      kind: .worktree, match: ["stale": ["day"]], question: "Can I burn them?", why: "",
      examples: [], count: 0, bytes: 0)
    AutopilotPolicy.refresh(&question, covering: [login, dark, footer, failed])
    return question
  }
}

func autopilotDetailsProof() {
  detailsListProof()
  detailWordsProof()
  sparingProof()
  tipDeckProof()
}

/// The list: what a Yes would burn and what the owner spared, biggest first, nothing else.
private func detailsListProof() {
  let world = DetailsWorld()
  let details = AutopilotPolicy.details(
    world.question, entries: world.entries, now: detailsNow, calendar: detailsCalendar)
  equal(
    details.map(\.id),
    ["worktree:fix-login", "worktree:dark-mode", "worktree:tidy-footer", "worktree:keep-me",
      "worktree:retry-me"],
    "details: the question's copies and the spared one, biggest first")
  equal(details.filter(\.spared).map(\.id), ["worktree:keep-me"], "details: only the owner's keep is spared")
  equal(
    details.filter { !$0.spared }.count, world.question.count,
    "details: what isn't spared is what the question counts")

  let filters = AutopilotPolicy.detailFilters(details)
  equal(filters.map(\.id), ["all", "local", "unsaved", "unchecked", "failed", "spared"], "filters")
  equal(filters.map(\.count), [5, 1, 1, 1, 1, 1], "filter counts")
  equal(
    AutopilotPolicy.filtered(details, by: "local").map(\.id), ["worktree:fix-login"],
    "filter: work only on this Mac")
  equal(
    AutopilotPolicy.filtered(details, by: "spared").map(\.id), ["worktree:keep-me"], "filter: spared")
  equal(AutopilotPolicy.filtered(details, by: "all").count, 5, "filter: all")
  let noneSpared = details.map { detail -> AutopilotDetail in
    var unspared = detail
    unspared.spared = false
    return unspared
  }
  equal(AutopilotPolicy.filtered(noneSpared, by: "spared").count, 0, "filter: nothing spared yet")
  checkFalse(
    AutopilotPolicy.detailFilters(noneSpared).contains { $0.id == "spared" },
    "no Spared filter until something is spared")
}

/// Each row's few words and the facts behind them, in the card's voice.
private func detailWordsProof() {
  let world = DetailsWorld()
  let details = AutopilotPolicy.details(
    world.question, entries: world.entries, now: detailsNow, calendar: detailsCalendar)
  guard details.count == 5 else { return failTest("details words: five copies listed") }
  let login = details[0]
  equal(login.title, "fix login")
  equal(login.subtitle, "web-app")
  equal(login.size, "2.0 GB")
  equal(login.when, "yesterday 5 pm")
  equal(login.tags.map(\.text), ["Only on this Mac", "6 unsaved files"])
  check(login.tags.allSatisfy(\.risky), "risky words stand out")
  equal(
    login.facts.map { "\($0.label): \($0.value)" },
    [
      "Size: 2.0 GB", "Last used: Yesterday 5 pm", "Work: Only on this Mac",
      "Unsaved changes: 6 files", "Branch: codex/fix-login", "Where: Codex worktree",
    ])
  equal(login.facts.filter(\.risky).map(\.label), ["Work", "Unsaved changes"])
  equal(
    login.consequence,
    "The folder goes away, but nothing is lost: your code is saved and I keep a backup you can restore."
  )
  equal(details[1].tags.map(\.text), ["Merged"], "a safe copy says why")
  checkFalse(details[1].tags[0].risky, "safe words don't stand out")
  equal(details[1].when, "Tue 4 pm")
  equal(details[2].tags.map(\.text), ["Changes not checked"])
  equal(details[2].facts[3].value, "Not checked yet", "an unchecked fact says so")
  equal(details[3].tags.map(\.text), ["On GitHub"])
  equal(details[4].tags.map(\.text), ["Failed last time", "On GitHub"])

  var bucket = world.login
  bucket.unsaved = nil
  bucket.facts["changes"] = "large"
  equal(
    AutopilotPolicy.details(
      world.question, entries: [detailsEntry(bucket, .unsure)], now: detailsNow,
      calendar: detailsCalendar
    ).first?.tags.map(\.text), ["Only on this Mac", "Lots of unsaved changes"],
    "without Git's count, the bucket's words")
}

/// Spare narrows the card the owner answers from: what's left is counted, sized and named, and
/// risks only spared copies had leave the card, so a Yes can't cover them.
private func sparingProof() {
  let world = DetailsWorld()
  let question = world.question
  let details = AutopilotPolicy.details(
    question, entries: world.entries, now: detailsNow, calendar: detailsCalendar)
  equal(
    AutopilotPolicy.sparing(question, details: details), question,
    "the engine's card already leaves out what was spared before")
  let unspared = details.filter { !$0.spared }
  equal(AutopilotPolicy.sparing(question, details: unspared), question, "nothing spared: unchanged")
  equal(question.risks, ["changes=small", "changes=unknown", "saved=local"], "the card's risks")

  let sparingLogin = details.map { detail -> AutopilotDetail in
    var changed = detail
    if detail.id == "worktree:fix-login" { changed.spared = true }
    return changed
  }
  let drawn = AutopilotPolicy.sparing(question, details: sparingLogin)
  equal(drawn.id, question.id, "the same question")
  equal(drawn.count, 3, "three left")
  equal(drawn.bytes, 3_100_000_000, "what the three free")
  equal(drawn.risks, ["changes=unknown"], "work only here and unsaved files left with fix login")
  equal(drawn.cautions, ["1 couldn't be checked"])
  let card = AutopilotPolicy.card(drawn, now: detailsNow, calendar: detailsCalendar)
  check(card.headline.hasPrefix("Burn 3 "), card.headline)
  equal(card.frees, "Frees 3.1 GB")
  checkFalse(
    card.facts.contains { $0.contains("work only on this Mac") }, "no chip for spared work")
}

/// The tips: the card's own reassurance first, tips for where the owner is before the rest, never
/// the same one twice running, a limit per tip, and a tip retires once the owner does what it says.
private func tipDeckProof() {
  let copies = AutopilotPolicy.tips(for: .worktree, filters: true)
  equal(
    copies.map(\.id),
    ["backup", "local", "unsaved", "safe", "teach", "skip", "details", "hover", "spare", "flip",
      "filters"])
  equal(copies.first?.text, "Every copy is backed up before it burns, so you can undo it.")
  checkFalse(
    AutopilotPolicy.tips(for: .worktree, filters: false).contains { $0.id == "filters" },
    "no filters tip without filters")
  equal(AutopilotPolicy.tips(for: .process, filters: false).first?.id, "quit")
  equal(AutopilotPolicy.tips(for: .disk, filters: false).first?.id, "rebuild")
  check(
    AutopilotPolicy.tips(for: .process, filters: false).contains {
      $0.text == "Rest the pointer on a program to see everything I know about it."
    }, "tips name the kind of thing")

  var deck = AutopilotTipDeck(tips: copies)
  var order: [String] = []
  for _ in 0..<7 { order.append(deck.next(at: .question, shuffle: false)?.id ?? "-") }
  equal(order, ["backup", "local", "unsaved", "safe", "teach", "skip", "details"], "question tips")
  equal(deck.next(at: .list, shuffle: false)?.id, "hover", "the list's own tips come first")
  let spare = deck.next(at: .list, shuffle: false)
  equal(spare?.id, "spare")
  equal(deck.next(at: .entry, shuffle: false)?.id, "flip", "the most specific place first")
  check(deck.did("spare", showing: spare), "doing what the tip says lets it go")
  checkFalse(deck.did("flip", showing: spare), "another action leaves it")
  for _ in 0..<40 {
    let id = deck.next(at: .entry)?.id
    check(id != "spare" && id != "flip", "retired tips never come back: \(id ?? "nil")")
  }

  var shuffled = AutopilotTipDeck(tips: copies)
  var last: String?
  for _ in 0..<30 {
    // The only one left may repeat; that's the one time it can.
    let left = copies.filter { shuffled.live($0) && $0.place <= .list }.count
    let id = shuffled.next(at: .list)?.id
    check(id != nil && (id != last || left == 1), "never the same tip twice running")
    last = id
  }
  check(
    shuffled.shown.values.allSatisfy { $0 <= AutopilotTipDeck.showsEach }, "each tip within its limit")

  let skip = copies.filter { $0.id == "skip" }
  var single = AutopilotTipDeck(tips: skip)
  let shows = (0..<4).map { _ in single.next(at: .question)?.id }
  equal(shows, ["skip", "skip", "skip", nil], "a tip shows three times, then retires")

  var learned = AutopilotTipDeck(tips: copies, done: ["details"])
  for _ in 0..<12 { check(learned.next(at: .question)?.id != "details", "View details was used") }
}

/// Spare and Unspare in the engine: a spared copy stays listed but leaves the card, a Yes burns
/// the rest and never it, and Unspare leaves no keep behind.
func spareEngineProof() async throws {
  let now = Date()
  // A copy whose folder is gone leaves the catalog, so these have real (empty) folders: a keep
  // names a copy by its path too.
  let folders = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-spare-copies-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folders) }
  func copy(_ name: String, saved: String = "pushed") throws -> AutopilotItem {
    let folder = folders.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let facts: [String: String] = [
      "repo": "web-app", "place": "patrol6", "saved": saved, "changes": "none", "stale": "week",
      "inUse": "no", "thread": "none",
    ]
    return AutopilotItem(
      id: "worktree:" + name, kind: .worktree, name: name, path: folder.path,
      bytes: 600_000_000, facts: facts, lastUsed: now.addingTimeInterval(-10 * 86_400),
      title: name.replacingOccurrences(of: "-", with: " "))
  }
  let world = TellWorld(
    copies: [try copy("fix-login"), try copy("dark-mode"), try copy("wip-search", saved: "local")])
  let (engine, store, root) = try tellEngine("spare", world, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: root) }
  guard let asked = await engine.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("spare: a card about the three copies") }
  equal(asked.count, 3, "spare: three copies on the card")
  equal(asked.risks, ["saved=local"], "spare: one has work only on this Mac")

  let spared = try await engine.apply(.keep(itemID: "worktree:wip-search"), now: now)
  let details = AutopilotPolicy.details(
    asked, entries: spared.entries, now: now, calendar: .current)
  equal(details.count, 3, "spare: the spared copy stays listed")
  equal(details.filter(\.spared).map(\.id), ["worktree:wip-search"], "spare: and shows as spared")
  let drawn = AutopilotPolicy.sparing(asked, details: details)
  equal(drawn.count, 2, "spare: the card counts two")
  equal(drawn.risks, [], "spare: and shows no work only on this Mac")

  _ = try await engine.apply(
    .answer(questionID: asked.id, answer: .yes, risks: drawn.risks), now: now)
  await eventually { world.burns.all.count == 2 }
  equal(
    Set(world.burns.all), ["worktree:fix-login", "worktree:dark-mode"], "spare: the Yes burns the two")
  let after = await engine.tick(now: now.addingTimeInterval(60))
  checkFalse(world.burns.all.contains("worktree:wip-search"), "spare: never the spared copy")
  equal(
    after.entries.first { $0.id == "worktree:wip-search" }?.status, .keep, "spare: still kept")

  let back = try await engine.apply(.unkeep(itemID: "worktree:wip-search"), now: now)
  equal(
    back.entries.first { $0.id == "worktree:wip-search" }?.status, .unsure,
    "unspare: BZ decides again, and the Yes never covered work only on this Mac")
  equal(try store.memory().keptItems, [], "unspare: no keep is left, by id or by path")
}
