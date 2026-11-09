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
  public var evidence: @Sendable (AutopilotItem, String) -> [String: String]
  public var coverageNotes: @Sendable () -> [String]
  /// While old copies wait for the owner to allow the backup key (`AutopilotRecoveryKey.wait`).
  public var recoveryKeyWait: @Sendable () -> AutopilotKeyWait?
  /// The owner's Allow: reads the key with macOS's question allowed.
  public var allowRecoveryKey: @Sendable () throws -> Void
  /// While the key waits, one quiet read in the background, so a wait can end without the owner.
  public var retryRecoveryKey: @Sendable () -> Void
  /// How many of the owner's programs are running, leftovers or not: what a hunt says it looked at.
  public var processCount: @Sendable () async -> Int
  public init(
    threads: @escaping @Sendable () -> [AgentThread] = { [] },
    processes: @escaping @Sendable ([AgentThread]) async -> [AutopilotItem] = { _ in [] },
    worktreeRecords: @escaping @Sendable () async -> [WorktreeRecord] = { [] },
    worktrees:
      @escaping @Sendable ([WorktreeRecord], [AgentThread], [String: AutopilotDelivery])
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
    evidence: @escaping @Sendable (AutopilotItem, String) -> [String: String] = { _, _ in
      ["error": "Scoped evidence unavailable."]
    },
    coverageNotes: @escaping @Sendable () -> [String] = { [] },
    recoveryKeyWait: @escaping @Sendable () -> AutopilotKeyWait? = { nil },
    allowRecoveryKey: @escaping @Sendable () throws -> Void = {
      throw StoreError.message("There is no backup key to allow here.")
    },
    retryRecoveryKey: @escaping @Sendable () -> Void = {},
    processCount: @escaping @Sendable () async -> Int = { 0 }
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
    self.evidence = evidence
    self.coverageNotes = coverageNotes
    self.recoveryKeyWait = recoveryKeyWait
    self.allowRecoveryKey = allowRecoveryKey
    self.retryRecoveryKey = retryRecoveryKey
    self.processCount = processCount
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

/// One of the owner's lessons as the AI reads it (spec 2.6): the sentence Settings shows for a
/// group of lessons, their ids and exact matches, how many of the owner's answers they rest on, and
/// what they burned, freed and the owner undid.
public struct AutopilotCatalogLesson: Codable, Sendable {
  public var ids: [String]
  public var sentence: String
  public var kind: AutopilotKind
  public var verdict: AutopilotVerdict
  public var matches: [[String: [String]]]
  public var answers: Int
  public var burned: Int
  public var bytes: UInt64
  public var undone: Int
}

public struct AutopilotCatalogPage: Codable, Sendable {
  public var summary: [String: String]
  public var rules: [AutopilotRule]
  /// The owner's lessons, one per group Settings shows: the AI's brief.
  public var lessons: [AutopilotCatalogLesson]
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
  /// Items burning right now, by id, with the authority each burns under.
  var burning: [String: String] = [:]
  var ticking = false
  /// Transient during a user-requested app update. Never changes the owner's saved rules.
  var updateSuspended = false
  public func suspendForAppUpdate(_ suspended: Bool) { updateSuspended = suspended }
  public func finishActionsForAppUpdate() async throws {
    while ticking || !burning.isEmpty || !undoing.isEmpty {
      try Task.checkCancellation()
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }
  /// Tells being undone: restores wait on Git, and a second Undo meanwhile would restore again.
  var undoing = Set<String>()
  /// Where `hunt-state.json` lives, beside the rest of BurnZombies' state.
  let huntStore: Store?
  /// The hunt under way: every tool call, burn and word of the AI adds to its feed and counters.
  var hunt: HuntSnapshot?
  /// Its AI run, so Stop can end it from the app or the command line.
  var huntRun: AutopilotRun?
  /// What the AI judged during this hunt, by kind, so each thing counts once.
  var huntJudged: [AutopilotKind: Set<String>] = [:]
  /// What the hunt had spent before this run began, when "Keep hunting" goes on with it.
  var huntSpentBefore = 0.0
  var huntTokensBefore = 0
  /// How many programs, copies and junk folders the last look saw, small ones included.
  var seen: [AutopilotKind: Int] = [:]
  /// While a deep hunt runs, programs this small are looked at too.
  var programFloor: UInt64?
  /// Tells the running app a hunt was asked for, so it starts now instead of at the next tick.
  var wake: (@Sendable () -> Void)?

  public init(
    root: URL = Store.defaultRoot, sources: AutopilotSources,
    minimumBytes: UInt64 = AutopilotPolicy.worthBytes
  ) throws {
    store = try AutopilotStore(root: root)
    huntStore = try? Store(root: root)
    self.sources = sources
    self.minimumBytes = minimumBytes
    catalog = try? store.catalog()
    // Memory from before lessons migrates now, before a tick changes a receipt: its tallies are
    // seeded from receipts.json as it stands, and each later burn counts as it is recorded.
    _ = try? store.memory()
    try? store.refreshImpact()
  }

  /// The executor repeats this after slow recovery work, immediately before removal.
  public static func executorAllowed(_ item: AutopilotItem, authority: String, root: URL) -> Bool {
    guard let state = try? AutopilotStore(root: root), let memory = try? state.memory(),
      let sweep = try? state.sweep(), (try? state.receipts()) != nil
    else { return false }
    if authority == "operator" { return true }
    let decision = AutopilotPolicy.decide(item, memory: memory)
    return sweep.enabled && sweep.lookOnly != true && decision.status == .burn
      && decision.authority == authority
  }

  /// Refresh the catalog and burn everything already authorized. Uses no AI.
  @discardableResult public func tick(now: Date = Date(), burn: Bool = true) async
    -> AutopilotSnapshot
  {
    // A long burn pass must not overlap the next tick; the caller gets the current view.
    guard !ticking, !updateSuspended else { return snapshot(now: now) }
    ticking = true
    defer { ticking = false }
    try? store.updateSweep {
      if $0.lastTick == nil { $0.firstTick = now }
      $0.lastTick = now
    }
    // During a hunt, the window watches this look count up as each part of it finishes.
    if hunt != nil {
      hunt?.focus = "Looking over this Mac"
      saveHunt()
    }
    let threads = sources.threads()
    let records = await sources.worktreeRecords()
    var items = await sources.processes(threads)
    let running = await sources.processCount()
    seen[.process] = running > 0 ? running : items.count
    looked(.process, seen[.process] ?? 0)
    let (copies, cache) = sources.worktrees(records, threads, delivery)
    delivery = cache
    items += copies.filter { $0.path.map { FileManager.default.fileExists(atPath: $0) } ?? true }
      .map { Self.mentionChat($0, threads: threads, now: now) }
    seen[.worktree] = records.count
    looked(.worktree, records.count)
    let junk = sources.disk(records)
    items += junk
    // Docker's build cache isn't a folder to anyone looking at the count.
    let folders = junk.filter { !AutopilotDockerCache.isCache($0) }.count
    seen[.disk] = folders
    looked(.disk, folders)
    // A copy retire couldn't back up for big unsaved files carries them as risks of their own.
    items = AutopilotPolicy.withBigFiles(items, receipts: (try? store.receipts()) ?? [])
    // A deep hunt looks at small programs too: a swarm of them frees as much as one big one.
    let floor = minimumBytes
    let programs = programFloor.map { min($0, floor) } ?? floor
    items = items.filter {
      AutopilotPolicy.worthAssessing($0, minimumBytes: $0.kind == .process ? programs : floor)
    }
    catalog = AutopilotCatalog(
      observedAt: now, items: items, threads: threads, coverageNotes: sources.coverageNotes())
    try? store.save(catalog: catalog!)
    await refreshReceipts()
    let canBurn = burn && burnsOnItsOwn()
    var used: [AutopilotKind: Int] = [:]
    if canBurn { used = await burnAuthorized(now: now) }
    // What BZ answers itself burns right away, through the same pass as an answer's matches and
    // within the bound this look's other burns already count toward. Asked again after that pass:
    // look-only or Autopilot off switched on while it ran stops this look acting too.
    let acted = refreshQuestions(now: now, acting: canBurn && burnsOnItsOwn())
    if !acted.isEmpty { await burnAuthorized(now: now, used: used, settling: acted) }
    return snapshot(now: now)
  }

  func memory() -> AutopilotMemory {
    if let memory = try? store.memory() { return memory }
    var held = AutopilotMemory()
    held.starterDisabled = Set(AutopilotPolicy.starterRules.map(\.id))
    return held
  }

  /// Whether Autopilot is switched on. Off, it catalogs and asks but burns nothing on its own.
  func enabled() -> Bool { (try? store.sweep().enabled) ?? false }

  /// Whether BZ burns on its own right now: Autopilot is on and not look-only. Only then does it
  /// act on a question it is sure of; otherwise it asks, so no tell says it burned what is still
  /// there.
  func burnsOnItsOwn() -> Bool { enabled() && !holdsBurns() }

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

  /// A refusal stands for the facts and authority it saw until either changes or a while
  /// passes. Keyed by `refusalKey`; the latest refusal says why. A check for programs using the
  /// item that couldn't finish says nothing about the item, so the next look tries once more;
  /// a second one stands like any other.
  /// `keyWaits`: old copies wait for the owner to allow the backup key. A refusal for the key
  /// stands only that long; once the key reads, its copy is tried at the next pass.
  static func standingRefusals(_ receipts: [AutopilotReceipt], now: Date, keyWaits: Bool)
    -> [String: AutopilotReceipt]
  {
    var standing = [String: AutopilotReceipt]()
    var unchecked = Set<String>()
    for r in receipts
    where r.outcome == "refused" && now.timeIntervalSince(r.date) < retryRefusalsAfter {
      guard let revision = r.revision else { continue }
      if !keyWaits && r.detail == AutopilotRecoveryKey.refusal { continue }
      // One from before refusals named big files names none: trying again names them.
      if r.bigFiles == nil && AutopilotWorktrees.unnamedBigFiles.contains(r.detail) { continue }
      let key = refusalKey(r.itemID, revision, r.authority)
      if uncheckedUse.contains(r.detail), unchecked.insert(key).inserted { continue }
      standing[key] = r
    }
    return standing
  }

  static let uncheckedUse: Set<String> = [
    AutopilotWorktrees.uncheckedUse, AutopilotDisk.uncheckedUse,
  ]

  static func refusalKey(_ id: String, _ revision: String, _ authority: String) -> String {
    [id, revision, authority].joined(separator: "@")
  }

  /// What the AI hears about an item waiting after a refusal, instead of a fresh try.
  static func waiting(after refusal: AutopilotReceipt, now: Date) -> String {
    let retry = refusal.date.addingTimeInterval(retryRefusalsAfter)
    let when = RelativeDateTimeFormatter().localizedString(for: retry, relativeTo: now)
    return
      "Waiting after a refusal: \(refusal.detail) I'll try again \(when), or sooner if it changes."
  }

  /// Look-only holds every burn BZ would make on its own. A sweep state it can't read holds them
  /// too, so a damaged file never turns look-only off.
  func holdsBurns() -> Bool {
    guard let sweep = try? store.sweep() else { return true }
    return sweep.lookOnly == true
  }

  /// What a second burn of an item hears while the first is still under way.
  static let alreadyBurning = "I'm already burning it."

  /// What an agent hears when it tries to allow the backup key for the owner.
  static let ownerAllowsKey = "Only the owner can allow my backup key, with Allow in BZ's menu."

  /// What the AI and the CLI read while old copies wait for the backup key.
  static let keyWaitNote =
    "Old copies wait: macOS needs the owner's OK before I can use my backup key, and BZ's menu asks them. Burning an old copy now is refused."

  /// What the AI hears when it asks to burn something while look-only is on.
  static let lookOnlyHold =
    "Look-only: the owner hasn't turned burning on, so nothing burns yet. Your verdicts are kept and burn once they do; don't burn again this sweep."

  /// Burns every item the policy authorizes now, at most `maximumBurns` of each kind in one look:
  /// `used` brings what the look's earlier passes burned, and the new counts come back. Each item
  /// is decided again on memory and receipts as they are right before it burns, so an Undo or an
  /// answer that lands while a pass waits on Git wins, and nothing another pass just burned is
  /// tried again. Then open tells say what their lessons burned; `settling` names tells whose act's
  /// own pass this is. Look-only holds the whole pass.
  @discardableResult func burnAuthorized(
    now: Date, used start: [AutopilotKind: Int] = [:], settling: Set<String> = []
  ) async -> [AutopilotKind: Int] {
    guard let items = catalog?.items, !holdsBurns() else {
      // Look-only switched on after BZ acted: the act's tell says what burned, which is nothing yet,
      // and never "Burned 3" for things still there.
      refreshTells(settling: settling)
      return start
    }
    // While old copies wait for the key, each pass tries one quiet read in the background: if the
    // key reads again by itself, the next pass burns them without the owner's click.
    if sources.recoveryKeyWait() != nil { sources.retryRecoveryKey() }
    let early = memory()
    let receipts = (try? store.receipts()) ?? []
    let spent = spent(receipts)
    let refused = Self.standingRefusals(
      receipts, now: now, keyWaits: sources.recoveryKeyWait() != nil)
    var used = start
    for item in items where !spent.contains(item.id) && burning[item.id] == nil {
      // A cheap first look, on memory as the pass began.
      guard AutopilotPolicy.decide(item, memory: early, now: now).status == .burn,
        used[item.kind, default: 0] < Self.maximumBurns[item.kind, default: 0]
      else { continue }
      // Every retire needs the backup key. While it waits for the owner, old copies wait too,
      // without a receipt: the copy that ran into it says why, and the menu asks.
      if item.kind == .worktree, sources.recoveryKeyWait() != nil { continue }
      let memory = memory()
      let decision = AutopilotPolicy.decide(item, memory: memory, now: now)
      guard decision.status == .burn, let authority = decision.authority,
        refused[Self.refusalKey(item.id, item.revision, authority)] == nil
      else { continue }
      let latest = (try? store.receipts()) ?? []
      if self.spent(latest).contains(item.id) { continue }
      // Only burns count toward the bound; a refusal frees nothing.
      let receipt = await execute(item, authority: authority, why: why(item, decision, memory))
      if receipt.outcome != "refused" { used[item.kind, default: 0] += 1 }
    }
    refreshTells(settling: settling)
    return used
  }

  /// Says on each open tell what its lesson burned (`AutopilotPolicy.refreshTells`), writing memory
  /// only when that changes.
  func refreshTells(settling: Set<String>) {
    let current = memory()
    guard current.tells.contains(where: \.isOpen), let items = catalog?.items else { return }
    let receipts = (try? store.receipts()) ?? []
    var updated = current
    AutopilotPolicy.refreshTells(&updated, receipts: receipts, items: items, settled: settling)
    guard updated.tells != current.tells else { return }
    try? store.updateMemory {
      AutopilotPolicy.refreshTells(&$0, receipts: receipts, items: items, settled: settling)
    }
  }

  func execute(_ item: AutopilotItem, authority: String, why: String) async -> AutopilotReceipt {
    guard !updateSuspended else {
      return .refused(
        item, authority: authority, "BurnZombies is updating. Your rules and decisions stay saved.")
    }
    // A damaged policy must never become empty authority, including the operator path.
    do {
      _ = try store.memory()
      _ = try store.sweep()
      let previous = try store.receipts()
      if previous.contains(where: {
        $0.itemID == item.id && $0.outcome == "failed" && $0.restore?.recovery != nil
      }) {
        return .refused(
          item, authority: authority,
          "A previous cleanup has unresolved recovery. Preserve it and restore or reconcile it first."
        )
      }
    } catch {
      return .refused(
        item, authority: authority,
        "Cleanup paused: saved permissions or recovery receipts could not be read. Preserve the state and repair it first."
      )
    }
    // Never touches means never, whoever asks.
    if AutopilotPolicy.neverTouched(item, memory: memory()) {
      return .refused(item, authority: authority, Self.neverTouchHold)
    }
    // Every burn passes here. Look-only lets through only the owner's own Burn now, and writes
    // nothing for a held one: it isn't a refusal to wait out.
    if authority != "operator", holdsBurns() {
      return .refused(item, authority: authority, Self.lookOnlyHold)
    }
    // One burn per item at a time, whoever asks: a second retire of the same copy would rewrite
    // the restore point the first one just verified. The first burn's receipt says how it went.
    guard burning[item.id] == nil else {
      return .refused(item, authority: authority, Self.alreadyBurning)
    }
    burning[item.id] = authority
    defer { burning[item.id] = nil }
    let sources = sources
    var receipt: AutopilotReceipt
    switch item.kind {
    case .process:
      do {
        let event = try await sources.burnProcess(item, authority, why)
        receipt = AutopilotReceipt(
          itemID: item.id, kind: .process, name: item.name, authority: authority,
          outcome: "verifying", detail: "Asked it to stop; checking that it did.",
          bytes: item.bytes,
          eventID: event)
      } catch {
        receipt = .refused(item, authority: authority, error.localizedDescription)
      }
    case .worktree:
      receipt = await Task.detached { sources.retireWorktree(item, authority) }.value
    case .disk:
      receipt = await Task.detached { sources.reclaimDisk(item, authority) }.value
    }
    // Docker went away since BZ looked. That's no refusal to wait out or to mention: BZ says nothing
    // while Docker isn't running, and this burns once it's back.
    if receipt.detail == AutopilotDockerCache.away { return receipt }
    if (try? store.append(receipt)) != nil { tally([receipt]) }
    recordBurn(receipt, item: item)
    var line = (receipt.outcome == "refused" ? "Skipped " : "Burned ") + item.name
    if receipt.outcome == "refused" {
      line += ": " + receipt.detail
      // What failed, so the log says why; the owner's card keeps the plain reason alone.
      if let cause = receipt.cause { line += " (" + cause + ")" }
    } else {
      line += "."
    }
    try? store.updateSweep { $0.append(line) }
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
    var stopped = [AutopilotReceipt]()
    do {
      try store.updateReceipts { all in
        for i in all.indices where all[i].outcome == "verifying" {
          guard let (outcome, detail) = updates[all[i].id] else { continue }
          all[i].outcome = outcome
          all[i].detail = detail
          if outcome == "burned" { stopped.append(all[i]) }
        }
      }
    } catch { return }
    // Counted only once saved as burned, so the next tick never counts the same stop again.
    tally(stopped)
  }

  /// Counts burns toward the lessons that authorized them, once each, as they are recorded.
  func tally(_ receipts: [AutopilotReceipt]) {
    let taught = receipts.filter { $0.outcome == "burned" && $0.authority.hasPrefix("rule:") }
    guard !taught.isEmpty else { return }
    try? store.updateMemoryAfterReceipts { memory, seeded in
      // A migration in this same read counted them from receipts.json already.
      guard !seeded else { return }
      for receipt in taught { AutopilotPolicy.tally(receipt, into: &memory) }
    }
  }

  /// Keeps open questions in step with current items and fills free slots. Each new question gets
  /// BZ's guess. One BZ is sure of is answered by BZ instead, when `acting` and the owner lets it
  /// act on its own (spec 3.4); only a question it would ask can become a tell. Returns the tells it
  /// made, so the caller burns what their lessons authorize. Open tells close after a week.
  @discardableResult func refreshQuestions(now: Date, acting: Bool) -> Set<String> {
    guard let items = catalog?.items else { return [] }
    let acted = try? store.updateMemory { memory -> Set<String> in
      AutopilotPolicy.expireTells(&memory, now: now)
      let unsure = items.filter {
        AutopilotPolicy.decide($0, memory: memory, now: now).status == .unsure
      }
      Self.keepCurrent(&memory, unsure: unsure)
      var acted = Set<String>()
      for var question in AutopilotPolicy.proposeQuestions(unsure, memory: memory, now: now) {
        question.guess = AutopilotPolicy.guess(question, memory: memory, reaching: unsure)
        if acting, memory.actsOnItsOwn, let guess = question.guess, guess.sure {
          // The tell carries the moment BZ acted, not when the look began.
          let made = AutopilotPolicy.act(question, guess: guess, memory: &memory, at: Date())
          acted.insert(made.tell.id)
        } else {
          memory.questions.append(question)
        }
      }
      return acted
    }
    return acted ?? []
  }

  /// Keeps open questions true to what is unsure now: each covers what its pattern reaches today,
  /// with its numbers and its card's words worked out again, and one that no longer holds goes.
  static func keepCurrent(_ memory: inout AutopilotMemory, unsure: [AutopilotItem]) {
    for i in memory.questions.indices where memory.questions[i].isOpen {
      let question = memory.questions[i]
      let rule = AutopilotPolicy.coverage(question.kind, question.match)
      let matching = unsure.filter { AutopilotPolicy.matches(rule, $0) }
      // The numbers follow, and what the card names: the rows, when they were last used, the
      // risks and the safe line.
      AutopilotPolicy.refresh(&memory.questions[i], covering: matching)
    }
    // Once burns shrink a pattern below what a question is worth, it stops being asked.
    memory.questions.removeAll { $0.isOpen && $0.bytes < AutopilotPolicy.worthAsking }
    // Questions asked before these rules held follow them too: only about things that went
    // quiet, never about every program BZ knows no family for, and one open per subject, the one
    // that frees the most.
    memory.questions.removeAll { $0.isOpen && !AutopilotPolicy.quiet($0.kind, $0.match) }
    memory.questions.removeAll { $0.isOpen && AutopilotPolicy.everyUnknownProgram($0.kind, $0.match) }
    var subjects = Set<String>()
    let kept = Set(
      memory.questions.filter(\.isOpen)
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        .filter { subjects.insert(AutopilotPolicy.subject($0.kind, $0.match)).inserted }
        .map(\.id))
    memory.questions.removeAll { $0.isOpen && !kept.contains($0.id) }
  }

  /// Right before Teach BZ shows a card: a program that exited, and a copy or folder deleted, since
  /// the last look leave the catalog and their questions now, so no card is about something already
  /// gone, and a program still running comes back as it is now. It only takes away: nothing new is
  /// asked, judged or burned before the next look.
  public func recheck(now: Date = Date()) async -> AutopilotSnapshot {
    guard !ticking, !updateSuspended, let seen = catalog else { return snapshot(now: now) }
    let running: [AutopilotItem] = await sources.processes(sources.threads())
    // A look that ran meanwhile saw more than this: it stands.
    guard !ticking, var current = catalog, current.observedAt == seen.observedAt else {
      return snapshot(now: now)
    }
    var live: [String: AutopilotItem] = [:]
    for item in running { live[item.id] = item }
    let floor: UInt64 = programFloor.map { min($0, minimumBytes) } ?? minimumBytes
    let kept: [AutopilotItem] = current.items.compactMap { item in
      switch item.kind {
      case .process:
        guard let fresh = live[item.id], AutopilotPolicy.worthAssessing(fresh, minimumBytes: floor)
        else { return nil }
        return fresh
      case .worktree, .disk:
        // Docker's build cache has no folder to look for.
        guard let path = item.path else { return item }
        return FileManager.default.fileExists(atPath: path) ? item : nil
      }
    }
    guard kept != current.items else { return snapshot(now: now) }
    current.items = kept
    catalog = current
    try? store.save(catalog: current)
    try? store.updateMemory { memory in
      let unsure = kept.filter {
        AutopilotPolicy.decide($0, memory: memory, now: now).status == .unsure
      }
      Self.keepCurrent(&memory, unsure: unsure)
    }
    return snapshot(now: now)
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
      if AutopilotWorktrees.holdsBigFiles(item) { return AutopilotPolicy.bigFilesWait }
      return "I'm not sure about this one yet, so I'll ask you."
    }
    if authority == "operator" { return "You asked me to keep it." }
    let id = authority.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
    if authority.hasPrefix("rule:"), let rule = memory.rules.first(where: { $0.id == id }) {
      return rule.verdict == .burn
        ? "You told me to burn things like this." : "You told me to keep things like this."
    }
    if authority.hasPrefix("starter:"),
      let rule = AutopilotPolicy.starterRules.first(where: { $0.id == id })
    {
      return "One of my safe starter rules: " + rule.title.lowercased() + "."
    }
    return "Decided by " + authority + "."
  }

  /// What the windows get, newest first: the latest 100 of anything, and every burn on file for the
  /// Burn Log, which lists them all.
  public static func shownReceipts(_ receipts: [AutopilotReceipt]) -> [AutopilotReceipt] {
    let recent = receipts.count - 100
    return zip(receipts.indices, receipts).reversed().compactMap { index, receipt in
      index >= recent || ["burned", "restored"].contains(receipt.outcome) ? receipt : nil
    }
  }

  public func snapshot(now: Date = Date()) -> AutopilotSnapshot {
    let memory = memory()
    let receipts = (try? store.receipts()) ?? []
    var latest = [String: AutopilotReceipt]()
    for receipt in receipts { latest[receipt.itemID] = receipt }
    var result = AutopilotSnapshot()
    result.recoveryKey = sources.recoveryKeyWait()
    var seen = Set<String>()
    for item in catalog?.items ?? [] {
      seen.insert(item.id)
      let decision = AutopilotPolicy.decide(item, memory: memory, now: now)
      var status = decision.status
      let receipt = latest[item.id]
      if let receipt, receipt.date >= item.observedAt {
        if receipt.outcome == "failed" { status = .failed }
        if receipt.outcome == "burned" { status = .burned }
      }
      let judgment = AutopilotPolicy.currentJudgment(for: item, memory: memory, now: now)
      var entry = AutopilotEntry(
        item: item, status: status, authority: decision.authority,
        label: judgment?.label ?? item.name, why: why(item, decision, memory),
        consequence: AutopilotPolicy.consequence(item), receipt: receipt)
      entry.judged = judgment != nil
      // The AI is sure but may not burn this one itself. Copies with big unsaved files are left
      // to their own card, which says a Yes deletes them for good, and Docker's build cache to its.
      if status == .unsure, let judgment, judgment.verdict == .burn,
        judgment.confidence >= AutopilotPolicy.aiConfidenceFloor,
        !AutopilotWorktrees.holdsBigFiles(item), !AutopilotDockerCache.isCache(item)
      {
        entry.needsOK = true
        entry.aiWhy = judgment.why
      }
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
    // Rules taught by a question read like its card, even rules taught with older words, and a keep
    // narrowed to some risks names them.
    let taught = AutopilotPolicy.questionsByID(memory.questions)
    result.rules =
      memory.rules.map { rule in
        guard let question = rule.questionID.flatMap({ taught[$0] }) else { return rule }
        var shown = rule
        shown.title = AutopilotPolicy.lessonTitle(rule, question: question)
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
    result.sweep = sweepState()
    result.receipts = Self.shownReceipts(receipts)
    result.coverageNotes = catalog?.coverageNotes ?? []
    result.observedAt = catalog?.observedAt
    result.lessons = AutopilotPolicy.lessonGroups(memory)
    result.progress = AutopilotPolicy.progress(
      memory, receipts: receipts, impact: try? store.impact(), now: now)
    result.tells = memory.tells.filter(\.waitsForOwner)
    result.actsOnItsOwn = memory.actsOnItsOwn
    result.neverTouch = memory.neverTouch
    result.keptPaths = memory.keptItems.filter { $0.hasPrefix("path:") }
      .map { String($0.dropFirst(5)) }.sorted()
    return result
  }

  /// Applies an operator command and returns the new snapshot.
  public func apply(_ command: AutopilotCommand, now: Date = Date()) async throws
    -> AutopilotSnapshot
  {
    guard !updateSuspended else {
      throw StoreError.message(
        "BurnZombies is finishing an app update. Try again after it restarts.")
    }
    switch command {
    case .answer(let id, let answer, let shown):
      try store.updateMemory { memory in
        // The open question with that id, which is the card the owner answered.
        guard let i = AutopilotPolicy.answering(id, in: memory.questions) else {
          throw StoreError.message("That question is no longer open.")
        }
        // A Yes or No stands. The same answer again (a double click) changes nothing, and any
        // other is refused: relearning would drop what its lesson took in from other answers.
        if let given = memory.questions[i].answer, given != .skip {
          guard given == answer else {
            throw StoreError.message("That question is already answered.")
          }
          return
        }
        memory.questions[i].answer = answer
        memory.questions[i].answered = now
        if answer == .skip {
          memory.questions[i].snoozedUntil = now.addingTimeInterval(86400)
        } else {
          // The risks the owner's card showed, when the app says: a look may have refreshed the
          // question since it was drawn, and an answer covers only what the owner saw. The lesson,
          // and what BZ counts as approved, follow them.
          if let shown { memory.questions[i].risks = Array(Set(shown)).sorted() }
          let q = memory.questions[i]
          // The guess BZ made before asking is checked against the answer, once (spec 3.2).
          if let guess = q.guess {
            AutopilotPolicy.score(q, guess: guess.answer, answer: answer, into: &memory, date: now)
          }
          let verdict: AutopilotVerdict = answer == .yes ? .burn : .keep
          // The answer teaches why, not which project: a general lesson, titled the same way. Memory
          // from before re-asked cards had ids of their own can hold a lesson under this id from an
          // older question: a Yes there gives way to this answer, and a No stays, so nothing the
          // owner said no to burns.
          memory.rules.removeAll { $0.questionID == q.id && $0.verdict == .burn }
          let taught: [AutopilotRule] = AutopilotPolicy.lessons(
            for: q, verdict: verdict, created: now, earlier: memory.questions)
          for lesson in taught { AutopilotPolicy.learn(lesson, into: &memory.rules) }
          // A lesson the new one took in brings its tally along.
          AutopilotPolicy.carryTallies(&memory)
        }
      }
      let acted = refreshQuestions(now: now, acting: burnsOnItsOwn())
      // Show the answer right away; matching items, and anything BZ just answered itself, burn in
      // the background.
      Task { await self.burnAuthorized(now: now, settling: acted) }
    case .allowRecoveryKey:
      // The owner's click, so macOS may ask now. What waited for the key burns right after.
      let sources = sources
      try await Task.detached { try sources.allowRecoveryKey() }.value
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
      let path = catalog?.items.first(where: { $0.id == id })?.path ?? AutopilotDockerCache.kept(id)
      try store.updateMemory { memory in
        memory.keptItems.insert(id)
        if let path { memory.keptItems.insert("path:" + path) }
      }
    case .unkeep(let id):
      // Both ways a keep can name it go, so nothing of the keep is left to hold it.
      let path = catalog?.items.first(where: { $0.id == id })?.path ?? AutopilotDockerCache.kept(id)
      try store.updateMemory { memory in
        memory.keptItems.remove(id)
        if let path { memory.keptItems.remove("path:" + path) }
      }
    case .restore(let receiptID):
      try await restore(receiptID: receiptID)
    case .forgetRule(let id):
      // Every answer the lesson was made from goes too, so those things can be asked again.
      try store.updateMemory { try AutopilotPolicy.forget([id], memory: &$0) }
    case .setStarter(let id, let enabled):
      try store.updateMemory { memory in
        if enabled { memory.starterDisabled.remove(id) } else { memory.starterDisabled.insert(id) }
      }
    case .setEnabled(let enabled):
      try store.updateSweep { $0.enabled = enabled }
    case .setLookOnly(let on):
      let enabled = try store.updateSweep { (sweep: inout AutopilotSweepState) -> Bool in
        sweep.lookOnly = on ? true : nil
        return sweep.enabled
      }
      // Turning burning on burns what's waiting right away, like an answer does.
      if !on && enabled { Task { await self.burnAuthorized(now: now) } }
    case .setInterval(let minutes):
      guard [5, 15, 30, 60, 240].contains(minutes) else {
        throw StoreError.message("Choose 5, 15, 30, 60 or 240 minutes.")
      }
      try store.updateSweep { $0.intervalMinutes = minutes }
    case .resetTraining:
      try store.updateMemory { memory in
        let kept = memory.keptItems
        let neverTouch = memory.neverTouch
        // Whether BZ may act on its own is the owner's setting, not something it learned.
        let acts = memory.actsOnItsOwn
        memory = AutopilotMemory()
        memory.keptItems = kept
        memory.neverTouch = neverTouch
        memory.actsOnItsOwn = acts
      }
      // Nothing is trusted after a reset, so there is nothing to act on.
      refreshQuestions(now: now, acting: false)
    case .sweepNow:
      try store.updateSweep { $0.requested = true }
      wake?()
    case .deepHunt(let limit):
      // Taken by the next tick, like "hunt now"; the running app wakes it at once. From the
      // command line it spends at most the Hunt window's top limit.
      try store.updateSweep {
        $0.requested = true
        $0.requestedDeep = min(HuntOptions.limits.max() ?? 15, max(HuntOptions.smallestRun, limit))
      }
      wake?()
    case .stopHunt:
      stopHunt()
    case .tellGood(let id):
      try store.updateMemory { try AutopilotPolicy.callGood(id, memory: &$0, now: now) }
    case .tellUndo(let id):
      try await undo(tell: id, now: now)
    case .tellSeen(let id):
      try store.updateMemory { try AutopilotPolicy.seen(id, memory: &$0) }
    case .setActsOnItsOwn(let acts):
      try store.updateMemory { $0.actsOnItsOwn = acts }
    case .forgetLesson(let ids):
      try store.updateMemory { try AutopilotPolicy.forget(ids, memory: &$0) }
    case .setLesson(let ids, let enabled):
      try store.updateMemory { memory in
        for i in memory.rules.indices where ids.contains(memory.rules[i].id) {
          memory.rules[i].enabled = enabled
        }
      }
      // Off, what it covered goes back to being unsure. On again, it burns like an answer does.
      let acted = refreshQuestions(now: now, acting: enabled && burnsOnItsOwn())
      if enabled { Task { await self.burnAuthorized(now: now, settling: acted) } }
    case .neverTouch(let path):
      let listed = WorkspaceSafety.canonical(path)
      try store.updateMemory { memory in
        memory.neverTouch = Array(Set(memory.neverTouch).union([listed])).sorted()
      }
      refreshQuestions(now: now, acting: false)
    case .allowTouch(let path):
      // Both ways a keep can name it go, as with Unspare.
      var ids = catalog?.items.filter { $0.path == path }.map(\.id) ?? []
      if path == AutopilotDockerCache.name { ids.append(AutopilotDockerCache.itemID) }
      try store.updateMemory { memory in
        memory.neverTouch.removeAll { $0 == path }
        memory.keptItems.remove("path:" + path)
        for id in ids { memory.keptItems.remove(id) }
      }
      refreshQuestions(now: now, acting: false)
    }
    return snapshot(now: now)
  }

  /// Brings an old copy back from its restore point. The owner keeps it from then on, and the burn
  /// counts as undone for the lesson that made it.
  func restore(receiptID: UUID) async throws {
    guard let receipt = try store.receipts().first(where: { $0.id == receiptID }),
      let backup = receipt.restore
    else { throw StoreError.message("There's nothing to restore for that one.") }
    try await Task.detached { [sources] in try sources.restoreWorktree(receipt) }.value
    var wasBurned = false
    try store.updateReceipts { all in
      if let i = all.firstIndex(where: { $0.id == receiptID }) {
        wasBurned = all[i].outcome == "burned"
        all[i].outcome = "restored"
        all[i].detail = "Restored at \(backup.path)."
        if !(all[i].bigFiles ?? []).isEmpty {
          all[i].detail += " Its big unsaved files didn't come back: they were deleted for good."
        }
      }
    }
    try store.updateMemoryAfterReceipts { memory, seeded in
      memory.keptItems.insert(receipt.itemID)
      memory.keptItems.insert("path:" + backup.path)
      // The burn already counted toward its lesson; restoring it only marks it undone. A
      // migration in this same read counted the restore from receipts.json already.
      if wasBurned && !seeded { AutopilotPolicy.undone(receipt, into: &memory) }
    }
  }

  /// Undo (spec 3.4), in an order that lets nothing burn after the owner's No. First, before
  /// anything comes back, the tell is undoing and the act's lesson is a keep, so no pass burns
  /// under it again; the owner's answer is No and BZ's guess scores wrong. Then any burn under the
  /// lesson already under way finishes, and every burn the lesson made comes back through the
  /// owner's own Restore where it can. The lesson and trust flip even when something can't come
  /// back, and what didn't is noted on the tell. An Undo cut short by a quit is picked up again by
  /// the next one.
  func undo(tell id: String, now: Date) async throws {
    guard !undoing.contains(id) else { throw StoreError.message(AutopilotPolicy.undoingNow) }
    undoing.insert(id)
    defer { undoing.remove(id) }
    let begun = try store.updateMemory { try AutopilotPolicy.beginUndo(id, memory: &$0, now: now) }
    guard let tell = begun else { return }
    let authority = "rule:" + tell.ruleID
    while burning.values.contains(authority) { try? await Task.sleep(nanoseconds: 50_000_000) }
    var failed = 0
    var reason: String?
    var missing = 0
    var withoutBigFiles = 0
    for receipt in AutopilotPolicy.burns(of: tell, receipts: try store.receipts()) {
      guard receipt.outcome == "burned", receipt.restore != nil else {
        missing += 1
        continue
      }
      do {
        try await restore(receiptID: receipt.id)
        if !(receipt.bigFiles ?? []).isEmpty { withoutBigFiles += 1 }
      } catch {
        failed += 1
        if reason == nil { reason = error.localizedDescription }
      }
    }
    // What didn't come back stays on the tell, in Teach BZ, until the owner has read it.
    let note: String? = AutopilotPolicy.undoNote(
      kind: tell.kind, failed: failed, reason: reason, missing: missing,
      withoutBigFiles: withoutBigFiles)
    try store.updateMemory { try AutopilotPolicy.finishUndo(id, note: note, memory: &$0) }
  }

  // MARK: AI reviewer surface

  public func catalogPage(status: String?, kind: String?, offset: Int, limit: Int)
    -> AutopilotCatalogPage
  {
    let now = Date()
    let snap = snapshot(now: now)
    let memory = memory()
    let refused = Self.standingRefusals(
      (try? store.receipts()) ?? [], now: now, keyWaits: sources.recoveryKeyWait() != nil)
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
    if snap.sweep.lookOnly == true { summary["lookOnly"] = "true" }
    return AutopilotCatalogPage(
      summary: summary, rules: snap.rules, lessons: AutopilotPolicy.catalogLessons(memory),
      openQuestions: snap.questions,
      answered: Array(
        memory.questions.filter { $0.answer == .yes || $0.answer == .no }.suffix(20)),
      items: page.map { entry in
        var why = entry.status == .unsure ? nil : entry.why
        // Authorized but refused for these same facts: burning it now only repeats the refusal.
        if entry.status == .burn, let authority = entry.authority,
          let refusal = refused[Self.refusalKey(entry.id, entry.item.revision, authority)]
        {
          why = Self.waiting(after: refusal, now: now)
        }
        return AutopilotCatalogItem(
          id: entry.id, kind: entry.item.kind, name: entry.item.name, detail: entry.item.detail,
          size: AutopilotPolicy.format(entry.item.bytes),
          facts: entry.item.facts.filter { $0.key != "kind" }, status: entry.status,
          authority: entry.authority, label: entry.label == entry.item.name ? nil : entry.label,
          why: why)
      },
      nextOffset: offset + page.count < entries.count ? offset + page.count : nil)
  }

  public func inspect(_ id: String, relativePath: String? = nil) -> [String: String] {
    guard let item = catalog?.items.first(where: { $0.id == id }) else {
      return ["error": "Unknown item. Read the catalog again."]
    }
    var result = relativePath.map { sources.evidence(item, $0) } ?? sources.inspect(item)
    result["id"] = item.id
    result["facts"] = item.facts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      .joined(separator: ", ")
    return result
  }

  /// Records AI judgments. Returns the ids that are now authorized to burn.
  public func decide(_ judgments: [AutopilotJudgment]) throws -> [String] {
    let acceptedAt = Date()
    let items = Dictionary(
      (catalog?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var accepted = [AutopilotJudgment]()
    for var judgment in judgments.prefix(200) {
      guard let item = items[judgment.itemID] else { continue }
      judgment.revision = item.revision
      judgment.confidence = min(1, max(0, judgment.confidence))
      judgment.label = String(judgment.label.prefix(120))
      judgment.why = String(judgment.why.prefix(400))
      judgment.date = acceptedAt
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

  /// Burns items the policy authorizes; everything else is refused with a reason. An item
  /// refused for the same facts and authority waits as it does for the native pass: the recorded
  /// reason comes back at once, without checking it again or adding a receipt or a log line.
  public func burn(_ ids: [String]) async -> [AutopilotReceipt] {
    var receipts = [AutopilotReceipt]()
    for id in ids.prefix(50) {
      guard let item = catalog?.items.first(where: { $0.id == id }) else {
        receipts.append(
          AutopilotReceipt(
            itemID: id, kind: .process, name: id, authority: "ai", outcome: "refused",
            detail: "Unknown item. Read the catalog again."))
        continue
      }
      let stored = (try? store.receipts()) ?? []
      if spent(stored).contains(id) {
        receipts.append(.refused(item, authority: "ai", "Already burned."))
        continue
      }
      if burning[id] != nil {
        receipts.append(.refused(item, authority: "ai", Self.alreadyBurning))
        continue
      }
      // Decided on memory as it is right before this burn, as in `burnAuthorized`: an Undo or an
      // answer that landed while an earlier burn waited on Git wins.
      let memory = memory()
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
      let now = Date()
      let key = Self.refusalKey(item.id, item.revision, authority)
      let keyWaits = sources.recoveryKeyWait() != nil
      if let refusal = Self.standingRefusals(stored, now: now, keyWaits: keyWaits)[key] {
        let reason = Self.waiting(after: refusal, now: now)
        receipts.append(.refused(item, authority: authority, reason))
        continue
      }
      receipts.append(await execute(item, authority: authority, why: why(item, decision, memory)))
    }
    return receipts
  }

  /// Opens a training question. Fails when three are open, unless it replaces one. The question
  /// keeps BZ's guess, with the AI's `guess` when it gives one (yes or no). When BZ is sure, the AI
  /// expects a yes too and BZ may act on its own, BZ answers it itself exactly as in
  /// `refreshQuestions` and returns the stored question, answered by BZ; what its lesson authorizes
  /// burns in the background.
  public func ask(
    _ question: AutopilotQuestion, replacing: String? = nil, guess: AutopilotAnswer? = nil
  ) throws -> AutopilotQuestion {
    let items = catalog?.items ?? []
    guard
      !AutopilotDockerCache.about(question.match),
      question.match[AutopilotDockerCache.risk] == nil
    else { throw StoreError.message("Docker's build cache is the owner's call. BZ asks them itself.") }
    guard !question.match.values.contains(where: { $0.contains("unknown") }) else {
      throw StoreError.message(
        "Leave out facts I haven't checked yet (\"unknown\"): an answer about them stops applying once they are checked."
      )
    }
    guard !AutopilotPolicy.everyUnknownProgram(question.kind, question.match) else {
      throw StoreError.message(
        "Name the program (fact `program`) when asking about programs of family \"other\": they share nothing else, so a Yes would reach every program I don't know."
      )
    }
    let now = Date()
    let acting = burnsOnItsOwn()
    var acted: String?
    let stored = try store.updateMemory { memory -> AutopilotQuestion in
      if let replacing {
        memory.questions.removeAll { $0.id == replacing && $0.isOpen }
      }
      // The AI rewording a pattern BZ already asked natively improves that question. A native
      // question's id also names its card's risks, so that the same pattern asked again for new
      // risks is a question of its own; it is found by its exact pattern instead.
      if let i = memory.questions.firstIndex(where: { open in
        guard open.isOpen, open.source == "native", open.kind == question.kind else { return false }
        return open.match == question.match
      }) {
        memory.questions[i].question = question.question
        if !question.why.isEmpty { memory.questions[i].why = question.why }
        if !question.examples.isEmpty { memory.questions[i].examples = question.examples }
        memory.questions[i].source = "ai"
        if guess != nil {
          memory.questions[i].guess = AutopilotPolicy.guess(memory.questions[i].guess, ai: guess)
        }
        return memory.questions[i]
      }
      guard !memory.questions.contains(where: { $0.id == question.id }) else {
        throw StoreError.message("That pattern was already asked.")
      }
      // One question per subject at a time, the same as BZ's own: the AI may reword or replace
      // the open one but not add a second one, nor ask again the day the owner skipped one.
      let subject = AutopilotPolicy.subject(question.kind, question.match)
      if AutopilotPolicy.busySubjects(memory, now: Date()).contains(subject) {
        let noun = AutopilotPolicy.subjectNoun(question.kind, question.match)
        throw StoreError.message(
          memory.openQuestions.contains { AutopilotPolicy.subject($0.kind, $0.match) == subject }
            ? "I'm already asking about \(noun). To improve that question, ask with `replace`."
            : "The owner skipped a question about \(noun) today. Ask about them again tomorrow.")
      }
      let unsure = items.filter { AutopilotPolicy.decide($0, memory: memory).status == .unsure }
      func covered(_ kind: AutopilotKind, _ match: [String: [String]]) -> Set<String> {
        let rule = AutopilotPolicy.coverage(kind, match)
        return Set(unsure.filter { AutopilotPolicy.matches(rule, $0) }.map(\.id))
      }
      let asked = covered(question.kind, question.match)
      let open = memory.questions.filter(\.isOpen).reduce(into: Set<String>()) {
        $0.formUnion(covered($1.kind, $1.match))
      }
      guard Double(asked.intersection(open).count) < Double(max(1, asked.count)) * 0.5 else {
        throw StoreError.message(
          "I'm already asking about most of these. To improve that question's words, ask with its exact match."
        )
      }
      guard memory.openQuestions.count < AutopilotPolicy.maximumOpenQuestions else {
        throw StoreError.message(
          "Three questions are already open. Replace one with `replace` or wait for answers.")
      }
      let rule = AutopilotPolicy.coverage(question.kind, question.match)
      let matching = unsure.filter { AutopilotPolicy.matches(rule, $0) }
      guard !matching.isEmpty else {
        throw StoreError.message("No unsure items match that pattern.")
      }
      let bytes = matching.reduce(0) { $0 + $1.bytes }
      guard bytes >= AutopilotPolicy.worthAsking else {
        throw StoreError.message(
          "That pattern frees only \(AutopilotPolicy.format(bytes)). Ask only about patterns freeing 1 GB or more."
        )
      }
      guard AutopilotPolicy.quiet(question.kind, question.match) else {
        throw StoreError.message(
          "Say how long they sat unused, and never ask about things used today or busy right now: a yes would also cover things still being worked on."
        )
      }
      var q = question
      q.count = matching.count
      q.bytes = bytes
      q.cautions = AutopilotPolicy.mix(question.kind, matching)
      AutopilotPolicy.describe(&q, covering: matching)
      if q.examples.isEmpty {
        q.examples = Array(matching.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name))
      }
      q.source = "ai"
      let own = AutopilotPolicy.guess(q, memory: memory, reaching: unsure)
      q.guess = AutopilotPolicy.guess(own, ai: guess)
      if acting, memory.actsOnItsOwn, let sure = q.guess, sure.sure {
        let made = AutopilotPolicy.act(q, guess: sure, memory: &memory, at: Date())
        acted = made.tell.id
        return made.question
      }
      memory.questions.append(q)
      return q
    }
    // What BZ answered itself burns in the background, as after an owner's Yes.
    if let acted { Task { await self.burnAuthorized(now: now, settling: [acted]) } }
    return stored
  }

  public func report(_ text: String) throws {
    try store.updateSweep { $0.append(String(text.prefix(500))) }
  }

  public func sweepState() -> AutopilotSweepState {
    if let state = try? store.sweep(), (try? store.memory()) != nil, (try? store.receipts()) != nil
    {
      return state
    }
    var held = AutopilotSweepState()
    held.enabled = false
    held.lookOnly = true
    held.lastError =
      "Saved permissions could not be read. Cleanup is paused; preserve and repair the state."
    return held
  }
  public func updateSweep(_ change: @Sendable (inout AutopilotSweepState) -> Void) {
    try? store.updateSweep { change(&$0) }
  }
}

/// What the AI hears when BZ answers its question itself: JSON like every other reply, saying that
/// BZ acted, in a sentence.
struct AutopilotActedReply: Codable, Sendable {
  var acted: Bool
  var message: String
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
  /// The owner's lessons as Settings shows them: each sentence, with what it rests on and did.
  public var lessons: [String]
  /// How I'm doing, line for line as Settings says it.
  public var progress: [String]
  public var enabled: Bool
  public var lookOnly: Bool
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
    lessons = s.lessons.map { "\($0.sentence) (\($0.evidence))" }
    progress = s.progress.lines
    enabled = s.sweep.enabled
    lookOnly = s.sweep.lookOnly == true
    intervalMinutes = s.sweep.intervalMinutes
    lastTick = s.sweep.lastTick
    lastAISweep = s.sweep.lastAISweep
    retryAfter = s.sweep.retryAfter
    lastError = s.sweep.lastError
    log = s.sweep.log.suffix(10).map(\.message)
    recent = s.receipts.prefix(20).map { "\($0.name): \($0.outcome) (\($0.authority))" }
    notes = s.coverageNotes
    if s.recoveryKey != nil { notes.append(Autopilot.keyWaitNote) }
  }
}

/// One autopilot call from the MCP server or CLI.
public struct AutopilotRequest: Codable, Sendable {
  /// `catalog`, `inspect`, `decide`, `burn`, `ask`, `report`, `snapshot`, `eval` or `command`.
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
  public var relativePath: String?
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
  /// What the AI thinks the owner will answer: "yes" or "no". Anything else is ignored.
  public var guess: String?
  public init(kind: AutopilotKind, match: [String: [String]], question: String) {
    self.kind = kind
    self.match = match
    self.question = question
  }
}

extension Autopilot {
  /// Dispatches one request and returns `(ok, json)`. During a hunt, what the AI did with it
  /// shows in the Hunt window's feed and counters.
  public func handle(_ request: AutopilotRequest) async -> (Bool, String) {
    let reply = await respond(request)
    if hunt != nil { recordTool(request, ok: reply.0, reply: reply.1) }
    return reply
  }

  func respond(_ request: AutopilotRequest) async -> (Bool, String) {
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
        return (true, encode(inspect(id, relativePath: request.relativePath)))
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
        return (
          true,
          encode([
            "recorded": String(inputs.count), "authorized": authorized.joined(separator: ","),
          ])
        )
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
        // Only yes or no is a guess; anything else is ignored rather than refused.
        let said: String = input.guess?.lowercased() ?? ""
        let guess: AutopilotAnswer? = said == "yes" ? .yes : (said == "no" ? .no : nil)
        q = try ask(q, replacing: request.replace, guess: guess)
        if q.answeredBy == "bz" {
          let sentence = "I was sure you'd say yes, so I burned them and will tell the owner."
          return (true, encode(AutopilotActedReply(acted: true, message: sentence)))
        }
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
      case "eval":
        // `burnzombies autopilot eval`: the replay of the owner's answers, read without a tick.
        // Memory that can't be read is an error, not a replay of nothing.
        let questions = try store.memory().questions
        return (true, encode(AutopilotEval.replay(questions)))
      case "command":
        guard let command = request.command else { return failure("Pass command.") }
        // Only the owner's click in the app makes macOS ask about the backup key.
        if command == .allowRecoveryKey { return failure(Self.ownerAllowsKey) }
        return (true, encode(AutopilotSummary(try await apply(command))))
      default:
        return failure("Unknown autopilot tool.")
      }
    } catch {
      return failure(error.localizedDescription)
    }
  }

  /// Look-only from setup or the installer. A running app takes the change itself, so its next
  /// tick can't write over it; with no app running it goes straight to the state folder.
  public static func setLookOnly(_ on: Bool, root: URL = Store.defaultRoot) throws {
    guard AgentConnection.isAvailable(root: root) else {
      try AutopilotStore(root: root).updateSweep { $0.lookOnly = on ? true : nil }
      return
    }
    var request = AutopilotRequest(tool: "command")
    request.command = .setLookOnly(on)
    let body = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    let raw = try AgentConnection.call(AgentRequest("autopilot", payload: body), root: root)
    let reply = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    guard reply?["ok"] as? Bool == true else {
      throw StoreError.message(
        "BurnZombies is running but didn't take the change. Use Settings → Autopilot instead.")
    }
  }
}
