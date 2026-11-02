import Foundation

/// Where Autopilot gets items and how it burns them. `live` wires the monitor and the
/// three executors; proofs inject fixtures.
public struct AutopilotSources: Sendable {
  public var threads: @Sendable () -> [AgentThread]
  public var processes: @Sendable ([AgentThread]) async -> [AutopilotItem]
  public var worktreeRecords: @Sendable () async -> [WorktreeRecord]
  public var worktrees:
    @Sendable ([WorktreeRecord], [AgentThread], [String: AutopilotDelivery]) -> (
      [AutopilotItem], [String: AutopilotDelivery]
    )
  public var disk: @Sendable ([WorktreeRecord]) -> [AutopilotItem]
  public var burnProcess: @Sendable (AutopilotItem, String, String) async throws -> UUID
  public var processOutcome: @Sendable (UUID) async -> (outcome: String, detail: String)?
  public var retireWorktree: @Sendable (AutopilotItem, String) -> AutopilotReceipt
  public var restoreWorktree: @Sendable (AutopilotReceipt) throws -> Void
  public var reclaimDisk: @Sendable (AutopilotItem, String) -> AutopilotReceipt
  public var inspect: @Sendable (AutopilotItem) -> [String: String]
  public var coverageNotes: @Sendable () -> [String]
  public init(
    threads: @escaping @Sendable () -> [AgentThread] = { [] },
    processes: @escaping @Sendable ([AgentThread]) async -> [AutopilotItem] = { _ in [] },
    worktreeRecords: @escaping @Sendable () async -> [WorktreeRecord] = { [] },
    worktrees: @escaping @Sendable ([WorktreeRecord], [AgentThread], [String: AutopilotDelivery])
      -> ([AutopilotItem], [String: AutopilotDelivery]) = { _, _, d in ([], d) },
    disk: @escaping @Sendable ([WorktreeRecord]) -> [AutopilotItem] = { _ in [] },
    burnProcess: @escaping @Sendable (AutopilotItem, String, String) async throws -> UUID = {
      _, _, _ in throw StoreError.message("Process cleanup is unavailable.")
    },
    processOutcome: @escaping @Sendable (UUID) async -> (outcome: String, detail: String)? = { _ in
      nil
    },
    retireWorktree: @escaping @Sendable (AutopilotItem, String) -> AutopilotReceipt = {
      .refused($0, authority: $1, "Old-copy cleanup is unavailable.")
    },
    restoreWorktree: @escaping @Sendable (AutopilotReceipt) throws -> Void = { _ in
      throw StoreError.message("Restore is unavailable.")
    },
    reclaimDisk: @escaping @Sendable (AutopilotItem, String) -> AutopilotReceipt = {
      .refused($0, authority: $1, "Junk-folder cleanup is unavailable.")
    },
    inspect: @escaping @Sendable (AutopilotItem) -> [String: String] = { _ in [:] },
    coverageNotes: @escaping @Sendable () -> [String] = { [] }
  ) {
    self.threads = threads
    self.processes = processes
    self.worktreeRecords = worktreeRecords
    self.worktrees = worktrees
    self.disk = disk
    self.burnProcess = burnProcess
    self.processOutcome = processOutcome
    self.retireWorktree = retireWorktree
    self.restoreWorktree = restoreWorktree
    self.reclaimDisk = reclaimDisk
    self.inspect = inspect
    self.coverageNotes = coverageNotes
  }
}

/// What the AI reads per item: compact, without UI-only text.
public struct AutopilotCatalogItem: Codable, Sendable {
  public var id: String
  public var kind: AutopilotKind
  public var name: String
  public var detail: String
  public var size: String
  public var facts: [String: String]
  public var status: AutopilotStatus
  public var authority: String?
  public var label: String?
  public var why: String?
}

public struct AutopilotCatalogPage: Codable, Sendable {
  public var summary: [String: String]
  public var rules: [AutopilotRule]
  public var openQuestions: [AutopilotQuestion]
  public var answered: [AutopilotQuestion]
  public var items: [AutopilotCatalogItem]
  public var nextOffset: Int?
}

/// Native autopilot: catalog, decide, burn what is authorized, keep questions current.
public actor Autopilot {
  /// Per tick, so a wrong fact can never sweep the whole Mac in one pass.
  public static let maximumBurns: [AutopilotKind: Int] = [.process: 50, .worktree: 20, .disk: 20]
  /// An item refused for unchanged facts is tried again after this long.
  public static let retryRefusalsAfter: TimeInterval = 6 * 3600
  let store: AutopilotStore
  let sources: AutopilotSources
  /// Items freeing less are not part of the assessment; fixtures with tiny files lower it.
  let minimumBytes: UInt64
  var catalog: AutopilotCatalog?
  var delivery: [String: AutopilotDelivery] = [:]
  var burning = Set<String>()
  var ticking = false

  public init(
    root: URL = Store.defaultRoot, sources: AutopilotSources,
    minimumBytes: UInt64 = AutopilotPolicy.worthBytes
  ) throws {
    store = try AutopilotStore(root: root)
    self.sources = sources
    self.minimumBytes = minimumBytes
    catalog = try? store.catalog()
  }

  /// Refresh the catalog and burn everything already authorized. Uses no AI.
  @discardableResult public func tick(now: Date = Date(), burn: Bool = true) async
    -> AutopilotSnapshot
  {
    // A long burn pass must not overlap the next tick; the caller gets the current view.
    guard !ticking else { return snapshot(now: now) }
    ticking = true
    defer { ticking = false }
    try? store.updateSweep { $0.lastTick = now }
    let threads = sources.threads()
    let records = await sources.worktreeRecords()
    var items = await sources.processes(threads)
    let (copies, cache) = sources.worktrees(records, threads, delivery)
    delivery = cache
    items += copies.filter { $0.path.map { FileManager.default.fileExists(atPath: $0) } ?? true }
      .map { Self.mentionChat($0, threads: threads, now: now) }
    items += sources.disk(records)
    items = items.filter { AutopilotPolicy.worthAssessing($0, minimumBytes: minimumBytes) }
    catalog = AutopilotCatalog(
      observedAt: now, items: items, threads: threads, coverageNotes: sources.coverageNotes())
    try? store.save(catalog: catalog!)
    await refreshReceipts()
    if burn, (try? store.sweep().enabled) ?? true { await burnAuthorized(now: now) }
    refreshQuestions(now: now)
    return snapshot(now: now)
  }

  func memory() -> AutopilotMemory { (try? store.memory()) ?? AutopilotMemory() }

  /// People remember chats by name: mention the last chat that worked in an old copy.
  static func mentionChat(_ item: AutopilotItem, threads: [AgentThread], now: Date)
    -> AutopilotItem
  {
    guard let path = item.path else { return item }
    let root = path.hasSuffix("/") ? path : path + "/"
    guard
      let chat = threads.filter({ ($0.cwd == path || $0.cwd.hasPrefix(root)) && $0.title != nil })
        .max(by: { $0.lastActive < $1.lastActive }), let title = chat.title
    else { return item }
    var copy = item
    let when = RelativeDateTimeFormatter().localizedString(for: chat.lastActive, relativeTo: now)
    copy.detail += " Last used in the chat “\(title.prefix(60))” \(when)."
    return copy
  }

  /// Items stopping right now, or burned since the catalog was built. The next tick drops
  /// them; until then nothing tries them again.
  func spent(_ receipts: [AutopilotReceipt]) -> Set<String> {
    let observed = catalog?.observedAt ?? .distantPast
    return Set(
      receipts.filter {
        $0.outcome == "verifying" || ($0.outcome == "burned" && $0.date >= observed)
      }.map(\.itemID))
  }

  /// Burns every item the policy authorizes now, bounded per kind.
  func burnAuthorized(now: Date) async {
    guard let items = catalog?.items else { return }
    let memory = memory()
    let receipts = (try? store.receipts()) ?? []
    let spent = spent(receipts)
    // A refusal stands for the facts and authority it saw until either changes or a while
    // passes.
    let refused = Set(
      receipts.filter {
        $0.outcome == "refused" && now.timeIntervalSince($0.date) < Self.retryRefusalsAfter
      }.compactMap { r in r.revision.map { [r.itemID, $0, r.authority].joined(separator: "@") } })
    var used = [AutopilotKind: Int]()
    for item in items where !spent.contains(item.id) && !burning.contains(item.id) {
      let decision = AutopilotPolicy.decide(item, memory: memory)
      guard decision.status == .burn, let authority = decision.authority,
        !refused.contains([item.id, item.revision, authority].joined(separator: "@")),
        used[item.kind, default: 0] < Self.maximumBurns[item.kind, default: 0]
      else { continue }
      // Only burns count toward the bound; a refusal frees nothing.
      let receipt = await execute(item, authority: authority, why: why(item, decision, memory))
      if receipt.outcome != "refused" { used[item.kind, default: 0] += 1 }
    }
  }

  func execute(_ item: AutopilotItem, authority: String, why: String) async -> AutopilotReceipt {
    burning.insert(item.id)
    defer { burning.remove(item.id) }
    let sources = sources
    var receipt: AutopilotReceipt
    switch item.kind {
    case .process:
      do {
        let event = try await sources.burnProcess(item, authority, why)
        receipt = AutopilotReceipt(
          itemID: item.id, kind: .process, name: item.name, authority: authority,
          outcome: "verifying", detail: "Asked it to stop; checking that it did.", bytes: item.bytes,
          eventID: event)
      } catch {
        receipt = .refused(item, authority: authority, error.localizedDescription)
      }
    case .worktree:
      receipt = await Task.detached { sources.retireWorktree(item, authority) }.value
    case .disk:
      receipt = await Task.detached { sources.reclaimDisk(item, authority) }.value
    }
    try? store.append(receipt)
    let verb = receipt.outcome == "refused" ? "Skipped" : "Burned"
    try? store.updateSweep {
      $0.append(
        "\(verb) \(item.name)" + (receipt.outcome == "refused" ? ": \(receipt.detail)" : "."))
    }
    return receipt
  }

  /// Process receipts finish when the monitor verifies the exit.
  func refreshReceipts() async {
    guard let receipts = try? store.receipts() else { return }
    var updates = [UUID: (String, String)]()
    for receipt in receipts where receipt.outcome == "verifying" {
      guard let event = receipt.eventID, let result = await sources.processOutcome(event) else {
        continue
      }
      switch result.outcome {
      case "verified": updates[receipt.id] = ("burned", "Stopped and verified.")
      case "verifying": continue
      default: updates[receipt.id] = ("failed", result.detail)
      }
    }
    guard !updates.isEmpty else { return }
    try? store.updateReceipts { all in
      for i in all.indices {
        if let (outcome, detail) = updates[all[i].id] {
          all[i].outcome = outcome
          all[i].detail = detail
        }
      }
    }
  }

  /// Keeps open questions in step with current items and fills free slots.
  func refreshQuestions(now: Date) {
    guard let items = catalog?.items else { return }
    try? store.updateMemory { memory in
      let unsure = items.filter { AutopilotPolicy.decide($0, memory: memory).status == .unsure }
      for i in memory.questions.indices where memory.questions[i].isOpen {
        let rule = AutopilotRule(
          kind: memory.questions[i].kind, match: memory.questions[i].match, verdict: .burn,
          source: .operator, title: "")
        let matching = unsure.filter { AutopilotPolicy.matches(rule, $0) }
        memory.questions[i].count = matching.count
        memory.questions[i].bytes = matching.reduce(0) { $0 + $1.bytes }
        memory.questions[i].examples = Array(
          matching.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name))
      }
      // Once burns shrink a pattern below what a question is worth, it stops being asked.
      memory.questions.removeAll { $0.isOpen && $0.bytes < AutopilotPolicy.worthAsking }
      memory.questions += AutopilotPolicy.proposeQuestions(unsure, memory: memory, now: now)
    }
  }

  func why(
    _ item: AutopilotItem, _ decision: (status: AutopilotStatus, authority: String?),
    _ memory: AutopilotMemory
  ) -> String {
    if let reason = item.protectedReason { return reason }
    if let judgment = memory.judgments[item.id], judgment.revision == item.revision,
      decision.authority?.hasPrefix("ai:") == true
    {
      return judgment.why
    }
    guard let authority = decision.authority else {
      return "I'm not sure about this one yet, so I'll ask you."
    }
    if authority == "operator" { return "You asked me to keep it." }
    let id = authority.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
    if authority.hasPrefix("rule:"), let rule = memory.rules.first(where: { $0.id == id }) {
      return "You told me: " + rule.title + "."
    }
    if authority.hasPrefix("starter:"),
      let rule = AutopilotPolicy.starterRules.first(where: { $0.id == id })
    {
      return "One of my safe starter rules: " + rule.title.lowercased() + "."
    }
    return "Decided by " + authority + "."
  }

  public func snapshot(now: Date = Date()) -> AutopilotSnapshot {
    let memory = memory()
    let receipts = (try? store.receipts()) ?? []
    var latest = [String: AutopilotReceipt]()
    for receipt in receipts { latest[receipt.itemID] = receipt }
    var result = AutopilotSnapshot()
    var seen = Set<String>()
    for item in catalog?.items ?? [] {
      seen.insert(item.id)
      let decision = AutopilotPolicy.decide(item, memory: memory)
      var status = decision.status
      let receipt = latest[item.id]
      if let receipt, receipt.date >= item.observedAt {
        if receipt.outcome == "failed" { status = .failed }
        if receipt.outcome == "burned" { status = .burned }
      }
      let judgment = memory.judgments[item.id].flatMap { $0.revision == item.revision ? $0 : nil }
      var entry = AutopilotEntry(
        item: item, status: status, authority: decision.authority,
        label: judgment?.label ?? item.name, why: why(item, decision, memory),
        consequence: AutopilotPolicy.consequence(item), receipt: receipt)
      entry.judged = judgment != nil
      result.entries.append(entry)
    }
    for receipt in latest.values
    where !seen.contains(receipt.itemID) && ["burned", "restored"].contains(receipt.outcome)
      && receipt.date > now.addingTimeInterval(-30 * 86400)
    {
      let item = AutopilotItem(
        id: receipt.itemID, kind: receipt.kind, name: receipt.name, detail: receipt.detail,
        path: receipt.restore?.path, bytes: receipt.bytes, facts: [:], observedAt: receipt.date)
      result.entries.append(
        AutopilotEntry(
          item: item, status: receipt.outcome == "burned" ? .burned : .keep,
          authority: receipt.authority,
          label: receipt.name,
          why: receipt.outcome == "burned"
            ? "Burned \(receipt.date.formatted(date: .abbreviated, time: .shortened))."
            : "You restored it.",
          consequence: AutopilotPolicy.consequence(item), receipt: receipt))
    }
    for entry in result.entries {
      result.counts[entry.status.rawValue, default: 0] += 1
      result.bytes[entry.status.rawValue, default: 0] += entry.item.bytes
    }
    result.questions = memory.openQuestions.filter { $0.count > 0 }
    // Rules taught by a question read like its card, even rules taught with older words.
    let taught = Dictionary(memory.questions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    result.rules =
      memory.rules.map { rule in
        guard let question = rule.questionID.flatMap({ taught[$0] }) else { return rule }
        var shown = rule
        shown.title = AutopilotPolicy.ruleTitle(question, answer: rule.verdict == .burn ? .yes : .no)
        return shown
      }
      + AutopilotPolicy.starterRules.map { rule in
        var copy = rule
        copy.enabled = !memory.starterDisabled.contains(rule.id)
        return copy
      }
    result.answers = memory.answers
    result.trainingProgress = AutopilotPolicy.trainingProgress(memory)
    result.coverage = AutopilotPolicy.coverage(result.entries)
    result.sweep = (try? store.sweep()) ?? AutopilotSweepState()
    result.receipts = Array(receipts.suffix(100).reversed())
    result.coverageNotes = catalog?.coverageNotes ?? []
    result.observedAt = catalog?.observedAt
    return result
  }

  /// Applies an operator command and returns the new snapshot.
  public func apply(_ command: AutopilotCommand, now: Date = Date()) async throws
    -> AutopilotSnapshot
  {
    switch command {
    case .answer(let id, let answer):
      try store.updateMemory { memory in
        guard let i = memory.questions.firstIndex(where: { $0.id == id }) else {
          throw StoreError.message("That question is no longer open.")
        }
        memory.questions[i].answer = answer
        memory.questions[i].answered = now
        if answer == .skip {
          memory.questions[i].snoozedUntil = now.addingTimeInterval(86400)
        } else {
          let q = memory.questions[i]
          let verdict: AutopilotVerdict = answer == .yes ? .burn : .keep
          memory.rules.removeAll { $0.questionID == q.id }
          memory.rules.append(
            AutopilotRule(
              kind: q.kind, match: AutopilotPolicy.widen(q.match, verdict: verdict),
              verdict: verdict, source: .operator,
              title: AutopilotPolicy.ruleTitle(q, answer: answer), created: now,
              questionID: q.id))
        }
      }
      refreshQuestions(now: now)
      // Show the answer right away; matching items burn in the background.
      Task { await self.burnAuthorized(now: now) }
    case .burnNow(let id):
      guard let item = catalog?.items.first(where: { $0.id == id }) else {
        throw StoreError.message("I can't find that anymore. It may already be gone.")
      }
      if let reason = item.protectedReason { throw StoreError.message(reason) }
      if spent((try? store.receipts()) ?? []).contains(id) {
        throw StoreError.message("I already burned that.")
      }
      let receipt = await execute(item, authority: "operator", why: "You asked me to burn it.")
      if receipt.outcome == "refused" { throw StoreError.message(receipt.detail) }
    case .keep(let id):
      let path = catalog?.items.first(where: { $0.id == id })?.path
      try store.updateMemory { memory in
        memory.keptItems.insert(id)
        if let path { memory.keptItems.insert("path:" + path) }
      }
    case .restore(let receiptID):
      guard let receipt = try store.receipts().first(where: { $0.id == receiptID }),
        let restore = receipt.restore
      else { throw StoreError.message("There's nothing to restore for that one.") }
      try await Task.detached { [sources] in try sources.restoreWorktree(receipt) }.value
      try store.updateReceipts { all in
        if let i = all.firstIndex(where: { $0.id == receiptID }) {
          all[i].outcome = "restored"
          all[i].detail = "Restored at \(restore.path)."
        }
      }
      try store.updateMemory {
        $0.keptItems.insert(receipt.itemID)
        $0.keptItems.insert("path:" + restore.path)
      }
    case .forgetRule(let id):
      try store.updateMemory { memory in
        if let rule = memory.rules.first(where: { $0.id == id }), let q = rule.questionID {
          memory.questions.removeAll { $0.id == q }
        }
        memory.rules.removeAll { $0.id == id }
      }
    case .setStarter(let id, let enabled):
      try store.updateMemory { memory in
        if enabled { memory.starterDisabled.remove(id) } else { memory.starterDisabled.insert(id) }
      }
    case .setEnabled(let enabled):
      try store.updateSweep { $0.enabled = enabled }
    case .setInterval(let minutes):
      guard [5, 15, 30, 60, 240].contains(minutes) else {
        throw StoreError.message("Choose 5, 15, 30, 60 or 240 minutes.")
      }
      try store.updateSweep { $0.intervalMinutes = minutes }
    case .resetTraining:
      try store.updateMemory { memory in
        let kept = memory.keptItems
        memory = AutopilotMemory()
        memory.keptItems = kept
      }
      refreshQuestions(now: now)
    case .sweepNow:
      try store.updateSweep { $0.requested = true }
    }
    return snapshot(now: now)
  }

  // MARK: AI reviewer surface

  public func catalogPage(status: String?, kind: String?, offset: Int, limit: Int)
    -> AutopilotCatalogPage
  {
    let snap = snapshot()
    let memory = memory()
    var entries = snap.entries.filter { entry in
      (status == nil || status == "all" || entry.status.rawValue == status)
        && (kind == nil || entry.item.kind.rawValue == kind)
    }
    let order: [AutopilotStatus] = [.unsure, .burn, .keep, .failed, .protected, .burned]
    entries.sort {
      let a = order.firstIndex(of: $0.status) ?? 9
      let b = order.firstIndex(of: $1.status) ?? 9
      return a != b ? a < b : $0.item.bytes > $1.item.bytes
    }
    let bounded = min(max(limit, 1), 200)
    let page = Array(entries.dropFirst(max(0, offset)).prefix(bounded))
    var summary = snap.counts.mapValues(String.init)
    summary["trainingProgress"] = String(format: "%.2f", snap.trainingProgress)
    summary["answers"] = String(snap.answers)
    summary["coverage"] = String(format: "%.2f", snap.coverage)
    summary["totalItems"] = String(entries.count)
    return AutopilotCatalogPage(
      summary: summary, rules: snap.rules, openQuestions: snap.questions,
      answered: Array(
        memory.questions.filter { $0.answer == .yes || $0.answer == .no }.suffix(20)),
      items: page.map { entry in
        AutopilotCatalogItem(
          id: entry.id, kind: entry.item.kind, name: entry.item.name, detail: entry.item.detail,
          size: AutopilotPolicy.format(entry.item.bytes),
          facts: entry.item.facts.filter { $0.key != "kind" }, status: entry.status,
          authority: entry.authority, label: entry.label == entry.item.name ? nil : entry.label,
          why: entry.status == .unsure ? nil : entry.why)
      },
      nextOffset: offset + page.count < entries.count ? offset + page.count : nil)
  }

  public func inspect(_ id: String) -> [String: String] {
    guard let item = catalog?.items.first(where: { $0.id == id }) else {
      return ["error": "Unknown item. Read the catalog again."]
    }
    var result = sources.inspect(item)
    result["id"] = item.id
    result["facts"] = item.facts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      .joined(separator: ", ")
    return result
  }

  /// Records AI judgments. Returns the ids that are now authorized to burn.
  public func decide(_ judgments: [AutopilotJudgment]) throws -> [String] {
    let items = Dictionary(
      (catalog?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var accepted = [AutopilotJudgment]()
    for var judgment in judgments.prefix(200) {
      guard let item = items[judgment.itemID] else { continue }
      judgment.revision = item.revision
      judgment.confidence = min(1, max(0, judgment.confidence))
      judgment.label = String(judgment.label.prefix(120))
      judgment.why = String(judgment.why.prefix(400))
      accepted.append(judgment)
    }
    try store.updateMemory { memory in
      for judgment in accepted { memory.judgments[judgment.itemID] = judgment }
    }
    let memory = memory()
    return accepted.compactMap { judgment in
      items[judgment.itemID].flatMap {
        AutopilotPolicy.decide($0, memory: memory).status == .burn ? $0.id : nil
      }
    }
  }

  /// Burns items the policy authorizes; everything else is refused with a reason.
  public func burn(_ ids: [String]) async -> [AutopilotReceipt] {
    let memory = memory()
    var receipts = [AutopilotReceipt]()
    for id in ids.prefix(50) {
      guard let item = catalog?.items.first(where: { $0.id == id }) else {
        receipts.append(
          AutopilotReceipt(
            itemID: id, kind: .process, name: id, authority: "ai", outcome: "refused",
            detail: "Unknown item. Read the catalog again."))
        continue
      }
      if spent((try? store.receipts()) ?? []).contains(id) {
        receipts.append(.refused(item, authority: "ai", "Already burned."))
        continue
      }
      let decision = AutopilotPolicy.decide(item, memory: memory)
      guard decision.status == .burn, let authority = decision.authority else {
        receipts.append(
          .refused(
            item, authority: "ai",
            decision.status == .protected
              ? (item.protectedReason ?? "Protected.")
              : "Not authorized. Record a confident judgment with autopilot_decide if it is AI-eligible, otherwise ask the operator with autopilot_ask."
          ))
        continue
      }
      receipts.append(await execute(item, authority: authority, why: why(item, decision, memory)))
    }
    return receipts
  }

  /// Opens a training question. Fails when three are open, unless it replaces one.
  public func ask(_ question: AutopilotQuestion, replacing: String? = nil) throws
    -> AutopilotQuestion
  {
    let items = catalog?.items ?? []
    return try store.updateMemory { memory in
      if let replacing {
        memory.questions.removeAll { $0.id == replacing && $0.isOpen }
      }
      // The AI rewording a pattern BZ already asked natively improves that question.
      if let i = memory.questions.firstIndex(where: {
        $0.id == question.id && $0.isOpen && $0.source == "native"
      }) {
        memory.questions[i].question = question.question
        if !question.why.isEmpty { memory.questions[i].why = question.why }
        if !question.examples.isEmpty { memory.questions[i].examples = question.examples }
        memory.questions[i].source = "ai"
        return memory.questions[i]
      }
      guard !memory.questions.contains(where: { $0.id == question.id }) else {
        throw StoreError.message("That pattern was already asked.")
      }
      // An AI question supersedes open native questions about mostly the same items.
      let unsure = items.filter { AutopilotPolicy.decide($0, memory: memory).status == .unsure }
      func covered(_ kind: AutopilotKind, _ match: [String: [String]]) -> Set<String> {
        let rule = AutopilotRule(
          kind: kind, match: match, verdict: .burn, source: .operator, title: "")
        return Set(unsure.filter { AutopilotPolicy.matches(rule, $0) }.map(\.id))
      }
      let asked = covered(question.kind, question.match)
      memory.questions.removeAll { open in
        guard open.isOpen, open.source == "native", open.kind == question.kind else {
          return false
        }
        let theirs = covered(open.kind, open.match)
        return !theirs.isEmpty && Double(theirs.intersection(asked).count) >= Double(theirs.count) * 0.5
      }
      guard memory.openQuestions.count < AutopilotPolicy.maximumOpenQuestions else {
        throw StoreError.message(
          "Three questions are already open. Replace one with `replace` or wait for answers.")
      }
      let rule = AutopilotRule(
        kind: question.kind, match: question.match, verdict: .burn, source: .operator, title: "")
      let matching = items.filter {
        AutopilotPolicy.decide($0, memory: memory).status == .unsure
          && AutopilotPolicy.matches(rule, $0)
      }
      guard !matching.isEmpty else {
        throw StoreError.message("No unsure items match that pattern.")
      }
      let bytes = matching.reduce(0) { $0 + $1.bytes }
      guard bytes >= AutopilotPolicy.worthAsking else {
        throw StoreError.message(
          "That pattern frees only \(AutopilotPolicy.format(bytes)). Ask only about patterns freeing 1 GB or more."
        )
      }
      var q = question
      q.count = matching.count
      q.bytes = bytes
      if q.examples.isEmpty {
        q.examples = Array(matching.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name))
      }
      q.source = "ai"
      memory.questions.append(q)
      return q
    }
  }

  public func report(_ text: String) throws {
    try store.updateSweep { $0.append(String(text.prefix(500))) }
  }

  public func sweepState() -> AutopilotSweepState { (try? store.sweep()) ?? AutopilotSweepState() }
  public func updateSweep(_ change: @Sendable (inout AutopilotSweepState) -> Void) {
    try? store.updateSweep { change(&$0) }
  }
}

/// A bounded overview for the CLI: the socket reply is capped, so no item lists.
public struct AutopilotSummary: Codable, Sendable {
  public var counts: [String: Int]
  public var bytes: [String: String]
  public var trainingProgress: Double
  public var answers: Int
  public var coverage: Double
  public var questions: [String]
  public var rules: [String]
  public var enabled: Bool
  public var intervalMinutes: Int
  public var lastTick: Date?
  public var lastAISweep: Date?
  public var retryAfter: Date?
  public var lastError: String?
  public var log: [String]
  public var recent: [String]
  public var notes: [String]
  public init(_ s: AutopilotSnapshot) {
    counts = s.counts
    bytes = s.bytes.mapValues(AutopilotPolicy.format)
    trainingProgress = s.trainingProgress
    answers = s.answers
    coverage = s.coverage
    questions = s.questions.map { "\($0.question) (\($0.why))" }
    rules = s.rules.filter(\.enabled).map { "\($0.source.rawValue): \($0.title)" }
    enabled = s.sweep.enabled
    intervalMinutes = s.sweep.intervalMinutes
    lastTick = s.sweep.lastTick
    lastAISweep = s.sweep.lastAISweep
    retryAfter = s.sweep.retryAfter
    lastError = s.sweep.lastError
    log = s.sweep.log.suffix(10).map(\.message)
    recent = s.receipts.prefix(20).map { "\($0.name): \($0.outcome) (\($0.authority))" }
    notes = s.coverageNotes
  }
}

/// One autopilot call from the MCP server or CLI.
public struct AutopilotRequest: Codable, Sendable {
  /// `catalog`, `inspect`, `decide`, `burn`, `ask`, `report`, `snapshot` or `command`.
  public var tool: String
  public var status: String?
  public var kind: String?
  public var offset: Int?
  public var limit: Int?
  public var id: String?
  public var ids: [String]?
  public var judgments: [AutopilotJudgmentInput]?
  public var question: AutopilotQuestionInput?
  public var replace: String?
  public var text: String?
  public var command: AutopilotCommand?
  public init(tool: String) { self.tool = tool }
}
public struct AutopilotJudgmentInput: Codable, Sendable {
  public var id: String
  public var verdict: AutopilotVerdict
  public var confidence: Double
  public var label: String
  public var why: String
  public init(id: String, verdict: AutopilotVerdict, confidence: Double, label: String, why: String)
  {
    self.id = id
    self.verdict = verdict
    self.confidence = confidence
    self.label = label
    self.why = why
  }
}
public struct AutopilotQuestionInput: Codable, Sendable {
  public var kind: AutopilotKind
  public var match: [String: [String]]
  public var question: String
  public var why: String?
  public var examples: [String]?
  public init(kind: AutopilotKind, match: [String: [String]], question: String) {
    self.kind = kind
    self.match = match
    self.question = question
  }
}

extension Autopilot {
  /// Dispatches one request and returns `(ok, json)`.
  public func handle(_ request: AutopilotRequest) async -> (Bool, String) {
    func encode<T: Encodable>(_ value: T) -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    func failure(_ message: String) -> (Bool, String) {
      (false, encode(["error": message]))
    }
    do {
      switch request.tool {
      case "catalog":
        return (
          true,
          encode(
            catalogPage(
              status: request.status, kind: request.kind, offset: request.offset ?? 0,
              limit: request.limit ?? 100))
        )
      case "inspect":
        guard let id = request.id else { return failure("Pass id.") }
        return (true, encode(inspect(id)))
      case "decide":
        guard let inputs = request.judgments, !inputs.isEmpty else {
          return failure("Pass judgments.")
        }
        let authorized = try decide(
          inputs.map {
            AutopilotJudgment(
              itemID: $0.id, revision: "", verdict: $0.verdict, confidence: $0.confidence,
              label: $0.label, why: $0.why)
          })
        return (true, encode(["recorded": String(inputs.count), "authorized": authorized.joined(separator: ",")]))
      case "burn":
        guard let ids = request.ids, !ids.isEmpty else { return failure("Pass ids.") }
        return (true, encode(await burn(ids)))
      case "ask":
        guard let input = request.question else { return failure("Pass question.") }
        let text = input.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...200).contains(text.count), text.hasSuffix("?"), !input.match.isEmpty else {
          return failure("A question is one short sentence ending with ? about a fact pattern.")
        }
        var q = AutopilotQuestion(
          kind: input.kind, match: input.match, question: text, why: input.why ?? "",
          examples: input.examples ?? [], count: 0, bytes: 0, source: "ai")
        q = try ask(q, replacing: request.replace)
        if q.why.isEmpty || input.why == nil {
          q.why = "I found \(q.count) like this, using \(AutopilotPolicy.format(q.bytes))."
          let final = q
          try store.updateMemory { memory in
            if let i = memory.questions.firstIndex(where: { $0.id == final.id }) {
              memory.questions[i].why = final.why
            }
          }
        }
        return (true, encode(q))
      case "report":
        try report(request.text ?? "")
        return (true, encode(["ok": "true"]))
      case "snapshot":
        return (true, encode(AutopilotSummary(snapshot())))
      case "command":
        guard let command = request.command else { return failure("Pass command.") }
        return (true, encode(AutopilotSummary(try await apply(command))))
      default:
        return failure("Unknown autopilot tool.")
      }
    } catch {
      return failure(error.localizedDescription)
    }
  }
}
