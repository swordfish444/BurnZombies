import BurnCore
import Foundation

/// Act, then tell (spec 3.4): once BZ has earned trust on a subject and is sure the owner would say
/// yes, it burns on its own and tells the owner afterwards, who can call it good or undo it.
func tellProof() async throws {
  try await scoreProof()
  try await actProof()
  try await tellRowsProof()
  try await goodCallProof()
  try await undoProof()
  try await programUndoProof()
  try await expiryProof()
  try await forgetTellProof()
  try await askActProof()
  try await lookOnlyActProof()
  try await lookOnlyAfterActProof()
  try await undoSafetyProof()
}

// MARK: A Mac BZ has learned about

/// What an engine's fake sources did. Something burned is gone until it is restored. A copy can
/// take `delay` to retire, the way Git takes its time, and restores can be made to fail.
final class TellWorld: @unchecked Sendable {
  let burns = Calls()
  let restores = Calls()
  let delay: TimeInterval
  private let lock = NSLock()
  private var items: [AutopilotItem]
  private var started: [String: Date] = [:]
  private var restoreRefusal: String?
  /// Every restore from now on fails, saying `reason`.
  func refuseRestores(_ reason: String) { lock.withLock { restoreRefusal = reason } }
  private func refusal() -> String? { lock.withLock { restoreRefusal } }
  init(copies: [AutopilotItem] = [], programs: [AutopilotItem] = [], delay: TimeInterval = 0) {
    items = copies + programs
    self.delay = delay
  }
  var copies: [AutopilotItem] { lock.withLock { items.filter { $0.kind == .worktree } } }
  var programs: [AutopilotItem] { lock.withLock { items.filter { $0.kind == .process } } }
  /// Something new shows up on the Mac.
  func add(_ item: AutopilotItem) { lock.withLock { items.append(item) } }
  /// When BZ started to burn it.
  func startedBurning(_ id: String) -> Date? { lock.withLock { started[id] } }
  func present(_ items: [AutopilotItem]) -> [AutopilotItem] {
    let burned = Set(burns.all)
    let back = Set(restores.all)
    return items.filter { !burned.contains($0.id) || back.contains($0.id) }
  }
  private func starting(_ id: String) {
    lock.withLock { started[id] = Date() }
    burns.add(id)
  }
  var sources: AutopilotSources {
    AutopilotSources(
      processes: { _ in self.present(self.programs) },
      worktrees: { _, _, delivery in (self.present(self.copies), delivery) },
      burnProcess: { item, _, _ in
        self.starting(item.id)
        return UUID()
      },
      processOutcome: { _ in ("verified", "") },
      retireWorktree: { item, authority in
        self.starting(item.id)
        if self.delay > 0 { Thread.sleep(forTimeInterval: self.delay) }
        let backup = AutopilotRestore(
          repository: "/fixture/.git", path: "/fixture/" + item.name,
          ref: "refs/fixture/" + item.name, head: String(repeating: "0", count: 40), branch: nil,
          snapshot: false)
        return AutopilotReceipt(
          itemID: item.id, kind: .worktree, name: item.name, authority: authority,
          outcome: "burned", detail: "", bytes: item.bytes, restore: backup)
      },
      restoreWorktree: { receipt in
        if let reason = self.refusal() { throw StoreError.message(reason) }
        self.restores.add(receipt.itemID)
      })
  }
}

/// A copy BZ isn't sure about: untouched for a week, with work only on this Mac.
func weekCopy(
  _ name: String, changes: String = "none", stale: String = "week",
  bytes: UInt64 = 400_000_000, now: Date
) -> AutopilotItem {
  AutopilotItem(
    id: "worktree:" + name, kind: .worktree, name: name, bytes: bytes,
    facts: [
      "repo": "web-app", "place": "patrol6", "saved": "local", "changes": changes,
      "stale": stale, "inUse": "no", "thread": "none",
    ], lastUsed: now.addingTimeInterval(-10 * 86_400),
    title: name.replacingOccurrences(of: "-", with: " "))
}

/// Three copies untouched for a week, 1.2 GB in all, one with unsaved changes.
func threeCopies(_ now: Date) -> [AutopilotItem] {
  [
    weekCopy("fix-login", now: now), weekCopy("dark-mode", now: now),
    weekCopy("tidy-footer", changes: "small", now: now),
  ]
}

/// A Node program serving a port, idle for 6 hours; its app may still be open.
func idleServer(_ name: String, now: Date) -> AutopilotItem {
  AutopilotItem(
    id: "process:" + name, kind: .process, name: name, bytes: 700_000_000,
    facts: [
      "family": "node", "orphaned": "maybe", "thread": "none", "idle": "6h", "listening": "yes",
      "agent": "codex",
    ], processKey: name, lastUsed: now.addingTimeInterval(-7 * 3600))
}

/// A question the owner said yes to.
func ownerYes(
  _ kind: AutopilotKind, _ match: [String: [String]], risks: [String], at date: Date
) -> AutopilotQuestion {
  var question = AutopilotQuestion(
    kind: kind, match: match, question: "Can I burn these?", why: "", examples: [], count: 2,
    bytes: 2_000_000_000, asked: date)
  question.answer = .yes
  question.answered = date
  question.risks = risks
  return question
}

/// Memory after the owner said yes to `answers`, learned as lessons, and BZ guessed its last 5 on
/// `subject` right.
func trustedOn(_ subject: String, _ answers: [AutopilotQuestion], now: Date)
  -> AutopilotMemory
{
  var memory = AutopilotMemory()
  memory.questions = answers
  for question in answers {
    let lesson = AutopilotPolicy.lesson(
      for: question, verdict: .burn, created: question.answered ?? now)
    AutopilotPolicy.learn(lesson, into: &memory.rules)
  }
  memory.scores = (0..<AutopilotPolicy.trustStreak).map { i in
    AutopilotScore(
      questionID: "\(subject)-\(i)", subject: subject, guess: .yes, answer: .yes, right: true,
      date: now.addingTimeInterval(Double(i - 10)))
  }
  return memory
}

/// R4: the owner said yes to copies untouched for a month with work only on this Mac, and to ones
/// with unsaved changes. Their lessons leave copies untouched for a week unsure. The first lesson
/// has burned 4 copies.
func trustedCopies(now: Date) -> AutopilotMemory {
  let local = ownerYes(
    .worktree, ["saved": ["local"], "stale": ["month"]], risks: ["saved=local"],
    at: now.addingTimeInterval(-3 * 86_400))
  let unsaved = ownerYes(
    .worktree, ["changes": ["small"], "stale": ["month"]], risks: ["changes=small"],
    at: now.addingTimeInterval(-2 * 86_400))
  var memory = trustedOn("worktree:", [local, unsaved], now: now)
  if let first = memory.rules.first {
    memory.tallies[first.id] = AutopilotTally(count: 4, bytes: 9_000_000_000, undone: 0)
  }
  return memory
}

/// An engine over `world` whose memory starts as `memory`, in a fresh temporary root.
func tellEngine(_ name: String, _ world: TellWorld, _ memory: AutopilotMemory) throws
  -> (Autopilot, AutopilotStore, URL)
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-tell-" + name + "-" + UUID().uuidString)
  let store = try AutopilotStore(root: root)
  try store.save(memory: memory)
  return (try Autopilot(root: root, sources: world.sources), store, root)
}

// MARK: Score

/// Answering a question BZ guessed scores the guess once, however often the answer comes. Skips
/// teach nothing and aren't scored.
private func scoreProof() async throws {
  let now = Date()
  var memory = trustedCopies(now: now)
  let start = memory.scores.count
  var guessed = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["week"]], question: "Can I burn 3 copies?", why: "",
    examples: [], count: 3, bytes: 1_200_000_000, asked: now)
  guessed.guess = AutopilotGuess(answer: .yes, sure: false, why: "You said yes to 2 like these.")
  var skipped = AutopilotQuestion(
    kind: .process, match: ["family": ["node"], "idle": ["1d"]], question: "Can I burn them?",
    why: "", examples: [], count: 1, bytes: 1_500_000_000, asked: now)
  skipped.guess = AutopilotGuess(answer: .yes, sure: false, why: "You said yes to 1 like this.")
  memory.questions += [guessed, skipped]
  let (engine, store, root) = try tellEngine("score", TellWorld(), memory)
  defer { try? FileManager.default.removeItem(at: root) }

  _ = try await engine.apply(.answer(questionID: guessed.id, answer: .no), now: now)
  var scores = try store.memory().scores
  equal(scores.count, start + 1, "a No to a question BZ guessed is scored")
  equal(scores.last?.right, false, "BZ guessed yes")
  equal(scores.last?.questionID, guessed.id)
  equal(scores.last?.subject, "worktree:")
  equal(scores.last?.guess, .yes)
  equal(scores.last?.answer, .no)
  checkFalse(AutopilotPolicy.trusted("worktree:", scores: scores), "a wrong guess ends trust")
  _ = try await engine.apply(.answer(questionID: guessed.id, answer: .no), now: now)
  equal(try store.memory().scores.count, start + 1, "the same answer again isn't scored twice")
  _ = try await engine.apply(.answer(questionID: skipped.id, answer: .skip), now: now)
  equal(try store.memory().scores.count, start + 1, "a skip isn't scored")
  _ = try await engine.apply(.answer(questionID: skipped.id, answer: .yes), now: now)
  scores = try store.memory().scores
  equal(scores.count, start + 2, "the Yes after it is")
  equal(scores.last?.right, true)
  equal(scores.last?.subject, "process:node")
}

// MARK: Act

/// A trusted subject and a sure guess: BZ answers yes itself, burns, and tells the owner.
private func actProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now))
  let memory = trustedCopies(now: now)
  let (engine, store, root) = try tellEngine("act", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  let snapshot = await engine.tick(now: now)
  checkFalse(
    snapshot.questions.contains { $0.kind == .worktree }, "no question about copies: BZ was sure")
  guard let tell = snapshot.tells.first, snapshot.tells.count == 1 else {
    return failTest("one open tell: \(snapshot.tells) \(snapshot.questions.map(\.question))")
  }
  equal(tell.state, "open")
  equal(tell.kind, .worktree)
  equal(tell.count, 3)
  equal(tell.bytes, 1_200_000_000)
  equal(
    tell.rows.map(\.title), ["dark mode", "fix login", "tidy footer"],
    "the copies, as a card names them")
  equal(
    tell.why,
    "You said yes to 2 like these, including ones with work only on this Mac and unsaved changes.")
  let stored = try store.memory()
  guard let question = stored.questions.first(where: { $0.id == tell.questionID }) else {
    return failTest("the question BZ answered is kept")
  }
  equal(question.match, ["stale": ["week"]])
  equal(question.answer, .yes, "answered yes")
  equal(question.answeredBy, "bz", "by BZ")
  equal(question.guess?.sure, true)
  // A tick burns what BZ acted on before it returns.
  equal(Set(world.burns.all), Set(world.copies.map(\.id)), "the 3 copies burned")
  let pattern: String = AutopilotRule.key(kind: .worktree, match: ["stale": ["week"]])
  check(question.id != pattern, "BZ's answer leaves the pattern free to ask the owner about")
  guard let lesson = stored.rules.first(where: { $0.id == tell.ruleID }) else {
    return failTest("the tell's lesson exists")
  }
  equal(lesson.verdict, .burn)
  equal(lesson.tellID, tell.id, "marked as the lesson of BZ's own act")
  // What a Yes teaches, kept to the risks the owner said yes to on copies: work only on this Mac
  // and small unsaved changes. Large ones and anything unchecked stay out.
  var approved = AutopilotPolicy.lessonMatch(.worktree, ["stale": ["week"]], verdict: .burn)
  approved["saved"] = ["local", "pushed", "merged"]
  approved["changes"] = ["small", "none"]
  approved["inUse"] = ["no"]
  equal(lesson.match, approved, "the lesson a Yes teaches, within the risks the owner approved")
  // R23: it takes nothing in, and the owner's own lessons stay exactly as they were.
  isNil(lesson.from)
  isNil(lesson.formerIDs)
  for rule in memory.rules {
    equal(stored.rules.first { $0.id == rule.id }, rule, "the owner's lesson is untouched")
  }
  let burned = try store.receipts().filter { $0.outcome == "burned" }
  equal(
    Set(burned.map(\.authority)), ["rule:" + tell.ruleID],
    "burned on the lesson's authority, as for a Yes")
  check(burned.allSatisfy { $0.restore != nil }, "each copy backed up first")
  let tallies = try store.memory().tallies
  equal(
    tallies[tell.ruleID], AutopilotTally(count: 3, bytes: 1_200_000_000, undone: 0),
    "BZ's lesson counts its own 3 burns")
  equal(
    tallies[memory.rules[0].id], AutopilotTally(count: 4, bytes: 9_000_000_000, undone: 0),
    "and the owner's lesson keeps its 4")

  // Later a copy untouched for a week shows up with large unsaved changes, which the owner never
  // said yes to: BZ's lesson doesn't burn it, it stays unsure, and BZ asks about it.
  world.add(weekCopy("big-rewrite", changes: "large", bytes: 1_200_000_000, now: now))
  let later = await engine.tick(now: now.addingTimeInterval(60))
  checkFalse(world.burns.all.contains("worktree:big-rewrite"), "not burned under BZ's lesson")
  equal(world.burns.all.count, 3, "nothing burns twice")
  equal(
    later.entries.first { $0.item.id == "worktree:big-rewrite" }?.status, .unsure,
    "it stays unsure")
  guard let risky = later.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("a question about the copy with large unsaved changes")
  }
  equal(risky.match, ["stale": ["week"]], "asked under the pattern BZ answered for the others")
  equal(risky.id, pattern + ":changes=large,saved=local", "its id names the risks its card shows")
  equal(risky.count, 1)
  equal(risky.risks, ["changes=large", "saved=local"])
  equal(risky.guess?.sure, false, "never sure of a risk the owner hasn't said yes to")
  equal(later.tells.count, 1, "still one tell")

  // With acting off, the same Mac is asked, BZ sure, and nothing burns.
  var cautious = trustedCopies(now: now)
  cautious.actsOnItsOwn = false
  let offWorld = TellWorld(copies: threeCopies(now))
  let (offEngine, offStore, offRoot) = try tellEngine("asks", offWorld, cautious)
  defer { try? FileManager.default.removeItem(at: offRoot) }
  let asked = await offEngine.tick(now: now)
  guard let open = asked.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("acting off: an open question about the copies")
  }
  equal(open.guess?.answer, .yes)
  equal(open.guess?.sure, true, "sure, and asked anyway")
  check(asked.tells.isEmpty, "no tell")
  equal(try offStore.memory().tells.count, 0)
  equal(offWorld.burns.all, [], "nothing burned")
  _ = try await offEngine.apply(.setActsOnItsOwn(true), now: now)
  let turnedOn = try offStore.memory().actsOnItsOwn
  check(turnedOn, "the setting is saved")
  _ = try await offEngine.apply(.setActsOnItsOwn(false), now: now)
  let turnedOff = try offStore.memory().actsOnItsOwn
  checkFalse(turnedOff, "both ways")

  // Turned off, Autopilot burns nothing, so it doesn't act either.
  let pausedWorld = TellWorld(copies: threeCopies(now))
  let (paused, _, pausedRoot) = try tellEngine("paused", pausedWorld, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: pausedRoot) }
  _ = try await paused.apply(.setEnabled(false), now: now)
  let idle = await paused.tick(now: now)
  check(idle.tells.isEmpty, "no tell while Autopilot is off")
  equal(pausedWorld.burns.all, [], "nothing burned while Autopilot is off")
  equal(idle.questions.first { $0.kind == .worktree }?.guess?.sure, true, "the question is asked")
}

// MARK: Rows

/// R32: a tell keeps the rows captured at the act, with each copy's task, project and when it was
/// last used. A later look, once the burned copies are gone from the catalog, updates only how many
/// and how much.
private func tellRowsProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now))
  let (engine, store, root) = try tellEngine("rows", world, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: root) }
  guard let acted = await engine.tick(now: now).tells.first else {
    return failTest("a tell whose rows to keep")
  }
  equal(acted.rows.map(\.title), ["dark mode", "fix login", "tidy footer"], "the copies' tasks")
  equal(acted.rows.map(\.subtitle), ["web-app", "web-app", "web-app"], "their project")
  check(acted.rows.allSatisfy { $0.lastUsed != nil }, "and when each was last used")
  let later = await engine.tick(now: now.addingTimeInterval(15 * 60))
  let items: [AutopilotItem] = try store.catalog()?.items ?? []
  let catalogued: [AutopilotItem] = items.filter { $0.kind == .worktree }
  check(catalogued.isEmpty, "the burned copies are gone from the catalog: \(catalogued.map(\.id))")
  guard let kept = later.tells.first else { return failTest("the tell is still open") }
  equal(kept.rows, acted.rows, "the rows from the act stay")
  equal(kept.count, 3)
  equal(kept.bytes, 1_200_000_000)
  equal(try store.memory().tells.first?.rows, acted.rows, "as stored")
}

// MARK: Good call

private func goodCallProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now))
  let (engine, store, root) = try tellEngine("good", world, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: root) }
  guard let tell = await engine.tick(now: now).tells.first else {
    return failTest("a tell to call good")
  }
  let before = try store.memory().scores.count
  let good = try await engine.apply(.tellGood(id: tell.id), now: now)
  check(good.tells.isEmpty, "a good call closes the tell")
  let memory = try store.memory()
  equal(memory.tells.map(\.state), ["good"])
  equal(memory.scores.count, before + 1, "and scores BZ's guess")
  equal(memory.scores.last?.right, true, "right")
  equal(memory.scores.last?.subject, "worktree:")
  equal(memory.scores.last?.questionID, tell.questionID)
  _ = try await engine.apply(.tellGood(id: tell.id), now: now)
  equal(try store.memory().scores.count, before + 1, "a second click scores nothing more")
  do {
    _ = try await engine.apply(.tellUndo(id: tell.id), now: now)
    failTest("a tell called good can't be undone")
  } catch {
    equal(error.localizedDescription, "That one is already closed.")
  }
  equal(world.restores.all, [], "nothing restored")
}

// MARK: Undo

/// Undo brings the copies back, turns the lesson into a keep, records the owner's No and scores BZ
/// wrong. The owner's own lessons were never part of BZ's, so they stand as they were.
private func undoProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now))
  let memory = trustedCopies(now: now)
  let (engine, store, root) = try tellEngine("undo", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  guard let tell = await engine.tick(now: now).tells.first else {
    return failTest("a tell to undo")
  }
  equal(world.burns.all.count, 3)
  let undone = try await engine.apply(.tellUndo(id: tell.id), now: now)
  check(undone.tells.isEmpty, "the tell closes")
  equal(Set(world.restores.all), Set(world.copies.map(\.id)), "the 3 copies are restored")
  let after = try store.memory()
  equal(after.tells.map(\.state), ["undone"])
  isNil(after.tells.first?.note)
  isNil(after.rules.first { $0.id == tell.ruleID })
  let keep = AutopilotPolicy.lessonMatch(.worktree, ["stale": ["week"]], verdict: .keep)
  equal(keep, ["stale": ["today", "day", "week"]])
  let flipped = after.rules.first { $0.questionID == tell.questionID }
  equal(flipped?.verdict, .keep, "the lesson is now a keep")
  equal(flipped?.match, keep, "widened toward riskier, like a No")
  // Nothing the owner taught is touched.
  for rule in memory.rules {
    equal(after.rules.first { $0.id == rule.id }, rule, "the owner's lesson stands as it was")
  }
  equal(
    after.tallies[memory.rules[0].id], AutopilotTally(count: 4, bytes: 9_000_000_000, undone: 0),
    "with what it had done")
  isNil(after.tallies[tell.ruleID])
  let question = after.questions.first { $0.id == tell.questionID }
  equal(question?.answer, .no, "the owner's answer is No")
  isNil(question?.answeredBy)
  equal(after.scores.last?.right, false, "BZ's guess scores wrong")
  equal(after.scores.last?.answer, .no)
  checkFalse(AutopilotPolicy.trusted("worktree:", scores: after.scores), "trust on copies ends")
  check(world.copies.allSatisfy { after.keptItems.contains($0.id) }, "restored copies are kept")
  // R2: a question like the one BZ acted on is asked again, not acted on.
  var again = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["week"]], question: "Can I burn 3 copies?", why: "",
    examples: [], count: 3, bytes: 1_200_000_000)
  again.risks = question?.risks
  equal(AutopilotPolicy.guess(again, memory: after)?.sure, false, "BZ isn't sure about copies now")
  let next = await engine.tick(now: now.addingTimeInterval(60))
  check(next.tells.isEmpty, "and doesn't act on them")
  equal(world.burns.all.count, 3, "the restored copies stay")
  let settled = try store.memory()
  _ = try await engine.apply(.tellUndo(id: tell.id), now: now)
  equal(try store.memory(), settled, "a second undo changes nothing")
  equal(world.restores.all.count, 3)
}

/// A stopped program can't be started again: nothing is restored and the tell says so, but the
/// lesson and trust still flip.
private func programUndoProof() async throws {
  let now = Date()
  let servers = ownerYes(
    .process, ["family": ["node"], "idle": ["1d"]], risks: ["listening=yes"],
    at: now.addingTimeInterval(-86_400))
  let world = TellWorld(programs: [idleServer("vite", now: now), idleServer("storybook", now: now)])
  let memory = trustedOn("process:node", [servers], now: now)
  let (engine, store, root) = try tellEngine("programs", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  let acted = await engine.tick(now: now)
  guard let tell = acted.tells.first else {
    return failTest("a tell about the programs: \(acted.questions.map(\.question))")
  }
  equal(tell.kind, .process)
  equal(tell.count, 2)
  equal(Set(world.burns.all), ["process:vite", "process:storybook"], "both stopped")
  let undone = try await engine.apply(.tellUndo(id: tell.id), now: now)
  equal(world.restores.all, [], "nothing can be restored")
  let after = try store.memory()
  equal(after.tells.first?.state, "undone")
  // The card said so before the press, so the Undo leaves nothing more to read.
  isNil(after.tells.first?.note)
  check(undone.tells.isEmpty, "the tell closes")
  let keep = AutopilotPolicy.lessonMatch(
    .process, ["family": ["node"], "idle": ["6h"]], verdict: .keep)
  let flipped = after.rules.first { $0.questionID == tell.questionID }
  equal(flipped?.verdict, .keep, "the lesson flips")
  equal(flipped?.match, keep)
  equal(
    after.rules.first { $0.questionID == servers.id }?.verdict, .burn, "the owner's lesson stays")
  equal(after.questions.first { $0.id == tell.questionID }?.answer, .no)
  checkFalse(AutopilotPolicy.trusted("process:node", scores: after.scores), "trust flips too")
}

// MARK: Expiry and Forget

/// An untouched tell closes after 7 days, without a score.
private func expiryProof() async throws {
  let now = Date()
  func tell(_ id: String, daysAgo: Double) -> AutopilotTell {
    AutopilotTell(
      id: id, questionID: "q-" + id, ruleID: "r-" + id, kind: .worktree, count: 2,
      bytes: 2_000_000_000, rows: [], why: "You said yes to 2 like these.",
      date: now.addingTimeInterval(-daysAgo * 86_400))
  }
  var memory = AutopilotMemory()
  memory.tells = [tell("old", daysAgo: 8), tell("recent", daysAgo: 6)]
  let (engine, store, root) = try tellEngine("expiry", TellWorld(), memory)
  defer { try? FileManager.default.removeItem(at: root) }
  let snapshot = await engine.tick(now: now)
  equal(try store.memory().tells.map(\.state), ["expired", "open"], "closed after 7 days")
  equal(snapshot.tells.map(\.id), ["recent"], "only open tells are shown")
  equal(try store.memory().scores, [], "without a score")
}

/// Forgetting a group forgets each of its lessons with every answer behind it; a tell whose answer
/// is forgotten closes.
private func forgetTellProof() async throws {
  let now = Date()
  let world = TellWorld(copies: threeCopies(now))
  let memory = trustedCopies(now: now)
  let (engine, store, root) = try tellEngine("forget", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  guard let tell = await engine.tick(now: now).tells.first else {
    return failTest("a tell whose lesson to forget")
  }
  let node = AutopilotRule(
    kind: .process, match: ["family": ["node"], "idle": ["1d"]], verdict: .burn,
    source: .operator, title: "", questionID: "q-node")
  try store.updateMemory { $0.rules.append(node) }
  let forgotten = try await engine.apply(.forgetLesson(ruleIDs: [tell.ruleID, node.id]), now: now)
  check(forgotten.tells.isEmpty, "the tell closes with its answer")
  let after = try store.memory()
  equal(after.rules, memory.rules, "both lessons forgotten; the owner's others stay")
  equal(after.questions, memory.questions, "with the answer behind BZ's lesson, and only that")
  equal(after.tells.map(\.state), ["expired"])
}

// MARK: The AI's questions

/// Waits a little for burns that run in the background.
func eventually(_ done: () -> Bool) async {
  for _ in 0..<60 where !done() { try? await Task.sleep(nanoseconds: 50_000_000) }
}

/// A question the AI asks is acted on like BZ's own when BZ is sure and the AI expects a yes too.
/// The AI's No, or a lesson that would reach riskier copies elsewhere, leaves it asked.
private func askActProof() async throws {
  let now = Date()
  let sentence = "I was sure you'd say yes, so I burned them and will tell the owner."
  func aiAsk(_ match: [String: [String]], guess: String, replacing: String) -> AutopilotRequest {
    var input = AutopilotQuestionInput(
      kind: .worktree, match: match, question: "Can I burn the copies nobody touched this week?")
    input.guess = guess
    var request = AutopilotRequest(tool: "ask")
    request.question = input
    request.replace = replacing
    return request
  }
  // BZ's own question stays open while acting is off; with acting on, the AI replaces it.
  var cautious = trustedCopies(now: now)
  cautious.actsOnItsOwn = false
  let world = TellWorld(copies: threeCopies(now))
  let (engine, store, root) = try tellEngine("ask-act", world, cautious)
  defer { try? FileManager.default.removeItem(at: root) }
  guard let native = await engine.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("BZ's own question for the AI to replace") }
  _ = try await engine.apply(.setActsOnItsOwn(true), now: now)
  let (ok, reply) = await engine.handle(
    aiAsk(["saved": ["local"], "stale": ["week"]], guess: "yes", replacing: native.id))
  check(ok, reply)
  // JSON like every other reply, carrying the sentence and that BZ acted.
  let heard = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
  equal(heard?["message"] as? String, sentence, "the AI hears that BZ acted: \(reply)")
  equal(heard?["acted"] as? Bool, true, "and that it acted, as a field")
  let memory = try store.memory()
  guard let tell = memory.tells.first(where: \.isOpen) else {
    return failTest("a tell for the AI's question")
  }
  equal(tell.count, 3)
  let asked = memory.questions.first { $0.id == tell.questionID }
  equal(asked?.source, "ai")
  equal(asked?.answer, .yes)
  equal(asked?.answeredBy, "bz")
  equal(asked?.guess?.source, "ai")
  equal(asked?.guess?.sure, true)
  isNil(memory.questions.first { $0.id == native.id })
  await eventually {
    let receipts = (try? store.receipts()) ?? []
    return receipts.filter { $0.outcome == "burned" }.count == 3
  }
  equal(Set(world.burns.all), Set(world.copies.map(\.id)), "burned in the background, like a Yes")
  equal(Set(try store.receipts().map(\.authority)), ["rule:" + tell.ruleID])

  // The AI's No keeps BZ from acting, sure as BZ is.
  let noWorld = TellWorld(copies: threeCopies(now))
  let (noEngine, noStore, noRoot) = try tellEngine("ask-no", noWorld, cautious)
  defer { try? FileManager.default.removeItem(at: noRoot) }
  guard let open = await noEngine.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("BZ's own question for the AI to replace with a No") }
  _ = try await noEngine.apply(.setActsOnItsOwn(true), now: now)
  let (noOK, noReply) = await noEngine.handle(
    aiAsk(["saved": ["local"], "stale": ["week"]], guess: "no", replacing: open.id))
  check(noOK, noReply)
  checkFalse(noReply == sentence, "asked, not acted on")
  let noMemory = try noStore.memory()
  equal(noMemory.tells.count, 0)
  let kept = noMemory.questions.first { $0.isOpen && $0.source == "ai" }
  equal(kept?.guess?.answer, .no)
  equal(kept?.guess?.sure, false)
  equal(kept?.guess?.source, "ai")
  equal(noWorld.burns.all, [])

  // The lesson reaches further than the AI's question: a yes about web-app copies teaches about
  // every project's, and a docs copy has unsaved work the owner never said yes to. BZ asks.
  let docs = AutopilotItem(
    id: "worktree:docs-draft", kind: .worktree, name: "docs-draft", bytes: 400_000_000,
    facts: [
      "repo": "docs", "place": "patrol6", "saved": "local", "changes": "large", "stale": "week",
      "inUse": "no", "thread": "none",
    ])
  let farWorld = TellWorld(copies: threeCopies(now) + [docs])
  let (farEngine, farStore, farRoot) = try tellEngine("ask-reach", farWorld, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: farRoot) }
  let first = await farEngine.tick(now: now)
  check(first.tells.isEmpty, "BZ isn't sure of its own question: unsaved work never said yes to")
  guard let wide = first.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("BZ's own question about the four copies")
  }
  equal(wide.guess?.sure, false)
  let (farOK, farReply) = await farEngine.handle(
    aiAsk(["repo": ["web-app"], "stale": ["week"]], guess: "yes", replacing: wide.id))
  check(farOK, farReply)
  checkFalse(farReply == sentence, "the AI's narrower question is asked, not acted on")
  let far = try farStore.memory()
  equal(far.tells.count, 0)
  let narrow = far.questions.first { $0.isOpen && $0.source == "ai" }
  equal(narrow?.count, 3, "about the web-app copies")
  equal(narrow?.guess?.sure, false, "its lesson would reach the docs copy")
  equal(farWorld.burns.all, [])
}

// MARK: Look-only

/// Look-only burns nothing on its own until the owner starts burning, so BZ doesn't act either: a
/// question it is sure of is asked, at a look, after an answer and when the AI asks it. A tell would
/// say BZ burned what is still there.
private func lookOnlyActProof() async throws {
  let now = Date()
  // At a look.
  let lookWorld = TellWorld(copies: threeCopies(now))
  let (look, lookStore, lookRoot) = try tellEngine("look-only", lookWorld, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: lookRoot) }
  _ = try await look.apply(.setLookOnly(true), now: now)
  let looked = await look.tick(now: now)
  check(looked.tells.isEmpty, "look-only: no tell at a look")
  equal(
    looked.questions.first { $0.kind == .worktree }?.guess?.sure, true,
    "look-only: BZ is sure of the copies and asks")
  equal(try lookStore.memory().tells.count, 0)
  equal(lookWorld.burns.all, [], "look-only: nothing burned at a look")

  // Switched on while a look's first pass is still burning: that same look doesn't act.
  let month = weekCopy("old-month", stale: "month", now: now)
  let slow = TellWorld(copies: threeCopies(now) + [month], delay: 0.5)
  let (slowEngine, slowStore, slowRoot) = try tellEngine(
    "look-only-mid-pass", slow, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: slowRoot) }
  let looking = Task { await slowEngine.tick(now: now) }
  await eventually { slow.burns.all.contains(month.id) }
  _ = try await slowEngine.apply(.setLookOnly(true), now: now)
  let finished = await looking.value
  equal(slow.burns.all, [month.id], "the owner's lesson burned the month-old copy before")
  check(finished.tells.isEmpty, "look-only switched on mid-pass: no tell")
  equal(try slowStore.memory().tells.count, 0)
  equal(
    finished.questions.first { $0.kind == .worktree }?.guess?.sure, true,
    "BZ is sure, and asks")

  // After an answer. Three kinds of program, each serving a port and bigger than the copies, take
  // the three slots; answering one frees a slot for the copies.
  func server(_ family: String) -> AutopilotItem {
    AutopilotItem(
      id: "process:" + family, kind: .process, name: family, bytes: 1_500_000_000,
      facts: [
        "family": family, "orphaned": "maybe", "thread": "none", "idle": "1d",
        "listening": "yes", "agent": "none",
      ], processKey: family)
  }
  let servers = ["python", "ruby", "java"].map(server)
  let world = TellWorld(copies: threeCopies(now), programs: servers)
  let (engine, store, root) = try tellEngine("look-only-answer", world, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try await engine.apply(.setLookOnly(true), now: now)
  let first = await engine.tick(now: now)
  equal(Set(first.questions.map(\.kind)), [.process], "the programs take the three slots")
  guard let python = first.questions.first(where: { $0.match["family"] == ["python"] }) else {
    return failTest("look-only: a question about the python program")
  }
  let answered = try await engine.apply(.answer(questionID: python.id, answer: .no), now: now)
  check(answered.tells.isEmpty, "look-only: no tell after an answer")
  guard let copies = answered.questions.first(where: { $0.kind == .worktree }) else {
    return failTest("look-only: the copies are asked after an answer")
  }
  equal(copies.guess?.sure, true, "look-only: sure, and asked")

  // When the AI asks, sure and expecting a yes.
  var input = AutopilotQuestionInput(
    kind: .worktree, match: ["saved": ["local"], "stale": ["week"]],
    question: "Can I burn the copies nobody touched this week?")
  input.guess = "yes"
  var request = AutopilotRequest(tool: "ask")
  request.question = input
  request.replace = copies.id
  let (ok, reply) = await engine.handle(request)
  check(ok, reply)
  checkFalse(reply.contains("I burned them"), "look-only: the AI hears nothing burned: \(reply)")
  let memory = try store.memory()
  equal(memory.tells.count, 0, "look-only: no tell at all")
  let asked = memory.questions.first { $0.isOpen && $0.source == "ai" }
  equal(asked?.guess?.sure, true, "the AI's question is asked, BZ sure")
  try await Task.sleep(nanoseconds: 300_000_000)
  equal(world.burns.all, [], "look-only: nothing burned")
}

extension Autopilot {
  /// `request`, then look-only switched on, in one turn of the engine: whatever the request starts in
  /// the background, like the burns after BZ acts, runs only after both.
  func handleThenLookOnly(_ request: AutopilotRequest, now: Date) async throws -> (Bool, String) {
    let reply: (Bool, String) = await handle(request)
    _ = try await apply(.setLookOnly(true), now: now)
    return reply
  }
}

/// Look-only switched on after BZ acted, before the act's burns start, after an answer and when the
/// AI asks: nothing burns, and the tell says nothing burned rather than "Burned 3", keeping the rows
/// of what BZ meant to burn. Once burning starts, the act's burns go and the tell counts them.
private func lookOnlyAfterActProof() async throws {
  let now = Date()
  func server(_ family: String) -> AutopilotItem {
    AutopilotItem(
      id: "process:" + family, kind: .process, name: family, bytes: 1_500_000_000,
      facts: [
        "family": family, "orphaned": "maybe", "thread": "none", "idle": "1d",
        "listening": "yes", "agent": "none",
      ], processKey: family)
  }
  // Three servers, bigger than the copies, take the three slots; answering one frees a slot, and BZ
  // acts on the copies.
  let world = TellWorld(copies: threeCopies(now), programs: ["python", "ruby", "java"].map(server))
  let (engine, store, root) = try tellEngine("look-only-after-act", world, trustedCopies(now: now))
  defer { try? FileManager.default.removeItem(at: root) }
  let first = await engine.tick(now: now)
  guard let python = first.questions.first(where: { $0.match["family"] == ["python"] }) else {
    return failTest("after act: a question about the python program")
  }
  var answer = AutopilotRequest(tool: "command")
  answer.command = .answer(questionID: python.id, answer: .no)
  let (answered, words) = try await engine.handleThenLookOnly(answer, now: now)
  check(answered, words)
  guard let tell = try store.memory().tells.first else {
    return failTest("after act: BZ acts on the copies once a slot is free")
  }
  equal(tell.rows.count, 3, "after act: the tell names the three copies")
  await eventually { (try? store.memory().tells.first?.count) == 0 }
  equal(world.burns.all, [], "after act: look-only, so nothing burned")
  let held = try store.memory().tells.first
  equal(held?.count, 0, "after act: the tell says nothing burned")
  equal(held?.bytes, 0)
  equal(held?.rows, tell.rows, "after act: and keeps what BZ meant to burn")

  _ = try await engine.apply(.setLookOnly(false), now: now)
  await eventually { (try? store.memory().tells.first?.count) == 3 }
  equal(Set(world.burns.all), Set(world.copies.map(\.id)), "burning on: the act's burns go")
  let burned = try store.memory().tells.first
  equal(burned?.count, 3, "burning on: the tell counts them")
  equal(burned?.rows, tell.rows, "burning on: with the rows captured at the act")

  // When the AI asks and BZ acts.
  var cautious = trustedCopies(now: now)
  cautious.actsOnItsOwn = false
  let askWorld = TellWorld(copies: threeCopies(now))
  let (asker, askStore, askRoot) = try tellEngine("look-only-after-ask", askWorld, cautious)
  defer { try? FileManager.default.removeItem(at: askRoot) }
  guard let native = await asker.tick(now: now).questions.first(where: { $0.kind == .worktree })
  else { return failTest("after ask: BZ's own question for the AI to replace") }
  _ = try await asker.apply(.setActsOnItsOwn(true), now: now)
  var input = AutopilotQuestionInput(
    kind: .worktree, match: ["saved": ["local"], "stale": ["week"]],
    question: "Can I burn the copies nobody touched this week?")
  input.guess = "yes"
  var ask = AutopilotRequest(tool: "ask")
  ask.question = input
  ask.replace = native.id
  let (asked, reply) = try await asker.handleThenLookOnly(ask, now: now)
  check(asked, reply)
  let actedOn: Int = try askStore.memory().tells.count
  equal(actedOn, 1, "after ask: BZ acts on the AI's question")
  await eventually { (try? askStore.memory().tells.first?.count) == 0 }
  equal(askWorld.burns.all, [], "after ask: look-only, so nothing burned")
  equal(try askStore.memory().tells.first?.count, 0, "after ask: the tell says nothing burned")
}

/// A running app for the MCP proof that BZ answers the AI's question itself: BZ trusts itself on old
/// copies, its own question about three of them is open, and it may act on its own.
func runAutopilotActFixture(root: URL) async throws {
  let now = Date()
  var memory = trustedCopies(now: now)
  memory.actsOnItsOwn = false
  try AutopilotStore(root: root).save(memory: memory)
  let engine = try Autopilot(root: root, sources: TellWorld(copies: threeCopies(now)).sources)
  _ = await engine.tick(now: now)
  _ = try await engine.apply(.setActsOnItsOwn(true), now: now)
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: root.appendingPathComponent("observation"),
    accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  let service = AgentService(monitor: monitor, autopilot: engine)
  let listener = try AgentListener(root: root) { await service.call($0) }
  print("READY")
  _ = FileHandle.standardInput.readDataToEndOfFile()
  withExtendedLifetime(listener) {}
}
