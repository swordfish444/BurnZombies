import Foundation

/// The words on a question card: which things a question is about, when they were last used, and
/// what is safe about them. A question stores what it needs (`rows`, `newest`, `risks`, `line`) when
/// it is asked or refreshed; the day and time words are worked out when the card is shown, so
/// "yesterday" is right whenever the owner looks. They are built from calendar components and never
/// from locale formatters, so they read the same on every Mac.
extension AutopilotPolicy {
  static let weekdayNames = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  ]
  static let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ]
  /// Rows show a title on one line, so one much longer is only kept in part.
  static let rowTitleLimit = 100

  // MARK: What a question stores

  /// A question worked out again for the things it covers now: how many, what they free, the
  /// biggest, the counted cautions and what its card names. The engine's refresh and Teach BZ's
  /// Spare both use it, so a card never says anything the engine wouldn't.
  public static func refresh(_ question: inout AutopilotQuestion, covering items: [AutopilotItem]) {
    question.count = items.count
    question.bytes = items.reduce(0) { $0 + $1.bytes }
    let biggest: [AutopilotItem] = items.sorted { $0.bytes > $1.bytes }
    question.examples = Array(biggest.prefix(3).map(\.name))
    question.cautions = mix(question.kind, items)
    describe(&question, covering: items)
  }

  /// What a card names about the things a question covers, kept with the question: the three
  /// biggest, the most recent use among all of them, the risks among them and the safe line.
  /// When any of them has no date the most recent use is unknown, and the card falls back to the
  /// age its question is about.
  static func describe(_ question: inout AutopilotQuestion, covering items: [AutopilotItem]) {
    question.rows = rows(of: items)
    let used = items.compactMap(\.lastUsed)
    question.newest = used.count == items.count ? used.max() : nil
    question.started = question.kind == .process ? youngestStart(items) : nil
    question.risks = risks(question.kind, items)
    question.profiles = profiles(question.kind, items)
    question.line = safeLine(question.kind, items)
    // What a Yes deletes in all, rows the card shows or not.
    var big: UInt64 = 0
    for item in items { big += (item.bigFiles ?? []).reduce(0) { $0 + $1.bytes } }
    question.bigBytes = big > 0 ? big : nil
    if question.source == "native" { question.why = nativeWhy(question, covering: items) }
  }

  /// When the program that started last started, so "running for" holds for every one of them.
  /// Nil when any of them has no start, or there are none.
  static func youngestStart(_ items: [AutopilotItem]) -> Date? {
    let starts: [Date] = items.compactMap(\.started)
    guard !items.isEmpty, starts.count == items.count else { return nil }
    return starts.max()
  }

  /// BZ's own words on why it asks: "I found 3 like this, using 2.8 GB. I back each one up first,
  /// so you can undo it." A copy's big unsaved files can't be backed up, so then it says so.
  static func nativeWhy(_ question: AutopilotQuestion, covering items: [AutopilotItem]) -> String {
    let bytes: UInt64 = items.reduce(0) { $0 + $1.bytes }
    let found: String = "I found \(items.count) like this, using \(format(bytes))."
    guard question.kind == .worktree else { return found }
    guard bigFilesCost(question) != nil else {
      return found + " I back each one up first, so you can undo it."
    }
    return found + " I back each one up first, except its big unsaved files, which a Yes deletes for good."
  }

  /// Each thing's risky facts, of the kinds a lesson keeps within (`riskFacts`), and how long it sat
  /// unused, as sorted "fact=value" lists: one per distinct mix, in a fixed order.
  static func profiles(_ kind: AutopilotKind, _ items: [AutopilotItem]) -> [[String]] {
    let checked: [String] = (riskFacts[kind] ?? []).map(\.fact)
    var found = Set<[String]>()
    for item in items where item.kind == kind {
      var profile: [String] = []
      for fact in checked {
        guard let value = item.facts[fact], risky(fact, value) else { continue }
        profile.append(fact + "=" + value)
      }
      if let recency = recencyFacts[kind], let value = item.facts[recency] {
        profile.append(recency + "=" + value)
      }
      found.insert(profile.sorted())
    }
    return found.sorted { $0.joined(separator: ",") < $1.joined(separator: ",") }
  }

  /// The three biggest, biggest first, with ties kept in a fixed order. Copies with big unsaved
  /// files come first, each with its files, so the card names what a Yes deletes.
  static func rows(of items: [AutopilotItem]) -> [AutopilotQuestionRow] {
    let biggest = items.sorted { a, b in
      let first: Bool = AutopilotWorktrees.holdsBigFiles(a)
      let second: Bool = AutopilotWorktrees.holdsBigFiles(b)
      if first != second { return first }
      return a.bytes != b.bytes ? a.bytes > b.bytes : a.id < b.id
    }
    return biggest.prefix(3).map { item in
      let title: String = item.title ?? item.name
      var row = AutopilotQuestionRow(
        title: String(title.prefix(rowTitleLimit)), subtitle: subtitle(of: item),
        bytes: item.bytes, lastUsed: item.lastUsed)
      row.bigFiles = item.bigFiles
      return row
    }
  }

  /// Who started a program, or the project a copy belongs to. A folder says nothing more: its
  /// name already carries its project ("node_modules in api").
  static func subtitle(of item: AutopilotItem) -> String? {
    switch item.kind {
    case .process:
      guard let agent = item.facts["agent"], !["", "none"].contains(agent) else { return nil }
      return "started by " + agent.capitalized
    case .worktree:
      guard let repo = item.facts["repo"], !["", "none"].contains(repo) else { return nil }
      return repo
    case .disk:
      return nil
    }
  }

  /// One sentence on what every one of the things shares that is safe, from their own facts and
  /// not from the pattern, which holds only the subject and how long they sat unused. Only what
  /// is true of all of them is said. Folders say nothing: their card already says tools rebuild
  /// them. Docker's build cache has no other words on its card, so it says so here.
  public static func safeLine(_ kind: AutopilotKind, _ items: [AutopilotItem]) -> String? {
    guard !items.isEmpty else { return nil }
    let one = items.count == 1
    func all(_ fact: String, _ values: Set<String>) -> Bool {
      items.allSatisfy { values.contains($0.facts[fact] ?? "") }
    }
    var sentences = [String]()
    switch kind {
    case .worktree:
      if all("saved", ["pushed", "merged"]) {
        sentences.append(one ? "Its work is on GitHub." : "Their work is on GitHub.")
      }
      if all("changes", ["none"]) {
        sentences.append(one ? "Nothing in it is unsaved." : "Nothing is unsaved.")
      }
      if all("thread", ["ended"]) {
        sentences.append(one ? "Its chat is finished." : "Their chats are finished.")
      }
    case .process:
      if all("listening", ["no"]) {
        sentences.append(one ? "It isn't serving anything." : "None is serving anything.")
      }
      if all("orphaned", ["yes"]) {
        sentences.append(one ? "Its app is gone." : "Their apps are gone.")
      }
    case .disk:
      if items.allSatisfy(AutopilotDockerCache.isCache) {
        sentences.append(AutopilotDockerCache.safeLine)
      }
    }
    return sentences.isEmpty ? nil : sentences.joined(separator: " ")
  }

  /// A branch as the task it was for: the text after the last slash, with `-` and `_` as spaces.
  /// "codex/fix-login-selector" is "fix login selector"; nil when nothing is left.
  public static func humanize(branch: String) -> String? {
    let parts: [Substring] = branch.split(separator: "/", omittingEmptySubsequences: false)
    let last: Substring = parts.last ?? ""
    let spaces: Set<Character> = ["-", "_", " "]
    let words: [Substring] = last.split(whereSeparator: { spaces.contains($0) })
    return words.isEmpty ? nil : words.joined(separator: " ")
  }

  // MARK: What a card says

  /// The headline's last words: when the most recently used of the things was used.
  /// - Copies and folders, by calendar days: "you used today", "you used yesterday", "untouched
  ///   since Monday" (2 to 6 days), "untouched for a week", "untouched for 2 weeks", "untouched for a
  ///   month", "untouched for 2 months", "untouched for 3+ months".
  /// - Programs: "idle for 40 minutes", "idle for an hour", "idle for 3 hours" (under 48 hours),
  ///   "idle for 2 days". A card uses these only when it has no start for them (`runningWords`).
  /// Without a date, the age the question is about in the same voice, lowercased: "unused since
  /// yesterday", "used in the last day". Programs have no such age, so they say nothing.
  public static func when(
    _ kind: AutopilotKind, newest: Date?, match: [String: [String]], now: Date, calendar: Calendar
  ) -> String {
    guard let newest else { return ageWords(match) }
    switch kind {
    case .process:
      return "idle for " + idleLength(now.timeIntervalSince(newest))
    case .worktree, .disk:
      return unusedWords(newest, now: now, calendar: gregorian(calendar))
    }
  }

  /// A program headline's last words when BZ knows when they started: how long the one that started
  /// last has been running, "running for 40 minutes", "running for 23 hours", "running for 2
  /// days". Their idle time starts over each time one wakes, so this is what grows while a card
  /// waits.
  public static func runningWords(since started: Date, now: Date) -> String {
    "running for " + idleLength(now.timeIntervalSince(started))
  }

  /// When a copy or folder last changed, for the right side of a row: "today 9 am", "yesterday
  /// 5 pm", "Mon 5 pm" (2 to 6 days), then the day alone, "Oct 12", with the year when it isn't
  /// this one, "Oct 12, 2025". Hours are on a 12-hour clock with no minutes.
  public static func clock(_ date: Date, now: Date, calendar: Calendar) -> String {
    let calendar = gregorian(calendar)
    let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour], from: date)
    let hour: String = hourWords(parts.hour ?? 0)
    switch daysBetween(date, now, calendar: calendar) {
    case 0: return "today " + hour
    case 1: return "yesterday " + hour
    case 2..<7:
      let weekday: Int = parts.weekday ?? 1
      let name: String = weekdayNames[(weekday - 1 + 7) % 7]
      return String(name.prefix(3)) + " " + hour
    default:
      let number: Int = parts.month ?? 1
      let month: String = monthNames[(number - 1 + 12) % 12]
      let day: String = month + " " + String(parts.day ?? 1)
      guard let year = parts.year, year != calendar.component(.year, from: now) else { return day }
      return day + ", " + String(year)
    }
  }

  /// A program's idle time for the right side of a row: "idle 40 min", "idle 3 h", "idle 2 d".
  public static func idleText(_ date: Date, now: Date) -> String {
    let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
    switch minutes {
    case 0: return "idle <1 min"
    case 1..<60: return "idle \(minutes) min"
    case 60..<2880: return "idle \(minutes / 60) h"
    default: return "idle \(minutes / 1440) d"
    }
  }

  // MARK: Pieces

  /// The most recent age a pattern covers, in the voice of the headline: "unused since yesterday".
  static func ageWords(_ match: [String: [String]]) -> String {
    let values = match["stale"] ?? []
    let ages = safety["stale"] ?? []
    guard let age = ages.first(where: { values.contains($0) }), let phrase = stalePhrases[age]
    else { return "" }
    return phrase.lowercased()
  }

  static func unusedWords(_ newest: Date, now: Date, calendar: Calendar) -> String {
    let days = daysBetween(newest, now, calendar: calendar)
    switch days {
    case 0: return "you used today"
    case 1: return "you used yesterday"
    case 2..<7:
      let weekday = calendar.component(.weekday, from: newest)
      return "untouched since " + weekdayNames[(weekday - 1 + 7) % 7]
    case 7..<14: return "untouched for a week"
    case 14..<30: return "untouched for \(days / 7) weeks"
    case 30..<60: return "untouched for a month"
    case 60..<90: return "untouched for 2 months"
    default: return "untouched for 3+ months"
    }
  }

  /// "under a minute", "a minute", "40 minutes", "an hour", "3 hours" (under 48 hours), "2 days".
  static func idleLength(_ seconds: TimeInterval) -> String {
    let minutes = Int(max(0, seconds) / 60)
    switch minutes {
    case 0: return "under a minute"
    case 1: return "a minute"
    case 2..<60: return "\(minutes) minutes"
    case 60..<120: return "an hour"
    case 120..<2880: return "\(minutes / 60) hours"
    default: return "\(minutes / 1440) days"
    }
  }

  /// "9 am", "12 pm", "5 pm", "12 am" for the hour after midnight.
  static func hourWords(_ hour: Int) -> String {
    let twelve: Int = hour % 12 == 0 ? 12 : hour % 12
    let suffix: String = hour < 12 ? " am" : " pm"
    return String(twelve) + suffix
  }

  /// Whole calendar days from the day `date` fell on to the day `now` falls on, never below zero.
  /// Days, not hours: 10 past midnight is today and ten to midnight the day before is yesterday.
  static func daysBetween(_ date: Date, _ now: Date, calendar: Calendar) -> Int {
    let from = calendar.startOfDay(for: date)
    let to = calendar.startOfDay(for: now)
    return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
  }

  /// The words are English and Gregorian, so a Mac that prefers another calendar still gets
  /// "Oct 12, 2025" and not another calendar's month or year. Its time zone is kept.
  static func gregorian(_ calendar: Calendar) -> Calendar {
    guard calendar.identifier != .gregorian else { return calendar }
    var result = Calendar(identifier: .gregorian)
    result.timeZone = calendar.timeZone
    return result
  }

  /// The right side of a row: a program's idle time, or when a copy or folder last changed.
  static func timeWords(
    _ date: Date, kind: AutopilotKind, now: Date, calendar: Calendar
  ) -> String {
    kind == .process ? idleText(date, now: now) : clock(date, now: now, calendar: calendar)
  }

  /// A card's rows: the stored rows with their times worked out for `now`, or, for a question
  /// asked before cards named things, its example names with no time.
  static func cardRows(
    _ question: AutopilotQuestion, now: Date, calendar: Calendar
  ) -> [AutopilotCardRow] {
    guard let stored = question.rows, !stored.isEmpty else {
      return question.examples.map { AutopilotCardRow(title: $0, subtitle: nil, when: "") }
    }
    return cardRows(stored, kind: question.kind, now: now, calendar: calendar)
  }

  /// Rows a question or a tell stores, ready to show: each with its time worked out for `now`
  /// (`timeWords`), and none for a row with no date. Public so a tell card words its rows exactly
  /// as a question card does.
  public static func cardRows(
    _ stored: [AutopilotQuestionRow], kind: AutopilotKind, now: Date, calendar: Calendar
  ) -> [AutopilotCardRow] {
    stored.map { (row: AutopilotQuestionRow) -> AutopilotCardRow in
      var when = ""
      if let used = row.lastUsed {
        when = timeWords(used, kind: kind, now: now, calendar: calendar)
      }
      let details: [String] = bigFilesLines(row.bigFiles ?? [], now: now, calendar: calendar)
      return AutopilotCardRow(
        title: row.title, subtitle: row.subtitle, when: when, details: details)
    }
  }
}
