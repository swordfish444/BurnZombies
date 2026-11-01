import Foundation

public enum CleanupAction: String, Codable, Sendable {
  case process, ownerStop, worktree, disk, cache
  public var label: String {
    switch self {
    case .process: return "Stop completed helper"
    case .ownerStop: return "Stop when idle"
    case .worktree: return "Archive and retire"
    case .disk: return "Remove regenerable output"
    case .cache: return "Reclaim unused cache"
    }
  }
}

/// A projection of native evidence, never an executor token or safety verdict.
public struct CleanupProposal: Codable, Sendable, Identifiable {
  public var id: String
  public var action: CleanupAction
  public var resources: [String]
  public var revision: String
  public var nativeRevision: String?
  public var notificationReviewOnly: Bool?
  public var notificationEligible: Bool?
  public var title: String
  public var detail: String
  public var path: String?
  public var workflow: String?
  public var workflowDetail: String?
  public var recovery: String
  public var bytes: UInt64
  public var ready: Bool
  public var fixture: Bool
  public var created: Date
  public var observed: Date
  public var state = "review"
  public var approvedRevision: String?
  public var approvedUntil: Date?
  public var snoozedUntil: Date?
  public var operationID: String?
  public init(
    action: CleanupAction, resources: [String], revision: String, title: String,
    detail: String, path: String? = nil, workflow: String? = nil, recovery: String,
    bytes: UInt64 = 0, ready: Bool, fixture: Bool = false, now: Date = Date()
  ) {
    self.action = action
    self.resources = resources.sorted()
    self.revision = revision
    self.id = WorkEvidence.hash(action.rawValue + "|" + self.resources.joined(separator: "|"))
    self.title = title
    self.detail = detail
    self.path = path
    self.workflow = workflow
    self.recovery = recovery
    self.bytes = bytes
    self.ready = ready
    self.fixture = fixture
    self.created = now
    self.observed = now
  }
}

public struct CleanupDecision: Codable, Sendable, Identifiable {
  public var id = UUID().uuidString
  public var proposal: String
  public var revision: String
  public var workflow: String?
  public var decision: String
  public var reason: String
  public var date: Date
  public var fixture: Bool
}

public struct CleanupRule: Codable, Sendable, Identifiable {
  public var id = UUID().uuidString
  public var action: CleanupAction
  public var workflow: String
  public var title: String
  public var maximumPerDay: Int
  public var expires: Date
  public var enabled = true
  public var shadow: Bool?
  public var version = 1
  public var capability = 1
  public var canaryVerified = false
  public var origin = "Explicit operator grant"
}

public struct CleanupReservation: Codable, Sendable, Identifiable {
  public var id: String  // exact native journal operation ID
  public var proposal: String
  public var revision: String
  public var resources: [String]
  public var ruleID: String?
  public var authority: String
  public var date: Date
  public var outcome = "uncertain"
  public var fixture: Bool
  public var workflow: String?
  public var requiresReview: Bool?
}

public struct FindingsSnapshot: Codable, Sendable {
  public var proposals: [CleanupProposal] = []
  public var rules: [CleanupRule] = []
  public var decisions: [CleanupDecision] = []
  public var operations: [CleanupReservation] = []
  public var error: String?
  public var legacyAuthority = false
  public var totalProposals = 0
  public var offset = 0
  public init() {}
}

/// Shared by the monitor and worktree executor. All callers pass through this
/// lock at final dispatch; slow inspection/Keychain work never holds it.
/// Native journals remain the only source of verified outcomes. Missing native
/// history never changes an unresolved reservation to "not dispatched".
public final class IntentLedger: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private let db: WorktreeStore
  private let now: @Sendable () -> Date
  private var recoveryFailure: String?
  private var pendingRecoveryFeedback: [String: RecoveryFeedback] = [:]
  private var lastCompaction: Date?
  private var legacyWorktrees: WorktreeStore?
  public init(
    root: URL, legacyAuthority: Bool = false, now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    self.now = now
    db = try WorktreeStore(root: root, databaseName: "intent.sqlite")
    try db.transaction {
      if try db.value(Bool.self, kind: "setting", id: "legacy-authority") == nil {
        try db.put(legacyAuthority, kind: "setting", id: "legacy-authority")
      }
    }
  }
  /// Called before setup writes any configuration. Only an already functioning
  /// pre-inbox installation can retain its old native policy contract. A newly
  /// written configuration or an empty/corrupt catalog cannot grant authority.
  private struct MigrationReceipt: Codable {
    var version = 1
    var id = UUID().uuidString
    var phase = "pending"
    var legacy: Bool
    var diskRevision: String
    var worktreeRevision: String?
    var ownerWorkflows: Set<String>
  }
  public static func migrate(root: URL) throws -> IntentLedger {
    let store = try Store(root: root)
    let migrationLock = try InstanceLock(
      url: root.appendingPathComponent("intent-migration.lock"), timeout: 5)
    defer { withExtendedLifetime(migrationLock) {} }
    let receiptURL = root.appendingPathComponent("intent-migration.json")
    let dbExists = FileManager.default.fileExists(
      atPath: root.appendingPathComponent("intent.sqlite").path)
    if FileManager.default.fileExists(atPath: receiptURL.path) {
      let receipt = try JSONDecoder().decode(
        MigrationReceipt.self, from: store.read(receiptURL, limit: 131072))
      guard receipt.version == 1, receipt.phase == "pending" || dbExists else {
        throw StoreError.message(
          "Decision database is missing after migration. Preserve the migration receipt and recover the database; cleanup authority cannot be recreated from inventory."
        )
      }
      if receipt.phase == "pending" { return try finishMigration(receipt, root: root) }
      guard receipt.phase == "complete" else {
        throw StoreError.message("Unsupported migration state; preserve authority.")
      }
      let ledger = try IntentLedger(root: root)
      guard
        try ledger.db.value(String.self, kind: "setting", id: "migration-identity") == receipt.id,
        try ledger.db.value(MigrationReceipt.self, kind: "setting", id: "migration-scope")?.id
          == receipt.id
      else {
        throw StoreError.message(
          "Decision ledger does not match its completed migration receipt. Preserve both; cleanup is blocked."
        )
      }
      return ledger
    }
    guard !dbExists else {
      throw StoreError.message(
        "Unlinked decision database found. Preserve it and reconcile migration; no inferred authority."
      )
    }
    let exists = FileManager.default.fileExists(
      atPath: root.appendingPathComponent("catalog.bzcat").path)
    let catalog = try store.load()
    let configured = try MachineReviewConfiguration.load(root: root) != nil
    let legacy = exists && catalog.intentVersion == nil && configured
    let worktrees =
      FileManager.default.fileExists(atPath: root.appendingPathComponent("worktrees.sqlite").path)
      ? try WorktreeStore(root: root).value(WorktreePolicy.self, kind: "policy", id: "current")
      : nil
    let receipt = MigrationReceipt(
      legacy: legacy, diskRevision: try DiskPolicy.load(store).revision,
      worktreeRevision: worktrees?.authorityRevision,
      ownerWorkflows: Set(
        (catalog.ownerDaemons ?? []).compactMap { CleanupProposal.owner($0).workflow }))
    // Persist the era marker first. A crash cannot cause a subsequent run to
    // reinterpret a new installation as a pre-inbox authority grant.
    try store.write(JSONEncoder().encode(receipt), to: receiptURL, limit: 131072)
    var marked = catalog
    marked.intentVersion = 1
    try store.save(marked)
    return try finishMigration(receipt, root: root)
  }
  private static func finishMigration(_ receipt: MigrationReceipt, root: URL) throws -> IntentLedger
  {
    let ledger = try IntentLedger(root: root)
    try ledger.db.transaction {
      if let identity = try ledger.db.value(String.self, kind: "setting", id: "migration-identity"),
        identity != receipt.id
      {
        throw StoreError.message(
          "Migration identity changed; preserve existing authority and journals.")
      }
      try ledger.db.put(receipt.id, kind: "setting", id: "migration-identity")
      try ledger.db.put(receipt.legacy, kind: "setting", id: "legacy-authority")
      try ledger.db.put(receipt, kind: "setting", id: "migration-scope")
    }
    var complete = receipt
    complete.phase = "complete"
    try Store(root: root).write(
      JSONEncoder().encode(complete), to: root.appendingPathComponent("intent-migration.json"),
      limit: 131072)
    return ledger
  }
  public func authorizeNativeWorktreePolicy(_ policy: WorktreePolicy) throws {
    try locked {
      try policy.validate()
      try db.put(policy.authorityRevision, kind: "setting", id: "operator-worktree-policy")
    }
  }
  public func authorizeNativeDiskPolicy(_ policy: DiskPolicy) throws {
    try locked {
      try policy.validate()
      // Called only by the native settings Save/Enable action. The grant is
      // exact and cannot bypass Keep, uncertainty, workflow pauses or caps.
      if policy.mode == "automatic" {
        try db.put(policy.revision, kind: "setting", id: "operator-disk-policy")
      } else {
        try db.remove(kind: "setting", id: "operator-disk-policy")
      }
    }
  }
  private func legacyPermits(_ p: CleanupProposal) throws -> Bool {
    if [.disk, .cache].contains(p.action),
      let revision = try db.value(String.self, kind: "setting", id: "operator-disk-policy"),
      try DiskPolicy.load(Store(root: db.root)).revision == revision
    {
      return true
    }
    if p.action == .worktree,
      let revision = try db.value(String.self, kind: "setting", id: "operator-worktree-policy")
    {
      if legacyWorktrees == nil { legacyWorktrees = try WorktreeStore(root: db.root) }
      if let current = try legacyWorktrees!.value(
        WorktreePolicy.self, kind: "policy", id: "current"), current.authorityRevision == revision,
        let resource = p.resources.first, resource.hasPrefix("worktree:"),
        let row = try legacyWorktrees!.value(
          WorktreeRecord.self, kind: "record", id: String(resource.dropFirst(9))),
        current.automaticRepositories.contains(row.repository)
      {
        return true
      }
    }
    guard try db.value(Bool.self, kind: "setting", id: "legacy-authority") == true else {
      return false
    }
    guard let scope = try db.value(MigrationReceipt.self, kind: "setting", id: "migration-scope")
    else {
      // Direct initializer is an explicit proof capability. Production always
      // enters through migrate, which atomically captures the old scope.
      return !FileManager.default.fileExists(
        atPath: db.root.appendingPathComponent("intent-migration.json").path)
    }
    switch p.action {
    case .ownerStop: return p.workflow.map(scope.ownerWorkflows.contains) ?? false
    case .disk, .cache:
      return try DiskPolicy.load(Store(root: db.root)).revision == scope.diskRevision
    case .worktree:
      if legacyWorktrees == nil { legacyWorktrees = try WorktreeStore(root: db.root) }
      let current = try legacyWorktrees!.value(WorktreePolicy.self, kind: "policy", id: "current")
      return scope.worktreeRevision != nil && current?.authorityRevision == scope.worktreeRevision
    case .process: return true  // Original exact owner-completion contract still enforced by native executor.
    }
  }
  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
  public func snapshot(offset: Int = 0) throws -> FindingsSnapshot {
    try locked {
      if lastCompaction.map({ now().timeIntervalSince($0) >= 86400 }) ?? true {
        try db.compactIntentPresentation(now: now())
        lastCompaction = now()
      }
      var value = FindingsSnapshot()
      value.totalProposals = try db.count(kind: "proposal")
      value.offset = offset
      value.proposals = try db.findingPage(offset: offset)
      value.rules = try db.values(CleanupRule.self, kind: "rule")
      value.decisions = try db.page(
        CleanupDecision.self, kind: "decision", offset: 0, limit: 1000, newest: true)
      value.operations = try db.page(
        CleanupReservation.self, kind: "operation", offset: 0, limit: 1000, newest: true)
      value.legacyAuthority =
        try db.value(Bool.self, kind: "setting", id: "legacy-authority") == true
      if recoveryFailure != nil || FileManager.default.fileExists(atPath: suspensionURL.path) {
        value.error =
          "Recovery feedback could not be saved. Cleanup is suspended; preserve the decision database and inspect its error. Recovery remains available."
      }
      return value
    }
  }
  @discardableResult public func present(_ incoming: CleanupProposal) throws -> CleanupProposal {
    try locked {
      guard !incoming.resources.isEmpty, !incoming.revision.isEmpty, incoming.resources.count <= 64
      else {
        throw StoreError.message("Invalid proposal evidence.")
      }
      var value = incoming
      value.title = String(value.title.prefix(300))
      value.detail = String(value.detail.prefix(4000))
      value.fixture =
        try incoming.fixture || FixtureProvenance.load(root: db.root).matches(value.resources)
      if let old = try db.value(CleanupProposal.self, kind: "proposal", id: value.id) {
        value.fixture = value.fixture || old.fixture
        value.created = old.created
        value.snoozedUntil = old.snoozedUntil
        value.operationID = old.operationID
        if old.revision != value.revision,
          ["verified", "refused", "quarantined"].contains(old.state)
        {
          value.operationID = nil
        }
        if old.state == "kept" || value.operationID != nil {
          value.state = old.state
        } else if old.revision == value.revision && value.ready && old.ready {
          value.state = old.state
          value.approvedRevision = old.approvedRevision
          value.approvedUntil = old.approvedUntil
        }
      }
      // An instance Keep covers every action against the same identity.
      if try kept(value.resources) { value.state = "kept" }
      try db.put(value, kind: "proposal", id: value.id)
      return value
    }
  }
  public func presentMany(_ values: [CleanupProposal]) throws {
    try locked { try db.transaction { for value in values { try present(value) } } }
  }
  private func kept(_ resources: [String]) throws -> Bool {
    try resources.contains { try db.value(Bool.self, kind: "keep", id: $0) == true }
  }
  public func veto(_ resources: [String]) throws {
    try locked {
      guard recoveryFailure == nil, !FileManager.default.fileExists(atPath: suspensionURL.path)
      else {
        throw StoreError.message(
          "Cleanup suspended after a recovery-feedback storage failure. Recovery remains available."
        )
      }
      guard !(try kept(resources)) else {
        throw StoreError.message("Kept by you. Clear Keep in Findings before reconsidering.")
      }
      let active = try db.overlapping(
        CleanupReservation.self, kind: "operation", resources: resources
      ).contains {
        $0.outcome == "uncertain" && !Set($0.resources).isDisjoint(with: resources)
      }
      guard !active else {
        throw StoreError.message(
          "An earlier dispatch is pending or uncertain. No duplicate cleanup.")
      }
    }
  }
  private var suspensionURL: URL { db.root.appendingPathComponent("intent-suspended") }
  public var suspensionReason: String? {
    locked {
      recoveryFailure != nil || FileManager.default.fileExists(atPath: suspensionURL.path)
        ? "Cleanup suspended after recovery-feedback storage failed; recovery remains available."
        : nil
    }
  }
  /// Recovery is never conditional on the preference store working. If feedback
  /// cannot be saved, suspend future cleanup independently of that database.
  private struct RecoveryFeedback: Codable {
    var operationID: String
    var proposal: CleanupProposal?
    var attemptID: String?
  }
  public func reconcileRecoveryFeedback() throws {
    try locked {
      let hasLatch = FileManager.default.fileExists(atPath: suspensionURL.path)
      var entries = Array(pendingRecoveryFeedback.values)
      if hasLatch {
        let data = try Store(root: db.root).read(suspensionURL, limit: 1_048_576)
        let saved = try JSONDecoder().decode([RecoveryFeedback].self, from: data)
        guard !saved.isEmpty else {
          throw StoreError.message("Missing recovery feedback; preserve suspension.")
        }
        entries += saved
      }
      for entry in entries {
        guard
          recordRecovery(
            operationID: entry.operationID, fallback: entry.proposal, attemptID: entry.attemptID)
            == nil
        else {
          throw StoreError.message(
            "Recovery feedback still cannot be saved. Cleanup remains suspended.")
        }
      }
      if hasLatch { try FileManager.default.removeItem(at: suspensionURL) }
      pendingRecoveryFeedback.removeAll()
      recoveryFailure = nil
    }
  }
  public func recordRecovery(
    operationID: String, fallback: CleanupProposal? = nil, attemptID: String? = nil
  ) -> String? {
    locked {
      do {
        let feedbackID = attemptID ?? operationID
        if try db.value(Bool.self, kind: "recovery-feedback", id: feedbackID) == true { return nil }
        let saved = try snapshot()
        let operation =
          try db.value(CleanupReservation.self, kind: "operation", id: operationID)
          ?? db.value(CleanupReservation.self, kind: "operation", id: operationID + ":finish")
        let current =
          try operation.flatMap {
            try db.value(CleanupProposal.self, kind: "proposal", id: $0.proposal)
          } ?? fallback
        if operation != nil || current != nil {
          let workflow = operation?.workflow ?? current?.workflow
          try db.transaction {
            if let workflow {
              try db.put(true, kind: "suspended-workflow", id: workflow)
              try invalidateApprovals(workflow: workflow)
              for var rule in saved.rules where rule.workflow == workflow {
                rule.enabled = false
                rule.version += 1
                try db.put(rule, kind: "rule", id: rule.id)
              }
            } else {
              let resources = operation?.resources ?? current!.resources
              for resource in resources { try db.put(true, kind: "keep", id: resource) }
              for var p in try db.overlapping(
                CleanupProposal.self, kind: "proposal", resources: resources)
              where p.operationID == nil {
                p.state = "kept"
                p.approvedRevision = nil
                p.approvedUntil = nil
                try db.put(p, kind: "proposal", id: p.id)
              }
            }
            let event = CleanupDecision(
              proposal: operation?.proposal ?? current!.id,
              revision: operation?.revision ?? current!.revision, workflow: workflow,
              decision: "needed",
              reason: "Recovery requested; pause affected automation pending review.", date: now(),
              fixture: operation?.fixture ?? current!.fixture)
            try db.put(event, kind: "decision", id: event.id)
            try db.put(true, kind: "recovery-feedback", id: feedbackID)
          }
        } else {
          throw StoreError.message(
            "Recovery ownership evidence unavailable; cleanup remains suspended.")
        }
        return nil
      } catch {
        recoveryFailure = error.localizedDescription
        let entry = RecoveryFeedback(
          operationID: operationID, proposal: fallback, attemptID: attemptID)
        pendingRecoveryFeedback[attemptID ?? operationID] = entry
        do {
          let store = try Store(root: db.root)
          var entries =
            FileManager.default.fileExists(atPath: suspensionURL.path)
            ? try JSONDecoder().decode(
              [RecoveryFeedback].self, from: store.read(suspensionURL, limit: 1_048_576)) : []
          if !entries.contains(where: {
            ($0.attemptID ?? $0.operationID) == (attemptID ?? operationID)
          }) {
            entries.append(entry)
          }
          try store.write(JSONEncoder().encode(entries), to: suspensionURL, limit: 1_048_576)
        } catch { /* Keep the existing latch and the in-memory veto. */  }
        return "Recovery feedback could not be saved; cleanup is suspended."
      }
    }
  }
  /// Only native operator UI/explicit CLI decisions call this. No MCP decision tool.
  public func decide(_ id: String, revision: String, decision: String, reason: String = "") throws {
    try locked {
      guard var p = try db.value(CleanupProposal.self, kind: "proposal", id: id),
        p.revision == revision,
        ["approve", "keep", "clear-keep", "snooze", "needed", "restore-test"].contains(decision),
        reason.count <= 1200
      else { throw StoreError.message("Finding changed. Review its current evidence.") }
      let operations = try db.overlapping(
        CleanupReservation.self, kind: "operation", resources: p.resources)
      if ["keep", "clear-keep", "approve"].contains(decision),
        operations.contains(where: {
          $0.outcome == "uncertain" && !Set($0.resources).isDisjoint(with: p.resources)
        })
      {
        throw StoreError.message(
          "Already dispatched; cancellation cannot be confirmed. See the operation and available recovery."
        )
      }
      try db.transaction {
        if decision == "approve" {
          guard p.ready, p.observed >= now().addingTimeInterval(-300), !(try kept(p.resources)),
            p.operationID == nil
          else {
            throw StoreError.message(
              "Current complete evidence and a fresh unprotected finding are required.")
          }
          p.state = "approved"
          p.approvedRevision = revision
          p.approvedUntil = now().addingTimeInterval(3600)
        } else if decision == "keep" || decision == "clear-keep" {
          for resource in p.resources { try db.put(decision == "keep", kind: "keep", id: resource) }
          p.state = decision == "keep" ? "kept" : "review"
          p.approvedRevision = nil
          p.approvedUntil = nil
          for var other in try db.overlapping(
            CleanupProposal.self, kind: "proposal", resources: p.resources)
          where !Set(other.resources).isDisjoint(with: p.resources) && other.operationID == nil {
            other.state = p.state
            other.approvedRevision = nil
            other.approvedUntil = nil
            try db.put(other, kind: "proposal", id: other.id)
          }
        } else if decision == "snooze" {
          p.snoozedUntil = now().addingTimeInterval(86400)
        } else {
          // A restoration/harm report suspends automation, never fabricates an outcome.
          for var rule in try db.values(CleanupRule.self, kind: "rule")
          where rule.workflow == p.workflow {
            rule.enabled = false
            rule.version += 1
            try db.put(rule, kind: "rule", id: rule.id)
          }
          try invalidateApprovals(workflow: p.workflow)
          if let workflow = p.workflow {
            try db.put(true, kind: "suspended-workflow", id: workflow)
          } else {
            for resource in p.resources { try db.put(true, kind: "keep", id: resource) }
          }
          p.approvedRevision = nil
          p.approvedUntil = nil
          if p.operationID == nil { p.state = "review" }
        }
        try db.put(p, kind: "proposal", id: id)
        let event = CleanupDecision(
          proposal: id, revision: revision, workflow: p.workflow,
          decision: decision, reason: reason, date: now(), fixture: p.fixture)
        try db.put(event, kind: "decision", id: event.id)
      }
    }
  }
  public func grant(
    _ id: String, revision: String, maximumPerDay: Int, expires: Date, shadow: Bool = false
  ) throws -> CleanupRule {
    try locked {
      guard let p = try db.value(CleanupProposal.self, kind: "proposal", id: id),
        p.revision == revision,
        let workflow = p.workflow, !workflow.isEmpty, p.ready,
        [.ownerStop, .worktree].contains(p.action),
        (1...10).contains(maximumPerDay), expires > now(),
        expires <= now().addingTimeInterval(366 * 86400),
        !(try kept(p.resources))
      else {
        throw StoreError.message(
          "A supported exact workflow, explicit cap and expiry are required.")
      }
      let previousOperations = try db.matching(
        CleanupReservation.self, kind: "operation", field: "workflow", value: workflow,
        limit: 100000)
      guard
        !previousOperations.contains(where: {
          $0.outcome == "uncertain" || $0.requiresReview == true
        })
      else {
        throw StoreError.message(
          "Reconcile uncertain workflow operations before granting another rule.")
      }
      var rule = CleanupRule(
        action: p.action, workflow: workflow, title: p.workflowDetail ?? p.title,
        maximumPerDay: maximumPerDay, expires: expires)
      rule.shadow = shadow
      try db.transaction {
        // A replacement is a new explicit grant, not a second allowance bucket.
        for var previous in try db.values(CleanupRule.self, kind: "rule")
        where previous.workflow == workflow && previous.action == p.action {
          previous.enabled = false
          previous.version += 1
          try db.put(previous, kind: "rule", id: previous.id)
        }
        try db.put(rule, kind: "rule", id: rule.id)
        try db.put(false, kind: "suspended-workflow", id: workflow)
        try invalidateApprovals(workflow: workflow)
      }
      return rule
    }
  }
  public func pauseRule(_ id: String) throws {
    try locked {
      guard var rule = try db.value(CleanupRule.self, kind: "rule", id: id) else {
        throw StoreError.message("Unknown rule.")
      }
      try db.transaction {
        rule.enabled = false
        rule.version += 1
        try db.put(rule, kind: "rule", id: id)
        try invalidateApprovals(workflow: rule.workflow)
      }
    }
  }
  private func invalidateApprovals(workflow: String?) throws {
    guard let workflow else { return }
    try db.invalidateApprovals(workflow: workflow)
  }

  private func matchingRule(_ p: CleanupProposal) throws -> CleanupRule? {
    guard let workflow = p.workflow else { return nil }
    let day = Calendar.current.startOfDay(for: now())
    for r in try db.matching(CleanupRule.self, kind: "rule", field: "workflow", value: workflow) {
      guard r.enabled, r.shadow != true, r.capability == 1, r.action == p.action, r.expires > now()
      else { continue }
      let operations = try db.matching(
        CleanupReservation.self, kind: "operation", field: "workflow", value: workflow,
        limit: 100000)
      if !operations.contains(where: { $0.outcome == "uncertain" })
        && operations.filter({ $0.ruleID != nil && $0.date >= day && $0.outcome != "refused" })
          .count < r.maximumPerDay
        && (r.canaryVerified
          || !operations.contains(where: { $0.ruleID == r.id && $0.outcome != "refused" }))
      {
        return r
      }
    }
    return nil
  }
  public func pendingOperationIDs() throws -> Set<String> {
    try locked {
      Set(
        try db.matching(
          CleanupReservation.self, kind: "operation", field: "outcome", value: "uncertain",
          limit: 100000
        ).map(\.id))
    }
  }
  public func proposal(_ id: String) throws -> CleanupProposal? {
    try locked { try db.value(CleanupProposal.self, kind: "proposal", id: id) }
  }
  public func check(_ p: CleanupProposal, legacy: Bool = false) throws {
    try locked {
      try veto(p.resources)
      guard let current = try db.value(CleanupProposal.self, kind: "proposal", id: p.id),
        current.revision == p.revision, current.ready
      else { throw StoreError.message("Current complete proposal evidence required.") }
      if current.approvedRevision == p.revision, let until = current.approvedUntil, until > now() {
        return
      }
      if let workflow = current.workflow,
        try db.value(Bool.self, kind: "suspended-workflow", id: workflow) == true
      {
        throw StoreError.message(
          "Workflow suspended after negative or recovery feedback. Review before granting any new permission."
        )
      }
      if try matchingRule(current) != nil { return }
      if try db.values(CleanupRule.self, kind: "rule").contains(where: {
        $0.action == current.action && $0.workflow == current.workflow
      }) {
        throw StoreError.message(
          "Workflow rule is paused, expired, awaiting its canary or at its cap. No legacy fallback."
        )
      }
      // A migration records only the existing native authority contract. The
      // caller must still prove every original policy/owner predicate afresh.
      if legacy, try legacyPermits(current) { return }
      throw StoreError.message(
        "Approval required. Review this finding in BurnZombies; nothing was removed.")
    }
  }
  /// The irreversible dispatch boundary. Native intent must already be durable.
  /// A reservation is an uncertainty barrier, not a claim of execution/success.
  public func reserve(_ p: CleanupProposal, operationID: String, legacy: Bool = false) throws {
    try locked {
      try db.transaction {
        guard try db.value(CleanupReservation.self, kind: "operation", id: operationID) == nil
        else {
          throw StoreError.message("Operation already reserved; replay refused.")
        }
        try check(p, legacy: legacy)
        var current = try db.value(CleanupProposal.self, kind: "proposal", id: p.id)!
        let approved =
          current.approvedRevision == current.revision
          && (current.approvedUntil ?? .distantPast) > now()
        let rule = approved ? nil : try matchingRule(current)
        let receipt = CleanupReservation(
          id: operationID, proposal: p.id, revision: p.revision,
          resources: p.resources, ruleID: rule?.id,
          authority: approved
            ? "Explicit approval once"
            : rule.map { "Rule \($0.id) version \($0.version)" }
              ?? "Migrated native policy; unchanged guards",
          date: now(), fixture: p.fixture, workflow: p.workflow)
        try db.put(receipt, kind: "operation", id: operationID)
        current.operationID = operationID
        current.state = "pending verification"
        current.approvedRevision = nil
        current.approvedUntil = nil
        try db.put(current, kind: "proposal", id: current.id)
      }
    }
  }
  public func project(operationID: String, outcome: String) throws {
    try locked {
      guard ["verified", "refused", "uncertain", "quarantined", "reconciled"].contains(outcome),
        var op = try db.value(CleanupReservation.self, kind: "operation", id: operationID)
      else { return }
      if op.outcome == outcome && (outcome != "uncertain" || op.requiresReview == true) { return }
      if outcome == "uncertain", op.outcome != "uncertain" { return }
      guard
        op.outcome == "uncertain"
          || (op.outcome == "quarantined" && ["verified", "reconciled"].contains(outcome))
      else {
        throw StoreError.message("Conflicting native receipt; preserve operation history.")
      }
      try db.transaction {
        if outcome == "uncertain" {
          op.requiresReview = true
          if let workflow = op.workflow {
            try db.put(true, kind: "suspended-workflow", id: workflow)
            try invalidateApprovals(workflow: workflow)
            for var rule in try db.values(CleanupRule.self, kind: "rule")
            where rule.workflow == workflow {
              rule.enabled = false
              rule.version += 1
              try db.put(rule, kind: "rule", id: rule.id)
            }
          }
        }
        if outcome != "uncertain" { op.requiresReview = false }
        op.outcome = outcome
        try db.put(op, kind: "operation", id: op.id)
        if var p = try db.value(CleanupProposal.self, kind: "proposal", id: op.proposal),
          p.operationID == op.id
        {
          p.state = outcome == "uncertain" ? "pending verification" : outcome
          if outcome == "refused" {
            p.operationID = nil
            p.state = try kept(p.resources) ? "kept" : "review"
          }
          try db.put(p, kind: "proposal", id: p.id)
        }
        if outcome == "verified", let id = op.ruleID,
          var rule = try db.value(CleanupRule.self, kind: "rule", id: id)
        {
          rule.canaryVerified = true
          try db.put(rule, kind: "rule", id: id)
        }
      }
    }
  }
  public func revokeApproval(_ id: String, revision: String) throws {
    try locked {
      guard var p = try proposal(id), p.revision == revision else { return }
      p.approvedRevision = nil
      p.approvedUntil = nil
      if p.operationID == nil && p.state == "approved" { p.state = "review" }
      try db.put(p, kind: "proposal", id: p.id)
    }
  }
  public func history(workflow: String) throws -> [CleanupDecision] {
    try locked {
      try db.matching(
        CleanupDecision.self, kind: "decision", field: "workflow", value: workflow, limit: 100000
      ).filter { !$0.fixture }
    }
  }
  public func forget(workflow: String) throws {
    try locked {
      try db.transaction {
        // Forget revokes authority first. Recovery and idempotence records remain.
        try db.put(true, kind: "suspended-workflow", id: workflow)
        try invalidateApprovals(workflow: workflow)
        for var rule in try db.matching(
          CleanupRule.self, kind: "rule", field: "workflow", value: workflow)
        {
          rule.enabled = false
          rule.version += 1
          try db.put(rule, kind: "rule", id: rule.id)
        }
        for decision in try db.matching(
          CleanupDecision.self, kind: "decision", field: "workflow", value: workflow, limit: 100000)
        {
          try db.remove(kind: "decision", id: decision.id)
        }
      }
    }
  }
  public func openProcessFindings() throws -> [CleanupProposal] {
    try locked { try db.openProposals(action: .process) }
  }
  public func resolveMissingProcesses(presentResources: Set<String>) throws {
    try locked {
      try db.transaction {
        for action: CleanupAction in [.process, .ownerStop] {
          for var p in try db.openProposals(action: action)
          where p.operationID == nil && p.state != "kept"
            && !Set(p.resources).isSubset(of: presentResources)
          {
            p.state = "absent"
            p.ready = false
            p.approvedRevision = nil
            p.approvedUntil = nil
            try db.put(p, kind: "proposal", id: p.id)
          }
        }
      }
    }
  }
  public func resolveAbsent(actions: Set<CleanupAction>, present: Set<String>) throws {
    try locked {
      try db.transaction {
        for action in actions {
          for var p in try db.openProposals(action: action)
          where !present.contains(p.id) && p.operationID == nil && p.state != "kept" {
            p.state = "absent"
            p.ready = false
            p.approvedRevision = nil
            p.approvedUntil = nil
            try db.put(p, kind: "proposal", id: p.id)
          }
        }
      }
    }
  }
  public func notificationCandidate(now date: Date = Date(), budget: Int = 3) throws
    -> CleanupProposal?
  {
    try locked {
      let delivered = try db.values(Date.self, kind: "delivery")
      var eligible: [CleanupProposal] = []
      for var p in try db.notificationProposals(now: date) {
        if try matchingRule(p) != nil { continue }
        if let workflow = p.workflow {
          p.notificationReviewOnly =
            try db.value(Bool.self, kind: "suspended-workflow", id: workflow) == true
        }
        eligible.append(p)
      }
      if !eligible.isEmpty, try db.value(Bool.self, kind: "setting", id: "digest-submitted") != true
      {
        var digest = eligible[0]
        digest.id = "digest"
        digest.revision = "first"
        digest.title = "\(eligible.count) findings ready for review"
        digest.detail =
          "Your private inbox contains the evidence, scope and recovery options. Nothing is approved by this notification."
        return digest
      }
      if let latest = delivered.max(), date.timeIntervalSince(latest) < 3600 { return nil }
      guard
        delivered.filter({ Calendar.current.isDate($0, inSameDayAs: date) }).count
          < max(1, min(5, budget))
      else { return nil }
      return eligible.sorted { $0.created < $1.created }.first {
        !$0.fixture && $0.ready && $0.state == "review" && ($0.snoozedUntil ?? .distantPast) <= date
          && (try? db.value(Bool.self, kind: "notification-sent", id: $0.id + ":" + $0.revision))
            != true
          && $0.observed >= date.addingTimeInterval(-300)
      }
    }
  }
  public func delivered(_ p: CleanupProposal) throws {
    try locked {
      try db.put(now(), kind: "delivery", id: p.id + ":" + p.revision)
      try db.put(true, kind: "notification-sent", id: p.id + ":" + p.revision)
      if p.id == "digest" { try db.put(true, kind: "setting", id: "digest-submitted") }
    }
  }
}
