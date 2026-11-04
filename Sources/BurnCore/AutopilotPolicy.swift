import Foundation

/// The autonomy contract. Hard rails are applied before an item reaches the policy
/// (`protectedReason`); everything here decides between burn, keep and asking.
public enum AutopilotPolicy {
  public static let trainingTarget = 12
  public static let aiConfidenceFloor = 0.85
  public static let maximumOpenQuestions = 3
  public static let ownerManagedPlaces: Set<String> = ["codex", "claude", "conductor"]

  /// Safe floor that works before the operator answers anything. Each can be switched off.
  public static let starterRules: [AutopilotRule] = [
    AutopilotRule(
      id: "starter-leftover-programs", kind: .process,
      match: [
        "orphaned": ["yes"], "thread": ["ended", "none"], "idle": ["6h", "1d"],
        "listening": ["no"],
      ], verdict: .burn, source: .starter,
      title: "Leftover programs whose app or chat closed and that sat idle for 6+ hours",
      created: Date(timeIntervalSinceReferenceDate: 0)),
    AutopilotRule(
      id: "starter-finished-copies", kind: .worktree,
      match: [
        "saved": ["merged"], "changes": ["none"], "stale": ["month", "older"], "inUse": ["no"],
        "thread": ["ended", "none"], "place": ["patrol6", "sibling", "other"],
      ], verdict: .burn, source: .starter,
      title: "Old copies already merged, with no changes, untouched for a month",
      created: Date(timeIntervalSinceReferenceDate: 0)),
    AutopilotRule(
      id: "starter-rebuildable-junk", kind: .disk,
      match: [
        "home": ["stale-worktree"], "folder": ["node_modules", "build-output", "xcode-derived"],
      ], verdict: .burn, source: .starter,
      title: "Rebuildable folders inside old copies",
      created: Date(timeIntervalSinceReferenceDate: 0)),
  ]

  public static func matches(_ rule: AutopilotRule, _ item: AutopilotItem) -> Bool {
    rule.kind == item.kind
      && rule.match.allSatisfy { key, values in item.facts[key].map(values.contains) ?? false }
  }

  /// Order: rails, the operator's own keeps, confident AI keeps, operator burn rules,
  /// starter rules, confident AI burns for eligible items. Every keep signal beats every burn.
  public static func decide(_ item: AutopilotItem, memory: AutopilotMemory) -> (
    status: AutopilotStatus, authority: String?
  ) {
    if item.protectedReason != nil { return (.protected, nil) }
    if memory.keptItems.contains(item.id)
      || item.path.map({ memory.keptItems.contains("path:" + $0) }) == true
    {
      return (.keep, "operator")
    }
    let rules = memory.rules.filter { $0.enabled && matches($0, item) }
    if let rule = rules.first(where: { $0.verdict == .keep }) { return (.keep, "rule:" + rule.id) }
    let judgment = memory.judgments[item.id].flatMap {
      $0.revision == item.revision && $0.confidence >= aiConfidenceFloor ? $0 : nil
    }
    if let judgment, judgment.verdict == .keep { return (.keep, ai(judgment)) }
    if let rule = rules.first(where: { $0.verdict == .burn }) { return (.burn, "rule:" + rule.id) }
    if let rule = starterRules.first(where: {
      !memory.starterDisabled.contains($0.id) && matches($0, item)
    }) {
      return (.burn, "starter:" + rule.id)
    }
    if let judgment, judgment.verdict == .burn, aiEligible(item) {
      return (.burn, ai(judgment))
    }
    return (.unsure, nil)
  }

  static func ai(_ judgment: AutopilotJudgment) -> String {
    "ai:" + String(format: "%.2f", judgment.confidence)
  }

  /// Items the AI may burn on its own judgment. Everything else needs an operator rule.
  public static func aiEligible(_ item: AutopilotItem) -> Bool {
    let f = item.facts
    switch item.kind {
    case .process:
      return f["listening"] == "no" && f["thread"] != "live"
        && (f["orphaned"] == "yes" || f["thread"] == "ended")
    case .worktree:
      return !ownerManagedPlaces.contains(f["place"] ?? "") && f["inUse"] == "no"
        && f["thread"] != "live"
    case .disk:
      return (f["folder"] ?? "other") != "other"
    }
  }

  /// What BZ asks about, one question at a time: old copies, each kind of program and each
  /// kind of folder. A question names only its subject and how long things sat unused, so a
  /// yes covers as much as it safely can; what makes some of them riskier is counted on its card.
  static let subjectFacts: [AutopilotKind: String] = [.process: "family", .disk: "folder"]
  /// Every question states how recently things were used, and nothing in use right now is
  /// asked about until it goes quiet.
  static let recencyFacts: [AutopilotKind: String] = [
    .process: "idle", .worktree: "stale", .disk: "stale",
  ]
  static let tooRecent: Set<String> = ["active", "today"]

  /// Below this much disk or memory an item isn't worth the owner's attention or a sweep's
  /// time: it is not shown, asked about, judged or burned.
  public static let worthBytes: UInt64 = 100_000_000
  /// A training question must free at least this much.
  public static let worthAsking: UInt64 = 1_000_000_000

  /// Worth assessing: frees at least `minimumBytes`, or is a program keeping a CPU busy.
  public static func worthAssessing(_ item: AutopilotItem, minimumBytes: UInt64 = worthBytes)
    -> Bool
  {
    item.bytes >= minimumBytes || item.facts["cpu"] == "busy"
  }

  /// How long something sat untouched, named by its lower bound like the idle ages of
  /// programs: `today`, `day` (1+ day), `week` (7+ days), `month` (30+ days) or `older` (90+).
  static func stale(since date: Date, now: Date) -> String {
    switch now.timeIntervalSince(date) / 86_400 {
    case ..<1: return "today"
    case ..<7: return "day"
    case ..<30: return "week"
    case ..<90: return "month"
    default: return "older"
    }
  }

  static func subject(_ kind: AutopilotKind, _ match: [String: [String]]) -> String {
    kind.rawValue + ":" + (subjectFacts[kind].flatMap { match[$0]?.first } ?? "")
  }

  /// What a subject is called: "old project copies", "leftover Node programs".
  static func subjectNoun(_ kind: AutopilotKind, _ match: [String: [String]]) -> String {
    noun(kind, match: subjectFacts[kind].flatMap { key in match[key].map { [key: $0] } } ?? [:]).1
  }

  /// A question holds its subject while it is open, and for a day after the owner skips it.
  static func waits(_ question: AutopilotQuestion, now: Date) -> Bool {
    question.isOpen || (question.answer == .skip && (question.snoozedUntil ?? .distantFuture) > now)
  }

  /// Subjects that get no other question for now, however it would be asked.
  static func busySubjects(_ memory: AutopilotMemory, now: Date) -> Set<String> {
    Set(memory.questions.filter { waits($0, now: now) }.map { subject($0.kind, $0.match) })
  }

  /// Whether a pattern says how long things sat unused and leaves out anything used today or
  /// busy right now: a yes would otherwise cover things still being worked on.
  static func quiet(_ kind: AutopilotKind, _ match: [String: [String]]) -> Bool {
    guard let recency = recencyFacts[kind], let values = match[recency], !values.isEmpty
    else { return false }
    return !values.contains(where: tooRecent.contains)
  }

  /// One yes/no question per subject with enough unsure things to be worth asking, biggest
  /// first. A question covers the most recent use not decided yet and everything older, so one
  /// answer can settle a whole subject; after a no the next question is about older things
  /// only. Never re-asks an answered or open pattern; a skipped subject waits for its snooze.
  public static func proposeQuestions(
    _ unsure: [AutopilotItem], memory: AutopilotMemory, limit: Int = maximumOpenQuestions,
    now: Date = Date()
  ) -> [AutopilotQuestion] {
    let waiting = memory.questions.filter { waits($0, now: now) }
    let excluded = Set(
      memory.questions.filter { $0.answer == .yes || $0.answer == .no }.map(\.id)
        + waiting.map(\.id))
    let slots = limit - memory.questions.filter(\.isOpen).count
    guard slots > 0 else { return [] }
    let busy = busySubjects(memory, now: now)
    // Items an open question already asks about never get a second question.
    let covered = Set(
      memory.questions.filter(\.isOpen).flatMap { open in
        unsure.filter { matches(coverage(open.kind, open.match), $0) }.map(\.id)
      })
    var subjects = [String: [AutopilotItem]]()
    for item in unsure where item.protectedReason == nil && !covered.contains(item.id) {
      guard let recency = recencyFacts[item.kind], let recent = item.facts[recency],
        recent != "unknown", !tooRecent.contains(recent),
        subjectFacts[item.kind].map({ ![nil, "unknown"].contains(item.facts[$0]) }) ?? true
      else { continue }
      subjects[subject(item.kind, item.facts.mapValues { [$0] }), default: []].append(item)
    }
    var candidates = [AutopilotQuestion]()
    for (name, items) in subjects where !busy.contains(name) {
      let kind = items[0].kind
      guard let recency = recencyFacts[kind] else { continue }
      var base = [String: [String]]()
      if let key = subjectFacts[kind], let value = items[0].facts[key] { base[key] = [value] }
      let present = Set(items.compactMap { $0.facts[recency] })
      // The broadest question not asked yet: the most recent use present and everything older.
      guard
        let recent = (safety[recency] ?? []).first(where: { value in
          present.contains(value)
            && !excluded.contains(
              AutopilotRule.key(kind: kind, match: base.merging([recency: [value]]) { a, _ in a }))
        })
      else { continue }
      var match = base
      match[recency] = [recent]
      let covering = items.filter { matches(coverage(kind, match), $0) }
      if covering.reduce(0, { $0 + $1.bytes }) >= worthAsking {
        candidates.append(question(kind, match: match, covering: covering, now: now))
      }
    }
    return Array(
      candidates.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        .prefix(slots))
  }

  /// What a yes to a pattern burns: the pattern and everything safer.
  static func coverage(_ kind: AutopilotKind, _ match: [String: [String]]) -> AutopilotRule {
    AutopilotRule(
      kind: kind, match: widen(match, verdict: .burn), verdict: .burn, source: .operator, title: "")
  }

  /// A question about the things a pattern covers, with their count, size and cautions, and what
  /// its card names about them (`describe`).
  static func question(
    _ kind: AutopilotKind, match: [String: [String]], covering: [AutopilotItem], now: Date
  ) -> AutopilotQuestion {
    let bytes = covering.reduce(0) { $0 + $1.bytes }
    let programs = Set(covering.compactMap { $0.facts["program"] })
    var question = AutopilotQuestion(
      kind: kind, match: match,
      question: wording(
        kind: kind, match: match, program: programs.count == 1 ? programs.first : nil),
      why: "I found \(covering.count) like this, using \(format(bytes))."
        + (kind == .worktree ? " I back each one up first, so you can undo it." : ""),
      examples: Array(covering.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name)),
      count: covering.count, bytes: bytes, asked: now)
    question.cautions = mix(kind, covering)
    describe(&question, covering: covering)
    return question
  }

  /// What makes some of the matches riskier, counted: "2 have work only on this Mac".
  static func mix(_ kind: AutopilotKind, _ items: [AutopilotItem]) -> [String]? {
    func count(_ test: (AutopilotItem) -> Bool, _ one: String, _ many: String) -> String? {
      let n = items.filter(test).count
      return n == 0 ? nil : "\(n) " + (n == 1 ? one : many)
    }
    let found: [String?]
    switch kind {
    case .worktree:
      found = [
        count({ $0.facts["saved"] == "local" }, "has work only on this Mac", "have work only on this Mac"),
        count(
          { ["small", "large"].contains($0.facts["changes"] ?? "") }, "has unsaved changes",
          "have unsaved changes"),
      ]
    case .process:
      found = [
        count(
          { $0.facts["listening"] == "yes" }, "is still running a server",
          "are still running a server")
      ]
    case .disk: found = []
    }
    let cautions = found.compactMap { $0 }
    return cautions.isEmpty ? nil : cautions
  }

  /// Native wording, used until the AI rewrites a question.
  public static func wording(
    kind: AutopilotKind, match: [String: [String]], program: String? = nil
  ) -> String {
    func value(_ key: String) -> String? { match[key]?.first }
    switch kind {
    case .process:
      let family =
        [
          "node": "leftover Node programs", "python": "leftover Python programs",
          "ruby": "leftover Ruby programs", "java": "leftover Java and Gradle helpers",
          "browser": "leftover robot browsers", "build": "leftover build tools",
          "shell": "leftover shell scripts",
        ][value("family") ?? ""] ?? (program.map { "leftover \($0) programs" } ?? "leftover programs")
      var parts = [String]()
      if value("orphaned") == "yes" { parts.append("whose app or chat already closed") }
      if value("thread") == "ended" { parts.append("from chats that already finished") }
      if let idle = value("idle"),
        let text = [
          "10m": "that sat idle for 10+ minutes", "1h": "that sat idle for over an hour",
          "6h": "that sat idle for over 6 hours", "1d": "that sat idle for over a day",
        ][idle]
      {
        parts.append(text)
      }
      if value("listening") == "yes" { parts.append("that are still serving a web page or port") }
      if let agent = value("agent"), agent != "none" {
        parts.append("that \(agent.capitalized) started")
      }
      return "Can I burn " + family + joined(parts) + "?"
    case .worktree:
      var parts = [String]()
      if let place = [
        "patrol6": "made by Patrol6 agents", "codex": "made by Codex", "claude": "made by Claude",
        "conductor": "made by Conductor", "sibling": "next to your main projects",
      ][value("place") ?? ""] {
        parts.append(place)
      }
      if let saved = [
        "merged": "already merged", "pushed": "already on GitHub",
        "local": "with work only on this Mac",
      ][value("saved") ?? ""] {
        parts.append(saved)
      }
      if let changes = value("changes") {
        parts.append(
          changes == "none" ? "with no unsaved changes" : "with unsaved changes")
      }
      if let stale = [
        "day": "untouched since yesterday", "week": "untouched for a week",
        "month": "untouched for a month", "older": "untouched for 3 months",
      ][value("stale") ?? ""] {
        parts.append(stale)
      }
      if value("thread") == "ended" { parts.append("whose chat finished") }
      return "Can I burn old project copies" + (parts.isEmpty ? "" : " " + parts.joined(separator: ", "))
        + "?"
    case .disk:
      let folder =
        [
          "node_modules": "downloaded packages (node_modules)",
          "build-output": "build leftovers", "xcode-derived": "Xcode build leftovers",
          "package-cache": "tool caches", "python-env": "Python environments",
        ][value("folder") ?? ""] ?? "these folders"
      let home =
        [
          "stale-worktree": " inside old copies of your projects",
          "repo": " inside your projects", "global-cache": " on your Mac",
        ][value("home") ?? ""] ?? ""
      let stale =
        [
          "day": " that weren't touched since yesterday",
          "week": " that weren't touched in a week", "month": " that weren't touched in a month",
          "older": " that weren't touched in 3 months",
        ][value("stale") ?? ""] ?? ""
      return "Can I delete " + folder + home + stale + "? They get rebuilt when needed."
    }
  }

  static func joined(_ parts: [String]) -> String {
    switch parts.count {
    case 0: return ""
    case 1: return " " + parts[0]
    default: return " " + parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
  }

  public static func format(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
  }

  /// "If I burn it" in kid-simple language.
  public static func consequence(_ item: AutopilotItem) -> String {
    switch item.kind {
    case .process:
      return
        "It just stops. If something needs it again, a fresh one starts. Nothing you're working on uses it."
    case .worktree:
      return
        "The folder goes away, but nothing is lost: your code is saved and I keep a backup you can restore."
    case .disk:
      return
        "The folder is deleted to free space. Your tools rebuild it automatically next time it's needed."
    }
  }

  public static func trainingProgress(_ memory: AutopilotMemory) -> Double {
    min(1, Double(memory.answers) / Double(trainingTarget))
  }

  /// Share of decidable items BZ resolves on its own (burn or keep) without asking.
  public static func coverage(_ entries: [AutopilotEntry]) -> Double {
    let decidable = entries.filter { [.burn, .keep, .unsure].contains($0.status) }
    guard !decidable.isEmpty else { return 1 }
    return Double(decidable.filter { $0.status != .unsure }.count) / Double(decidable.count)
  }

  /// Fact values ordered from riskiest to safest to burn.
  static let safety: [String: [String]] = [
    "orphaned": ["maybe", "yes"], "thread": ["none", "ended"],
    "idle": ["active", "10m", "1h", "6h", "1d"],
    "stale": ["today", "day", "week", "month", "older"],
    "saved": ["local", "pushed", "merged"], "listening": ["yes", "no"],
    "changes": ["large", "small", "none"],
  ]

  /// An answer also covers strictly safer (yes) or strictly riskier (no) values of the same
  /// facts, so each answer teaches as much as it safely can.
  public static func widen(_ match: [String: [String]], verdict: AutopilotVerdict) -> [String: [
    String
  ]] {
    var result = match
    for (key, values) in match {
      guard let order = safety[key], values.count == 1, let i = order.firstIndex(of: values[0])
      else { continue }
      result[key] = verdict == .burn ? Array(order[i...]) : Array(order[...i])
    }
    return result
  }

  /// Plain-English title for the rule an answer creates.
  /// The same short words as the question's card: "Burn: Old project copies · Saved on GitHub".
  public static func ruleTitle(_ question: AutopilotQuestion, answer: AutopilotAnswer) -> String {
    let plural = noun(question.kind, match: question.match).1
    // A real folder name like node_modules keeps its case.
    let subject =
      plural.split(separator: " ").first?.contains("_") == true
      ? plural : plural.prefix(1).uppercased() + plural.dropFirst()
    return (answer == .yes ? "Burn: " : "Keep: ")
      + ([subject] + facts(question.kind, match: question.match)).joined(separator: " · ")
  }
}

/// A training question as the owner sees it: a short headline with the count, what it frees,
/// a few facts of two to four words and one reassuring line. Less to read than a sentence.
public struct AutopilotCard: Equatable, Sendable {
  public var headline: String
  public var frees: String
  /// What is true of what it covers, in a few words each, with the counted cautions. How long it
  /// sat unused is left out when the headline already says it.
  public var facts: [String]
  public var note: String
  public var yes: String
  public var no: String
  /// The facts that make burning riskier, shown so they stand out.
  public var cautions: [String] = []
  /// What every one of the things shares that is safe, as one sentence.
  public var line: String?
  /// Up to three of the things the question is about, biggest first.
  public var rows: [AutopilotCardRow] = []
  /// How many more there are than the rows show.
  public var more = 0
}

/// One thing a question is about, ready to show: what it is called, where it lives and when it
/// was last used, in words that are right when the card is shown.
public struct AutopilotCardRow: Equatable, Sendable {
  public var title: String
  public var subtitle: String?
  public var when: String
  public init(title: String, subtitle: String? = nil, when: String) {
    self.title = title
    self.subtitle = subtitle
    self.when = when
  }
}

extension AutopilotPolicy {
  static let stalePhrases = [
    "today": "Used in the last day", "day": "Unused since yesterday", "week": "Unused for a week",
    "month": "Unused for a month", "older": "Unused for 3+ months",
  ]

  /// The project a pattern names, when it names exactly one.
  static func pinnedRepo(_ match: [String: [String]]) -> String? {
    guard let repos = match["repo"], repos.count == 1, !["", "none"].contains(repos[0]) else {
      return nil
    }
    return repos[0]
  }

  /// What a card's headline calls the things, singular and plural: "copy" and "copies", or "copy of
  /// api" and "copies of api" when the pattern names one project. Programs and folders keep the
  /// words `noun` gives. The old "old project copies" stays only in rule titles and lessons.
  static func cardNoun(_ kind: AutopilotKind, match: [String: [String]]) -> (String, String) {
    guard kind == .worktree else { return noun(kind, match: match) }
    guard let name = pinnedRepo(match) else { return ("copy", "copies") }
    return ("copy of " + name, "copies of " + name)
  }

  /// What a question is about, singular and plural, naming the project when there is one.
  static func noun(_ kind: AutopilotKind, match: [String: [String]]) -> (String, String) {
    let value = { (key: String) in match[key]?.first ?? "" }
    let project = pinnedRepo(match)
    switch kind {
    case .worktree:
      return project.map { ("old copy of " + $0, "old copies of " + $0) }
        ?? ("old project copy", "old project copies")
    case .process:
      let (one, many) = [
        "node": ("leftover Node program", "leftover Node programs"),
        "python": ("leftover Python program", "leftover Python programs"),
        "ruby": ("leftover Ruby program", "leftover Ruby programs"),
        "java": ("leftover Java helper", "leftover Java helpers"),
        "browser": ("leftover robot browser", "leftover robot browsers"),
        "build": ("leftover build tool", "leftover build tools"),
        "shell": ("leftover script", "leftover scripts"),
      ][value("family")] ?? ("leftover program", "leftover programs")
      return project.map { (one + " in " + $0, many + " in " + $0) } ?? (one, many)
    case .disk:
      return [
        "node_modules": ("node_modules folder", "node_modules folders"),
        "build-output": ("build folder", "build folders"),
        "xcode-derived": ("Xcode build folder", "Xcode build folders"),
        "package-cache": ("tool cache", "tool caches"),
        "python-env": ("Python environment", "Python environments"),
      ][value("folder")] ?? ("folder", "folders")
    }
  }

  /// A pattern's facts in two to four words each, most decisive first.
  static func facts(_ kind: AutopilotKind, match: [String: [String]]) -> [String] {
    let table: [(String, [String: String])]
    switch kind {
    case .worktree:
      table = [
        ("saved", ["merged": "Already merged", "pushed": "Saved on GitHub", "local": "Work only on this Mac"]),
        ("changes", ["none": "No unsaved changes", "small": "Has unsaved changes", "large": "Has unsaved changes"]),
        ("stale", stalePhrases),
        ("place", ["patrol6": "Made by Patrol6 agents", "codex": "Made by Codex", "claude": "Made by Claude", "conductor": "Made by Conductor"]),
        ("thread", ["ended": "Its chat is finished"]),
      ]
    case .process:
      table = [
        ("listening", ["yes": "Still running a server", "no": "Not serving anything"]),
        ("idle", ["active": "Still busy", "10m": "Idle 10+ minutes", "1h": "Idle 1+ hour", "6h": "Idle 6+ hours", "1d": "Idle 1+ day"]),
        ("orphaned", ["yes": "Its app is gone"]),
        ("thread", ["ended": "Its chat is finished"]),
        ("agent", ["codex": "Started by Codex", "claude": "Started by Claude", "cursor": "Started by Cursor"]),
      ]
    case .disk:
      table = [
        ("stale", stalePhrases),
        ("home", ["stale-worktree": "Inside old project copies", "repo": "Inside your projects"]),
      ]
    }
    return table.compactMap { key, words in match[key]?.first.flatMap { words[$0] } }
  }

  /// "14.4 GB" or "300 MB": one decimal is plenty for deciding. Public so a tell card says its size
  /// the way a question card says what it frees.
  public static func roughly(_ bytes: UInt64) -> String {
    bytes >= 1_000_000_000
      ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
  }

  /// Facts that make burning riskier: work that exists nowhere else, things still in use. How
  /// long something sat unused is not one: a card says that in its headline and leaves it out of
  /// its facts, and only a program with no date lists its idle time here.
  static let cautions: Set<String> = [
    "Work only on this Mac", "Has unsaved changes", "Still running a server", "Still busy",
    "Idle 10+ minutes",
  ]

  /// The card for a question as it reads at `now`. The headline is "Burn 5 copies you used
  /// yesterday?": what it covers and when the most recently used of it was used, in calendar words
  /// for `calendar`, so the same question reads differently tomorrow.
  public static func card(
    _ question: AutopilotQuestion, now: Date = Date(), calendar: Calendar = .current
  ) -> AutopilotCard {
    let one = question.count == 1
    let (single, plural) = cardNoun(question.kind, match: question.match)
    let note: String
    switch question.kind {
    case .worktree:
      note = one
        ? "It's backed up first, so you can undo it."
        : "Each one is backed up first, so you can undo it."
    case .process: note = one ? "It just gets asked to quit." : "They just get asked to quit."
    case .disk: note = one ? "Your tools rebuild it when needed." : "Your tools rebuild them when needed."
    }
    let age = when(
      question.kind, newest: question.newest, match: question.match, now: now, calendar: calendar)
    let words: [String] = ["Burn", String(question.count), one ? single : plural, age]
    let headline: String = words.filter { !$0.isEmpty }.joined(separator: " ") + "?"
    // When the headline says how long it sat unused, the facts and cautions don't say it again.
    var described = question.match
    if !age.isEmpty, let recency = recencyFacts[question.kind] { described[recency] = nil }
    let shown = facts(question.kind, match: described)
    let rows = cardRows(question, now: now, calendar: calendar)
    var card = AutopilotCard(
      headline: headline,
      frees: "Frees \(roughly(question.bytes))" + (question.kind == .process ? " of memory" : ""),
      facts: shown + (question.cautions ?? []), note: note,
      yes: one ? "Yes, burn it" : "Yes, burn them", no: one ? "No, keep it" : "No, keep them",
      cautions: shown.filter(cautions.contains) + (question.cautions ?? []))
    card.line = question.line
    card.rows = rows
    card.more = max(0, question.count - rows.count)
    return card
  }
}
