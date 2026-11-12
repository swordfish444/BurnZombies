import BurnCore
import Foundation

/// What the owner saw decides what an answer teaches, and nothing under an answered pattern is left
/// unsure without a question: an answer carries the risks its card showed, and things the lessons
/// from a pattern's answers don't cover are asked about again.
func shownRisksProof() async throws {
  try await answerCarriesShownRisksProof()
  try await reaskUncoveredProof()
}

/// A copy untouched for a week, at `now`: its work on GitHub, nothing unsaved and not in use unless
/// told otherwise.
private func agedCopy(
  _ name: String, now: Date, saved: String = "pushed", changes: String = "none",
  inUse: String = "no"
) -> AutopilotItem {
  AutopilotItem(
    id: "worktree:" + name, kind: .worktree, name: name, bytes: 600_000_000,
    facts: [
      "repo": "web-app", "place": "agent", "saved": saved, "changes": changes, "stale": "week",
      "inUse": inUse, "thread": "none",
    ], lastUsed: now.addingTimeInterval(-10 * 86_400))
}

private func status(_ snapshot: AutopilotSnapshot, _ name: String) -> AutopilotStatus? {
  snapshot.entries.first { $0.item.id == "worktree:" + name }?.status
}

/// A look can refresh an open question while its card is on screen. The answer teaches from what the
/// card showed: a Yes to a clean card burns the clean copies and approves no unsaved work, though
/// copies with unsaved work turned up under the question meanwhile. Those are asked about next, on a
/// card that names the risk, and BZ, trusted on copies, doesn't act on a risk the owner never saw. A
/// caller that doesn't say what its card showed teaches from the question as BZ last saw it, as
/// before.
private func answerCarriesShownRisksProof() async throws {
  let now = Date()
  var trusted = AutopilotMemory()
  trusted.scores = (0..<AutopilotPolicy.trustStreak).map { i in
    AutopilotScore(
      questionID: "replayed-\(i)", subject: "worktree:", guess: .yes, answer: .yes, right: true,
      date: now.addingTimeInterval(Double(i - 10)), replayed: true)
  }
  /// The card the owner sees, then a look that finds copies with small unsaved changes under its
  /// question before the owner clicks.
  func cardThenLook(_ name: String) async throws -> (
    engine: Autopilot, store: AutopilotStore, root: URL, world: TellWorld, card: AutopilotQuestion
  ) {
    let world = TellWorld(
      copies: [agedCopy("fix-login", now: now), agedCopy("dark-mode", now: now)])
    let (engine, store, root) = try tellEngine(name, world, trusted)
    guard let card = await engine.tick(now: now).questions.first(where: { $0.kind == .worktree })
    else {
      failTest("\(name): a card about the clean copies")
      throw StoreError.message("no card")
    }
    equal(card.risks, [], "\(name): the card shows no risk")
    world.add(agedCopy("wip-search", now: now, changes: "small"))
    world.add(agedCopy("wip-cart", now: now, changes: "small"))
    let looked = await engine.tick(now: now.addingTimeInterval(60))
    let open: AutopilotQuestion? = looked.questions.first { $0.id == card.id }
    equal(open?.count, 4, "\(name): the look adds the new copies to the open question")
    equal(open?.risks, ["changes=small"], "\(name): and their risk")
    return (engine, store, root, world, card)
  }

  // The owner answers the card on screen, and the app sends what it showed.
  let shown = try await cardThenLook("shown-risks")
  defer { try? FileManager.default.removeItem(at: shown.root) }
  _ = try await shown.engine.apply(
    .answer(questionID: shown.card.id, answer: .yes, risks: shown.card.risks), now: now)
  await eventually { shown.world.burns.all.count == 2 }
  let after = await shown.engine.tick(now: now.addingTimeInterval(120))
  equal(
    Set(shown.world.burns.all), ["worktree:fix-login", "worktree:dark-mode"],
    "the Yes burns the clean copies on the card, and none with unsaved work")
  let memory = try shown.store.memory()
  equal(
    memory.questions.first { $0.id == shown.card.id }?.risks, [],
    "the answer keeps the risks its card showed")
  equal(
    memory.rules.first { $0.questionID == shown.card.id }?.match["changes"], ["none"],
    "so its lesson covers no unsaved work")
  check(
    after.tells.isEmpty, "BZ, trusted on copies, doesn't act on unsaved work the owner never saw")
  guard let next = after.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("the copies with unsaved work are asked about")
  }
  equal(next.count, 2)
  equal(next.risks, ["changes=small"])
  let cautions: [String] = AutopilotPolicy.card(next).cautions
  check(cautions.contains("2 have unsaved changes"), "the card names the risk: \(cautions)")
  equal(next.guess?.sure, false, "BZ isn't sure of a risk the owner never said yes to")

  // A caller that doesn't say what its card showed teaches from the question as BZ last saw it.
  let stored = try await cardThenLook("stored-risks")
  defer { try? FileManager.default.removeItem(at: stored.root) }
  _ = try await stored.engine.apply(.answer(questionID: stored.card.id, answer: .yes), now: now)
  await eventually { stored.world.burns.all.count == 4 }
  equal(stored.world.burns.all.count, 4, "the refreshed question's risks, as before")
  let taught: AutopilotRule? = try stored.store.memory().rules.first {
    $0.questionID == stored.card.id
  }
  equal(taught?.match["changes"], ["small", "none"])
}

/// Things under an answered pattern that the lessons from its answers leave unsure are asked about
/// again, even when a card about the pattern showed all their risks. The owner says yes to copies
/// with work only on this Mac, then to copies with small unsaved changes, on separate cards, and no
/// to a card that also showed copies BZ couldn't tell were in use, which keeps only those. Copies
/// with both risks the owner said yes to apart are covered by no lesson: they are asked about, and a
/// Yes burns them while the copies the No kept stay.
private func reaskUncoveredProof() async throws {
  let now = Date()
  let world = TellWorld(
    copies: [
      agedCopy("local-a", now: now, saved: "local"), agedCopy("local-b", now: now, saved: "local"),
    ])
  let (engine, store, root) = try tellEngine("reask-uncovered", world, AutopilotMemory())
  defer { try? FileManager.default.removeItem(at: root) }
  /// The question about copies after a look at `minutes` past `now`.
  func copiesQuestion(at minutes: Double) async -> AutopilotQuestion? {
    await engine.tick(now: now.addingTimeInterval(minutes * 60)).questions.first {
      $0.kind == .worktree
    }
  }

  // Yes to copies with work only on this Mac.
  guard let q1 = await copiesQuestion(at: 0) else {
    return failTest("a question about the copies with work only on this Mac")
  }
  equal(q1.risks, ["saved=local"])
  _ = try await engine.apply(.answer(questionID: q1.id, answer: .yes, risks: q1.risks), now: now)
  await eventually { world.burns.all.count == 2 }
  // Yes to copies with small unsaved changes, on a card of their own.
  world.add(agedCopy("small-a", now: now, changes: "small"))
  world.add(agedCopy("small-b", now: now, saved: "merged", changes: "small"))
  guard let q2 = await copiesQuestion(at: 1) else {
    return failTest("a question about the copies with small unsaved changes")
  }
  equal(q2.risks, ["changes=small"])
  _ = try await engine.apply(.answer(questionID: q2.id, answer: .yes, risks: q2.risks), now: now)
  await eventually { world.burns.all.count == 4 }
  // No to a card about copies BZ couldn't tell were in use, one of them with both risks.
  world.add(agedCopy("odd-mix", now: now, saved: "local", changes: "small", inUse: "unknown"))
  world.add(agedCopy("odd-clean", now: now, inUse: "unknown"))
  guard let q3 = await copiesQuestion(at: 2) else {
    return failTest("a question about the copies BZ couldn't tell were in use")
  }
  equal(q3.risks, ["changes=small", "inUse=unknown", "saved=local"])
  let refused = try await engine.apply(
    .answer(questionID: q3.id, answer: .no, risks: q3.risks), now: now)
  equal(status(refused, "odd-mix"), .keep, "the No keeps odd-mix")
  equal(status(refused, "odd-clean"), .keep, "and odd-clean")
  let keeps: [AutopilotRule] = try store.memory().rules.filter { $0.questionID == q3.id }
  equal(keeps.map { $0.match["inUse"] }, [["unknown"]], "it keeps only copies not checked for use")

  // Copies with both risks the owner said yes to, on separate cards: no lesson covers them.
  world.add(agedCopy("both-a", now: now, saved: "local", changes: "small"))
  world.add(agedCopy("both-b", now: now, saved: "local", changes: "small"))
  let later = await engine.tick(now: now.addingTimeInterval(180))
  equal(status(later, "both-a"), .unsure, "no lesson covers a copy with both risks")
  guard let q4 = later.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("the copies with both risks are asked about")
  }
  equal(q4.count, 2)
  equal(q4.risks, ["changes=small", "saved=local"])
  checkFalse([q1.id, q2.id, q3.id].contains(q4.id), "a question of its own: \(q4.id)")
  _ = try await engine.apply(.answer(questionID: q4.id, answer: .yes, risks: q4.risks), now: now)
  await eventually { world.burns.all.count == 6 }
  check(
    world.burns.all.contains("worktree:both-a") && world.burns.all.contains("worktree:both-b"),
    "the Yes burns them: \(world.burns.all)")
  checkFalse(
    world.burns.all.contains("worktree:odd-mix") || world.burns.all.contains("worktree:odd-clean"),
    "the copies the No kept stay")
  let settled = await engine.tick(now: now.addingTimeInterval(240))
  checkFalse(
    settled.questions.contains { $0.kind == .worktree }, "nothing left to ask about copies")
}
