import BurnCore
import Foundation

/// Simulated owners (spec 4.3): a Mac that gains old copies, programs and folders every round, and
/// owners who answer every question by a fixed policy. Deterministic, with no model.

/// The Mac. Something burned is gone until it is restored.
final class OwnerMac: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [AutopilotItem] = []
  private var gone: Set<String> = []

  func add(_ new: [AutopilotItem]) { lock.withLock { items += new } }
  func present(_ kind: AutopilotKind) -> [AutopilotItem] {
    lock.withLock { items.filter { $0.kind == kind && !gone.contains($0.id) } }
  }
  /// Anything the Mac ever had, burned or not.
  func item(_ id: String) -> AutopilotItem? { lock.withLock { items.first { $0.id == id } } }
  private func burn(_ id: String) { lock.withLock { _ = gone.insert(id) } }
  private func bringBack(_ id: String) { lock.withLock { _ = gone.remove(id) } }

  var sources: AutopilotSources {
    AutopilotSources(
      processes: { _ in self.present(.process) },
      worktrees: { _, _, delivery in (self.present(.worktree), delivery) },
      disk: { _ in self.present(.disk) },
      burnProcess: { item, _, _ in
        self.burn(item.id)
        return UUID()
      },
      processOutcome: { _ in ("verified", "") },
      retireWorktree: { item, authority in
        self.burn(item.id)
        let backup = AutopilotRestore(
          repository: "/fixture/.git", path: "/fixture/" + item.name,
          ref: "refs/fixture/" + item.name, head: String(repeating: "0", count: 40), branch: nil,
          snapshot: false)
        return AutopilotReceipt(
          itemID: item.id, kind: .worktree, name: item.name, authority: authority,
          outcome: "burned", detail: "", bytes: item.bytes, restore: backup)
      },
      restoreWorktree: { receipt in self.bringBack(receipt.itemID) },
      reclaimDisk: { item, authority in
        self.burn(item.id)
        return AutopilotReceipt(
          itemID: item.id, kind: .disk, name: item.name, authority: authority, outcome: "burned",
          detail: "", bytes: item.bytes)
      })
  }
}

/// When something untouched for `stale` was last used, as its card would say.
private func lastUsed(_ stale: String, now: Date) -> Date {
  let days: [String: Double] = ["today": 0.1, "day": 2, "week": 10, "month": 40, "older": 100]
  let ago: Double = (days[stale] ?? 1) * 86_400
  return now.addingTimeInterval(-ago)
}

/// What shows up on the Mac in round `round` (1-based): five old copies, one for each age from
/// used today to untouched for months, with varied saving, unsaved work, project and maker; two
/// Node and two Java programs with varied idle time and ports; and two node_modules and two
/// package-cache folders of varied age.
func ownerItems(round: Int, now: Date) -> [AutopilotItem] {
  let saved: [String] = ["pushed", "merged", "local"]
  let changes: [String] = ["none", "small", "none", "large"]
  let stale: [String] = ["day", "week", "month", "older", "today"]
  let repos: [String] = ["web-app", "api", "docs", "mobile"]
  let places: [String] = ["patrol6", "sibling", "codex", "claude", "other"]
  var items: [AutopilotItem] = []
  for i in 0..<5 {
    let n: Int = round * 5 + i
    let age: String = stale[(round + i) % 5]
    let facts: [String: String] = [
      "repo": repos[n % 4], "place": places[(n + round) % 5], "saved": saved[n % 3],
      "changes": changes[(n / 3) % 4], "stale": age, "inUse": "no", "thread": "none",
    ]
    let name: String = "copy-\(round)-\(i)"
    let bytes: UInt64 = 400_000_000 + UInt64(n % 4) * 150_000_000
    items.append(
      AutopilotItem(
        id: "worktree:" + name, kind: .worktree, name: name, bytes: bytes, facts: facts,
        lastUsed: lastUsed(age, now: now), title: "task \(round) \(i)"))
  }
  let idles: [String] = ["10m", "1h", "6h", "1d", "active"]
  let agents: [String] = ["codex", "claude", "none"]
  for (j, family) in ["node", "node", "java", "java"].enumerated() {
    let n: Int = round * 4 + j
    let facts: [String: String] = [
      "family": family, "orphaned": (j + round) % 2 == 0 ? "yes" : "maybe",
      "thread": (j + round) % 4 == 0 ? "ended" : "none", "idle": idles[(j + 2 * round) % 5],
      "listening": (j + round) % 3 == 0 ? "yes" : "no", "agent": agents[n % 3],
    ]
    let name: String = "\(family)-\(round)-\(j)"
    let bytes: UInt64 = 500_000_000 + UInt64(n % 3) * 150_000_000
    items.append(
      AutopilotItem(
        id: "process:" + name, kind: .process, name: name, bytes: bytes, facts: facts,
        processKey: name))
  }
  for (j, folder) in ["node_modules", "node_modules", "package-cache", "package-cache"].enumerated()
  {
    let n: Int = round * 4 + j
    let age: String = stale[(j + 3 * round) % 5]
    let home: String = folder == "node_modules" ? "repo" : "global-cache"
    let facts: [String: String] = [
      "folder": folder, "home": home, "stale": age, "size": "medium",
    ]
    let name: String = "\(folder)-\(round)-\(j)"
    let bytes: UInt64 = 400_000_000 + UInt64(n % 3) * 250_000_000
    items.append(
      AutopilotItem(
        id: "disk:" + name, kind: .disk, name: name, bytes: bytes, facts: facts,
        lastUsed: lastUsed(age, now: now)))
  }
  return items
}

/// An owner who answers by a fixed policy: what they would burn.
struct OwnerPersona: Sendable {
  let name: String
  let burns: @Sendable (AutopilotItem) -> Bool

  /// Burns copies that are on GitHub or untouched since yesterday or longer, programs idle for
  /// 10 minutes or more, and folders untouched since yesterday or longer.
  static let liberal = OwnerPersona(name: "liberal", burns: liberalBurns)
  /// Like liberal, but keeps any copy with unsaved work.
  static let cautious = OwnerPersona(name: "cautious") { item in
    guard liberalBurns(item) else { return false }
    return item.kind != .worktree || item.facts["changes"] == "none"
  }
  /// Like liberal, but keeps programs serving a port.
  static let serverKeeper = OwnerPersona(name: "server keeper") { item in
    guard liberalBurns(item) else { return false }
    return item.kind != .process || item.facts["listening"] != "yes"
  }

  @Sendable static func liberalBurns(_ item: AutopilotItem) -> Bool {
    let quiet: Set<String> = ["day", "week", "month", "older"]
    let f: [String: String] = item.facts
    switch item.kind {
    case .worktree:
      let onGitHub: Bool = ["pushed", "merged"].contains(f["saved"] ?? "")
      return onGitHub || quiet.contains(f["stale"] ?? "")
    case .process:
      return ["10m", "1h", "6h", "1d"].contains(f["idle"] ?? "")
    case .disk:
      return quiet.contains(f["stale"] ?? "")
    }
  }
}

/// One round as the owner saw it.
struct OwnerRound {
  var round: Int
  /// Questions the owner answered.
  var questions: Int = 0
  /// What BZ burned at the look, before the owner answered anything: lessons, starter rules and
  /// tells.
  var handledBytes: UInt64 = 0
  /// Tells BZ made this round, and their subjects.
  var tells: Int = 0
  var tellSubjects: [String] = []
  /// Things still waiting for the owner at the end of the round.
  var unsure: Int = 0
}

/// A whole run for one persona.
struct OwnerRun {
  var persona: String
  var rounds: [OwnerRound] = []
  /// Burns, tells included, of things the persona would keep.
  var wrong: [String] = []
  /// The subject of the tell the owner undid, and the round.
  var undone: (subject: String, round: Int)?
  var goodCalls = 0
  /// Per subject: the owner's answers, BZ's scored guesses, and the longest run of right ones.
  var subjects: [String] = []

  func questions(_ range: ClosedRange<Int>) -> Int {
    rounds.filter { range.contains($0.round) }.reduce(0) { $0 + $1.questions }
  }
  func handled(_ range: ClosedRange<Int>) -> UInt64 {
    rounds.filter { range.contains($0.round) }.reduce(UInt64(0)) { $0 + $1.handledBytes }
  }
  var tells: Int { rounds.reduce(0) { $0 + $1.tells } }

  /// "liberal: questions 2 3 0 … · handled without asking 0.8 3.5 … GB · tells 0 0 … · unsure 6 6 …
  /// · good calls 0 · wrong burns 0", a number per round.
  var line: String {
    let asked: String = rounds.map { String($0.questions) }.joined(separator: " ")
    let handled: String = rounds.map { gigabytes($0.handledBytes) }.joined(separator: " ")
    let told: String = rounds.map { String($0.tells) }.joined(separator: " ")
    let waiting: String = rounds.map { String($0.unsure) }.joined(separator: " ")
    var text: String = persona + ": questions " + asked + " · handled without asking " + handled
    text += " GB · tells " + told + " · unsure " + waiting
    text += " · good calls \(goodCalls) · wrong burns \(wrong.count)"
    if let undone { text += " · undid \(undone.subject) in round \(undone.round)" }
    return text
  }

  func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1e9) }
}

/// A question's subject as BZ keeps score on it: all copies, one program family or one folder kind.
private func subject(of question: AutopilotQuestion) -> String {
  let fact: String? = ["process": "family", "disk": "folder"][question.kind.rawValue]
  let value: String = fact.flatMap { question.match[$0]?.first } ?? ""
  return question.kind.rawValue + ":" + value
}

/// The subject a tell was about: the subject of the question BZ answered itself.
private func subject(of tell: AutopilotTell, _ memory: AutopilotMemory) -> String {
  guard let question = memory.questions.first(where: { $0.id == tell.questionID }) else {
    return tell.kind.rawValue + ":?"
  }
  return subject(of: question)
}

/// The things a question is about: unsure things its pattern covers, the way BZ counts them.
private func members(of question: AutopilotQuestion, in snapshot: AutopilotSnapshot)
  -> [AutopilotItem]
{
  let covers = AutopilotRule(
    kind: question.kind, match: AutopilotPolicy.widen(question.match, verdict: .burn),
    verdict: .burn, source: .operator, title: "")
  let unsure: [AutopilotItem] = snapshot.entries.filter { $0.status == .unsure }.map(\.item)
  return unsure.filter { AutopilotPolicy.matches(covers, $0) }
}

/// Waits for burns an answer started in the background: until the receipts hold still.
private func settle(_ store: AutopilotStore) async {
  var last = -1
  var steady = 0
  for _ in 0..<300 where steady < 3 {
    let count: Int = ((try? store.receipts()) ?? []).count
    steady = count == last ? steady + 1 : 0
    last = count
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
}

private let burnt: Set<String> = ["burned", "verifying", "restored"]

/// Runs `persona` for `rounds` rounds. Each round the Mac gains new things, BZ looks, the owner
/// judges what BZ did on its own (a good call when they'd have burned every one, an Undo
/// otherwise) and answers every open question, including ones that open as earlier answers land:
/// yes only when they would burn every thing it is about. With `undoRound`, the owner undoes BZ's
/// first open tell that round whatever they think of it.
func simulateOwner(_ persona: OwnerPersona, rounds: Int = 8, undoRound: Int? = nil) async throws
  -> OwnerRun
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-owner-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let mac = OwnerMac()
  let store = try AutopilotStore(root: root)
  let engine = try Autopilot(root: root, sources: mac.sources)
  var run = OwnerRun(persona: persona.name)
  // Rounds a day apart, ending about now: receipts carry the real time they were written.
  let start: Date = Date().addingTimeInterval(-Double(rounds + 1) * 86_400)
  var seenTells = Set<String>()
  for round in 1...rounds {
    let now: Date = start.addingTimeInterval(Double(round) * 86_400)
    var result = OwnerRound(round: round)
    mac.add(ownerItems(round: round, now: now))
    let before = Set(try store.receipts().map(\.id))
    // A look finishes its own burns before it returns.
    var snapshot: AutopilotSnapshot = await engine.tick(now: now)
    let afterLook: [AutopilotReceipt] = try store.receipts()
    for receipt in afterLook where !before.contains(receipt.id) && burnt.contains(receipt.outcome) {
      result.handledBytes += receipt.bytes
    }

    // What BZ did on its own, then every question.
    func judge() async throws {
      let memory = try store.memory()
      let receipts = try store.receipts()
      for tell in memory.tells where tell.state == "open" {
        if !seenTells.contains(tell.id) {
          seenTells.insert(tell.id)
          result.tells += 1
          result.tellSubjects.append(subject(of: tell, memory))
        }
        let made = receipts.filter { $0.authority == "rule:" + tell.ruleID }
        let things: [AutopilotItem] = made.compactMap { mac.item($0.itemID) }
        if round == undoRound && run.undone == nil {
          run.undone = (subject(of: tell, memory), round)
          _ = try await engine.apply(.tellUndo(id: tell.id), now: now)
        } else if things.allSatisfy(persona.burns) {
          run.goodCalls += 1
          _ = try await engine.apply(.tellGood(id: tell.id), now: now)
        } else {
          _ = try await engine.apply(.tellUndo(id: tell.id), now: now)
        }
      }
    }
    try await judge()
    snapshot = await engine.snapshot(now: now)
    while result.questions < 50, let question = snapshot.questions.first {
      let about: [AutopilotItem] = members(of: question, in: snapshot)
      equal(about.count, question.count, "\(persona.name): the owner sees what BZ counted")
      let yes: Bool = !about.isEmpty && about.allSatisfy(persona.burns)
      let answer: AutopilotAnswer = yes ? .yes : .no
      snapshot = try await engine.apply(.answer(questionID: question.id, answer: answer), now: now)
      result.questions += 1
    }
    await settle(store)
    try await judge()
    result.unsure = await engine.snapshot(now: now).count(.unsure)
    run.rounds.append(result)
  }
  for receipt in try store.receipts() where burnt.contains(receipt.outcome) {
    guard let item = mac.item(receipt.itemID) else { continue }
    if !persona.burns(item) { run.wrong.append(item.id + " under " + receipt.authority) }
  }
  run.subjects = subjectLines(try store.memory())
  return run
}

/// "process:node 3 answered, 2 scored, best run 2": what trust on each subject could rest on. Trust
/// takes the last 5 scored guesses right.
private func subjectLines(_ memory: AutopilotMemory) -> [String] {
  var answers: [String: Int] = [:]
  for question in memory.questions where question.answer == .yes || question.answer == .no {
    guard question.answeredBy != "bz" else { continue }
    answers[subject(of: question), default: 0] += 1
  }
  var lines: [String] = []
  for subject in answers.keys.sorted() {
    let scores: [AutopilotScore] = memory.scores.filter { $0.subject == subject }
    var best = 0
    var streak = 0
    for score in scores {
      streak = score.right ? streak + 1 : 0
      best = max(best, streak)
    }
    let count: Int = answers[subject] ?? 0
    let trusted: Bool = AutopilotPolicy.trusted(subject, scores: memory.scores)
    var line: String = subject + " \(count) answered, \(scores.count) scored, best run \(best)"
    if trusted { line += ", trusted" }
    lines.append(line)
  }
  return lines
}
