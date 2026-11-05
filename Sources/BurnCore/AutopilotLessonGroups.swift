import Foundation

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
    // A No to a card asked again for new risks teaches a keep per risk, so that it doesn't cancel
    // an earlier Yes; those keeps read and are forgotten as one.
    var keeps: [[AutopilotRule]] = []
    for rule in lessons where rule.verdict != .burn {
      let sibling: Int? = rule.questionID.flatMap { id in
        keeps.firstIndex { $0.first?.questionID == id }
      }
      if let sibling { keeps[sibling].append(rule) } else { keeps.append([rule]) }
    }
    for members in keeps { groups.append(keepGroup(members, memory)) }
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
    // Large changes are unsaved work; a lesson that stops at small ones says so.
    if rules.contains(where: { covers($0, "changes", any: ["large"]) }) {
      risks.append("unsaved work")
    } else if rules.contains(where: { covers($0, "changes", any: ["small"]) }) {
      risks.append("a few unsaved changes")
    }
    if rules.contains(where: { covers($0, "saved", any: ["local"]) }) {
      risks.append("work only on this Mac")
    }
    let unchecked = rules.contains { rule in
      covers(rule, "saved", any: ["unknown"]) || covers(rule, "changes", any: ["unknown"])
    }
    if unchecked { risks.append("work I couldn't check") }
    // Each kind of big unsaved files is covered only where a lesson names it.
    for risk in AutopilotWorktrees.bigFileRisks {
      if rules.contains(where: { $0.match[risk.fact]?.contains("yes") == true }) {
        risks.append(risk.words)
      }
    }
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
  /// One keep, or the keeps one No taught, as one sentence: what each keeps is listed together.
  static func keepGroup(_ rules: [AutopilotRule], _ memory: AutopilotMemory)
    -> AutopilotLessonGroup
  {
    var shown: AutopilotRule = rules[0]
    for other in rules.dropFirst() {
      for (fact, values) in other.match where shown.match[fact] == nil {
        shown.match[fact] = values
      }
    }
    let sentence = shown.kind == .process ? programKeep(shown) : keepSentence(shown)
    return group("rule:" + rules[0].id, shown.kind, shown.verdict, sentence, rules, memory)
  }

  /// "Java helpers serving a port stay while idle less than an hour."
  static func programKeep(_ rule: AutopilotRule) -> String {
    let families = rule.match["family"] ?? []
    var subject = "Programs"
    if families.count == 1 {
      subject = keptProgramNames[families[0]] ?? otherPrograms(families[0])
    }
    subject += serving(rule.match["listening"])
    guard let below = idleCeiling(rule) else { return subject + " stay." }
    return subject + " stay while idle less than " + below + "."
  }

  /// Which programs a keep holds by what they serve: " serving a port", " whose port couldn't be
  /// checked", both joined with "or", or nothing when it holds them whatever they serve.
  static func serving(_ values: [String]?) -> String {
    guard let values else { return "" }
    let known: Set<String> = Set(values.filter { $0 != "unknown" })
    if known == ["yes", "no"] { return "" }
    var parts: [String] = []
    if known == ["yes"] { parts.append("serving a port") }
    if known == ["no"] { parts.append("serving nothing") }
    if values.contains("unknown") { parts.append("whose port couldn't be checked") }
    return parts.isEmpty ? "" : " " + parts.joined(separator: " or ")
  }

  /// The idle floor just above everything a keep covers: "an hour" for active and 10m.
  static func idleCeiling(_ rule: AutopilotRule) -> String? {
    guard let values = rule.match["idle"], let order = safety["idle"],
      let top = order.lastIndex(where: values.contains), top + 1 < order.count
    else { return nil }
    return idleBelow[order[top + 1]]
  }

  /// "Copies used in the last week stay: Work only on this Mac, Has unsaved changes." Every value
  /// each fact keeps is named, so a keep narrowed to some risks never reads as keeping everything.
  static func keepSentence(_ rule: AutopilotRule) -> String {
    var subject: String = keptSubject(rule)
    if let bound = keptBound(rule) { subject += " " + bound }
    // How recently they were used is the bound's to say, so it isn't listed again as a fact.
    var listed = rule.match
    if let recency = recencyFacts[rule.kind] { listed[recency] = nil }
    let shown: [String] = lessonFacts(rule.kind, match: listed)
    guard !shown.isEmpty else { return subject + " stay." }
    return subject + " stay: " + shown.joined(separator: ", ") + "."
  }

  /// "Copies", "Copies of api", "node_modules folders", "Tool caches".
  static func keptSubject(_ rule: AutopilotRule) -> String {
    if rule.kind == .worktree {
      let repos: [String] = rule.match["repo"] ?? []
      guard repos.count == 1, !["", "none"].contains(repos[0]) else { return "Copies" }
      return "Copies of " + repos[0]
    }
    let plural: String = noun(rule.kind, match: rule.match).1
    // A real folder name like node_modules keeps its case.
    if plural.split(separator: " ").first?.contains("_") == true { return plural }
    let first: String = plural.prefix(1).uppercased()
    let rest: String = String(plural.dropFirst())
    return first + rest
  }

  /// How recently the copies or folders a keep covers were used: up to the bucket after the most
  /// recent age it keeps. nil when it keeps every age.
  static let keptRecently: [String: String] = [
    "today": "used in the last day", "day": "used in the last week",
    "week": "used in the last month", "month": "used in the last 3 months",
  ]

  static func keptBound(_ rule: AutopilotRule) -> String? {
    guard let fact = recencyFacts[rule.kind], let values = rule.match[fact],
      let order = safety[fact], let oldest = order.last(where: values.contains)
    else { return nil }
    return keptRecently[oldest]
  }

  static func group(
    _ id: String, _ kind: AutopilotKind, _ verdict: AutopilotVerdict, _ sentence: String,
    _ rules: [AutopilotRule], _ memory: AutopilotMemory
  ) -> AutopilotLessonGroup {
    AutopilotLessonGroup(
      id: id, kind: kind, verdict: verdict, sentence: sentence,
      evidence: evidence(kind, verdict, rules, memory), ruleIDs: rules.map(\.id))
  }

  /// The owner's lessons as the AI reads them in the catalog (spec 2.6): one per group Settings
  /// shows, with the same sentence, the lessons' ids and exact matches, the owner's answers behind
  /// them and what they did.
  public static func catalogLessons(_ memory: AutopilotMemory) -> [AutopilotCatalogLesson] {
    var byID: [String: AutopilotRule] = [:]
    for rule in memory.rules where byID[rule.id] == nil { byID[rule.id] = rule }
    return lessonGroups(memory).map { group in
      let rules: [AutopilotRule] = group.ruleIDs.compactMap { byID[$0] }
      let behind = answers(behind: rules, memory)
      let done: AutopilotTally = tallied(rules, memory)
      return AutopilotCatalogLesson(
        ids: group.ruleIDs, sentence: group.sentence, kind: group.kind, verdict: group.verdict,
        matches: rules.map(\.match), answers: behind.owner, burned: done.count,
        bytes: done.bytes, undone: done.undone)
    }
  }

  /// The answers still in memory that lessons were made from: the owner's, and BZ's own calls.
  static func answers(behind rules: [AutopilotRule], _ memory: AutopilotMemory) -> (
    owner: Int, calls: Int
  ) {
    let asked = questionsByID(memory.questions)
    var seen = Set<String>()
    var owner = 0
    var calls = 0
    for rule in rules {
      for id in questionIDs(rule) where seen.insert(id).inserted {
        guard let question = asked[id], question.answer == .yes || question.answer == .no else {
          continue
        }
        if question.answeredBy == "bz" { calls += 1 } else { owner += 1 }
      }
    }
    return (owner, calls)
  }

  /// What lessons did together: burns, what they freed and how many were undone.
  static func tallied(_ rules: [AutopilotRule], _ memory: AutopilotMemory) -> AutopilotTally {
    var done = AutopilotTally()
    for rule in rules {
      if let tally = memory.tallies[rule.id] { done.add(tally) }
    }
    return done
  }

  /// "From 11 answers · burned 364 copies, 396.0 GB · undone 0": the answers still in memory that
  /// the lessons were made from, BZ's own calls apart, and for burns what the lessons did. A lesson
  /// made only from BZ's own calls reads "From my own call" or "From 3 of my own calls", never
  /// "From 0 answers and …".
  static func evidence(
    _ kind: AutopilotKind, _ verdict: AutopilotVerdict, _ rules: [AutopilotRule],
    _ memory: AutopilotMemory
  ) -> String {
    let behind = answers(behind: rules, memory)
    var text = "From " + AutopilotEval.plural(behind.owner, "answer")
    if behind.owner == 0 && behind.calls > 0 {
      text = behind.calls == 1 ? "From my own call" : "From \(behind.calls) of my own calls"
    } else if behind.calls > 0 {
      // "1 of my own calls": one of the calls BZ made, so always plural.
      text += " and \(behind.calls) of my own calls"
    }
    guard verdict == .burn else { return text }
    let done: AutopilotTally = tallied(rules, memory)
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
