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

  /// Facts a training question may be about, and the ones every question must include.
  public static let questionFacts: [AutopilotKind: [String]] = [
    .process: ["family", "orphaned", "thread", "agent", "idle", "listening"],
    .worktree: ["place", "saved", "changes", "stale", "thread"],
    .disk: ["folder", "home", "stale"],
  ]
  static let primaryFacts: [AutopilotKind: String] = [
    .process: "family", .worktree: "saved", .disk: "folder",
  ]
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

  /// Turns the largest clusters of unsure items into yes/no questions about a fact pattern.
  /// Never re-asks an answered pattern, an open one, or one skipped until its snooze ends.
  public static func proposeQuestions(
    _ unsure: [AutopilotItem], memory: AutopilotMemory, limit: Int = maximumOpenQuestions,
    now: Date = Date()
  ) -> [AutopilotQuestion] {
    let open = memory.questions.filter {
      $0.isOpen || $0.answer == .yes || $0.answer == .no
        || ($0.answer == .skip && ($0.snoozedUntil ?? .distantFuture) > now)
    }
    let excluded = Set(open.map(\.id))
    let slots = limit - memory.questions.filter(\.isOpen).count
    guard slots > 0 else { return [] }
    struct Cluster {
      var kind: AutopilotKind
      var match: [String: [String]]
      var items: [AutopilotItem] = []
      var bytes: UInt64 = 0
    }
    var clusters = [String: Cluster]()
    for item in unsure where item.protectedReason == nil {
      guard let primary = primaryFacts[item.kind], let primaryValue = item.facts[primary],
        primaryValue != "unknown", let recency = recencyFacts[item.kind],
        let recent = item.facts[recency], recent != "unknown", !tooRecent.contains(recent)
      else { continue }
      let others = (questionFacts[item.kind] ?? []).filter {
        $0 != primary && $0 != recency && item.facts[$0] != nil && item.facts[$0] != "unknown"
      }
      var subsets = [[String]()] + others.map { [$0] }
      for i in others.indices {
        for j in others.indices where j > i { subsets.append([others[i], others[j]]) }
      }
      for subset in subsets {
        var match = [primary: [primaryValue], recency: [recent]]
        for key in subset { match[key] = [item.facts[key]!] }
        let id = AutopilotRule.key(kind: item.kind, match: match)
        guard !excluded.contains(id) else { continue }
        clusters[id, default: Cluster(kind: item.kind, match: match)].items.append(item)
        clusters[id]!.bytes += item.bytes
      }
    }
    // Questions go where the space is, and a pattern freeing little isn't worth one. Equal
    // space: prefer patterns the wording can actually describe, then broader ones.
    func clarity(_ c: Cluster) -> Int { min(2, describable(kind: c.kind, match: c.match)) }
    let ranked = clusters.filter { $0.value.bytes >= worthAsking }.sorted {
      $0.value.bytes != $1.value.bytes
        ? $0.value.bytes > $1.value.bytes
        : clarity($0.value) != clarity($1.value)
          ? clarity($0.value) > clarity($1.value)
          : $0.value.match.count != $1.value.match.count
            ? $0.value.match.count < $1.value.match.count : $0.key < $1.key
    }
    var picked = [Cluster]()
    // Items an open question already asks about never get a second question.
    var covered = Set<String>()
    for open in memory.questions where open.isOpen {
      let rule = AutopilotRule(
        kind: open.kind, match: open.match, verdict: .burn, source: .operator, title: "")
      covered.formUnion(unsure.filter { matches(rule, $0) }.map(\.id))
    }
    func take(_ cluster: Cluster) -> Bool {
      let ids = Set(cluster.items.map(\.id))
      guard picked.count < slots,
        Double(ids.intersection(covered).count) < Double(ids.count) * 0.5
      else { return false }
      picked.append(cluster)
      covered.formUnion(ids)
      return true
    }
    // The best question for each kind first, so programs and junk aren't drowned out by
    // a large pile of old copies; then the rest by value.
    let openKinds = Set(memory.questions.filter(\.isOpen).map(\.kind))
    for kind in AutopilotKind.allCases where !openKinds.contains(kind) {
      if let best = ranked.first(where: { $0.value.kind == kind }) { _ = take(best.value) }
    }
    for (_, cluster) in ranked { _ = take(cluster) }
    return picked.map { cluster in
      let programs = Set(cluster.items.compactMap { $0.facts["program"] })
      let text = wording(
        kind: cluster.kind, match: cluster.match,
        program: programs.count == 1 ? programs.first : nil)
      return AutopilotQuestion(
        kind: cluster.kind, match: cluster.match, question: text,
        why: "I found \(cluster.items.count) like this, using \(format(cluster.bytes))."
          + (cluster.kind == .worktree ? " I back each one up first, so you can undo it." : ""),
        examples: Array(
          cluster.items.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name)),
        count: cluster.items.count, bytes: cluster.bytes, asked: now)
    }
  }

  /// How many of a pattern's secondary facts the native wording puts into words.
  static func describable(kind: AutopilotKind, match: [String: [String]]) -> Int {
    let value = { (key: String) in match[key]?.first }
    switch kind {
    case .process:
      return [
        value("orphaned") == "yes", value("thread") == "ended",
        ["10m", "1h", "6h", "1d"].contains(value("idle") ?? ""), value("listening") == "yes",
        (value("agent") ?? "none") != "none",
      ].filter { $0 }.count
    case .worktree:
      return ["place", "changes", "stale", "thread"].filter {
        guard let v = value($0) else { return false }
        return !["other", "none", "today", "unknown"].contains(v) || $0 == "changes"
      }.count
    case .disk:
      return ["home", "stale"].filter { value($0) != nil && value($0) != "today" }.count
    }
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
  public static func ruleTitle(_ question: AutopilotQuestion, answer: AutopilotAnswer) -> String {
    let core = question.question.replacingOccurrences(of: "Can I burn ", with: "")
      .replacingOccurrences(of: "Can I delete ", with: "")
      .replacingOccurrences(of: "? They get rebuilt when needed.", with: "")
      .replacingOccurrences(of: "?", with: "")
    let first = core.prefix(1).uppercased() + core.dropFirst()
    return (answer == .yes ? "Burn: " : "Keep: ") + first
  }
}
