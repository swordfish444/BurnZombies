import Foundation

/// Guess before asking, keep score, earn trust: BZ guesses how the owner will answer each
/// question, and acts on its own only where its guesses have been right and nothing about the
/// question is new to the owner.
extension AutopilotPolicy {
  /// Right guesses in a row on a subject that earn trust on it.
  public static let trustStreak = 5
  /// Scores memory keeps, newest last.
  public static let maximumScores = 300

  /// Facts that make burning riskier: work only on this Mac, unsaved changes, a running server,
  /// recent use. Any fact BZ couldn't check (`unknown`) is risky too.
  static let riskyFacts: Set<String> = [
    "saved=local", "changes=small", "changes=large", "listening=yes", "stale=today",
    "idle=active", "idle=10m",
  ]
  /// Caution text on older questions, and the risk each one names.
  static let cautionRisks: [(text: String, risk: String)] = [
    ("work only on this Mac", "saved=local"), ("unsaved changes", "changes=small"),
    ("running a server", "listening=yes"),
  ]

  static func risky(_ fact: String, _ value: String) -> Bool {
    value == "unknown" || riskyFacts.contains(fact + "=" + value)
  }

  /// Sorted "fact=value" strings for the risky facts present among items (spec Part 3 list).
  public static func risks(_ kind: AutopilotKind, _ items: [AutopilotItem]) -> [String] {
    var found = Set<String>()
    for item in items where item.kind == kind {
      for (fact, value) in item.facts where risky(fact, value) { found.insert(fact + "=" + value) }
    }
    return found.sorted()
  }

  /// A stored question's risks: `risks` when set, otherwise from its match values plus caution
  /// text ("work only on this Mac" → saved=local, "unsaved changes" → changes=small,
  /// "running a server" → listening=yes).
  public static func risks(of question: AutopilotQuestion) -> Set<String> {
    if let stored = question.risks { return Set(stored) }
    var found = Set<String>()
    for (fact, values) in question.match {
      for value in values where risky(fact, value) { found.insert(fact + "=" + value) }
    }
    for caution in question.cautions ?? [] {
      for named in cautionRisks where caution.contains(named.text) { found.insert(named.risk) }
    }
    return found
  }

  /// A Yes or No the owner gave, not one BZ gave on its own.
  public static func ownerAnswered(_ question: AutopilotQuestion) -> Bool {
    guard question.answer == .yes || question.answer == .no else { return false }
    return question.answeredBy != "bz"
  }

  /// A subject is trusted when its last `trustStreak` scores are all right.
  public static func trusted(_ subject: String, scores: [AutopilotScore]) -> Bool {
    let recent = scores.filter { $0.subject == subject }.suffix(trustStreak)
    return recent.count == trustStreak && recent.allSatisfy(\.right)
  }

  /// nil when there is nothing to go on. Owner answers only: questions with answeredBy == "bz"
  /// don't count. The lean is the owner's usual answer on the question's subject, or on its kind
  /// when the subject has none; a tie is no guess. Sure only when the subject is trusted, the lean
  /// is yes, the owner said yes on the subject before, every risk on the question was on a
  /// question they said yes to there, and no keep lesson on the subject overlaps it.
  public static func guess(_ question: AutopilotQuestion, memory: AutopilotMemory)
    -> AutopilotGuess?
  {
    let topic = subject(question.kind, question.match)
    let owned = memory.questions.filter { past in
      guard past.id != question.id else { return false }
      return ownerAnswered(past)
    }
    let same = owned.filter { subject($0.kind, $0.match) == topic }
    let pool = same.isEmpty ? owned.filter { $0.kind == question.kind } : same
    let yes = pool.filter { $0.answer == .yes }
    let no = pool.count - yes.count
    guard yes.count != no else { return nil }
    let lean: AutopilotAnswer = yes.count > no ? .yes : .no
    let asked = risks(of: question)
    let saidYes = approvedRisks(topic, memory, besides: question.id)
    let general = generalize(question.kind, question.match)
    let kept = memory.rules.contains { rule in
      guard rule.verdict == .keep, rule.kind == question.kind else { return false }
      guard subject(rule.kind, rule.match) == topic else { return false }
      return overlaps(rule.match, general)
    }
    let earned: Bool = trusted(topic, scores: memory.scores) && lean == .yes
    let answeredYes: Bool = same.contains { $0.answer == .yes }
    let known: Bool = asked.isSubset(of: saidYes)
    let sure: Bool = earned && answeredYes && known && !kept
    // The words name only risks the owner said yes to among the answers counted.
    var seen = Set<String>()
    for past in yes { seen.formUnion(risks(of: past)) }
    let why: String
    if lean == .yes {
      why = reason(saidYes: yes.count, risks: asked.intersection(seen))
    } else {
      why = "You said no to " + like(no) + "."
    }
    return AutopilotGuess(answer: lean, sure: sure, why: why, source: "native")
  }

  /// The risks the owner said yes to on a subject: every risk on a question of theirs about it
  /// that they answered Yes. BZ's own calls don't count, nor does `questionID` itself.
  static func approvedRisks(_ topic: String, _ memory: AutopilotMemory, besides questionID: String)
    -> Set<String>
  {
    var said = Set<String>()
    for past in memory.questions where past.id != questionID && past.answer == .yes {
      guard ownerAnswered(past), subject(past.kind, past.match) == topic else { continue }
      said.formUnion(risks(of: past))
    }
    return said
  }

  /// How I'm doing (spec 4.2): plain counts, each line only when it has something to say.
  /// 1. Guesses right among the last 10 scores, replayed ones included.
  /// 2. Questions shown to the owner this week and what BZ burned on its own, and last week's when
  ///    it had any.
  /// 3. Copies the owner restored, out of the copies BZ burned, from the impact tally, which keeps
  ///    both for good (receipts.json keeps only the latest); without the tally, no line.
  /// 4. The replay of the owner's answers, once there are 5.
  public static func progress(
    _ memory: AutopilotMemory, receipts: [AutopilotReceipt], impact: AutopilotImpact?, now: Date
  ) -> AutopilotProgress {
    let told = Set(memory.tells.map(\.questionID))
    let lines: [String?] = [
      guessedLine(memory.scores), weekLine(memory.questions, told: told, receipts, now: now),
      undoneLine(impact), replayLine(memory.questions),
    ]
    return AutopilotProgress(lines: lines.compactMap { $0 })
  }

  /// "I guessed 9 of your last 10 answers right."
  static func guessedLine(_ scores: [AutopilotScore]) -> String? {
    let recent = scores.suffix(10)
    let right = recent.filter(\.right).count
    switch recent.count {
    case 0: return nil
    case 1: return right == 1 ? "I guessed your last answer right." : "I missed your last answer."
    default: return "I guessed \(right) of your last \(recent.count) answers right."
    }
  }

  /// "This week: 2 questions, 120.0 GB burned on my own. Last week: 9 questions, 80.0 GB."
  static func weekLine(
    _ questions: [AutopilotQuestion], told: Set<String>, _ receipts: [AutopilotReceipt], now: Date
  ) -> String? {
    let weekAgo = now.addingTimeInterval(-7 * 86_400)
    let twoWeeksAgo = weekAgo.addingTimeInterval(-7 * 86_400)
    let asked = questions.filter { !told.contains($0.id) }
    let this = week(asked, receipts, after: weekAgo, through: now)
    let last = week(asked, receipts, after: twoWeeksAgo, through: weekAgo)
    let lastHadAny = last.questions > 0 || last.bytes > 0
    guard this.questions > 0 || this.bytes > 0 || lastHadAny else { return nil }
    let shown: String = AutopilotEval.plural(this.questions, "question")
    let burned: String = roughly(this.bytes)
    var line: String = "This week: " + shown + ", " + burned + " burned on my own."
    if lastHadAny {
      let before: String = AutopilotEval.plural(last.questions, "question")
      let freed: String = roughly(last.bytes)
      line += " Last week: " + before + ", " + freed + "."
    }
    return line
  }

  /// Questions shown to the owner in a window (BZ's own calls aren't shown, and the caller leaves
  /// out ones that were tells, undone or not), and the disk that burns of copies and folders not
  /// asked for by the owner's Burn now freed in it. A stopped program frees memory, not disk.
  static func week(
    _ questions: [AutopilotQuestion], _ receipts: [AutopilotReceipt], after start: Date,
    through end: Date
  ) -> (questions: Int, bytes: UInt64) {
    let shown = questions.filter { question in
      question.answeredBy != "bz" && question.asked > start && question.asked <= end
    }
    var bytes: UInt64 = 0
    for receipt in receipts where receipt.outcome == "burned" && receipt.authority != "operator" {
      guard receipt.kind == .worktree || receipt.kind == .disk else { continue }
      if receipt.date > start && receipt.date <= end { bytes += receipt.bytes }
    }
    return (shown.count, bytes)
  }

  /// "You undid 0 of the 498 copies I burned." Only copies can be brought back.
  static func undoneLine(_ impact: AutopilotImpact?) -> String? {
    guard let impact else { return nil }
    let burned = impact.worktrees + impact.restored
    guard burned > 0 else { return nil }
    let copies: String = burned == 1 ? "1 copy" : "\(burned) copies"
    return "You undid \(impact.restored) of the " + copies + " I burned."
  }

  /// "Replaying your 27 answers, I'd have asked 17 and handled the other 10 on my own the way you
  /// would have."
  static func replayLine(_ questions: [AutopilotQuestion]) -> String? {
    let summary = AutopilotEval.replay(questions).summary
    guard summary.answers >= 5 else { return nil }
    let handled = summary.settled + summary.acted
    let wrong = summary.wrongSettled + summary.wrongActed
    let start =
      "Replaying your \(summary.answers) answers, I'd have asked \(summary.asked)"
      + " and handled the other \(handled) on my own"
    guard wrong > 0 else { return start + " the way you would have." }
    return start + ", \(wrong) of them not the way you would have."
  }

  /// "1 like this", "6 like these".
  static func like(_ count: Int) -> String {
    count == 1 ? "1 like this" : "\(count) like these"
  }

  /// "You said yes to 6 like these, including ones with unsaved changes."
  static func reason(saidYes count: Int, risks: Set<String>) -> String {
    let words = riskWords(risks)
    guard !words.isEmpty else { return "You said yes to " + like(count) + "." }
    return "You said yes to " + like(count) + ", including ones with" + joined(words) + "."
  }

  /// Risks in plain words, each once, in a fixed order.
  static func riskWords(_ risks: Set<String>) -> [String] {
    var words = Set<String>()
    for risk in risks {
      let parts = risk.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, let word = riskWord(fact: parts[0], value: parts[1]) else {
        continue
      }
      words.insert(word)
    }
    let order = [
      "work only on this Mac", "unsaved changes", "a running server", "things I couldn't check",
      "recent use",
    ]
    return order.filter(words.contains)
  }

  /// What a risk means to the owner. Something BZ couldn't check reads as that, whatever the fact.
  static func riskWord(fact: String, value: String) -> String? {
    if value == "unknown" { return "things I couldn't check" }
    switch fact {
    case "saved": return value == "local" ? "work only on this Mac" : nil
    case "changes": return "unsaved changes"
    case "listening": return value == "yes" ? "a running server" : nil
    case "stale": return value == "today" ? "recent use" : nil
    case "idle": return "recent use"
    default: return nil
    }
  }
}

/// The eval: replays the owner's answers in order and shows what BZ would have done with each,
/// using the same lessons, guesses and trust as the live path.
public enum AutopilotEval {
  public struct Step: Codable, Sendable, Equatable {
    public var questionID: String
    public var date: Date
    public var kind: AutopilotKind
    public var subject: String
    public var owner: AutopilotAnswer
    public var guess: AutopilotAnswer?
    /// "settled" (an earlier lesson covered it), "acted" (sure and trusted) or "asked".
    public var outcome: String
    /// Whether the guess or the lesson matched the owner; nil without either.
    public var matched: Bool?
    public var bytes: UInt64
    public init(
      questionID: String, date: Date, kind: AutopilotKind, subject: String,
      owner: AutopilotAnswer, guess: AutopilotAnswer?, outcome: String, matched: Bool?,
      bytes: UInt64
    ) {
      self.questionID = questionID
      self.date = date
      self.kind = kind
      self.subject = subject
      self.owner = owner
      self.guess = guess
      self.outcome = outcome
      self.matched = matched
      self.bytes = bytes
    }
  }

  public struct Summary: Codable, Sendable, Equatable {
    public var answers = 0, settled = 0, acted = 0, asked = 0, guesses = 0, right = 0
    public var wrongSettled = 0, wrongActed = 0
    /// What settled and acted steps would have freed without asking.
    public var handledBytes: UInt64 = 0
    /// Lessons left at the end.
    public var lessons = 0
    public init() {}
  }

  public struct Replay: Codable, Sendable, Equatable {
    public var steps: [Step]
    public var summary: Summary
    /// Scores of the guesses on asked questions, marked replayed.
    public var scores: [AutopilotScore]
    public init(steps: [Step], summary: Summary, scores: [AutopilotScore]) {
      self.steps = steps
      self.summary = summary
      self.scores = scores
    }
  }

  /// Replays the owner's Yes and No answers in the order they were answered; skips teach
  /// nothing, and BZ's own calls are not the owner's. Each answer is first settled by an earlier
  /// lesson, acted on when the guess is sure, or asked, and then teaches its lesson.
  public static func replay(_ questions: [AutopilotQuestion]) -> Replay {
    let owned = questions.enumerated().filter { _, question in
      guard question.answered != nil else { return false }
      return AutopilotPolicy.ownerAnswered(question)
    }
    let ordered = owned.sorted { a, b in
      let first = a.element.answered ?? .distantPast
      let second = b.element.answered ?? .distantPast
      return first != second ? first < second : a.offset < b.offset
    }
    var memory = AutopilotMemory()
    var steps = [Step]()
    var summary = Summary()
    for (_, question) in ordered {
      guard let owner = question.answer, let date = question.answered else { continue }
      let step = replay(question, owner: owner, date: date, memory: &memory)
      steps.append(step)
      add(step, to: &summary)
    }
    summary.answers = steps.count
    summary.lessons = memory.rules.count
    return Replay(steps: steps, summary: summary, scores: memory.scores)
  }

  /// One answer: what BZ would have done, then the lesson it teaches.
  static func replay(
    _ question: AutopilotQuestion, owner: AutopilotAnswer, date: Date,
    memory: inout AutopilotMemory
  ) -> Step {
    let subject = AutopilotPolicy.subject(question.kind, question.match)
    let general = AutopilotPolicy.generalize(question.kind, question.match)
    let lessons = memory.rules.filter { $0.kind == question.kind }
    let kept = lessons.contains {
      $0.verdict == .keep && AutopilotPolicy.overlaps($0.match, general)
    }
    let burned = lessons.contains {
      $0.verdict == .burn && AutopilotPolicy.subsumes($0.match, general)
    }
    var lean: AutopilotAnswer?
    var outcome = "settled"
    if kept || burned {
      lean = kept ? .no : .yes
    } else {
      let guess = AutopilotPolicy.guess(question, memory: memory)
      lean = guess?.answer
      outcome = guess?.sure == true ? "acted" : "asked"
      if outcome == "asked", let lean {
        AutopilotPolicy.score(
          question, guess: lean, answer: owner, into: &memory, date: date, replayed: true)
      }
    }
    let verdict: AutopilotVerdict = owner == .yes ? .burn : .keep
    let taught: [AutopilotRule] = AutopilotPolicy.lessons(
      for: question, verdict: verdict, created: date, earlier: memory.questions)
    for lesson in taught { AutopilotPolicy.learn(lesson, into: &memory.rules) }
    memory.questions.append(question)
    let matched: Bool? = lean.map { $0 == owner }
    return Step(
      questionID: question.id, date: date, kind: question.kind, subject: subject, owner: owner,
      guess: lean, outcome: outcome, matched: matched, bytes: question.bytes)
  }

  static func add(_ step: Step, to summary: inout Summary) {
    switch step.outcome {
    case "settled": summary.settled += 1
    case "acted": summary.acted += 1
    default: summary.asked += 1
    }
    if step.outcome == "asked" {
      guard let matched = step.matched else { return }
      summary.guesses += 1
      if matched { summary.right += 1 }
      return
    }
    summary.handledBytes += step.bytes
    if step.matched != true {
      if step.outcome == "settled" { summary.wrongSettled += 1 } else { summary.wrongActed += 1 }
    }
  }

  /// The replay as the running app sends it to `burnzombies autopilot eval`: JSON with ISO 8601
  /// dates.
  public static func replay(json: Data) throws -> Replay {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Replay.self, from: json)
  }

  /// Plain text for the CLI: one line per step, then the summary.
  public static func report(_ replay: Replay) -> String {
    let dates = DateFormatter()
    dates.locale = Locale(identifier: "en_US_POSIX")
    dates.dateFormat = "yyyy-MM-dd HH:mm"
    var lines = [String]()
    for step in replay.steps {
      let guess = step.guess?.rawValue ?? "-"
      let columns: [String] = [
        dates.string(from: step.date),
        "owner " + pad(step.owner.rawValue, 3),
        "guess " + pad(guess, 3),
        pad(step.outcome, 7),
        pad(step.subject, 24),
        AutopilotPolicy.roughly(step.bytes),
      ]
      lines.append(columns.joined(separator: "  "))
    }
    lines.append(summaryLine(replay.summary))
    return lines.joined(separator: "\n")
  }

  /// "27 answers: 3 settled, 7 acted, 17 asked. Guessed 13 of 14 right. ..."
  static func summaryLine(_ s: Summary) -> String {
    let answers = plural(s.answers, "answer")
    let outcomes = "\(answers): \(s.settled) settled, \(s.acted) acted, \(s.asked) asked."
    let guesses = "Guessed \(s.right) of \(s.guesses) right."
    let wrong = "Wrong: \(s.wrongSettled) settled, \(s.wrongActed) acted."
    let handled = "Handled \(AutopilotPolicy.roughly(s.handledBytes)) without asking."
    let lessons = plural(s.lessons, "lesson") + "."
    return [outcomes, guesses, wrong, handled, lessons].joined(separator: " ")
  }

  static func plural(_ count: Int, _ noun: String) -> String {
    "\(count) " + (count == 1 ? noun : noun + "s")
  }

  static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text.padding(toLength: width, withPad: " ", startingAt: 0)
  }
}
