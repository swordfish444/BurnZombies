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
  @discardableResult public static func learn(
    _ rule: AutopilotRule, into rules: inout [AutopilotRule]
  ) -> String {
    guard rule.source == .operator, pinsRecency(rule.kind, rule.match) else {
      rules.append(rule)
      return rule.id
    }
    func mergeable(_ other: AutopilotRule) -> Bool {
      other.source == .operator && other.kind == rule.kind && other.verdict == rule.verdict
        && pinsRecency(other.kind, other.match)
    }
    if let i = rules.firstIndex(where: { mergeable($0) && subsumes($0.match, rule.match) }) {
      // An id another rule still has stays that rule's.
      let taken = rules.contains { $0.id == rule.id }
      let ids: [String] = (taken ? [] : [rule.id]) + (rule.formerIDs ?? [])
      rules[i].from = adding(questionIDs(rule), to: rules[i].from, except: rules[i].questionID)
      rules[i].formerIDs = adding(ids, to: rules[i].formerIDs, except: rules[i].id)
      return rules[i].id
    }
    var lesson = rule
    for old in rules where mergeable(old) && subsumes(rule.match, old.match) {
      let ids: [String] = [old.id] + (old.formerIDs ?? [])
      lesson.from = adding(questionIDs(old), to: lesson.from, except: lesson.questionID)
      lesson.formerIDs = adding(ids, to: lesson.formerIDs, except: lesson.id)
    }
    rules.removeAll { mergeable($0) && subsumes(rule.match, $0.match) }
    rules.append(lesson)
    return lesson.id
  }

  /// All question ids a lesson was made from: questionID plus from.
  public static func questionIDs(_ rule: AutopilotRule) -> [String] {
    let own: [String] = rule.questionID.map { [$0] } ?? []
    return own + (rule.from ?? [])
  }

  /// `list` with each new id appended once; nil stays nil when there is nothing to add.
  static func adding(_ ids: [String], to list: [String]?, except own: String?) -> [String]? {
    var result = list ?? []
    for id in ids where id != own && !result.contains(id) { result.append(id) }
    return result.isEmpty ? list : result
  }
}
