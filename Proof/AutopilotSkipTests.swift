import BurnCore
import Foundation

/// A card asked again after a Skip has an id of its own, so an answer lands on the card the owner
/// sees: a No closes it and the question about older things follows, and a Yes covers only the risks
/// that card shows. Memory from before, which can hold an open card and a skipped one under the same
/// id, can still be answered.
func skipProof() async throws {
  try await reaskedNoProof()
  try await reaskedYesProof()
  try await duplicateProof()
}

/// A copy whose work is on GitHub, untouched for a week or a month.
private func quietCopy(
  _ name: String, stale: String, changes: String = "none", now: Date
) -> AutopilotItem {
  let days: Double = stale == "month" ? 40 : 10
  let facts: [String: String] = [
    "repo": "web-app", "place": "agent", "saved": "pushed", "changes": changes,
    "stale": stale, "inUse": "no", "thread": "none",
  ]
  return AutopilotItem(
    id: "worktree:" + name, kind: .worktree, name: name, bytes: 600_000_000, facts: facts,
    lastUsed: now.addingTimeInterval(-days * 86_400),
    title: name.replacingOccurrences(of: "-", with: " "))
}

/// Skip, the snooze ends, and the same pattern is asked again under an id of its own. The owner's
/// No closes that card and keeps what it was about; the older copies get the next question.
private func reaskedNoProof() async throws {
  let now = Date()
  let later: Date = now.addingTimeInterval(86_400 + 60)
  let world = TellWorld(
    copies: [
      quietCopy("fix-login", stale: "week", now: now),
      quietCopy("dark-mode", stale: "week", now: now),
      quietCopy("old-api", stale: "month", now: now),
      quietCopy("old-docs", stale: "month", now: now),
    ])
  let (engine, store, root) = try tellEngine("skip-no", world, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: root) }
  guard let first = await engine.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("skip, no: a card about the copies") }
  equal(first.match, ["stale": ["week"]], "skip, no: the card is about a week and older")
  _ = try await engine.apply(.answer(questionID: first.id, answer: .skip), now: now)

  let reasked = await engine.tick(now: later)
  guard let again = reasked.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("skip, no: the card is asked again once the snooze ends")
  }
  equal(again.match, first.match, "skip, no: the same pattern")
  check(again.id != first.id, "skip, no: an id of its own, not the skipped card's: \(again.id)")
  let answered = try await engine.apply(.answer(questionID: again.id, answer: .no), now: later)
  checkFalse(
    answered.questions.contains { $0.id == again.id }, "skip, no: the No closes the card")
  let memory = try store.memory()
  let skips: [AutopilotAnswer?] = memory.questions.filter { $0.id == first.id }.map(\.answer)
  equal(skips, [.skip], "skip, no: the skipped card stays skipped")
  let nos: [AutopilotAnswer?] = memory.questions.filter { $0.id == again.id }.map(\.answer)
  equal(nos, [.no], "skip, no: the No is the new card's")
  for name in ["fix-login", "dark-mode"] {
    let status = answered.entries.first { $0.item.id == "worktree:" + name }?.status
    equal(status, .keep, "skip, no: \(name) is kept")
  }
  let next = answered.questions.first { $0.kind == .worktree }
  equal(next?.match, ["stale": ["month"]], "skip, no: the question about older copies follows")
  equal(next?.count, 2, "skip, no: about the two month-old copies")
}

/// A copy with unsaved changes joins a card before the owner skips it, and the owner then keeps
/// that copy. Asked again, the card shows no risk, and its Yes covers nothing unsaved: a later copy
/// with unsaved changes stays unsure.
private func reaskedYesProof() async throws {
  let now = Date()
  let later: Date = now.addingTimeInterval(86_400 + 60)
  let world = TellWorld(
    copies: [
      quietCopy("fix-login", stale: "week", now: now),
      quietCopy("dark-mode", stale: "week", now: now),
    ])
  let (engine, store, root) = try tellEngine("skip-yes", world, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: root) }
  guard let first = await engine.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("skip, yes: a card about the clean copies") }
  equal(first.risks, [], "skip, yes: nothing risky on the card at first")
  world.add(quietCopy("wip-search", stale: "week", changes: "small", now: now))
  let grown = await engine.tick(now: now.addingTimeInterval(60))
  let shown: [String]? = grown.questions.first { $0.id == first.id }?.risks
  equal(shown, ["changes=small"], "skip, yes: the card shows the unsaved changes")
  _ = try await engine.apply(.answer(questionID: first.id, answer: .skip), now: now)
  _ = try await engine.apply(.keep(itemID: "worktree:wip-search"), now: now)

  guard
    let again = await engine.tick(now: later).questions.first(where: { $0.kind == .worktree })
  else { return failTest("skip, yes: the clean copies are asked about again") }
  equal(again.risks, [], "skip, yes: the card asked again shows no risk")
  _ = try await engine.apply(.answer(questionID: again.id, answer: .yes), now: later)
  await eventually { world.burns.all.count == 2 }
  equal(world.burns.all.count, 2, "skip, yes: the Yes burns the two clean copies")
  let lesson = try store.memory().rules.first { $0.questionID == again.id }
  equal(lesson?.match["changes"], ["none"], "skip, yes: the Yes covers only what its card showed")
  world.add(quietCopy("half-done", stale: "week", changes: "small", now: now))
  let after = await engine.tick(now: later.addingTimeInterval(60))
  checkFalse(
    world.burns.all.contains("worktree:half-done"),
    "skip, yes: unsaved changes only the skipped card showed never burn")
  let status = after.entries.first { $0.item.id == "worktree:half-done" }?.status
  equal(status, .unsure, "skip, yes: the copy with unsaved changes is asked about")
}

/// Memory from before re-asked cards had ids of their own: a skipped card and, later in the list, an
/// open one under the same id. The open one takes the answer and closes, its Yes covers its own
/// risks, a second click changes nothing, and the skip stays a skip.
private func duplicateProof() async throws {
  let now = Date()
  let world = TellWorld(
    copies: [
      quietCopy("fix-login", stale: "week", now: now),
      quietCopy("dark-mode", stale: "week", now: now),
    ])
  let pattern: [String: [String]] = ["stale": ["week"]]
  let words = "Can I burn old project copies untouched for a week?"
  var skipped = AutopilotQuestion(
    kind: .worktree, match: pattern, question: words, why: "", examples: [], count: 3,
    bytes: 1_800_000_000, asked: now.addingTimeInterval(-3 * 86_400))
  skipped.answer = .skip
  skipped.answered = now.addingTimeInterval(-3 * 86_400)
  skipped.snoozedUntil = now.addingTimeInterval(-2 * 86_400)
  skipped.risks = ["changes=small"]
  var open = AutopilotQuestion(
    kind: .worktree, match: pattern, question: words, why: "", examples: [], count: 2,
    bytes: 1_200_000_000, asked: now.addingTimeInterval(-86_400))
  open.risks = []
  equal(open.id, skipped.id, "duplicate: one id for both, as memory from before has it")
  var memory = AutopilotMemory()
  memory.questions = [skipped, open]
  let (engine, store, root) = try tellEngine("skip-duplicate", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  let shown = await engine.tick(now: now)
  equal(shown.questions.map(\.id), [open.id], "duplicate: the open card is shown")

  let answered = try await engine.apply(.answer(questionID: open.id, answer: .yes), now: now)
  checkFalse(
    answered.questions.contains { $0.id == open.id }, "duplicate: the Yes closes the open card")
  await eventually { world.burns.all.count == 2 }
  let after = try store.memory()
  equal(after.questions.map(\.answer), [.skip, .yes], "duplicate: the open card took the Yes")
  let lesson = after.rules.first { $0.questionID == open.id }
  equal(lesson?.match["changes"], ["none"], "duplicate: the Yes covers the open card's risks")
  let evidence: String = AutopilotPolicy.lessonGroups(after).first?.evidence ?? ""
  check(evidence.hasPrefix("From 1 answer "), "duplicate: the lesson counts the Yes: \(evidence)")

  _ = try await engine.apply(.answer(questionID: open.id, answer: .yes), now: now)
  let twice = try store.memory()
  equal(twice.questions, after.questions, "duplicate: a second Yes changes no answer")
  equal(twice.rules, after.rules, "duplicate: and no lesson")
  do {
    _ = try await engine.apply(.answer(questionID: open.id, answer: .no), now: now)
    failTest("duplicate: a different answer is refused")
  } catch {
    equal(error.localizedDescription, "That question is already answered.")
  }
  equal(try store.memory().questions.map(\.answer), [.skip, .yes], "duplicate: the skip stays")
}
