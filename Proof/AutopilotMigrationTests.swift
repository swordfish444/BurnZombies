import BurnCore
import Foundation

/// The owner's anonymized answers (`teachHistoryJSON`), 30 questions with 3 skips.
func teachHistory() throws -> [AutopilotQuestion] {
  try JSONDecoder().decode([AutopilotQuestion].self, from: Data(teachHistoryJSON.utf8))
}

/// Version-1 memory made from the teach history the way it was before lessons: one rule per Yes or
/// No, widened, keeping the project and maker it was asked about.
func teachHistoryVersion1(_ history: [AutopilotQuestion]) -> AutopilotMemory {
  var memory = AutopilotMemory()
  memory.version = 1
  memory.questions = history
  for q in history {
    guard let answer = q.answer, answer != .skip else { continue }
    let verdict: AutopilotVerdict = answer == .yes ? .burn : .keep
    memory.rules.append(
      AutopilotRule(
        kind: q.kind, match: AutopilotPolicy.widen(q.match, verdict: verdict), verdict: verdict,
        source: .operator, title: AutopilotPolicy.ruleTitle(q, answer: answer),
        created: q.answered ?? q.asked, questionID: q.id))
  }
  return memory
}

/// The lessons the teach history leaves, by match, worked out by hand from the fixture.
enum TeachLessons {
  static let ages = ["day", "week", "month", "older"]
  /// q16 with q01, q02, q04, q05, q07, q10 and q27 in it.
  static let copiesDay: [String: [String]] = [
    "saved": ["local", "pushed", "merged"], "stale": ages,
  ]
  /// q13 with q14.
  static let unchecked: [String: [String]] = [
    "changes": ["small", "none"], "inUse": ["no"], "saved": ["unknown"], "stale": ages,
    "thread": ["none", "ended"],
  ]
  /// q19.
  static let unsavedUnchecked: [String: [String]] = [
    "changes": ["small", "large"], "inUse": ["no"], "saved": ["unknown"], "stale": ["day", "week"],
    "thread": ["none", "ended"],
  ]
  /// q25 with q30.
  static let sameDay: [String: [String]] = [
    "changes": ["none"], "inUse": ["no"], "saved": ["merged", "pushed"],
    "stale": ["today"] + ages, "thread": ["none", "ended"],
  ]
  static let javaBurn: [String: [String]] = [
    "family": ["java"], "idle": ["1h", "6h", "1d"], "listening": ["yes", "no"],
  ]
  /// q23 with q08.
  static let nodeBurn: [String: [String]] = ["family": ["node"], "idle": ["10m", "1h", "6h", "1d"]]
  static let javaKeep: [String: [String]] = [
    "family": ["java"], "idle": ["active", "10m"], "listening": ["yes"],
  ]
  static let caches: [String: [String]] = ["folder": ["package-cache"], "stale": ages]
  static let modules: [String: [String]] = [
    "folder": ["node_modules"], "home": ["repo"], "stale": ages,
  ]
  static let builds: [String: [String]] = [
    "folder": ["build-output"], "home": ["repo"], "stale": ages,
  ]
  /// Answers whose rules don't pin recency, so they stay exactly as they were.
  static let anyAge = ["q20", "q21", "q22", "q24", "q26", "q28", "q29"]

  static func id(_ kind: AutopilotKind, _ match: [String: [String]], _ verdict: AutopilotVerdict)
    -> String
  {
    AutopilotRule.key(kind: kind, match: match) + ":" + verdict.rawValue
  }
  static var copiesDayID: String { id(.worktree, copiesDay, .burn) }
  static var javaKeepID: String { id(.process, javaKeep, .keep) }
  /// The rule q04 taught before lessons: no project in it, so the lesson keeps its id.
  static var q04ID: String {
    id(.worktree, ["saved": ["merged"], "stale": ages], .burn)
  }
  /// The rule q07 taught before lessons, naming who made the copies.
  static var q07ID: String {
    id(.worktree, ["place": ["patrol6"], "saved": ["pushed", "merged"], "stale": ages], .burn)
  }
}

/// Burns, a restore and receipts no lesson made, by the rule q04 taught before lessons.
func teachHistoryReceipts() -> [AutopilotReceipt] {
  let old = "rule:" + TeachLessons.q04ID
  func receipt(_ authority: String, _ outcome: String, _ gigabytes: UInt64) -> AutopilotReceipt {
    AutopilotReceipt(
      itemID: "worktree:" + UUID().uuidString, kind: .worktree, name: "copy",
      authority: authority, outcome: outcome, detail: "", bytes: gigabytes * 1_000_000_000,
      date: Date(timeIntervalSinceReferenceDate: 815_420_000))
  }
  return [
    receipt(old, "burned", 1), receipt(old, "burned", 2), receipt(old, "restored", 4),
    receipt(old, "refused", 8), receipt(old, "verifying", 16), receipt(old, "failed", 32),
    receipt("starter:starter-finished-copies", "burned", 64), receipt("ai:0.90", "burned", 128),
    receipt("operator", "burned", 256),
  ]
}

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
