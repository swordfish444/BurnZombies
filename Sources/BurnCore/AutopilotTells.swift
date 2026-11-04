import Foundation

/// Act, then tell (spec 3.4). When BZ has earned trust on a subject and is sure the owner would say
/// yes to a question it is about to ask, it answers the question itself, learns what a Yes teaches,
/// burns through the same path as an owner's Yes, and tells the owner afterwards. The owner calls it
/// good or undoes it; a tell nobody touches closes after a week.
extension AutopilotPolicy {
  /// Open tells close on their own after this long, without a score.
  public static let tellLifetime: TimeInterval = 7 * 86_400
  /// What an undo says when some of what BZ burned can't be brought back.
  public static let cantComeBack =
    "Stopped programs and deleted folders can't come back; I'll ask next time."

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

  /// BZ answers `question` yes itself: the answer is recorded as BZ's, the lesson a Yes teaches is
  /// learned the same way, and an open tell is added. The caller then burns what the lesson
  /// authorizes, through the same path as an owner's Yes. Returns the stored question.
  @discardableResult static func act(
    _ question: AutopilotQuestion, guess: AutopilotGuess, memory: inout AutopilotMemory, now: Date
  ) -> AutopilotQuestion {
    var answered = question
    answered.guess = guess
    answered.answer = .yes
    answered.answered = now
    answered.answeredBy = "bz"
    // A skip of the same pattern from before is replaced by this answer.
    memory.questions.removeAll { $0.id == question.id }
    memory.questions.append(answered)
    let before = memory.tallies
    let taught = lesson(for: answered, verdict: .burn, created: now)
    let ruleID = learn(taught, into: &memory.rules)
    carryTallies(&memory)
    let tell = AutopilotTell(
      id: UUID().uuidString, questionID: answered.id, ruleID: ruleID, kind: answered.kind,
      count: answered.count, bytes: answered.bytes, rows: answered.rows ?? [], why: guess.why,
      date: now, absorbed: absorbed(by: ruleID, before: before, memory: memory))
    memory.tells.append(tell)
    return answered
  }

  /// What the lessons `ruleID` just took in had done, by their ids; nil when it took in none.
  static func absorbed(
    by ruleID: String, before: [String: AutopilotTally], memory: AutopilotMemory
  ) -> [String: AutopilotTally]? {
    guard let rule = memory.rules.first(where: { $0.id == ruleID }) else { return nil }
    let current = Set(memory.rules.map(\.id))
    var taken: [String: AutopilotTally] = [:]
    for id in rule.formerIDs ?? [] where !current.contains(id) {
      if let tally = before[id] { taken[id] = tally }
    }
    return taken.isEmpty ? nil : taken
  }

  /// Closes open tells older than `tellLifetime`, without a score.
  static func expireTells(_ memory: inout AutopilotMemory, now: Date) {
    for i in memory.tells.indices where memory.tells[i].isOpen {
      guard now.timeIntervalSince(memory.tells[i].date) > tellLifetime else { continue }
      memory.tells[i].state = "expired"
    }
  }

  /// The tell's index while it is open; nil when it is already `state`, as after a second click.
  /// Throws when it is gone or was closed some other way.
  static func openTell(_ id: String, _ memory: AutopilotMemory, already state: String) throws
    -> Int?
  {
    guard let i = memory.tells.firstIndex(where: { $0.id == id }) else {
      throw StoreError.message("I can't find that anymore.")
    }
    if memory.tells[i].state == state { return nil }
    guard memory.tells[i].isOpen else { throw StoreError.message("That one is already closed.") }
    return i
  }

  /// Good call: the tell closes and BZ's guess scores right.
  static func callGood(_ id: String, memory: inout AutopilotMemory, now: Date) throws {
    guard let i = try openTell(id, memory, already: "good") else { return }
    memory.tells[i].state = "good"
    let questionID = memory.tells[i].questionID
    guard let question = memory.questions.first(where: { $0.id == questionID }) else { return }
    score(question, guess: .yes, answer: .yes, into: &memory, date: now)
  }

  /// What the tell's lesson burned since the tell: receipts by its id, or an id it took in, that
  /// freed something or are still stopping it. Only copies with a restore point can come back.
  public static func burns(
    of tell: AutopilotTell, receipts: [AutopilotReceipt], rules: [AutopilotRule]
  ) -> [AutopilotReceipt] {
    var ids: Set<String> = [tell.ruleID]
    if let rule = rules.first(where: { $0.id == tell.ruleID }) {
      ids.formUnion(rule.formerIDs ?? [])
    }
    let authorities = Set(ids.map { "rule:" + $0 })
    return receipts.filter { receipt in
      guard receipt.outcome == "burned" || receipt.outcome == "verifying" else { return false }
      return receipt.date >= tell.date && authorities.contains(receipt.authority)
    }
  }

  /// The memory side of an Undo, once what can come back is back: the lesson becomes a keep, the
  /// owner's answer is No, BZ's guess scores wrong and the tell closes, with `note` when something
  /// couldn't come back. A second Undo changes nothing.
  static func undo(_ id: String, note: String?, memory: inout AutopilotMemory, now: Date) throws {
    guard let t = try openTell(id, memory, already: "undone") else { return }
    let tell = memory.tells[t]
    if let q = memory.questions.firstIndex(where: { $0.id == tell.questionID }) {
      let question = memory.questions[q]
      unlearn(question, tell: tell, memory: &memory, now: now)
      memory.questions[q].answer = .no
      memory.questions[q].answered = now
      memory.questions[q].answeredBy = nil
      score(question, guess: .yes, answer: .no, into: &memory, date: now)
    }
    memory.tells[t].state = "undone"
    memory.tells[t].note = note
  }

  /// Replaces what BZ's Yes to `question` taught with what a No teaches. The lesson holding the
  /// answer goes; every other answer it held teaches its own lesson again before the keep is
  /// learned, so nothing the owner taught is lost; and lessons BZ's lesson took in get back what
  /// they had done.
  static func unlearn(
    _ question: AutopilotQuestion, tell: AutopilotTell, memory: inout AutopilotMemory, now: Date
  ) {
    let answers = questionsByID(memory.questions)
    if let holder = memory.rules.first(where: { questionIDs($0).contains(question.id) }) {
      memory.rules.removeAll { $0.id == holder.id }
      for id in questionIDs(holder) where id != question.id {
        guard let other = answers[id], other.answer == .yes || other.answer == .no else {
          continue
        }
        let verdict: AutopilotVerdict = other.answer == .yes ? .burn : .keep
        let created: Date = other.answered ?? now
        learn(lesson(for: other, verdict: verdict, created: created), into: &memory.rules)
      }
      // BZ's own lesson goes with what it did; a later lesson of the owner's that took it in
      // was learned again under its own id and keeps its tally.
      if holder.id == tell.ruleID {
        for (id, tally) in tell.absorbed ?? [:] {
          var mark = memory.tallies[id] ?? AutopilotTally()
          mark.add(tally)
          memory.tallies[id] = mark
        }
      }
    }
    learn(lesson(for: question, verdict: .keep, created: now), into: &memory.rules)
    carryTallies(&memory)
  }

  /// Forgets lessons, each with every answer it was made from, so those things can be asked again.
  /// A tell whose answer is forgotten closes, without a score.
  static func forget(_ ruleIDs: [String], memory: inout AutopilotMemory) {
    for id in ruleIDs {
      if let rule = memory.rules.first(where: { $0.id == id }) {
        let taught = Set(questionIDs(rule))
        memory.questions.removeAll { taught.contains($0.id) }
      }
      memory.rules.removeAll { $0.id == id }
    }
    carryTallies(&memory)
    let asked = Set(memory.questions.map(\.id))
    for i in memory.tells.indices where memory.tells[i].isOpen {
      if !asked.contains(memory.tells[i].questionID) { memory.tells[i].state = "expired" }
    }
  }
}
