import Foundation

/// One of the things a question's card is about, as Teach BZ's details show it: a row in the list,
/// the card that comes up when the pointer rests on it, and the page the owner opens. Pure, so a
/// proof can check every word.
public struct AutopilotDetail: Equatable, Sendable, Identifiable {
  /// A few words worth knowing at a glance: "Only on this Mac", "6 unsaved files", "Merged".
  public struct Tag: Equatable, Sendable {
    public var text: String
    /// Risky words stand out, the way a card's cautions do.
    public var risky: Bool
    /// The filter that finds it ("local", "unsaved", "serving", "unchecked"), when one does.
    public var filter: String?
  }
  /// One labeled fact for the hover card and the opened page: "Work" → "Only on this Mac".
  public struct Fact: Equatable, Sendable {
    public var label: String
    public var value: String
    public var risky: Bool
  }
  public var entry: AutopilotEntry
  public var title: String
  /// The project a copy belongs to, or who started a program.
  public var subtitle: String?
  public var size: String
  /// When it was last used, the way its row says it ("yesterday 5 pm", "idle 3 h"); empty when
  /// nobody knows.
  public var when: String
  public var tags: [Tag]
  public var facts: [Fact]
  /// What burning it does, in the owner's words.
  public var consequence: String
  /// The owner keeps it (Spare in Teach BZ, Keep forever in Findings): it stays listed so it can
  /// be unspared, and nothing burns it.
  public var spared: Bool
  public var id: String { entry.id }
  public var item: AutopilotItem { entry.item }
}

/// A way to narrow the details list: everything, one kind of risk, or what the owner spared.
public struct AutopilotDetailFilter: Equatable, Sendable, Identifiable {
  public var id: String
  public var label: String
  public var count: Int
  public var risky: Bool
}

extension AutopilotPolicy {
  /// Everything a question's card is about, biggest first: the unsure things its pattern covers,
  /// which are what a Yes burns, and the ones the owner spared, which stay listed so they can be
  /// unspared. Protected things and things BZ already decided are left out, as they are from the
  /// question, except those in `including`: what the owner spared or unspared on the card stays
  /// in view while it's on screen, whatever BZ makes of it meanwhile.
  public static func details(
    _ question: AutopilotQuestion, entries: [AutopilotEntry], now: Date, calendar: Calendar,
    including: Set<String> = []
  ) -> [AutopilotDetail] {
    let rule = coverage(question.kind, question.match)
    let mine = entries.filter { entry in
      guard matches(rule, entry.item), entry.item.protectedReason == nil else { return false }
      return asked(entry) || isSpared(entry) || including.contains(entry.id)
    }
    let biggest = mine.sorted { a, b in
      a.item.bytes != b.item.bytes ? a.item.bytes > b.item.bytes : a.id < b.id
    }
    return biggest.map { detail($0, now: now, calendar: calendar) }
  }

  /// Kept by the owner: Teach BZ's Spare, Findings' Keep forever and a restore. A lesson's or the
  /// AI's keep is BZ deciding, not the owner sparing it.
  public static func isSpared(_ entry: AutopilotEntry) -> Bool {
    entry.status == .keep && entry.authority == "operator"
  }

  /// Unsure, as a question counts it: a burn that failed last time is shown as failed but is still
  /// BZ's to ask about.
  static func asked(_ entry: AutopilotEntry) -> Bool {
    if entry.status == .unsure { return true }
    return entry.status == .failed && entry.authority == nil && entry.item.protectedReason == nil
  }

  /// The question as its card reads once the owner spared some of what it covers: how many, what it
  /// frees, the counted cautions, the rows and the risks follow what is left, so a Yes covers only
  /// what will burn. Unchanged when nothing on it is spared, unless the owner `changed` something
  /// on the card the engine hasn't counted yet (an Unspare).
  public static func sparing(
    _ question: AutopilotQuestion, details: [AutopilotDetail], changed: Bool = false
  ) -> AutopilotQuestion {
    guard changed || details.contains(where: \.spared) else { return question }
    var drawn = question
    let left: [AutopilotItem] = details.filter { !$0.spared }.map(\.item)
    refresh(&drawn, covering: left)
    return drawn
  }

  /// The filters a details list offers: everything, each kind of risk found in it, then what the
  /// owner spared. Each says how many it shows.
  public static func detailFilters(_ details: [AutopilotDetail]) -> [AutopilotDetailFilter] {
    var filters = [AutopilotDetailFilter(id: "all", label: "All", count: details.count, risky: false)]
    let risks: [(id: String, label: String)] = [
      ("local", "Only on this Mac"), ("unsaved", "Unsaved changes"), ("big", "Big files"),
      ("serving", "Still serving"),
      ("unchecked", "Not checked"), ("failed", "Failed last time"),
    ]
    for risk in risks {
      let count = details.filter { $0.tags.contains { $0.filter == risk.id } }.count
      if count > 0 {
        filters.append(AutopilotDetailFilter(id: risk.id, label: risk.label, count: count, risky: true))
      }
    }
    let spared = details.filter(\.spared).count
    if spared > 0 {
      filters.append(AutopilotDetailFilter(id: "spared", label: "Spared", count: spared, risky: false))
    }
    return filters
  }

  /// What a filter shows; "all" or a filter nobody knows shows everything.
  public static func filtered(_ details: [AutopilotDetail], by filter: String) -> [AutopilotDetail] {
    switch filter {
    case "all": return details
    case "spared": return details.filter(\.spared)
    default:
      let found = details.filter { $0.tags.contains { $0.filter == filter } }
      return found.isEmpty && !details.isEmpty ? details : found
    }
  }

  static func detail(_ entry: AutopilotEntry, now: Date, calendar: Calendar) -> AutopilotDetail {
    let item = entry.item
    let title = String((item.title ?? item.name).prefix(rowTitleLimit))
    var when = ""
    if let used = item.lastUsed { when = timeWords(used, kind: item.kind, now: now, calendar: calendar) }
    var tags = detailTags(item)
    if entry.status == .failed {
      tags.insert(AutopilotDetail.Tag(text: "Failed last time", risky: true, filter: "failed"), at: 0)
    }
    return AutopilotDetail(
      entry: entry, title: title, subtitle: subtitle(of: item), size: roughly(item.bytes), when: when,
      tags: tags, facts: detailFacts(item, now: now, calendar: calendar),
      consequence: consequence(item), spared: isSpared(entry))
  }

  /// A row's few words. Risky ones first; a thing with no risk says what makes it safe.
  static func detailTags(_ item: AutopilotItem) -> [AutopilotDetail.Tag] {
    typealias Tag = AutopilotDetail.Tag
    let f = item.facts
    var tags: [Tag] = []
    switch item.kind {
    case .worktree:
      if f["saved"] == "local" { tags.append(Tag(text: "Only on this Mac", risky: true, filter: "local")) }
      if f["saved"] == "unknown" {
        tags.append(Tag(text: "Saving not checked", risky: true, filter: "unchecked"))
      }
      if f["changes"] == "small" || f["changes"] == "large" {
        tags.append(Tag(text: unsavedWords(item), risky: true, filter: "unsaved"))
      }
      if f["changes"] == "unknown" {
        tags.append(Tag(text: "Changes not checked", risky: true, filter: "unchecked"))
      }
      if f["inUse"] == "unknown" { tags.append(Tag(text: "Use not checked", risky: true, filter: "unchecked")) }
      if AutopilotWorktrees.holdsBigFiles(item) {
        // What a Yes deletes for good: big unsaved files no backup holds.
        let big: UInt64 = (item.bigFiles ?? []).reduce(0) { $0 + $1.bytes }
        let words: String = big > 0 ? roughly(big) + " not backed up" : "Big files not backed up"
        tags.append(Tag(text: words, risky: true, filter: "big"))
      }
      if tags.isEmpty, f["saved"] == "merged" { tags.append(Tag(text: "Merged", risky: false, filter: nil)) }
      if tags.isEmpty, f["saved"] == "pushed" { tags.append(Tag(text: "On GitHub", risky: false, filter: nil)) }
    case .process:
      if f["listening"] == "yes" { tags.append(Tag(text: "Still serving", risky: true, filter: "serving")) }
      if f["listening"] == "unknown" {
        tags.append(Tag(text: "Serving not checked", risky: true, filter: "unchecked"))
      }
      if f["robot"] == "abandoned" {
        tags.append(Tag(text: "Nothing can drive it", risky: false, filter: nil))
      } else if f["orphaned"] == "yes" {
        tags.append(Tag(text: "Its app is gone", risky: false, filter: nil))
      }
    case .disk:
      tags.append(
        f["folder"] == "browser-temp"
          ? Tag(text: "Its browsers are gone", risky: false, filter: nil)
          : Tag(text: "Rebuilds itself", risky: false, filter: nil))
    }
    return tags
  }

  /// "6 unsaved files" when Git said how many, else the size of the bucket.
  static func unsavedWords(_ item: AutopilotItem) -> String {
    if let count = item.unsaved, count > 0 { return "\(count) unsaved " + (count == 1 ? "file" : "files") }
    return item.facts["changes"] == "large" ? "Lots of unsaved changes" : "Unsaved changes"
  }

  /// The labeled facts the hover card and the opened page show, the riskiest worded so they stand
  /// out. Only what BZ knows: an unchecked fact says so.
  static func detailFacts(_ item: AutopilotItem, now: Date, calendar: Calendar) -> [AutopilotDetail.Fact] {
    typealias Fact = AutopilotDetail.Fact
    let f = item.facts
    var used = "Not known"
    if let date = item.lastUsed { used = capitalized(clock(date, now: now, calendar: calendar)) }
    switch item.kind {
    case .worktree:
      let work: Fact
      switch f["saved"] {
      case "merged": work = Fact(label: "Work", value: "Merged", risky: false)
      case "pushed": work = Fact(label: "Work", value: "On GitHub, not merged", risky: false)
      case "local": work = Fact(label: "Work", value: "Only on this Mac", risky: true)
      default: work = Fact(label: "Work", value: "Not checked yet", risky: true)
      }
      let unsaved: Fact
      switch f["changes"] {
      case "none": unsaved = Fact(label: "Unsaved changes", value: "None", risky: false)
      case "small", "large":
        var words = f["changes"] == "large" ? "Lots of files" : "A few files"
        if let count = item.unsaved, count > 0 { words = "\(count) " + (count == 1 ? "file" : "files") }
        unsaved = Fact(label: "Unsaved changes", value: words, risky: true)
      default: unsaved = Fact(label: "Unsaved changes", value: "Not checked yet", risky: true)
      }
      var facts: [Fact] = [
        Fact(label: "Size", value: roughly(item.bytes), risky: false),
        Fact(label: "Last used", value: used, risky: false), work, unsaved,
      ]
      // Each big unsaved file or folder a Yes deletes for good.
      for line in bigFilesLines(item.bigFiles ?? [], now: now, calendar: calendar) {
        facts.append(Fact(label: "Not backed up", value: line, risky: true))
      }
      facts.append(Fact(label: "Branch", value: item.branch ?? "None", risky: false))
      facts.append(Fact(label: "Where", value: placeWords(f["place"]), risky: false))
      return facts
    case .process:
      var idle = "Not known"
      if let date = item.lastUsed { idle = String(idleText(date, now: now).dropFirst("idle ".count)) }
      let serving: Fact
      switch f["listening"] {
      case "yes": serving = Fact(label: "Serving", value: "A web page or port", risky: true)
      case "no": serving = Fact(label: "Serving", value: "Nothing", risky: false)
      default: serving = Fact(label: "Serving", value: "Not checked yet", risky: true)
      }
      var agent = "Not an agent"
      if let who = f["agent"], !["", "none"].contains(who) { agent = who.capitalized }
      return [
        Fact(label: "Memory", value: roughly(item.bytes), risky: false),
        Fact(label: "Idle for", value: idle, risky: false), serving,
        Fact(label: "Started by", value: agent, risky: false),
        Fact(label: "Program", value: f["program"] ?? item.name, risky: false),
        Fact(label: "Its app", value: f["orphaned"] == "yes" ? "Gone" : "Still open", risky: false),
      ]
    case .disk:
      return [
        Fact(label: "Size", value: roughly(item.bytes), risky: false),
        Fact(label: "Last changed", value: used, risky: false),
        Fact(label: "Kind", value: folderWords(f["folder"]), risky: false),
        Fact(label: "Inside", value: homeWords(f["home"]), risky: false),
      ]
    }
  }

  static func placeWords(_ place: String?) -> String {
    switch place {
    case "claude": return "Claude Code worktree"
    case "codex": return "Codex worktree"
    case "patrol6": return "Patrol6 worktree"
    case "conductor": return "Conductor workspace"
    case "sibling": return "Next to its project"
    default: return "Elsewhere on this Mac"
    }
  }

  static func folderWords(_ folder: String?) -> String {
    switch folder {
    case "node_modules": return "node_modules"
    case "build-output": return "Build output"
    case "xcode-derived": return "Xcode DerivedData"
    case "package-cache": return "Package cache"
    case "python-env": return "Python environment"
    case "browser-temp": return "Robot-browser leftovers"
    case .some(let other) where !other.isEmpty && other != "other":
      return capitalized(other.replacingOccurrences(of: "-", with: " "))
    default: return "Folder"
    }
  }

  static func homeWords(_ home: String?) -> String {
    switch home {
    case "stale-worktree": return "An old project copy"
    case "repo": return "A project"
    case "global-cache": return "A shared cache"
    default: return "This Mac"
    }
  }

  static func capitalized(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }
}
