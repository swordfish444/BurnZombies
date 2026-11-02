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
  public init(
    id: String, kind: AutopilotKind, name: String, detail: String = "", path: String? = nil,
    bytes: UInt64 = 0, facts: [String: String], protectedReason: String? = nil,
    observedAt: Date = Date(), pid: Int32? = nil, processKey: String? = nil
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
    .init(
      itemID: item.id, kind: item.kind, name: item.name, authority: authority, outcome: "refused",
      detail: reason)
  }
}

public struct AutopilotMemory: Codable, Sendable, Equatable {
  public var version = 1
  /// Operator rules learned from answers.
  public var rules: [AutopilotRule] = []
  public var starterDisabled: Set<String> = []
  /// Items the operator chose to keep forever.
  public var keptItems: Set<String> = []
  public var questions: [AutopilotQuestion] = []
  public var judgments: [String: AutopilotJudgment] = [:]
  public init() {}
  public var answers: Int { questions.filter { $0.answer == .yes || $0.answer == .no }.count }
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
  public var intervalMinutes = 15
  public var lastTick: Date?
  public var lastAISweep: Date?
  /// Digest of unsure item revisions and rules the AI last judged.
  public var lastAIDigest: String?
  public var failures = 0
  public var retryAfter: Date?
  public var lastError: String?
  public var running = false
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
