import BurnCore
import Foundation

private func encoded(_ rule: AutopilotRule) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(rule)
}

/// Memory from before lessons moves to version 2 once: rules regeneralized and merged, rules that
/// don't pin recency untouched, tallies seeded from receipts, scores replayed.
func migrationProof() async throws {
  let history = try teachHistory()
  let v1 = teachHistoryVersion1(history)
  equal(v1.rules.count, 27, "one rule per Yes or No")
  let receipts = teachHistoryReceipts()
  let migrated = AutopilotPolicy.migrate(v1, receipts: receipts)
  equal(migrated.version, 2)
  equal(migrated.rules.count, 17, "the same 17 lessons the replay learns")
  var expected = Set<String>()
  let lessons: [(AutopilotKind, [String: [String]], AutopilotVerdict)] = [
    (.worktree, TeachLessons.copiesDay, .burn), (.worktree, TeachLessons.unchecked, .burn),
    (.worktree, TeachLessons.unsavedUnchecked, .burn), (.worktree, TeachLessons.sameDay, .burn),
    (.process, TeachLessons.javaBurn, .burn), (.process, TeachLessons.nodeBurn, .burn),
    (.process, TeachLessons.javaKeep, .keep), (.disk, TeachLessons.caches, .burn),
    (.disk, TeachLessons.modules, .burn), (.disk, TeachLessons.builds, .burn),
  ]
  for (kind, match, verdict) in lessons { expected.insert(TeachLessons.id(kind, match, verdict)) }
  for rule in v1.rules where TeachLessons.anyAge.contains(rule.questionID ?? "") {
    expected.insert(rule.id)
  }
  equal(Set(migrated.rules.map(\.id)), expected, "the general lessons and the any-age rules")
  for question in TeachLessons.anyAge {
    let before = v1.rules.first { $0.questionID == question }
    let after = migrated.rules.first { $0.questionID == question }
    check(before != nil && after != nil, "the rule \(question) taught is still there")
    equal(try after.map(encoded), try before.map(encoded), "\(question)'s rule byte for byte")
  }
  let day = migrated.rules.first { $0.id == TeachLessons.copiesDayID }
  equal(
    day?.title, "Burn: Old project copies · Work only on this Mac · Unused since yesterday",
    "a lesson is titled without the project or its maker")
  equal(
    Set(day.map(AutopilotPolicy.questionIDs) ?? []),
    ["q16", "q01", "q02", "q04", "q05", "q07", "q10", "q27"], "with every answer behind it")
  equal(migrated.scores.count, 14, "a score for each guess the replay made on an asked question")
  check(migrated.scores.allSatisfy { $0.replayed == true }, "all marked replayed")
  equal(migrated.questions, v1.questions, "the answers themselves stay")
  // What the owner kept, the AI's judgments and the starter switches come through as they were.
  var owned = v1
  owned.keptItems = ["worktree:kept", "path:/kept"]
  owned.starterDisabled = ["starter-finished-copies"]
  owned.judgments = [
    "worktree:judged": AutopilotJudgment(
      itemID: "worktree:judged", revision: "r", verdict: .burn, confidence: 0.9,
      label: "Old copy", why: "Merged", date: Date(timeIntervalSinceReferenceDate: 815_000_000))
  ]
  let carried = AutopilotPolicy.migrate(owned, receipts: receipts)
  equal(carried.keptItems, owned.keptItems, "kept items survive migration")
  equal(carried.judgments, owned.judgments, "judgments survive migration")
  equal(carried.starterDisabled, owned.starterDisabled, "starter switches survive migration")

  // Receipts count toward the lesson that now holds the rule that made them, by its old id too.
  equal(
    migrated.tallies,
    [TeachLessons.copiesDayID: AutopilotTally(count: 3, bytes: 7_000_000_000, undone: 1)],
    "two burns and a restore by q04's absorbed rule; nothing from starter, AI or the owner")
  let rules = migrated.rules
  equal(
    AutopilotPolicy.lessonID(forAuthority: "rule:" + TeachLessons.q07ID, rules: rules),
    TeachLessons.copiesDayID, "a regeneralized rule's old id finds its lesson")
  equal(
    AutopilotPolicy.lessonID(forAuthority: "rule:" + TeachLessons.javaKeepID, rules: rules),
    TeachLessons.javaKeepID, "a current id is its own lesson")
  for authority in ["starter:starter-finished-copies", "ai:0.90", "operator", "rule:gone"] {
    isNil(AutopilotPolicy.lessonID(forAuthority: authority, rules: rules))
  }

  // Once is enough: version 2 is left as it is, and the same version 1 always migrates the same.
  equal(AutopilotPolicy.migrate(migrated, receipts: receipts), migrated, "migrating twice")
  equal(AutopilotPolicy.migrate(v1, receipts: receipts), migrated, "the same every time")

  try roundTripProof()
  try migrationStoreProof(v1)
  try await tallyEngineProof()
  try await firstTickProof()
}

/// A version-1 file migrates when the engine starts, before a tick changes any receipt, so a stop
/// verified on the first tick counts once. A migration that can't finish then (receipts.json
/// unreadable) finishes on a later load, and a stop that load records still counts once.
private func firstTickProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-first-tick-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let v1 = try JSONEncoder().encode(teachHistoryVersion1(try teachHistory()))
  let lesson = TeachLessons.id(.process, TeachLessons.nodeBurn, .burn)
  func stopping() -> AutopilotReceipt {
    AutopilotReceipt(
      itemID: "process:node", kind: .process, name: "node", authority: "rule:" + lesson,
      outcome: "verifying", detail: "Asked it to stop; checking that it did.",
      bytes: 2_000_000_000, eventID: UUID())
  }
  let verified = AutopilotSources(processOutcome: { _ in ("verified", "") })
  let once = AutopilotTally(count: 1, bytes: 2_000_000_000, undone: 0)

  let store = try AutopilotStore(root: root.appendingPathComponent("start"))
  try store.append(stopping())
  try v1.write(to: store.directory.appendingPathComponent("memory.json"))
  let engine = try Autopilot(root: root.appendingPathComponent("start"), sources: verified)
  let file = store.directory.appendingPathComponent("memory.json")
  let started = try JSONDecoder().decode(AutopilotMemory.self, from: Data(contentsOf: file))
  equal(started.version, 2, "migrated when the engine starts, before any tick")
  _ = await engine.tick(now: Date())
  equal(try store.receipts().first?.outcome, "burned", "the stop was verified")
  equal(try store.memory().tallies[lesson], once, "the first tick's verified stop counts once")

  let late = try AutopilotStore(root: root.appendingPathComponent("late"))
  let receipts = late.directory.appendingPathComponent("receipts.json")
  try Data("not receipts".utf8).write(to: receipts)
  try v1.write(to: late.directory.appendingPathComponent("memory.json"))
  let waiting = try Autopilot(root: root.appendingPathComponent("late"), sources: verified)
  equal(try late.memory().version, 1, "receipts.json can't be read yet")
  try JSONEncoder().encode([stopping()]).write(to: receipts)
  _ = await waiting.tick(now: Date())
  equal(try late.memory().version, 2, "migrated once receipts.json reads")
  equal(try late.memory().tallies[lesson], once, "the stop it recorded counts once")
}

/// Ruling R8: a memory with every field set comes back equal, so a field the hand-written decoder
/// forgets fails here.
private func roundTripProof() throws {
  var full = AutopilotMemory()
  full.version = 7
  var rule = AutopilotRule(
    id: "lesson", kind: .disk, match: ["folder": ["node_modules"]], verdict: .keep,
    source: .operator, title: "Keep: node_modules folders", enabled: false,
    created: Date(timeIntervalSinceReferenceDate: 1_000), questionID: "q-full")
  rule.from = ["q-other"]
  rule.formerIDs = ["old-lesson"]
  full.rules = [rule]
  full.starterDisabled = ["starter-finished-copies"]
  full.keptItems = ["worktree:kept", "path:/kept"]
  var question = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["week"]], question: "Can I burn old copies?", why: "Why",
    examples: ["one"], count: 2, bytes: 3, asked: Date(timeIntervalSinceReferenceDate: 2_000),
    source: "ai")
  question.answer = .yes
  question.answered = Date(timeIntervalSinceReferenceDate: 3_000)
  question.snoozedUntil = Date(timeIntervalSinceReferenceDate: 4_000)
  question.cautions = ["1 has unsaved changes"]
  question.risks = ["changes=small"]
  question.guess = AutopilotGuess(
    answer: .yes, sure: true, why: "You said yes to 1 like this.", source: "ai")
  question.answeredBy = "bz"
  question.rows = [
    AutopilotQuestionRow(
      title: "fix login selector", subtitle: "web-app", bytes: 5,
      lastUsed: Date(timeIntervalSinceReferenceDate: 7_000)),
    AutopilotQuestionRow(title: "node_modules in api", subtitle: nil, bytes: 6, lastUsed: nil),
  ]
  question.newest = Date(timeIntervalSinceReferenceDate: 7_000)
  question.line = "Their work is on GitHub. Nothing is unsaved."
  full.questions = [question]
  full.judgments = [
    "worktree:judged": AutopilotJudgment(
      itemID: "worktree:judged", revision: "r", verdict: .burn, confidence: 0.9, label: "Old copy",
      why: "Merged", date: Date(timeIntervalSinceReferenceDate: 5_000))
  ]
  full.scores = [
    AutopilotScore(
      questionID: "q-full", subject: "worktree:", guess: .yes, answer: .no, right: false,
      date: Date(timeIntervalSinceReferenceDate: 6_000), replayed: true)
  ]
  full.tallies = ["lesson": AutopilotTally(count: 3, bytes: 4, undone: 1)]
  let defaults = Array(Mirror(reflecting: AutopilotMemory()).children)
  let filled = Array(Mirror(reflecting: full).children)
  equal(filled.count, defaults.count)
  for (empty, set) in zip(defaults, filled) {
    let name = set.label ?? "?"
    check(
      String(describing: empty.value) != String(describing: set.value),
      "the round trip sets \(name); add it to this fixture")
  }
  let decoded = try JSONDecoder().decode(AutopilotMemory.self, from: JSONEncoder().encode(full))
  equal(decoded, full, "every field round-trips")
}

private func modified(_ url: URL) -> Date? {
  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
  return attributes?[.modificationDate] as? Date
}

/// A file's bytes, or nil when it isn't there, so a missing file fails a check instead of
/// stopping the proof.
private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

/// The store migrates on first load and keeps the version-1 file beside it, once.
private func migrationStoreProof(_ v1: AutopilotMemory) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-migration-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }

  // A new install starts at version 2 and has nothing to migrate.
  let fresh = try AutopilotStore(root: root.appendingPathComponent("fresh"))
  equal(try fresh.memory().version, 2, "new memory is version 2")
  let freshBackup = fresh.directory.appendingPathComponent("memory.v1.json")
  checkFalse(FileManager.default.fileExists(atPath: freshBackup.path), "no copy of nothing")

  let store = try AutopilotStore(root: root.appendingPathComponent("old"))
  for receipt in teachHistoryReceipts() { try store.append(receipt) }
  let file = store.directory.appendingPathComponent("memory.json")
  let backup = store.directory.appendingPathComponent("memory.v1.json")
  // Written differently from the store's own encoding, so a re-encoded copy can't pass.
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted]
  let original = try encoder.encode(v1)
  try original.write(to: file)
  let loaded = try store.memory()
  equal(loaded.version, 2, "loaded as version 2")
  equal(loaded.rules.count, 17)
  equal(loaded.tallies[TeachLessons.copiesDayID]?.count, 3, "tallied from the store's receipts")
  equal(loaded.scores.count, 14)
  equal(bytes(backup), original, "memory.v1.json holds the original bytes")
  let saved = try JSONDecoder().decode(AutopilotMemory.self, from: Data(contentsOf: file))
  equal(saved, loaded, "the migration is saved")
  let stamp = Date(timeIntervalSince1970: 1_000_000_000)
  try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: backup.path)
  equal(try store.memory(), loaded, "a second load reads version 2 as it is")
  equal(bytes(backup), original, "and leaves the copy alone")
  equal(modified(backup), stamp, "not even rewritten")

  // An existing copy is never overwritten, and updates migrate the same way.
  let again = try AutopilotStore(root: root.appendingPathComponent("again"))
  let earlier = Data("an earlier copy".utf8)
  try earlier.write(to: again.directory.appendingPathComponent("memory.v1.json"))
  try original.write(to: again.directory.appendingPathComponent("memory.json"))
  let seen = try again.updateMemory { $0.version }
  equal(seen, 2, "an update sees migrated memory")
  equal(
    bytes(again.directory.appendingPathComponent("memory.v1.json")), earlier,
    "an existing memory.v1.json stays as it is")
  equal(try again.memory().rules.count, 17)

  // Receipts that are there but can't be read leave memory at version 1, to retry on the next
  // load; only a missing receipts.json counts as no receipts.
  let unreadable = try AutopilotStore(root: root.appendingPathComponent("unreadable"))
  let receiptsFile = unreadable.directory.appendingPathComponent("receipts.json")
  let memoryFile = unreadable.directory.appendingPathComponent("memory.json")
  try Data("not receipts".utf8).write(to: receiptsFile)
  try original.write(to: memoryFile)
  equal(try unreadable.memory().version, 1, "version 1 while receipts.json can't be read")
  equal(bytes(memoryFile), original, "memory.json is left as it was")
  try JSONEncoder().encode(teachHistoryReceipts()).write(to: receiptsFile)
  let retried = try unreadable.memory()
  equal(retried.version, 2, "the next load migrates")
  equal(retried.tallies[TeachLessons.copiesDayID]?.count, 3, "tallied from the receipts")
}

private final class Gone: @unchecked Sendable {
  private let lock = NSLock()
  private var ids = Set<String>()
  func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
  func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}

/// Live, a lesson's tally counts each burn once, when it is recorded as burned, and a restore
/// only marks it undone. Tallies move with the lessons that take them in.
private func tallyEngineProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-tallies-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AutopilotStore(root: root)
  let copies = AutopilotRule(
    kind: .worktree, match: ["saved": ["merged"], "stale": ["week", "month", "older"]],
    verdict: .burn, source: .operator, title: "", questionID: "q-copies")
  let programs = AutopilotRule(
    kind: .process, match: ["family": ["node"], "idle": ["1h", "6h", "1d"]], verdict: .burn,
    source: .operator, title: "", questionID: "q-programs")
  let folders = AutopilotRule(
    kind: .disk, match: ["folder": ["node_modules"], "stale": ["week", "month", "older"]],
    verdict: .burn, source: .operator, title: "", questionID: "q-folders")
  try store.updateMemory { $0.rules = [copies, programs, folders] }
  let copy = AutopilotItem(
    id: "worktree:old", kind: .worktree, name: "old", bytes: 3_000_000_000,
    facts: [
      "saved": "merged", "stale": "month", "changes": "none", "inUse": "no", "thread": "none",
      "place": "other",
    ])
  let node = AutopilotItem(
    id: "process:node", kind: .process, name: "node", bytes: 2_000_000_000,
    facts: [
      "family": "node", "idle": "6h", "listening": "no", "orphaned": "maybe", "thread": "none",
    ], processKey: "node")
  let folder = AutopilotItem(
    id: "disk:modules", kind: .disk, name: "node_modules", bytes: 1_000_000_000,
    facts: ["folder": "node_modules", "stale": "week", "home": "repo"])
  let gone = Gone()
  let backup = AutopilotRestore(
    repository: "/fixture/.git", path: "/fixture/old", ref: "refs/fixture/old",
    head: String(repeating: "0", count: 40), branch: nil, snapshot: false)
  let sources = AutopilotSources(
    processes: { _ in gone.contains(node.id) ? [] : [node] },
    worktrees: { _, _, d in (gone.contains(copy.id) ? [] : [copy], d) },
    disk: { _ in gone.contains(folder.id) ? [] : [folder] },
    burnProcess: { item, _, _ in
      gone.add(item.id)
      return UUID()
    },
    processOutcome: { _ in ("verified", "") },
    retireWorktree: { item, authority in
      gone.add(item.id)
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: authority,
        outcome: "burned", detail: "", bytes: item.bytes, restore: backup)
    },
    restoreWorktree: { _ in },
    reclaimDisk: { item, authority in
      gone.add(item.id)
      return AutopilotReceipt(
        itemID: item.id, kind: .disk, name: item.name, authority: authority, outcome: "burned",
        detail: "", bytes: item.bytes)
    })
  let engine = try Autopilot(root: root, sources: sources)
  let now = Date()
  _ = await engine.tick(now: now)
  equal(
    try store.memory().tallies,
    [
      copies.id: AutopilotTally(count: 1, bytes: 3_000_000_000, undone: 0),
      folders.id: AutopilotTally(count: 1, bytes: 1_000_000_000, undone: 0),
    ], "a burn counts toward its lesson; a program still stopping doesn't count yet")
  _ = await engine.tick(now: now.addingTimeInterval(60))
  let stopped = try store.memory().tallies
  equal(
    stopped[programs.id], AutopilotTally(count: 1, bytes: 2_000_000_000, undone: 0),
    "a program counts once its stop is verified")
  _ = await engine.tick(now: now.addingTimeInterval(120))
  equal(try store.memory().tallies, stopped, "each burn counts once")

  guard let burned = try store.receipts().first(where: { $0.itemID == copy.id }) else {
    return failTest("the copy's receipt")
  }
  _ = try await engine.apply(.restore(receiptID: burned.id))
  equal(
    try store.memory().tallies[copies.id],
    AutopilotTally(count: 1, bytes: 3_000_000_000, undone: 1),
    "a restore marks the burn undone without counting it again")
  _ = try? await engine.apply(.restore(receiptID: burned.id))
  equal(try store.memory().tallies[copies.id]?.undone, 1, "restoring it again undoes nothing more")

  // A wider answer takes the lesson in, and its tally with it; forgetting a lesson forgets it.
  let wider = AutopilotQuestion(
    kind: .worktree, match: ["saved": ["merged"], "stale": ["day"]],
    question: "Can I burn old project copies already merged, untouched since yesterday?", why: "",
    examples: [], count: 1, bytes: 1_000_000_000)
  try store.updateMemory { $0.questions.append(wider) }
  _ = try await engine.apply(.answer(questionID: wider.id, answer: .yes))
  let widerID = TeachLessons.id(.worktree, ["saved": ["merged"], "stale": TeachLessons.ages], .burn)
  var tallies = try store.memory().tallies
  equal(
    tallies[widerID], AutopilotTally(count: 1, bytes: 3_000_000_000, undone: 1),
    "the tally moves to the lesson that took it in")
  isNil(tallies[copies.id])
  _ = try await engine.apply(.forgetRule(ruleID: widerID))
  tallies = try store.memory().tallies
  isNil(tallies[widerID])
  equal(Set(tallies.keys), [programs.id, folders.id], "the other lessons keep theirs")
}
