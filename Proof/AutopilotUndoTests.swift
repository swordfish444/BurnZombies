import BurnCore
import Foundation

/// Undo stays exact and safe. It stops BZ's lesson before it restores anything, waits
/// for burns already under way, and brings back exactly what BZ's act burned. It leaves the owner's
/// lessons and burns alone, and a look never burns more than its bound across its passes.
func undoSafetyProof() async throws {
  try await undoRaceProof()
  try await standaloneProof()
  try await absorbedUndoProof()
  try await scopeProof()
  try await leftoverUndoProof()
  try await tellBookkeepingProof()
  try await failedRestoreProof()
}

/// A restore that fails during an Undo: the tell stays in view, undone, saying what didn't come
/// back and why. The lesson and trust still flip.
private func failedRestoreProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now))
  let (engine, store, root) = try tellEngine("undo-failed", world, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: root) }
  guard let tell = await engine.tick(now: now).tells.first else {
    return failTest("failed restore: a tell to undo")
  }
  world.refuseRestores("The restore point is gone.")
  let undone = try await engine.apply(.tellUndo(id: tell.id), now: now)
  equal(world.restores.all, [], "failed restore: nothing came back")
  guard let shown = undone.tells.first(where: { $0.id == tell.id }) else {
    return failTest("failed restore: the tell stays in view after the Undo")
  }
  equal(shown.state, "undone", "failed restore: the Undo itself is done")
  equal(
    shown.note, "3 copies couldn't come back. The restore point is gone.",
    "failed restore: the tell says which didn't come back, and why")
  check(shown.waitsForOK, "failed restore: the tell waits for the owner's OK")
  let after = try store.memory()
  equal(after.rules.first { $0.questionID == tell.questionID }?.verdict, .keep, "the lesson flips")
  equal(after.scores.last?.right, false, "and BZ's guess scores wrong")

  // OK closes it. A second OK changes nothing, and OK on an open tell leaves it open.
  let seen = try await engine.apply(.tellSeen(id: tell.id), now: now)
  checkFalse(seen.tells.contains { $0.id == tell.id }, "failed restore: OK closes it")
  let read = try store.memory()
  equal(read.tells.first?.seen, true, "failed restore: the note was seen")
  equal(read.tells.first?.note, shown.note, "and keeps what it said")
  _ = try await engine.apply(.tellSeen(id: tell.id), now: now)
  equal(try store.memory().tells, read.tells, "failed restore: a second OK changes nothing")
  let openWorld = TellWorld(copies: threeCopies(now))
  let (open, openStore, openRoot) = try tellEngine(
    "undo-ok-open", openWorld, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: openRoot) }
  guard let waiting = await open.tick(now: now).tells.first else {
    return failTest("failed restore: an open tell")
  }
  let stillOpen = try await open.apply(.tellSeen(id: waiting.id), now: now)
  equal(stillOpen.tells.map(\.id), [waiting.id], "OK on an open tell leaves it open")
  equal(try openStore.memory().tells.first?.state, "open")
}

/// The owner clicks Undo while BZ is still retiring the copies it acted on. Nothing starts to burn
/// after the click; the copy already under way finishes and comes back. While the undo runs, Good
/// call, Forget and a second Undo are refused.
private func undoRaceProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now), delay: 0.6)
  let (engine, store, root) = try tellEngine("undo-race", world, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: root) }
  let ticking = Task { await engine.tick(now: now) }
  await eventually { !world.burns.all.isEmpty }
  guard let tell = try store.memory().tells.first else {
    return failTest("a tell while its copies are still burning")
  }
  let clicked = Date()
  let undoing = Task { try await engine.apply(.tellUndo(id: tell.id), now: Date()) }
  await eventually { (try? store.memory().tells.first?.state) == "undoing" }
  let during = try store.memory()
  equal(during.tells.first?.state, "undoing", "the tell is undoing")
  isNil(during.rules.first { $0.id == tell.ruleID })
  guard let keep = during.rules.first(where: { $0.questionID == tell.questionID }) else {
    return failTest("the lesson is a keep before anything is restored")
  }
  equal(keep.verdict, .keep)
  let refused: [AutopilotCommand] = [
    .tellGood(id: tell.id), .tellUndo(id: tell.id), .forgetLesson(ruleIDs: [keep.id]),
    .forgetRule(ruleID: keep.id),
  ]
  for command in refused {
    do {
      _ = try await engine.apply(command, now: Date())
      failTest("refused while undoing: \(command)")
    } catch {
      equal(error.localizedDescription, "I'm already undoing that.", "\(command)")
    }
  }
  _ = try await undoing.value
  _ = await ticking.value
  let burned = world.burns.all
  equal(burned.count, 1, "only the copy already under way burned")
  for id in burned {
    let start = world.startedBurning(id) ?? .distantFuture
    check(start < clicked, "\(id) started burning before Undo")
  }
  equal(Set(world.restores.all), Set(burned), "and it came back")
  let after = try store.memory()
  equal(after.tells.first?.state, "undone")
  let made = try store.receipts().filter { $0.authority == "rule:" + tell.ruleID }
  equal(made.map(\.outcome), ["restored"], "every burn BZ's lesson made is restored")
}

/// BZ's lesson takes nothing in, and nothing joins it. An owner's lesson inside its reach
/// stands, and a later owner answer it reaches becomes a lesson of its own, so Undo takes back
/// only what BZ did.
private func standaloneProof() async throws {
  let now = Date()
  var memory = trustedCopies(now: now)
  // The owner also said yes to merged copies with no changes, untouched for a week: BZ's lesson
  // for the week-old copies reaches all of those too, and no other lesson of the owner's does.
  let dayAgo = now.addingTimeInterval(-86_400)
  let clean = ownerYes(
    .worktree, ["saved": ["merged"], "changes": ["none"], "inUse": ["no"], "stale": ["week"]],
    risks: [], at: dayAgo)
  memory.questions.append(clean)
  let cleanLesson = AutopilotPolicy.lesson(for: clean, verdict: .burn, created: dayAgo)
  AutopilotPolicy.learn(cleanLesson, into: &memory.rules)
  equal(memory.rules.count, 3, "three owner lessons")
  let world = TellWorld(copies: threeCopies(now))
  let (engine, store, root) = try tellEngine("undo-standalone", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  guard let tell = await engine.tick(now: now).tells.first else {
    return failTest("a tell whose lesson reaches an owner's lesson")
  }
  var after = try store.memory()
  guard let act = after.rules.first(where: { $0.id == tell.ruleID }) else {
    return failTest("BZ's lesson")
  }
  check(AutopilotPolicy.subsumes(act.match, cleanLesson.match), "BZ's lesson reaches it")
  for rule in memory.rules {
    equal(after.rules.first { $0.id == rule.id }, rule, "an owner's lesson in BZ's reach stands")
  }
  // The owner answers a question only BZ's lesson reaches: it teaches a lesson of its own.
  let later = AutopilotQuestion(
    kind: .worktree,
    match: ["saved": ["pushed"], "changes": ["none"], "inUse": ["no"], "stale": ["week"]],
    question: "Can I burn copies already on GitHub, untouched for a week?", why: "",
    examples: [], count: 1, bytes: 1_000_000_000, asked: now)
  try store.updateMemory { $0.questions.append(later) }
  _ = try await engine.apply(.answer(questionID: later.id, answer: .yes), now: now)
  after = try store.memory()
  isNil(after.rules.first { $0.id == tell.ruleID }?.from)
  check(
    after.rules.contains { $0.questionID == later.id }, "the owner's answer is a lesson of its own")
  _ = try await engine.apply(.tellUndo(id: tell.id), now: now)
  after = try store.memory()
  equal(
    after.rules.first { $0.questionID == later.id }?.verdict, .burn,
    "and it outlives BZ's Undo")
  equal(after.questions.first { $0.id == later.id }?.answer, .yes, "the owner's answer stays")
}

/// The owner answered a wider question after BZ acted, and the owner's lesson took BZ's in. Undo
/// still brings back what BZ burned and scores BZ wrong, but learns no keep: the newer answer
/// stands.
private func absorbedUndoProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now))
  let (engine, store, root) = try tellEngine("undo-absorbed", world, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: root) }
  guard let tell = await engine.tick(now: now).tells.first else {
    return failTest("a tell whose lesson the owner's newer answer takes in")
  }
  let wider = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["day"]],
    question: "Can I burn old project copies untouched since yesterday?", why: "", examples: [],
    count: 2, bytes: 2_000_000_000, asked: now)
  try store.updateMemory { $0.questions.append(wider) }
  _ = try await engine.apply(.answer(questionID: wider.id, answer: .yes), now: now)
  let before = try store.memory()
  let owner = before.rules.first { $0.questionID == wider.id }
  check(owner?.formerIDs?.contains(tell.ruleID) == true, "the owner's lesson took BZ's in")
  isNil(before.rules.first { $0.id == tell.ruleID })
  _ = try await engine.apply(.tellUndo(id: tell.id), now: now)
  let after = try store.memory()
  equal(Set(world.restores.all), Set(world.copies.map(\.id)), "BZ's burns come back")
  equal(after.tells.first?.state, "undone")
  equal(after.tells.first?.note, "Your newer answer stands.")
  check(after.tells.first?.waitsForOK == true, "the note stays in view until the owner's OK")
  equal(after.scores.count, before.scores.count + 1)
  equal(after.scores.last?.right, false, "BZ's guess scores wrong")
  checkFalse(after.rules.contains { $0.verdict == .keep }, "no keep is learned")
  equal(
    after.rules.first { $0.questionID == wider.id }?.verdict, .burn, "the newer answer stands")
}

/// One look burns at most 20 copies across all its passes. Undo brings back only what BZ's own
/// lesson burned, never what the owner's lesson burned in the same look.
private func scopeProof() async throws {
  let now = Date()
  // The owner's lesson covers copies untouched for a month; BZ acts on the ones untouched for a
  // week.
  let monthOld = (1...15).map {
    weekCopy("month-\($0)", stale: "month", bytes: 200_000_000, now: now)
  }
  let weekOld = (1...10).map { weekCopy("week-\($0)", now: now) }
  let world = TellWorld(copies: monthOld + weekOld)
  let memory = trustedCopies(now: now)
  let (engine, store, root) = try tellEngine("undo-scope", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  let first = await engine.tick(now: now)
  let bound: Int = Autopilot.maximumBurns[.worktree] ?? 0
  equal(bound, 20)
  equal(world.burns.all.count, bound, "20 copies in one look, across both passes")
  guard let tell = first.tells.first else { return failTest("a tell for the week-old copies") }
  let burned = try store.receipts().filter { $0.outcome == "burned" }
  let owners = burned.filter { $0.authority == "rule:" + memory.rules[0].id }
  let bz = burned.filter { $0.authority == "rule:" + tell.ruleID }
  equal(owners.count, 15, "the owner's lesson burned 15 first")
  equal(bz.count, 5, "BZ's lesson burned the 5 the look had left")
  equal(tell.count, 5, "the tell says what BZ burned")
  equal(tell.bytes, 2_000_000_000)
  equal(tell.rows.count, 3)
  let burnedNames: Set<String> = Set(bz.map(\.name))
  let rowNames: [String] = tell.rows.map { $0.title.replacingOccurrences(of: " ", with: "-") }
  check(
    rowNames.allSatisfy(burnedNames.contains), "its rows are copies BZ burned: \(rowNames)")
  _ = try await engine.apply(.tellUndo(id: tell.id), now: now)
  equal(Set(world.restores.all), Set(bz.map(\.itemID)), "Undo brings back only BZ's burns")
  checkFalse(
    world.restores.all.contains { $0.hasPrefix("worktree:month-") },
    "never one the owner's lesson burned in the same look")
}

/// An undo cut short by a quit leaves its tell undoing. It never expires, it is still shown, and
/// Undo picks it up again.
private func leftoverUndoProof() async throws {
  let now = Date()
  var memory = AutopilotMemory()
  memory.tells = [
    AutopilotTell(
      id: "left", questionID: "q-left", ruleID: "r-left", kind: .worktree, count: 1,
      bytes: 1_000_000_000, rows: [], why: "You said yes to 2 like these.",
      date: now.addingTimeInterval(-8 * 86_400), state: "undoing")
  ]
  let (engine, store, root) = try tellEngine("undo-left", TellWorld(), memory)
  defer { try? FileManager.default.removeItem(at: root) }
  let snapshot = await engine.tick(now: now)
  equal(try store.memory().tells.first?.state, "undoing", "an undo under way never expires")
  equal(snapshot.tells.map(\.id), ["left"], "and is still shown")
  _ = try await engine.apply(.tellUndo(id: "left"), now: now)
  equal(try store.memory().tells.first?.state, "undone", "Undo picks it up again")
}

/// Closed tells are kept to the last 100, BZ's own calls aren't the owner's answers, and a week's
/// questions leave out ones that were tells.
private func tellBookkeepingProof() async throws {
  let now = Date()
  func tell(_ id: String, minutesAgo: Double, state: String) -> AutopilotTell {
    AutopilotTell(
      id: id, questionID: "q-" + id, ruleID: "r-" + id, kind: .worktree, count: 1,
      bytes: 1_000_000_000, rows: [], why: "", date: now.addingTimeInterval(-minutesAgo * 60),
      state: state)
  }
  var many = AutopilotMemory()
  many.tells = (0..<101).map { tell("closed-\($0)", minutesAgo: Double(200 - $0), state: "expired") }
  many.tells.append(tell("open", minutesAgo: 1, state: "open"))
  let (engine, store, root) = try tellEngine("tells-kept", TellWorld(), many)
  defer { try? FileManager.default.removeItem(at: root) }
  _ = await engine.tick(now: now)
  let kept = try store.memory().tells
  let closed = kept.filter { $0.state != "open" }
  equal(closed.count, 100, "the last 100 closed tells")
  equal(closed.first?.id, "closed-1", "the oldest goes")
  equal(kept.last?.id, "open", "an open tell always stays")

  var counted = AutopilotMemory()
  var call = ownerYes(.worktree, ["stale": ["week"]], risks: [], at: now)
  call.answeredBy = "bz"
  var no = ownerYes(.worktree, ["stale": ["day"]], risks: [], at: now)
  no.answer = .no
  counted.questions = [call, no]
  equal(counted.answers, 1, "BZ's own calls aren't the owner's answers")

  var weekly = AutopilotMemory()
  let shown = ownerYes(.worktree, ["stale": ["day"]], risks: [], at: now.addingTimeInterval(-3600))
  var undone = ownerYes(.worktree, ["stale": ["week"]], risks: [], at: now.addingTimeInterval(-3600))
  undone.answer = .no
  weekly.questions = [shown, undone]
  var told = tell("told", minutesAgo: 60, state: "undone")
  told.questionID = undone.id
  weekly.tells = [told]
  let lines = AutopilotPolicy.progress(weekly, receipts: [], impact: nil, now: now).lines
  check(
    lines.contains("This week: 1 question, 0 MB burned on my own."),
    "a question that was a tell isn't one the owner was shown: \(lines)")
}
