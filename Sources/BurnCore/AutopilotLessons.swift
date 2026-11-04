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
      guard other.source == .operator, other.kind == rule.kind, other.verdict == rule.verdict
      else { return false }
      return pinsRecency(other.kind, other.match)
    }
    if let i = rules.firstIndex(where: { mergeable($0) && subsumes($0.match, rule.match) }) {
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
    var asked = [String: AutopilotQuestion]()
    for question in memory.questions where asked[question.id] == nil {
      asked[question.id] = question
    }
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
    var lesson = rule
    lesson.match = lessonMatch(question.kind, question.match, verdict: rule.verdict)
    lesson.id = AutopilotRule.key(kind: rule.kind, match: lesson.match) + ":" + rule.verdict.rawValue
    lesson.formerIDs = adding([rule.id], to: rule.formerIDs, except: lesson.id)
    // Titled like a new answer's lesson: without the project or its maker.
    var general = question
    general.match = generalize(question.kind, question.match)
    lesson.title = ruleTitle(general, answer: rule.verdict == .burn ? .yes : .no)
    return lesson
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
  public static func carryTallies(_ memory: inout AutopilotMemory) {
    let current = Set(memory.rules.map(\.id))
    for key in memory.tallies.keys.sorted() where !current.contains(key) {
      guard let mark = memory.tallies.removeValue(forKey: key),
        let owner = memory.rules.first(where: { $0.formerIDs?.contains(key) == true })
      else { continue }
      var into = memory.tallies[owner.id] ?? AutopilotTally()
      into.count += mark.count
      into.bytes += mark.bytes
      into.undone += mark.undone
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

/// How lessons read in Settings (spec 2.4): display-only groups, one sentence each, written by
/// native templates. Only the owner's lessons; starter rules are listed apart.
extension AutopilotPolicy {
  /// Copies to burn by how recently they were used, copies of named projects at any age, programs,
  /// folders by how recently they were used, then each keep.
  public static func lessonGroups(_ memory: AutopilotMemory) -> [AutopilotLessonGroup] {
    let lessons = memory.rules.filter { $0.source == .operator }
    let burns = lessons.filter { $0.verdict == .burn }
    var groups: [AutopilotLessonGroup] = []
    groups += copyGroups(burns.filter { $0.kind == .worktree }, memory)
    groups += programGroups(burns.filter { $0.kind == .process }, memory)
    groups += folderGroups(burns.filter { $0.kind == .disk }, memory)
    for rule in lessons where rule.verdict != .burn { groups.append(keepGroup(rule, memory)) }
    return groups
  }

  /// "since yesterday" for `day`: how long copies and folders sat untouched, by floor.
  static let untouched: [String: String] = [
    "day": "since yesterday", "week": "for a week", "month": "for a month",
    "older": "for 3 months",
  ]
  static let programNames: [String: String] = [
    "node": "Node", "java": "Java helpers", "python": "Python", "ruby": "Ruby",
    "browser": "Robot browsers", "build": "Build tools", "shell": "Scripts",
  ]
  /// A keep's subject: a plural noun that can begin a sentence.
  static let keptProgramNames: [String: String] = [
    "node": "Node programs", "java": "Java helpers", "python": "Python programs",
    "ruby": "Ruby programs", "browser": "Robot browsers", "build": "Build tools",
    "shell": "Scripts",
  ]
  static let idleAfter: [String: String] = [
    "active": "right away", "10m": "after 10 minutes", "1h": "after an hour",
    "6h": "after 6 hours", "1d": "after a day",
  ]
  static let idleBelow: [String: String] = [
    "10m": "10 minutes", "1h": "an hour", "6h": "6 hours", "1d": "a day",
  ]
  static let folderNames: [String: String] = [
    "node_modules": "node_modules", "build-output": "build folders",
    "xcode-derived": "Xcode build folders", "package-cache": "tool caches",
    "python-env": "Python environments",
  ]

  /// The most recent use a lesson covers, when it pins recency: its first recency value in
  /// safety order.
  static func recencyFloor(_ rule: AutopilotRule) -> String? {
    guard pinsRecency(rule.kind, rule.match), let fact = recencyFacts[rule.kind],
      let values = rule.match[fact], let order = safety[fact]
    else { return nil }
    return order.first(where: values.contains)
  }

  /// Whether a lesson only covers these values of a fact. A lesson without the fact covers all.
  static func requires(_ rule: AutopilotRule, _ fact: String, within allowed: Set<String>) -> Bool {
    guard let values = rule.match[fact] else { return false }
    return Set(values).isSubset(of: allowed)
  }

  /// Whether a lesson covers any of these values of a fact. A lesson without the fact covers all.
  static func covers(_ rule: AutopilotRule, _ fact: String, any values: Set<String>) -> Bool {
    guard let mine = rule.match[fact] else { return true }
    return !values.isDisjoint(with: mine)
  }

  /// "A", "A or B", "A, B, or C".
  static func either(_ items: [String]) -> String {
    guard items.count > 2 else { return items.joined(separator: " or ") }
    let head = items.dropLast().joined(separator: ", ")
    return head + ", or " + (items.last ?? "")
  }

  static func copyGroups(_ rules: [AutopilotRule], _ memory: AutopilotMemory)
    -> [AutopilotLessonGroup]
  {
    var byFloor: [String: [AutopilotRule]] = [:]
    var anyAge: [AutopilotRule] = []
    for rule in rules {
      if let floor = recencyFloor(rule) {
        byFloor[floor, default: []].append(rule)
      } else {
        anyAge.append(rule)
      }
    }
    var groups: [AutopilotLessonGroup] = []
    for floor in safety["stale"] ?? [] {
      guard let members = byFloor[floor] else { continue }
      let start: String
      if floor == "today" {
        start = "Copies are done the same day"
      } else {
        start = "Copies nobody touched " + (untouched[floor] ?? floor) + " are done"
      }
      let sentence: String = start + copyOnce(members) + copyEven(members) + "."
      groups.append(group("worktree:burn:" + floor, .worktree, .burn, sentence, members, memory))
    }
    if !anyAge.isEmpty {
      let start = projectNames(anyAge) + ", copies are done at any age"
      let sentence: String = start + anyAgeOnce(anyAge) + "."
      groups.append(group("worktree:burn:projects", .worktree, .burn, sentence, anyAge, memory))
    }
    return groups
  }

  /// What every lesson in the group requires before a copy is done.
  static func copyOnce(_ rules: [AutopilotRule]) -> String {
    let github = rules.allSatisfy { requires($0, "saved", within: ["pushed", "merged"]) }
    let clean = rules.allSatisfy { requires($0, "changes", within: ["none"]) }
    if github && clean { return " once their work is on GitHub and nothing is unsaved" }
    if github { return " once their work is on GitHub" }
    return clean ? " once nothing is unsaved" : ""
  }

  /// The risky copies any lesson in the group covers.
  static func copyEven(_ rules: [AutopilotRule]) -> String {
    var risks: [String] = []
    if rules.contains(where: { covers($0, "changes", any: ["small", "large"]) }) {
      risks.append("unsaved work")
    }
    if rules.contains(where: { covers($0, "saved", any: ["local"]) }) {
      risks.append("work only on this Mac")
    }
    let unchecked = rules.contains { rule in
      covers(rule, "saved", any: ["unknown"]) || covers(rule, "changes", any: ["unknown"])
    }
    if unchecked { risks.append("work I couldn't check") }
    return risks.isEmpty ? "" : ", even with " + either(risks)
  }

  /// "In api, web-app and 2 more projects": the projects most lessons name, then a count.
  static func projectNames(_ rules: [AutopilotRule]) -> String {
    var counts: [String: Int] = [:]
    for rule in rules {
      for repo in Set(rule.match["repo"] ?? []) where !["", "none", "unknown"].contains(repo) {
        counts[repo, default: 0] += 1
      }
    }
    let ranked = counts.keys.sorted { a, b in
      let first = counts[a] ?? 0
      let second = counts[b] ?? 0
      return first != second ? first > second : a < b
    }
    switch ranked.count {
    case 0: return "For some projects"
    case 1: return "In " + ranked[0]
    case 2: return "In " + ranked[0] + " and " + ranked[1]
    default:
      let named: String = ranked[0] + ", " + ranked[1]
      let more: String = AutopilotEval.plural(ranked.count - 2, "more project")
      return "In " + named + " and " + more
    }
  }

  /// What every any-age lesson requires: work on GitHub, and no chat using the copy.
  static func anyAgeOnce(_ rules: [AutopilotRule]) -> String {
    var parts: [String] = []
    if rules.allSatisfy({ requires($0, "saved", within: ["pushed", "merged"]) }) {
      parts.append("their work is on GitHub")
    }
    if rules.allSatisfy({ requires($0, "thread", within: ["none", "ended"]) }) {
      parts.append("no chat is using them")
    }
    return parts.isEmpty ? "" : " once " + parts.joined(separator: " and ")
  }

  /// One sentence for every program lesson: each family once, at the lowest idle floor any of its
  /// lessons covers, ordered by floor and then family.
  static func programGroups(_ rules: [AutopilotRule], _ memory: AutopilotMemory)
    -> [AutopilotLessonGroup]
  {
    guard !rules.isEmpty else { return [] }
    let order = safety["idle"] ?? []
    var floors: [String: Int] = [:]
    for rule in rules {
      // Without an idle fact a lesson covers programs busy right now too.
      let idle = rule.match["idle"] ?? ["active"]
      let floor = order.firstIndex(where: idle.contains) ?? order.count
      for family in rule.match["family"] ?? [""] {
        floors[family] = min(floors[family] ?? Int.max, floor)
      }
    }
    let families = floors.keys.sorted { a, b in
      let first = floors[a] ?? 0
      let second = floors[b] ?? 0
      return first != second ? first < second : a < b
    }
    var parts: [String] = []
    for family in families {
      let name = programNames[family] ?? otherPrograms(family)
      let floor: Int = floors[family] ?? order.count
      guard floor < order.count, let after = idleAfter[order[floor]] else {
        parts.append(name)
        continue
      }
      parts.append(name + " " + after)
    }
    let sentence = "Leftover programs can stop once idle: " + parts.joined(separator: ", ") + "."
    return [group("process:burn", .process, .burn, sentence, rules, memory)]
  }

  static func otherPrograms(_ family: String) -> String {
    switch family {
    case "": return "All programs"
    case "other": return "Other programs"
    default: return family.capitalized + " programs"
    }
  }

  /// Folder lessons by how recently the folders were used; each folder kind once, those that
  /// freed the most first.
  static func folderGroups(_ rules: [AutopilotRule], _ memory: AutopilotMemory)
    -> [AutopilotLessonGroup]
  {
    var byFloor: [String: [AutopilotRule]] = [:]
    for rule in rules { byFloor[recencyFloor(rule) ?? "any", default: []].append(rule) }
    var groups: [AutopilotLessonGroup] = []
    for floor in (safety["stale"] ?? []) + ["any"] {
      guard let members = byFloor[floor] else { continue }
      var freed: [String: UInt64] = [:]
      for rule in members {
        let bytes = memory.tallies[rule.id]?.bytes ?? 0
        for folder in rule.match["folder"] ?? ["other"] {
          freed[folderNames[folder] ?? "other folders", default: 0] += bytes
        }
      }
      let names = freed.keys.sorted { a, b in
        let first = freed[a] ?? 0
        let second = freed[b] ?? 0
        return first != second ? first > second : a.lowercased() < b.lowercased()
      }
      let start: String
      switch floor {
      case "today": start = "Rebuildable folders can go the same day: "
      case "any": start = "Rebuildable folders can go at any age: "
      default: start = "Rebuildable folders untouched " + (untouched[floor] ?? floor) + " can go: "
      }
      let sentence = start + names.joined(separator: ", ") + "."
      groups.append(group("disk:burn:" + floor, .disk, .burn, sentence, members, memory))
    }
    return groups
  }

  /// A keep reads on its own: programs by how long they may sit idle, anything else by its facts.
  static func keepGroup(_ rule: AutopilotRule, _ memory: AutopilotMemory) -> AutopilotLessonGroup {
    let sentence = rule.kind == .process ? programKeep(rule) : keepSentence(rule)
    return group("rule:" + rule.id, rule.kind, rule.verdict, sentence, [rule], memory)
  }

  /// "Java helpers serving a port stay while idle less than an hour."
  static func programKeep(_ rule: AutopilotRule) -> String {
    let families = rule.match["family"] ?? []
    var subject = "Programs"
    if families.count == 1 {
      subject = keptProgramNames[families[0]] ?? otherPrograms(families[0])
    }
    if rule.match["listening"] == ["yes"] { subject += " serving a port" }
    guard let below = idleCeiling(rule) else { return subject + " stay." }
    return subject + " stay while idle less than " + below + "."
  }

  /// The idle floor just above everything a keep covers: "an hour" for active and 10m.
  static func idleCeiling(_ rule: AutopilotRule) -> String? {
    guard let values = rule.match["idle"], let order = safety["idle"],
      let top = order.lastIndex(where: values.contains), top + 1 < order.count
    else { return nil }
    return idleBelow[order[top + 1]]
  }

  /// "Old project copies stay: Work only on this Mac, Has unsaved changes."
  static func keepSentence(_ rule: AutopilotRule) -> String {
    let plural = noun(rule.kind, match: rule.match).1
    // A real folder name like node_modules keeps its case.
    let named = plural.split(separator: " ").first?.contains("_") == true
    let subject = named ? plural : plural.prefix(1).uppercased() + plural.dropFirst()
    let shown = facts(rule.kind, match: rule.match)
    guard !shown.isEmpty else { return subject + " stay." }
    return subject + " stay: " + shown.joined(separator: ", ") + "."
  }

  static func group(
    _ id: String, _ kind: AutopilotKind, _ verdict: AutopilotVerdict, _ sentence: String,
    _ rules: [AutopilotRule], _ memory: AutopilotMemory
  ) -> AutopilotLessonGroup {
    AutopilotLessonGroup(
      id: id, kind: kind, verdict: verdict, sentence: sentence,
      evidence: evidence(kind, verdict, rules, memory), ruleIDs: rules.map(\.id))
  }

  /// "From 11 answers · burned 364 copies, 396.0 GB · undone 0": the answers still in memory that
  /// the lessons were made from, BZ's own calls apart, and for burns what the lessons did.
  static func evidence(
    _ kind: AutopilotKind, _ verdict: AutopilotVerdict, _ rules: [AutopilotRule],
    _ memory: AutopilotMemory
  ) -> String {
    var asked: [String: AutopilotQuestion] = [:]
    for question in memory.questions where asked[question.id] == nil {
      asked[question.id] = question
    }
    var seen = Set<String>()
    var answers = 0
    var calls = 0
    for rule in rules {
      for id in questionIDs(rule) where seen.insert(id).inserted {
        guard let question = asked[id], question.answer == .yes || question.answer == .no else {
          continue
        }
        if question.answeredBy == "bz" { calls += 1 } else { answers += 1 }
      }
    }
    var text = "From " + AutopilotEval.plural(answers, "answer")
    // "1 of my own calls": one of the calls BZ made, so always plural.
    if calls > 0 { text += " and \(calls) of my own calls" }
    guard verdict == .burn else { return text }
    var done = AutopilotTally()
    for rule in rules {
      guard let tally = memory.tallies[rule.id] else { continue }
      done.count += tally.count
      done.bytes += tally.bytes
      done.undone += tally.undone
    }
    let freed: String = roughly(done.bytes)
    switch kind {
    case .worktree:
      let copies: String = done.count == 1 ? "1 copy" : "\(done.count) copies"
      let burned: String = " · burned " + copies + ", " + freed
      return text + burned + " · undone \(done.undone)"
    case .process:
      let programs: String = AutopilotEval.plural(done.count, "program")
      let stopped: String = " · stopped " + programs + ", " + freed
      return text + stopped + " of memory"
    case .disk:
      let folders: String = AutopilotEval.plural(done.count, "folder")
      return text + " · deleted " + folders + ", " + freed
    }
  }
}
