import CryptoKit
import Foundation

/// Autopilot catalogs three kinds of leftovers. Facts are small categorical strings so a
/// rule learned from one yes/no answer matches every later item with the same pattern.
public enum AutopilotKind: String, Codable, Sendable, CaseIterable {
  case process, worktree, disk
}

public enum AutopilotStatus: String, Codable, Sendable, CaseIterable {
  case protected, burn, keep, unsure, burned, failed
}

public enum AutopilotVerdict: String, Codable, Sendable { case burn, keep, unsure }
public enum AutopilotAnswer: String, Codable, Sendable { case yes, no, skip }
public enum AutopilotRuleSource: String, Codable, Sendable { case `operator`, starter }

public struct AutopilotItem: Codable, Sendable, Identifiable, Equatable {
  /// `process:<ProcessIdentity.key>`, `worktree:<WorktreeRecord.id>` or `disk:<sha256(path)>`.
  public var id: String
  public var kind: AutopilotKind
  public var name: String
  /// Native one-line plain description, used until the AI writes a better label.
  public var detail: String
  public var path: String?
  public var bytes: UInt64
  public var facts: [String: String]
  /// AI judgments bind to this; any fact or identity change invalidates them.
  public var revision: String
  public var protectedReason: String?
  public var observedAt: Date
  public var pid: Int32?
  public var processKey: String?
  /// When it was last used, as a question card says it: a copy's last change (or its chat's), a
  /// program's last busy moment (or its start), a folder's last change. Not a fact, so it never
  /// changes `revision`.
  public var lastUsed: Date?
  /// What the owner would call it: the chat or branch a copy was made for. Programs and folders
  /// have none; a card row uses their name ("node in api"). Not a fact either.
  public var title: String?
  public init(
    id: String, kind: AutopilotKind, name: String, detail: String = "", path: String? = nil,
    bytes: UInt64 = 0, facts: [String: String], protectedReason: String? = nil,
    observedAt: Date = Date(), pid: Int32? = nil, processKey: String? = nil,
    lastUsed: Date? = nil, title: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.detail = detail
    self.path = path
    self.bytes = bytes
    var all = facts
    all["kind"] = kind.rawValue
    self.facts = all
    self.protectedReason = protectedReason
    self.observedAt = observedAt
    self.pid = pid
    self.processKey = processKey
    self.lastUsed = lastUsed
    self.title = title
    revision = Self.revision(id: id, facts: all)
  }
  public static func revision(id: String, facts: [String: String]) -> String {
    hash(([id] + facts.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }).joined(
      separator: "|"))
  }
  public static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// A fact pattern: every listed fact must equal one of its allowed values.
public struct AutopilotRule: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var kind: AutopilotKind
  public var match: [String: [String]]
  public var verdict: AutopilotVerdict
  public var source: AutopilotRuleSource
  /// Plain English, for Settings ("Old copies already saved on GitHub").
  public var title: String
  public var enabled: Bool
  public var created: Date
  public var questionID: String?
  /// The other answers an operator lesson was made from, besides `questionID`'s.
  public var from: [String]?
  /// Ids of the lessons it took in, so what they did still counts toward it.
  public var formerIDs: [String]?
  /// Set on a lesson BZ taught itself by acting on its own: the tell it made. Such a lesson never
  /// takes another in nor joins one, so an Undo takes back exactly what BZ did; an owner's answer
  /// may still take it in.
  public var tellID: String?
  public init(
    id: String? = nil, kind: AutopilotKind, match: [String: [String]], verdict: AutopilotVerdict,
    source: AutopilotRuleSource, title: String, enabled: Bool = true, created: Date = Date(),
    questionID: String? = nil
  ) {
    self.kind = kind
    self.match = match
    self.verdict = verdict
    self.source = source
    self.title = title
    self.enabled = enabled
    self.created = created
    self.questionID = questionID
    self.id = id ?? AutopilotRule.key(kind: kind, match: match) + ":" + verdict.rawValue
  }
  public static func key(kind: AutopilotKind, match: [String: [String]]) -> String {
    AutopilotItem.hash(
      ([kind.rawValue] + match.sorted { $0.key < $1.key }.map {
        $0.key + "=" + $0.value.sorted().joined(separator: ",")
      }).joined(separator: "|"))
  }
}

/// The AI's judgment for one exact item revision.
public struct AutopilotJudgment: Codable, Sendable, Equatable {
  public var itemID: String
  public var revision: String
  public var verdict: AutopilotVerdict
  public var confidence: Double
  public var label: String
  public var why: String
  public var date: Date
  public init(
    itemID: String, revision: String, verdict: AutopilotVerdict, confidence: Double,
    label: String, why: String, date: Date = Date()
  ) {
    self.itemID = itemID
    self.revision = revision
    self.verdict = verdict
    self.confidence = confidence
    self.label = label
    self.why = why
    self.date = date
  }
}

public struct AutopilotQuestion: Codable, Sendable, Identifiable, Equatable {
  /// Stable per pattern, so the same question is never asked twice.
  public var id: String
  public var kind: AutopilotKind
  public var match: [String: [String]]
  public var question: String
  public var why: String
  public var examples: [String]
  public var count: Int
  public var bytes: UInt64
  public var asked: Date
  /// `ai` or `native`.
  public var source: String
  public var answer: AutopilotAnswer?
  public var answered: Date?
  public var snoozedUntil: Date?
  /// What makes some of the matches riskier, counted: "2 have work only on this Mac".
  public var cautions: [String]?
  /// The risky facts among the matches, as "fact=value": "saved=local", "changes=small".
  public var risks: [String]?
  /// BZ's guess at the answer, made when the question is created.
  public var guess: AutopilotGuess?
  /// "bz" when BZ answered it on its own; nil when the owner did.
  public var answeredBy: String?
  /// The things it is about, biggest first and at most three: what its card names. Nil on a
  /// question asked before cards named things; the card falls back to `examples`.
  public var rows: [AutopilotQuestionRow]?
  /// When the most recently used of everything it covers was last used.
  public var newest: Date?
  /// One sentence on what all of them share that is safe ("Their work is on GitHub."), worked out
  /// whenever the question is asked or refreshed.
  public var line: String?
  /// What each of the things it is about carries: its risky facts and how long it sat unused, as
  /// sorted "fact=value" lists, one per distinct mix. A No keeps every one of them at the card's
  /// age (R38), and an Undo of BZ's own call does too.
  public var profiles: [[String]]?
  public init(
    kind: AutopilotKind, match: [String: [String]], question: String, why: String,
    examples: [String], count: Int, bytes: UInt64, asked: Date = Date(), source: String = "native"
  ) {
    id = AutopilotRule.key(kind: kind, match: match)
    self.kind = kind
    self.match = match
    self.question = question
    self.why = why
    self.examples = examples
    self.count = count
    self.bytes = bytes
    self.asked = asked
    self.source = source
  }
  public var isOpen: Bool { answer == nil }
}

/// One of the things a question is about, as its card lists it. The time on the card is worked out
/// from `lastUsed` when the card is shown.
public struct AutopilotQuestionRow: Codable, Sendable, Equatable {
  public var title: String
  /// The project a copy belongs to, or who started a program.
  public var subtitle: String?
  public var bytes: UInt64
  public var lastUsed: Date?
  public init(title: String, subtitle: String? = nil, bytes: UInt64, lastUsed: Date? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.bytes = bytes
    self.lastUsed = lastUsed
  }
}

/// BZ's guess at how the owner will answer a question.
public struct AutopilotGuess: Codable, Sendable, Equatable {
  /// `.yes` or `.no`.
  public var answer: AutopilotAnswer
  /// Sure enough to act without asking, when the owner lets BZ act on its own.
  public var sure: Bool
  /// For display: "You said yes to 6 like these."
  public var why: String
  /// `native` or `ai`.
  public var source: String
  public init(answer: AutopilotAnswer, sure: Bool, why: String, source: String = "native") {
    self.answer = answer
    self.sure = sure
    self.why = why
    self.source = source
  }
}

/// A guess checked against the owner's answer. Trust on a subject is earned from these.
public struct AutopilotScore: Codable, Sendable, Equatable {
  public var questionID: String
  /// The question's subject (`AutopilotPolicy.subject`): "worktree:", "process:node".
  public var subject: String
  public var guess: AutopilotAnswer
  public var answer: AutopilotAnswer
  public var right: Bool
  public var date: Date
  /// True when it comes from replaying earlier answers rather than a live guess.
  public var replayed: Bool?
  public init(
    questionID: String, subject: String, guess: AutopilotAnswer, answer: AutopilotAnswer,
    right: Bool, date: Date, replayed: Bool? = nil
  ) {
    self.questionID = questionID
    self.subject = subject
    self.guess = guess
    self.answer = answer
    self.right = right
    self.date = date
    self.replayed = replayed
  }
}

/// What BZ did on its own: a question it was sure the owner would say yes to, answered yes and
/// burned without asking, then shown to the owner with Good call and Undo.
public struct AutopilotTell: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  /// The question BZ answered itself.
  public var questionID: String
  /// The lesson that answer taught, made for this act alone: every burn it authorized is the act's.
  public var ruleID: String
  public var kind: AutopilotKind
  /// What BZ burned, from the act's receipts once its burns are done; until then, what it meant to.
  public var count: Int
  public var bytes: UInt64
  /// What its card names, as on a question card.
  public var rows: [AutopilotQuestionRow]
  /// "You said yes to 6 like these."
  public var why: String
  /// When BZ acted.
  public var date: Date
  /// "open"; "undoing" while an Undo runs; then "good", "undone" or "expired".
  public var state: String
  /// What an Undo couldn't bring back and why, or that a newer answer of the owner's stands.
  public var note: String?
  /// For an Undo that left a note: false until the owner presses OK on it, then true. Nil otherwise.
  public var seen: Bool?
  public init(
    id: String, questionID: String, ruleID: String, kind: AutopilotKind, count: Int,
    bytes: UInt64, rows: [AutopilotQuestionRow], why: String, date: Date,
    state: String = "open", note: String? = nil
  ) {
    self.id = id
    self.questionID = questionID
    self.ruleID = ruleID
    self.kind = kind
    self.count = count
    self.bytes = bytes
    self.rows = rows
    self.why = why
    self.date = date
    self.state = state
    self.note = note
  }
  public var isOpen: Bool { state == "open" }
  /// Called good, undone or expired: nothing more happens to it.
  public var isClosed: Bool { state == "good" || state == "undone" || state == "expired" }
  /// Undone, with a note the owner hasn't pressed OK on yet.
  public var waitsForOK: Bool { state == "undone" && seen == false }
  /// Still something for the owner: open, being undone, or undone with a note to read.
  public var waitsForOwner: Bool { !isClosed || waitsForOK }
}

/// What one lesson has done: the burns it authorized, what they freed, and how many the owner
/// undid. Counted as burns are recorded, because receipts.json keeps only the latest 500.
public struct AutopilotTally: Codable, Sendable, Equatable {
  public var count: Int
  public var bytes: UInt64
  public var undone: Int
  public init(count: Int = 0, bytes: UInt64 = 0, undone: Int = 0) {
    self.count = count
    self.bytes = bytes
    self.undone = undone
  }
  /// Adds what another lesson, or another part of a group, did.
  mutating func add(_ other: AutopilotTally) {
    count += other.count
    bytes += other.bytes
    undone += other.undone
  }
}

/// What Autopilot's cleanups freed. Kept apart from the receipts, which keep only the latest 500,
/// so the totals never go down when old receipts are trimmed.
public struct AutopilotImpact: Codable, Sendable, Equatable {
  public struct Cleanup: Codable, Sendable, Equatable {
    public var receiptID: UUID
    public var date: Date
    public var worktree: Bool
    public var bytes: UInt64
    public init(receiptID: UUID, date: Date, worktree: Bool, bytes: UInt64) {
      self.receiptID = receiptID
      self.date = date
      self.worktree = worktree
      self.bytes = bytes
    }
  }
  /// Old project copies burned, all time.
  public var worktrees = 0
  /// Disk freed by copies and junk folders together, all time.
  public var bytes: UInt64 = 0
  /// Cleanups of the last week, and older ones whose receipt is still kept.
  public var cleanups: [Cleanup] = []
  /// Copies the owner restored, all time. With `worktrees`, every copy Autopilot burned.
  public var restored = 0
  public init() {}
  /// A tally saved before `restored` existed still loads, with nothing restored.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    worktrees = try values.decode(Int.self, forKey: .worktrees)
    bytes = try values.decode(UInt64.self, forKey: .bytes)
    cleanups = try values.decode([Cleanup].self, forKey: .cleanups)
    restored = try values.decodeIfPresent(Int.self, forKey: .restored) ?? 0
  }

  /// Counts burned copies and junk folders not counted yet, and takes restored ones back out;
  /// a restored copy counts as `restored`.
  public mutating func count(_ receipts: [AutopilotReceipt]) {
    var counted = Set(cleanups.map(\.receiptID))
    for r in receipts
    where r.outcome == "burned" && (r.kind == .worktree || r.kind == .disk)
      && !counted.contains(r.id)
    {
      counted.insert(r.id)
      cleanups.append(
        .init(receiptID: r.id, date: r.date, worktree: r.kind == .worktree, bytes: r.bytes))
      worktrees += r.kind == .worktree ? 1 : 0
      bytes += r.bytes
    }
    let restoredIDs = Set(receipts.filter { $0.outcome == "restored" }.map(\.id))
    cleanups.removeAll { cleanup in
      guard restoredIDs.contains(cleanup.receiptID) else { return false }
      worktrees -= cleanup.worktree ? 1 : 0
      restored += cleanup.worktree ? 1 : 0
      bytes -= min(bytes, cleanup.bytes)
      return true
    }
  }

  /// Keeps a week of cleanups for the 7-day total, and every one whose receipt is still kept so
  /// none is counted twice.
  public mutating func prune(keeping receipts: [AutopilotReceipt], now: Date) {
    let kept = Set(receipts.map(\.id))
    cleanups.removeAll {
      now.timeIntervalSince($0.date) >= 8 * 86_400 && !kept.contains($0.receiptID)
    }
  }
}

public struct AutopilotRestore: Codable, Sendable, Equatable {
  /// Git common directory that holds the safety ref.
  public var repository: String
  /// Original worktree path.
  public var path: String
  public var ref: String
  public var head: String
  public var branch: String?
  /// True when the ref is a snapshot commit on top of `head` holding local changes.
  public var snapshot: Bool
  public init(
    repository: String, path: String, ref: String, head: String, branch: String?, snapshot: Bool
  ) {
    self.repository = repository
    self.path = path
    self.ref = ref
    self.head = head
    self.branch = branch
    self.snapshot = snapshot
  }
}

public struct AutopilotReceipt: Codable, Sendable, Identifiable, Equatable {
  public var id: UUID
  public var itemID: String
  public var kind: AutopilotKind
  public var name: String
  /// `rule:<id>`, `starter:<id>`, `ai:<confidence>` or `operator`.
  public var authority: String
  /// `verifying`, `burned`, `refused`, `failed` or `restored`.
  public var outcome: String
  public var detail: String
  public var bytes: UInt64
  public var date: Date
  public var restore: AutopilotRestore?
  /// Process burns are verified by the monitor's cleanup event.
  public var eventID: UUID?
  /// The item revision a refusal saw, so an unchanged item is not retried every tick.
  public var revision: String?
  public init(
    id: UUID = UUID(), itemID: String, kind: AutopilotKind, name: String, authority: String,
    outcome: String, detail: String, bytes: UInt64 = 0, date: Date = Date(),
    restore: AutopilotRestore? = nil, eventID: UUID? = nil
  ) {
    self.id = id
    self.itemID = itemID
    self.kind = kind
    self.name = name
    self.authority = authority
    self.outcome = outcome
    self.detail = detail
    self.bytes = bytes
    self.date = date
    self.restore = restore
    self.eventID = eventID
  }
  public static func refused(_ item: AutopilotItem, authority: String, _ reason: String)
    -> AutopilotReceipt
  {
    var receipt = AutopilotReceipt(
      itemID: item.id, kind: item.kind, name: item.name, authority: authority, outcome: "refused",
      detail: reason)
    receipt.revision = item.revision
    return receipt
  }
}

public struct AutopilotMemory: Codable, Sendable, Equatable {
  /// 2 since lessons (`AutopilotPolicy.migrate`). A decoded file keeps its own version, so memory
  /// saved before lessons is found and migrated once.
  public var version = 2
  /// Operator rules learned from answers.
  public var rules: [AutopilotRule] = []
  public var starterDisabled: Set<String> = []
  /// Items the operator chose to keep forever.
  public var keptItems: Set<String> = []
  public var questions: [AutopilotQuestion] = []
  public var judgments: [String: AutopilotJudgment] = [:]
  /// BZ's guesses checked against the owner's answers, oldest first, at most
  /// `AutopilotPolicy.maximumScores`.
  public var scores: [AutopilotScore] = []
  /// What each lesson has done, by lesson id.
  public var tallies: [String: AutopilotTally] = [:]
  /// What BZ did on its own, oldest first; the open ones wait for Good call or Undo.
  public var tells: [AutopilotTell] = []
  /// Act on its own when sure (Settings → Autopilot). Off, sure questions are asked like any other.
  public var actsOnItsOwn = true
  public init() {}
  /// Memory saved before a field existed still loads. The original fields are required as they
  /// always were; every field added since is decoded with `decodeIfPresent` and falls back to its
  /// default, and fields added later must be decoded here the same way.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    rules = try values.decode([AutopilotRule].self, forKey: .rules)
    starterDisabled = try values.decode(Set<String>.self, forKey: .starterDisabled)
    keptItems = try values.decode(Set<String>.self, forKey: .keptItems)
    questions = try values.decode([AutopilotQuestion].self, forKey: .questions)
    judgments = try values.decode([String: AutopilotJudgment].self, forKey: .judgments)
    scores = try values.decodeIfPresent([AutopilotScore].self, forKey: .scores) ?? []
    tallies = try values.decodeIfPresent([String: AutopilotTally].self, forKey: .tallies) ?? [:]
    tells = try values.decodeIfPresent([AutopilotTell].self, forKey: .tells) ?? []
    actsOnItsOwn = try values.decodeIfPresent(Bool.self, forKey: .actsOnItsOwn) ?? true
  }
  /// The owner's Yes and No answers; BZ's own calls aren't counted.
  public var answers: Int {
    questions.filter { question in
      guard question.answer == .yes || question.answer == .no else { return false }
      return question.answeredBy != "bz"
    }.count
  }
  public var openQuestions: [AutopilotQuestion] { questions.filter(\.isOpen) }
}

public struct AutopilotLogEntry: Codable, Sendable, Identifiable, Equatable {
  public var id = UUID()
  public var date: Date
  public var message: String
  public init(date: Date = Date(), message: String) {
    self.date = date
    self.message = message
  }
}

public struct AutopilotSweepState: Codable, Sendable, Equatable {
  public var enabled = true
  /// Look-only: Autopilot finds, sizes and asks as usual but burns nothing on its own, whatever
  /// a starter rule, an answer or the AI says, until the owner turns burning on.
  public var lookOnly: Bool?
  public var intervalMinutes = 15
  /// The very first tick of this install; it looks every minute for a while after it.
  public var firstTick: Date?
  public var lastTick: Date?
  public var lastAISweep: Date?
  /// Digest of unsure item revisions and rules the AI last judged.
  public var lastAIDigest: String?
  public var failures = 0
  public var retryAfter: Date?
  public var lastError: String?
  public var running = false
  /// Set by "Hunt now" from the CLI or MCP; the coordinator starts an AI sweep next tick.
  public var requested: Bool?
  public var log: [AutopilotLogEntry] = []
  public init() {}
  public mutating func append(_ message: String, date: Date = Date()) {
    log.append(.init(date: date, message: message))
    if log.count > 100 { log.removeFirst(log.count - 100) }
  }
}

/// An item with its current decision, ready for the UI and the MCP catalog.
public struct AutopilotEntry: Codable, Sendable, Identifiable, Equatable {
  public var item: AutopilotItem
  public var status: AutopilotStatus
  public var authority: String?
  /// AI label when available, otherwise the item's name.
  public var label: String
  /// Why BZ decided this: AI reasoning, the matching rule or the protection.
  public var why: String
  /// What happens if BZ burns it.
  public var consequence: String
  public var receipt: AutopilotReceipt?
  /// True when the AI has judged this exact revision.
  public var judged: Bool?
  public var id: String { item.id }
  public init(
    item: AutopilotItem, status: AutopilotStatus, authority: String?, label: String, why: String,
    consequence: String, receipt: AutopilotReceipt? = nil
  ) {
    self.item = item
    self.status = status
    self.authority = authority
    self.label = label
    self.why = why
    self.consequence = consequence
    self.receipt = receipt
  }
}

/// Lessons as Settings shows them: one sentence for a group of lessons, with what they rest on and
/// what they did. Forgetting the group forgets every lesson in `ruleIDs`.
public struct AutopilotLessonGroup: Codable, Sendable, Equatable, Identifiable {
  /// "worktree:burn:day", "worktree:burn:projects", "process:burn", "disk:burn:day", or
  /// "rule:<id>" for a keep.
  public var id: String
  public var kind: AutopilotKind
  public var verdict: AutopilotVerdict
  /// "Copies nobody touched since yesterday are done, even with unsaved work."
  public var sentence: String
  /// "From 11 answers · burned 364 copies, 396.0 GB · undone 0"
  public var evidence: String
  public var ruleIDs: [String]
  public init(
    id: String, kind: AutopilotKind, verdict: AutopilotVerdict, sentence: String,
    evidence: String, ruleIDs: [String]
  ) {
    self.id = id
    self.kind = kind
    self.verdict = verdict
    self.sentence = sentence
    self.evidence = evidence
    self.ruleIDs = ruleIDs
  }
}

/// How I'm doing: plain counts, one sentence each.
public struct AutopilotProgress: Codable, Sendable, Equatable {
  public var lines: [String] = []
  public init(lines: [String] = []) { self.lines = lines }
}

public struct AutopilotSnapshot: Codable, Sendable, Equatable {
  public var entries: [AutopilotEntry] = []
  public var questions: [AutopilotQuestion] = []
  /// Operator rules followed by starter rules with their current switch.
  public var rules: [AutopilotRule] = []
  public var trainingProgress: Double = 0
  public var answers = 0
  /// Share of current items BZ decides without asking.
  public var coverage: Double = 1
  public var counts: [String: Int] = [:]
  public var bytes: [String: UInt64] = [:]
  public var sweep = AutopilotSweepState()
  public var receipts: [AutopilotReceipt] = []
  public var coverageNotes: [String] = []
  public var observedAt: Date?
  /// The owner's lessons as sentences (`AutopilotPolicy.lessonGroups`); starter rules stay in
  /// `rules`.
  public var lessons: [AutopilotLessonGroup] = []
  /// How I'm doing (`AutopilotPolicy.progress`).
  public var progress = AutopilotProgress()
  /// What BZ did on its own that the owner hasn't called good or undone yet, oldest first, with
  /// any Undo still running ("undoing"), so one cut short by a quit can be clicked again, and any
  /// undone one whose note the owner hasn't pressed OK on.
  public var tells: [AutopilotTell] = []
  /// Whether BZ acts on its own when sure (Settings → Autopilot): the owner's setting, not
  /// something it learned.
  public var actsOnItsOwn = true
  public init() {}
  public func count(_ status: AutopilotStatus) -> Int { counts[status.rawValue] ?? 0 }
}

public struct AutopilotCatalog: Codable, Sendable {
  public var observedAt: Date
  public var items: [AutopilotItem]
  public var threads: [AgentThread]
  public var coverageNotes: [String]
  public init(
    observedAt: Date = Date(), items: [AutopilotItem] = [], threads: [AgentThread] = [],
    coverageNotes: [String] = []
  ) {
    self.observedAt = observedAt
    self.items = items
    self.threads = threads
    self.coverageNotes = coverageNotes
  }
}

/// Everything the operator can do from the UI or CLI. The engine applies each command
/// and returns a fresh snapshot.
public enum AutopilotCommand: Codable, Sendable, Equatable {
  case answer(questionID: String, answer: AutopilotAnswer)
  case burnNow(itemID: String)
  case keep(itemID: String)
  case restore(receiptID: UUID)
  case forgetRule(ruleID: String)
  case setStarter(ruleID: String, enabled: Bool)
  case setEnabled(Bool)
  case setLookOnly(Bool)
  case setInterval(minutes: Int)
  case resetTraining
  case sweepNow
  /// The owner agrees with what BZ did on its own: the tell closes and BZ's guess scores right.
  case tellGood(id: String)
  /// The owner undoes what BZ did on its own: copies come back, the lesson becomes a keep and the
  /// guess scores wrong.
  case tellUndo(id: String)
  /// OK on what an Undo left the owner to read: the tell leaves Teach BZ.
  case tellSeen(id: String)
  case setActsOnItsOwn(Bool)
  /// Forgets every lesson of a group, as Settings shows them.
  case forgetLesson(ruleIDs: [String])
}
