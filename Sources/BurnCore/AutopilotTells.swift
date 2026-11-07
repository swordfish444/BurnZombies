import Foundation

/// Act, then tell (spec 3.4). When BZ has earned trust on a subject and is sure the owner would say
/// yes to a question it is about to ask, it answers the question itself, learns what a Yes teaches,
/// burns through the same path as an owner's Yes, and tells the owner afterwards. The owner calls it
/// good or undoes it; a tell nobody touches closes after a week.
extension AutopilotPolicy {
  /// Open tells close on their own after this long, without a score.
  public static let tellLifetime: TimeInterval = 7 * 86_400

  /// What an Undo of copies tells the owner about the ones that didn't come back: how many failed
  /// to restore, with the first reason, how many had no restore point, and how many came back
  /// without the big unsaved files their burn deleted for good, as the card said before the press.
  /// Stopped programs and deleted folders never come back, and their card says so before the press,
  /// so they need none.
  static func undoNote(
    kind: AutopilotKind, failed: Int, reason: String?, missing: Int, withoutBigFiles: Int = 0
  ) -> String? {
    guard kind == .worktree else { return nil }
    var parts: [String] = []
    if withoutBigFiles > 0 {
      let one: Bool = withoutBigFiles == 1
      let copies: String = one ? "1 copy" : "\(withoutBigFiles) copies"
      let whose: String = one ? " its" : " their"
      parts.append(copies + " came back without" + whose + " big unsaved files, which were deleted for good.")
    }
    if failed > 0 {
      let copies: String = failed == 1 ? "1 copy" : "\(failed) copies"
      let why: String = reason ?? "The restore failed."
      parts.append(copies + " couldn't come back. " + why)
    }
    if missing > 0 {
      let copies: String = missing == 1 ? "1 copy" : "\(missing) copies"
      parts.append(copies + " had no backup to come back from.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// BZ's guess at a question it is about to ask, sure only when it is sure of everything a yes
  /// would burn. The lesson a Yes teaches can reach further than the question's own matches: one the
  /// AI asks about one project teaches about every project. So BZ is sure only when every unsure
  /// thing that lesson reaches is on the question's subject and carries only risks the owner said
  /// yes to there. The lesson from one of BZ's own questions reaches just its matches.
  static func guess(
    _ question: AutopilotQuestion, memory: AutopilotMemory, reaching unsure: [AutopilotItem]
  ) -> AutopilotGuess? {
    guard var own = guess(question, memory: memory) else { return nil }
    guard own.sure else { return own }
    let taught = AutopilotRule(
      kind: question.kind, match: lessonMatch(question.kind, question.match, verdict: .burn),
      verdict: .burn, source: .operator, title: "")
    let reached = unsure.filter { matches(taught, $0) }
    let topic: String = subject(question.kind, question.match)
    let elsewhere: Bool = reached.contains { item in
      let facts: [String: [String]] = item.facts.mapValues { [$0] }
      let place: String = subject(item.kind, facts)
      return place != topic
    }
    var probe = question
    probe.risks = risks(question.kind, reached)
    let known: Bool = guess(probe, memory: memory)?.sure == true
    own.sure = known && !elsewhere
    return own
  }

  /// The guess a question the AI asks keeps (spec 2.6): BZ's own, with the AI's answer when it gives
  /// one, and sure only when BZ is sure and the AI expects a yes too. Where the AI's answer isn't
  /// BZ's lean, BZ's reason doesn't back it, so the words only say what the AI expects.
  static func guess(_ own: AutopilotGuess?, ai: AutopilotAnswer?) -> AutopilotGuess? {
    guard let ai, ai != .skip else { return own }
    let expected: String = "I think you'll say " + ai.rawValue + "."
    guard var guess = own else {
      return AutopilotGuess(answer: ai, sure: false, why: expected, source: "ai")
    }
    if guess.answer != ai { guess.why = expected }
    guess.sure = guess.sure && ai == .yes
    guess.answer = ai
    guess.source = "ai"
    return guess
  }

  /// A guess checked against an answer (spec 3.2), keeping the latest `maximumScores`.
  static func score(
    _ question: AutopilotQuestion, guess: AutopilotAnswer, answer: AutopilotAnswer,
    into memory: inout AutopilotMemory, date: Date, replayed: Bool? = nil
  ) {
    let topic: String = subject(question.kind, question.match)
    let right: Bool = guess == answer
    memory.scores.append(
      AutopilotScore(
        questionID: question.id, subject: topic, guess: guess, answer: answer, right: right,
        date: date, replayed: replayed))
    let excess = memory.scores.count - maximumScores
    if excess > 0 { memory.scores.removeFirst(excess) }
  }

  /// The risk facts a Yes and BZ's own act are kept within, so that BZ never burns on a risk the
  /// owner hasn't said yes to, by kind, with every value each can take, riskiest first: work only
  /// on this Mac, unsaved changes, unsaved files too big to back up, a running server, and anything
  /// BZ couldn't check (`unknown`). A copy in use is protected and never burned, so "yes" isn't
  /// listed for `inUse`.
  static let riskFacts: [AutopilotKind: [(fact: String, values: [String])]] = {
    let copies: [(fact: String, values: [String])] = [
      (fact: "saved", values: ["unknown", "local", "pushed", "merged"]),
      (fact: "changes", values: ["unknown", "large", "small", "none"]),
      (fact: "inUse", values: ["unknown", "no"]),
    ]
    let big: [(fact: String, values: [String])] = AutopilotWorktrees.bigFileRisks.map {
      (fact: $0.fact, values: ["yes", "no"])
    }
    return [
      .worktree: copies + big, .process: [(fact: "listening", values: ["unknown", "yes", "no"])],
      .disk: [(fact: "docker", values: ["yes", "no"])],
    ]
  }()
  /// What Undo, Good call and Forget say while an Undo runs.
  public static let undoingNow = "I'm already undoing that."
  /// An Undo's note when an owner's newer answer took the act's lesson in.
  public static let newerAnswerStands = "Your newer answer stands."
  /// Closed tells memory keeps, newest last; open and undoing ones always stay.
  public static let maximumClosedTells = 100

  /// The lesson BZ's own Yes teaches: what an owner's Yes would, kept to the risks the owner has
  /// said yes to on the subject (`approved`), through the same `narrowed` as an owner's Yes. Each
  /// risk fact allows its safe values and the risky values the owner approved, and `unknown` only
  /// when approved. A later thing with a risk the owner never saw isn't burned under it, but asked
  /// about, a kind of big unsaved files the owner never said yes to among them. It is this act's
  /// alone: its id carries the tell's, so every burn it authorizes is the act's.
  static func actLesson(
    for question: AutopilotQuestion, approved: Set<String>, created: Date, tellID: String
  ) -> AutopilotRule {
    var rule = lesson(for: question, verdict: .burn, created: created, approved: approved)
    let key: String = AutopilotRule.key(kind: rule.kind, match: rule.match)
    rule.id = key + ":burn:" + tellID
    rule.tellID = tellID
    return rule
  }

  /// BZ answers `question` yes itself, at `date`, when it acts. The answer is stored as BZ's under
  /// an id of its own: that leaves the pattern free, so things it covers with a risk the owner never
  /// approved stay unsure and are asked about under it. The lesson is `actLesson`, learned on its
  /// own, and an open tell is added. The caller then burns what the lesson authorizes, through the
  /// same path as an owner's Yes. Returns the stored question and the tell.
  @discardableResult static func act(
    _ question: AutopilotQuestion, guess: AutopilotGuess, memory: inout AutopilotMemory,
    at date: Date
  ) -> (question: AutopilotQuestion, tell: AutopilotTell) {
    let tellID = UUID().uuidString
    let topic: String = subject(question.kind, question.match)
    let approved = approvedRisks(topic, memory, besides: question.id)
    var answered = question
    answered.id = question.id + ":" + tellID
    answered.guess = guess
    answered.answer = .yes
    answered.answered = date
    answered.answeredBy = "bz"
    memory.questions.append(answered)
    let taught = actLesson(for: answered, approved: approved, created: date, tellID: tellID)
    learn(taught, into: &memory.rules)
    let tell = AutopilotTell(
      id: tellID, questionID: answered.id, ruleID: taught.id, kind: answered.kind,
      count: answered.count, bytes: answered.bytes, rows: answered.rows ?? [], why: guess.why,
      date: date)
    memory.tells.append(tell)
    trimTells(&memory)
    return (answered, tell)
  }

  /// Says on each open tell what its lesson burned, from its receipts (burned, still stopping, or
  /// burned and since restored), so "Burned N" stays true as the act's burns land: count and bytes.
  /// The rows are captured at the act, so a tell keeps each thing's task, project and last use after
  /// the next look drops burned things from the catalog: the act's own burn pass (`settled`) names
  /// what it burned as the catalog shows it then, and a later refresh keeps them. A tell with no
  /// burn yet keeps what BZ meant to burn, unless its act's own pass just finished: then it says
  /// nothing burned (it is hidden at 0) but keeps the rows, for burns that come once look-only ends.
  static func refreshTells(
    _ memory: inout AutopilotMemory, receipts: [AutopilotReceipt], items: [AutopilotItem],
    settled: Set<String>
  ) {
    let burnt: Set<String> = ["burned", "verifying", "restored"]
    var byID: [String: AutopilotItem] = [:]
    for item in items { byID[item.id] = item }
    for i in memory.tells.indices where memory.tells[i].isOpen {
      let authority: String = "rule:" + memory.tells[i].ruleID
      var made: [String: AutopilotItem] = [:]
      for receipt in receipts where receipt.authority == authority {
        guard burnt.contains(receipt.outcome) else { continue }
        var item: AutopilotItem =
          byID[receipt.itemID]
          ?? AutopilotItem(
            id: receipt.itemID, kind: receipt.kind, name: receipt.name, facts: [:])
        item.bytes = receipt.bytes
        // What its burn deleted for good, as its receipt says.
        item.bigFiles = receipt.bigFiles
        made[receipt.itemID] = item
      }
      let settling: Bool = settled.contains(memory.tells[i].id)
      guard !made.isEmpty || settling else { continue }
      let things: [AutopilotItem] = Array(made.values)
      memory.tells[i].count = things.count
      memory.tells[i].bytes = things.reduce(0) { $0 + $1.bytes }
      var deleted: UInt64 = 0
      for thing in things { deleted += (thing.bigFiles ?? []).reduce(0) { $0 + $1.bytes } }
      memory.tells[i].bigBytes = deleted > 0 ? deleted : nil
      // Rows only ever come from what the catalog shows, never from a receipt's bare name. A pass
      // that burned nothing, refused or held, keeps what BZ meant to burn for when burns come.
      let named: Bool = made.keys.allSatisfy { byID[$0] != nil }
      if settling && named && !things.isEmpty { memory.tells[i].rows = rows(of: things) }
    }
  }

  /// Closes open tells older than `tellLifetime`, without a score. A tell an Undo is working on
  /// never expires.
  static func expireTells(_ memory: inout AutopilotMemory, now: Date) {
    for i in memory.tells.indices where memory.tells[i].isOpen {
      guard now.timeIntervalSince(memory.tells[i].date) > tellLifetime else { continue }
      memory.tells[i].state = "expired"
    }
    trimTells(&memory)
  }

  /// Keeps the last `maximumClosedTells` closed tells; open and undoing ones always stay, and so does
  /// an undone one whose note waits for the owner's OK.
  static func trimTells(_ memory: inout AutopilotMemory) {
    let done: [AutopilotTell] = memory.tells.filter { !$0.waitsForOwner }
    var excess = done.count - maximumClosedTells
    guard excess > 0 else { return }
    memory.tells.removeAll { tell in
      guard excess > 0, !tell.waitsForOwner else { return false }
      excess -= 1
      return true
    }
  }

  /// The tell's index while it is open; nil when it is already `state`, as after a second click.
  /// Throws while an Undo runs, and when it is gone or was closed some other way.
  static func openTell(_ id: String, _ memory: AutopilotMemory, already state: String) throws
    -> Int?
  {
    guard let i = memory.tells.firstIndex(where: { $0.id == id }) else {
      throw StoreError.message("I can't find that anymore.")
    }
    if memory.tells[i].state == state { return nil }
    if memory.tells[i].state == "undoing" { throw StoreError.message(undoingNow) }
    guard memory.tells[i].isOpen else { throw StoreError.message("That one is already closed.") }
    return i
  }

  /// Good call: the tell closes and BZ's guess scores right.
  static func callGood(_ id: String, memory: inout AutopilotMemory, now: Date) throws {
    guard let i = try openTell(id, memory, already: "good") else { return }
    memory.tells[i].state = "good"
    let questionID = memory.tells[i].questionID
    if let question = memory.questions.first(where: { $0.id == questionID }) {
      score(question, guess: .yes, answer: .yes, into: &memory, date: now)
    }
    trimTells(&memory)
  }

  /// Every burn the act's lesson made: receipts whose authority is exactly its id, which was born
  /// with the act, that freed something or are still stopping it. Only copies with a restore point
  /// can come back.
  public static func burns(of tell: AutopilotTell, receipts: [AutopilotReceipt])
    -> [AutopilotReceipt]
  {
    let authority: String = "rule:" + tell.ruleID
    return receipts.filter { receipt in
      guard receipt.authority == authority else { return false }
      return receipt.outcome == "burned" || receipt.outcome == "verifying"
    }
  }

  /// An Undo's first step, before anything is restored, so that nothing burns under the act's
  /// lesson once the owner has said no. The tell is undoing; the act's lesson is gone, with the keep
  /// a No teaches in its place; the owner's answer is No; and BZ's guess scores wrong. If an owner's
  /// newer answer took the act's lesson in, that answer stands: no keep is learned, BZ's Yes stays
  /// held by it, and the note says so. Returns the tell to finish, or nil when it is already
  /// undone. One left undoing by an Undo cut short is picked up as it is.
  static func beginUndo(_ id: String, memory: inout AutopilotMemory, now: Date) throws
    -> AutopilotTell?
  {
    guard let t = memory.tells.firstIndex(where: { $0.id == id }) else {
      throw StoreError.message("I can't find that anymore.")
    }
    let tell = memory.tells[t]
    switch tell.state {
    case "undone": return nil
    case "undoing": return tell
    case "open": break
    default: throw StoreError.message("That one is already closed.")
    }
    memory.tells[t].state = "undoing"
    let q = memory.questions.firstIndex(where: { $0.id == tell.questionID })
    if memory.rules.contains(where: { $0.id == tell.ruleID }) {
      memory.rules.removeAll { $0.id == tell.ruleID }
      if let q {
        memory.questions[q].answer = .no
        memory.questions[q].answered = now
        memory.questions[q].answeredBy = nil
        // The same keeps an owner's No to that card teaches, so the Undo keeps what a No would.
        let keeps: [AutopilotRule] = lessons(
          for: memory.questions[q], verdict: .keep, created: now, earlier: memory.questions)
        for keep in keeps { learn(keep, into: &memory.rules) }
      }
      carryTallies(&memory)
    } else if memory.rules.contains(where: { $0.formerIDs?.contains(tell.ruleID) == true }) {
      memory.tells[t].note = newerAnswerStands
    }
    if let q { score(memory.questions[q], guess: .yes, answer: .no, into: &memory, date: now) }
    return memory.tells[t]
  }

  /// An Undo's last step, once the act's burns that can come back are back: the tell closes, with
  /// what couldn't come back added to its note. A tell with a note stays in Teach BZ until the owner
  /// presses OK, so a copy that didn't come back is never missed.
  static func finishUndo(_ id: String, note: String?, memory: inout AutopilotMemory) throws {
    guard let t = memory.tells.firstIndex(where: { $0.id == id }) else {
      throw StoreError.message("I can't find that anymore.")
    }
    guard memory.tells[t].state == "undoing" else { return }
    let parts: [String] = [memory.tells[t].note, note].compactMap { $0 }
    memory.tells[t].note = parts.isEmpty ? nil : parts.joined(separator: " ")
    memory.tells[t].state = "undone"
    // A tell that burned nothing is never shown, so it waits for no OK.
    if !parts.isEmpty && memory.tells[t].count > 0 { memory.tells[t].seen = false }
    trimTells(&memory)
  }

  /// OK on what an Undo left the owner to read: the tell has been seen and leaves Teach BZ. Any
  /// other tell is left as it is.
  static func seen(_ id: String, memory: inout AutopilotMemory) throws {
    guard let t = memory.tells.firstIndex(where: { $0.id == id }) else {
      throw StoreError.message("I can't find that anymore.")
    }
    guard memory.tells[t].waitsForOK else { return }
    memory.tells[t].seen = true
    trimTells(&memory)
  }

  /// Forgets lessons, each with every answer it was made from, so those things can be asked again.
  /// A tell whose answer is forgotten closes, without a score. While an Undo needs one of those
  /// answers, nothing is forgotten.
  static func forget(_ ruleIDs: [String], memory: inout AutopilotMemory) throws {
    var taught = Set<String>()
    for rule in memory.rules where ruleIDs.contains(rule.id) {
      taught.formUnion(questionIDs(rule))
    }
    let needed = memory.tells.contains { tell in
      tell.state == "undoing" && taught.contains(tell.questionID)
    }
    if needed { throw StoreError.message(undoingNow) }
    memory.questions.removeAll { taught.contains($0.id) }
    // A keep the same No taught for another risk goes with its answer, so none outlives it.
    memory.rules.removeAll { rule in
      ruleIDs.contains(rule.id) || rule.questionID.map(taught.contains) == true
    }
    carryTallies(&memory)
    let asked = Set(memory.questions.map(\.id))
    for i in memory.tells.indices where memory.tells[i].isOpen {
      if !asked.contains(memory.tells[i].questionID) { memory.tells[i].state = "expired" }
    }
    trimTells(&memory)
  }
}
