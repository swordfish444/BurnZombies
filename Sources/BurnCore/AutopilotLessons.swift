import Foundation

/// Lessons: what an answer teaches. An answer says why the owner burns or keeps things, not
/// which project they belong to, so it becomes a general rule, and a lesson that covers another
/// takes it in instead of piling up beside it.
extension AutopilotPolicy {
  /// Which project, place, maker or size a thing is. In the owner's answers these never changed
  /// the answer, so a lesson that pins recency leaves them out.
  static let identityFacts: Set<String> = ["repo", "place", "agent", "size"]

  /// Whether a pattern says how long things sat unused, with values that are all known.
  public static func pinsRecency(_ kind: AutopilotKind, _ match: [String: [String]]) -> Bool {
    guard let recency = recencyFacts[kind], let values = match[recency], !values.isEmpty else {
      return false
    }
    return !values.contains("unknown")
  }

  /// The pattern without its identity facts, when it pins recency. Without known recency a
  /// general pattern would cover things used an hour ago, so the pattern stays as it is.
  public static func generalize(_ kind: AutopilotKind, _ match: [String: [String]]) -> [String: [
    String
  ]] {
    guard pinsRecency(kind, match) else { return match }
    return match.filter { !identityFacts.contains($0.key) }
  }

  /// What an answer to a pattern teaches: the general pattern, widened toward safer things for a
  /// yes and riskier ones for a no.
  public static func lessonMatch(
    _ kind: AutopilotKind, _ match: [String: [String]], verdict: AutopilotVerdict
  ) -> [String: [String]] {
    widen(generalize(kind, match), verdict: verdict)
  }

  /// Whether `wide` matches every item `narrow` matches: each of its facts is in `narrow`, with
  /// no value `wide` leaves out.
  public static func subsumes(_ wide: [String: [String]], _ narrow: [String: [String]]) -> Bool {
    wide.allSatisfy { key, values in
      guard let inner = narrow[key] else { return false }
      return Set(inner).isSubset(of: values)
    }
  }

  /// Whether some item could match both: every fact they share has a value in common.
  public static func overlaps(_ a: [String: [String]], _ b: [String: [String]]) -> Bool {
    a.allSatisfy { key, values in
      guard let other = b[key] else { return true }
      return !Set(values).isDisjoint(with: other)
    }
  }

  /// Adds an operator lesson. Two cases, both only for operator rules of the same kind and
  /// verdict that pin recency:
  /// - an existing lesson already subsumes `rule`: `rule`'s question id joins that lesson's
  ///   `from`, and its id is returned;
  /// - `rule` subsumes existing lessons: they are removed, and their questionID, `from` and id
  ///   move into `rule.from` / `rule.formerIDs`.
  /// Merging carries every question id and former id along, so nothing a lesson was made from or
  /// did is lost. A rule that doesn't pin recency is only ever appended, and never changed.
  ///
  /// A lesson BZ taught itself by acting (`tellID`) stands alone (R23): it takes nothing in and
  /// joins nothing, and an owner's answer never joins it, so an Undo takes back exactly what BZ did
  /// and nothing the owner taught. An owner's wider answer may still take it in.
  @discardableResult public static func learn(
    _ rule: AutopilotRule, into rules: inout [AutopilotRule]
  ) -> String {
    guard rule.source == .operator, rule.tellID == nil, pinsRecency(rule.kind, rule.match) else {
      rules.append(rule)
      return rule.id
    }
    func mergeable(_ other: AutopilotRule) -> Bool {
      guard other.source == .operator, other.kind == rule.kind, other.verdict == rule.verdict
      else { return false }
      return pinsRecency(other.kind, other.match)
    }
    func joinable(_ other: AutopilotRule) -> Bool {
      guard other.tellID == nil, mergeable(other) else { return false }
      return subsumes(other.match, rule.match)
    }
    if let i = rules.firstIndex(where: joinable) {
      var ids: [String] = []
      // An id another rule still has stays that rule's.
      if !rules.contains(where: { $0.id == rule.id }) { ids.append(rule.id) }
      ids.append(contentsOf: rule.formerIDs ?? [])
      rules[i].from = adding(questionIDs(rule), to: rules[i].from, except: rules[i].questionID)
      rules[i].formerIDs = adding(ids, to: rules[i].formerIDs, except: rules[i].id)
      return rules[i].id
    }
    var lesson = rule
    for old in rules where mergeable(old) && subsumes(rule.match, old.match) {
      var ids: [String] = [old.id]
      ids.append(contentsOf: old.formerIDs ?? [])
      lesson.from = adding(questionIDs(old), to: lesson.from, except: lesson.questionID)
      lesson.formerIDs = adding(ids, to: lesson.formerIDs, except: lesson.id)
    }
    rules.removeAll { mergeable($0) && subsumes(rule.match, $0.match) }
    rules.append(lesson)
    return lesson.id
  }

  /// All question ids a lesson was made from: questionID plus from.
  public static func questionIDs(_ rule: AutopilotRule) -> [String] {
    var ids: [String] = []
    if let own = rule.questionID { ids.append(own) }
    ids.append(contentsOf: rule.from ?? [])
    return ids
  }

  /// The lesson an answer to `question` teaches: its general pattern, widened toward `verdict`,
  /// titled without the project or its maker. The one way a lesson is made, whether from an
  /// answer, BZ's own act, an undo, a migration or the replay.
  ///
  /// A Yes covers only the risks it was given (R31): the ones its card showed (`risks`), or for
  /// BZ's own act the ones the owner approved on the subject (`approved`). A question from before
  /// cards named their risks (`risks` nil) teaches what it always did. A No is never narrowed.
  public static func lesson(
    for question: AutopilotQuestion, verdict: AutopilotVerdict, created: Date,
    approved: Set<String>? = nil
  ) -> AutopilotRule {
    var general = question
    general.match = generalize(question.kind, question.match)
    var match = lessonMatch(question.kind, question.match, verdict: verdict)
    let shown: Set<String>? = question.risks.map { Set($0) }
    if verdict == .burn, let allowed = approved ?? shown {
      match = narrowed(match, kind: question.kind, to: allowed)
    }
    let answer: AutopilotAnswer = verdict == .burn ? .yes : .no
    return AutopilotRule(
      kind: question.kind, match: match, verdict: verdict, source: .operator,
      title: ruleTitle(general, answer: answer), created: created, questionID: question.id)
  }

  /// A burn lesson kept within `allowed` risks, for an owner's Yes and BZ's own act alike: each
  /// risk fact of the kind (`riskFacts`) allows its safe values and only the risky values in
  /// `allowed`, and `unknown` only when it is there. A value the lesson already left out stays out.
  static func narrowed(
    _ match: [String: [String]], kind: AutopilotKind, to allowed: Set<String>
  ) -> [String: [String]] {
    var result = match
    for (fact, values) in riskFacts[kind] ?? [] {
      let kept: [String] = values.filter { value in
        !risky(fact, value) || allowed.contains(fact + "=" + value)
      }
      if let mine = result[fact] {
        result[fact] = kept.filter(mine.contains)
      } else {
        result[fact] = kept
      }
    }
    return result
  }

  /// Questions by id; the first of a repeated id wins.
  static func questionsByID(_ questions: [AutopilotQuestion]) -> [String: AutopilotQuestion] {
    var byID = [String: AutopilotQuestion]()
    for question in questions where byID[question.id] == nil { byID[question.id] = question }
    return byID
  }

  /// Version 1 → 2:
  /// - regeneralize operator rules whose question pins recency (new id; old id goes to formerIDs);
  /// - absorb with learn();
  /// - seed tallies from receipts;
  /// - seed scores from AutopilotEval.replay(memory.questions).scores.
  /// Version >= 2 returns its input unchanged.
  public static func migrate(_ memory: AutopilotMemory, receipts: [AutopilotReceipt])
    -> AutopilotMemory
  {
    guard memory.version < 2 else { return memory }
    var result = memory
    result.version = 2
    let asked = questionsByID(memory.questions)
    var rules: [AutopilotRule] = []
    for rule in memory.rules { learn(regeneralized(rule, asked: asked), into: &rules) }
    result.rules = rules
    // Seeded from the receipts once; from now on burns count as they are recorded.
    result.tallies = [:]
    for receipt in receipts { tally(receipt, into: &result) }
    if result.scores.isEmpty { result.scores = AutopilotEval.replay(memory.questions).scores }
    return result
  }

  /// A rule from before lessons, made general the way an answer is now. Its old id goes to
  /// `formerIDs`, so receipts that name it still count toward the lesson. A rule whose question
  /// doesn't pin recency comes back unchanged.
  static func regeneralized(_ rule: AutopilotRule, asked: [String: AutopilotQuestion])
    -> AutopilotRule
  {
    guard rule.source == .operator, let id = rule.questionID, let question = asked[id],
      pinsRecency(question.kind, question.match)
    else { return rule }
    var relearned = lesson(for: question, verdict: rule.verdict, created: rule.created)
    relearned.enabled = rule.enabled
    relearned.from = rule.from
    relearned.formerIDs = adding([rule.id], to: rule.formerIDs, except: relearned.id)
    return relearned
  }

  /// The current lesson id for an authority "rule:<id>", where <id> is current or in some formerIDs.
  public static func lessonID(forAuthority authority: String, rules: [AutopilotRule]) -> String? {
    let prefix = "rule:"
    guard authority.hasPrefix(prefix) else { return nil }
    let id = String(authority.dropFirst(prefix.count))
    if rules.contains(where: { $0.id == id }) { return id }
    return rules.first { $0.formerIDs?.contains(id) == true }?.id
  }

  /// outcome "burned": count+1, bytes += receipt.bytes. outcome "restored": also count, plus undone+1.
  /// Called once per receipt outcome.
  public static func tally(_ receipt: AutopilotReceipt, into memory: inout AutopilotMemory) {
    guard receipt.outcome == "burned" || receipt.outcome == "restored",
      let id = lessonID(forAuthority: receipt.authority, rules: memory.rules)
    else { return }
    var mark = memory.tallies[id] ?? AutopilotTally()
    mark.count += 1
    mark.bytes += receipt.bytes
    if receipt.outcome == "restored" { mark.undone += 1 }
    memory.tallies[id] = mark
  }

  /// A restore of a burn its lesson already counted: only marks it undone.
  static func undone(_ receipt: AutopilotReceipt, into memory: inout AutopilotMemory) {
    guard let id = lessonID(forAuthority: receipt.authority, rules: memory.rules) else { return }
    var mark = memory.tallies[id] ?? AutopilotTally()
    mark.undone += 1
    memory.tallies[id] = mark
  }

  /// Tallies follow their lessons: a lesson taken into another adds its tally to that one's, and a
  /// forgotten lesson's tally goes with it.
  static func carryTallies(_ memory: inout AutopilotMemory) {
    let current = Set(memory.rules.map(\.id))
    for key in memory.tallies.keys.sorted() where !current.contains(key) {
      guard let mark = memory.tallies.removeValue(forKey: key),
        let owner = memory.rules.first(where: { $0.formerIDs?.contains(key) == true })
      else { continue }
      var into = memory.tallies[owner.id] ?? AutopilotTally()
      into.add(mark)
      memory.tallies[owner.id] = into
    }
  }

  /// `list` with each new id appended once; nil stays nil when there is nothing to add.
  static func adding(_ ids: [String], to list: [String]?, except own: String?) -> [String]? {
    var result = list ?? []
    for id in ids where id != own && !result.contains(id) { result.append(id) }
    return result.isEmpty ? list : result
  }
}
