import Foundation

/// The Hunt window's live record of a hunt: what the AI read, judged, burned and asked, as it
/// happens, and what it spent. Presentation only: nothing here authorizes a burn.
extension Autopilot {
  /// Programs this small are looked at too in a deep hunt: a swarm of leftovers adds up.
  public static let deepProgramFloor: UInt64 = 20_000_000

  /// Starts recording `snapshot` as the hunt under way, with the AI run Stop ends. A deep hunt
  /// looks at small programs from the next look on.
  public func beginHunt(_ snapshot: HuntSnapshot, run: AutopilotRun? = nil) {
    hunt = snapshot
    huntRun = run
    huntJudged = [:]
    huntSpentBefore = snapshot.spentUSD ?? 0
    huntTokensBefore = snapshot.tokens ?? 0
    programFloor = snapshot.deep == true ? Self.deepProgramFloor : nil
    saveHunt()
  }

  /// The hunt under way, if any.
  public func currentHunt() -> HuntSnapshot? { hunt }

  /// What the running app does when the command line asks for a hunt: tick now.
  public func onRequest(_ wake: @escaping @Sendable () -> Void) { self.wake = wake }

  /// Counts what the last look saw and what waits for the AI, by kind. Returns how many things
  /// the AI has to judge. A deep hunt's second look at what the AI kept before is extra: it isn't
  /// counted as waiting, so a hunt that judged everything reads as done.
  @discardableResult public func startLanes() -> Int {
    guard var current = hunt else { return 0 }
    let entries = snapshot().entries
    var total = 0
    for kind in AutopilotKind.allCases {
      let mine = entries.filter { $0.item.kind == kind }
      let waiting = mine.filter { $0.status == .unsure }.count
      total += waiting
      let looked = seen[kind] ?? mine.count
      current.update(lane: kind.rawValue) {
        $0.seen = looked
        // Going on with a stopped hunt keeps what it judged already.
        $0.toJudge = $0.judged + waiting
      }
    }
    current.processCount = seen[.process] ?? 0
    hunt = current
    saveHunt()
    return total
  }

  /// What a look found, as it finds it: the lane's count, and on the hunt's first look a line.
  func looked(_ kind: AutopilotKind, _ count: Int) {
    guard hunt != nil else { return }
    // Only the hunt's first look says so: a later one, such as the closing look, only counts.
    let first = hunt?.lanes?.contains { $0.kind == kind.rawValue } != true
    hunt?.update(lane: kind.rawValue) { $0.seen = count }
    if kind == .process { hunt?.processCount = count }
    guard first, count > 0 else {
      saveHunt()
      return
    }
    let line: String
    switch kind {
    case .process:
      line = "Looked over \(count.formatted()) running program\(count == 1 ? "" : "s")."
    case .worktree:
      line = "Looked over \(count.formatted()) project cop\(count == 1 ? "y" : "ies")."
    case .disk:
      line = "Measured \(count.formatted()) junk folder\(count == 1 ? "" : "s")."
    }
    noteHunt("scanning", line)
  }

  /// Adds a line to the hunt's feed.
  public func noteHunt(_ kind: String, _ message: String) {
    guard hunt != nil else { return }
    hunt?.append(kind, message)
    saveHunt()
  }

  /// Ends the hunt's AI run. What it burned stays burned; the coordinator finishes the hunt.
  @discardableResult public func stopHunt() -> Bool {
    guard let run = huntRun, run.stopReason == nil else { return false }
    run.stop()
    noteHunt("stopped", "Stopping. Everything I burned stays burned.")
    return true
  }

  /// What this run of the hunt spent so far: the whole hunt's, less what came before it.
  public func runSpentUSD() -> Double? {
    hunt?.spentUSD.map { $0 - huntSpentBefore }
  }

  /// What the AI's streamed run said or spent.
  public func huntEvent(_ event: AutopilotStreamEvent) {
    guard var current = hunt else { return }
    switch event {
    case .text(let words):
      let line = Self.narration(words)
      guard !line.isEmpty else { return }
      current.append("thinking", line)
    case .spend(let tokens, let usd):
      current.tokens = huntTokensBefore + tokens
      if let usd { current.spentUSD = huntSpentBefore + usd }
    case .result(let usd, _, _):
      if let usd { current.spentUSD = huntSpentBefore + usd }
    }
    hunt = current
    saveHunt()
  }

  /// What the AI did with one tool call, as a feed line and the counters it moves.
  func recordTool(_ request: AutopilotRequest, ok: Bool, reply: String) {
    guard ok, hunt != nil else { return }
    let items = Dictionary(
      (catalog?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    switch request.tool {
    case "catalog":
      // Paging on through the same list says nothing new.
      guard (request.offset ?? 0) == 0 else { return }
      let page = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
      let summary = page?["summary"] as? [String: String]
      let count = Int(summary?["totalItems"] ?? "") ?? 0
      let what: String
      switch request.status {
      case "unsure"?: what = count == 1 ? "thing I'm unsure about" : "things I'm unsure about"
      case "keep"?: what = count == 1 ? "thing kept before" : "things kept before"
      default: what = count == 1 ? "thing" : "things"
      }
      hunt?.focus = "Reading the list"
      noteHunt("scanning", "Reading \(count.formatted()) \(what), biggest first.")
    case "inspect":
      guard let id = request.id, let item = items[id] else { return }
      hunt?.focus = Self.focus(item)
      noteHunt(
        "scanning", "Looking closely at \(item.name), \(AutopilotPolicy.format(item.bytes)).")
    case "decide":
      let judgments = request.judgments ?? []
      var burn = 0
      var keep = 0
      var unsure = 0
      for judgment in judgments {
        guard let item = items[judgment.id] else { continue }
        judged(item)
        switch judgment.verdict {
        case .burn: burn += 1
        case .keep: keep += 1
        case .unsure: unsure += 1
        }
      }
      guard burn + keep + unsure > 0 else { return }
      var parts = [String]()
      if burn > 0 { parts.append("\(burn) to burn") }
      if keep > 0 { parts.append("\(keep) to keep") }
      if unsure > 0 { parts.append("\(unsure) unsure") }
      if let last = judgments.last(where: { items[$0.id] != nil }), let item = items[last.id] {
        let label = last.label.trimmingCharacters(in: .whitespacesAndNewlines)
        hunt?.focus =
          label.isEmpty ? Self.focus(item) : label + " · " + AutopilotPolicy.format(item.bytes)
      }
      noteHunt(
        burn > 0 ? "detected" : "scanning",
        "Judged \(burn + keep + unsure): " + parts.joined(separator: ", ") + ".")
    case "burn":
      // Each burn writes its own line as it happens; here it only counts as looked at.
      for id in request.ids ?? [] { if let item = items[id] { judged(item) } }
      saveHunt()
    case "ask":
      guard let text = request.question?.question else { return }
      if reply.contains("\"acted\":true") {
        noteHunt("info", "I was sure you'd say yes to “\(text)” so I burned them myself.")
      } else {
        noteHunt("ask", "Needs you: " + text)
      }
    case "report":
      let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { noteHunt("info", text) }
    default:
      break
    }
  }

  /// Counts an item as judged during this hunt, once.
  func judged(_ item: AutopilotItem) {
    guard hunt != nil, huntJudged[item.kind, default: []].insert(item.id).inserted else { return }
    hunt?.update(lane: item.kind.rawValue) { $0.judged += 1 }
  }

  /// Every burn passes `execute`: during a hunt it shows at once, whoever authorized it.
  func recordBurn(_ receipt: AutopilotReceipt, item: AutopilotItem) {
    guard var current = hunt else { return }
    if receipt.outcome == "refused" {
      // A look-only hold and a second burn of the same thing say nothing new.
      guard receipt.detail != Self.lookOnlyHold, receipt.detail != Self.alreadyBurning else {
        return
      }
      current.append("warning", "Skipped \(item.name): \(receipt.detail)")
    } else {
      current.update(lane: item.kind.rawValue) {
        $0.burned += 1
        $0.bytes += receipt.bytes
      }
      current.burned += 1
      switch item.kind {
      case .process: current.memoryReclaimed += receipt.bytes
      case .worktree:
        current.worktreesCleaned += 1
        current.diskReclaimed += receipt.bytes
      case .disk: current.diskReclaimed += receipt.bytes
      }
      current.append(
        "burn", "Burned \(item.name). " + Self.back(item.kind, receipt.bytes),
        id: "receipt-" + receipt.id.uuidString)
    }
    hunt = current
    saveHunt()
  }

  /// Ends the record: totals come from the receipts themselves, so a program that didn't stop
  /// doesn't count. `stopReason` is `stopped` or `limit` for a hunt that ended early.
  public func finishHunt(
    now: Date = Date(), failure: String?, stopReason: String?, questions: Int, interval: Int
  ) {
    guard var current = hunt else { return }
    let receipts = ((try? store.receipts()) ?? []).filter { $0.date >= current.startedAt }
    Self.reconcile(&current, receipts: receipts)
    for failed in receipts where failed.outcome == "failed" {
      let id = "failed-" + failed.id.uuidString
      guard !current.log.contains(where: { $0.id == id }) else { continue }
      current.append("warning", "Couldn't burn \(failed.name): \(failed.detail)", id: id)
    }
    if let failure { current.append("warning", failure + " I'll retry later.", date: now) }
    if questions > 0 {
      current.append(
        "ask",
        questions == 1
          ? "1 question waits for you. A yes burns them right away."
          : "\(questions) questions wait for you. A yes burns them right away.", date: now)
    }
    current.focus = nil
    current.finishedAt = now
    current.stopReason = stopReason
    current.phase = stopReason == nil ? "completed" : "stopped"
    let total = current.memoryReclaimed + current.diskReclaimed
    let freed = AutopilotPolicy.format(total)
    let spent = current.deep == true ? current.spentUSD.map(HuntOptions.dollars) : nil
    let cost = spent.map { " for \($0) of AI" } ?? ""
    let only = spent.map { " It spent \($0) of AI." } ?? ""
    switch stopReason {
    case "limit"?:
      let limit = HuntOptions.dollars(current.limitUSD ?? 0)
      current.detail =
        total > 0
        ? "Reached your \(limit) limit. Everything burned stays burned: \(freed) freed\(cost)."
        : "Reached your \(limit) limit before anything was safe to burn."
    case "stopped"?:
      current.detail =
        total > 0
        ? "Stopped. Everything burned stays burned: \(freed) freed\(cost)."
        : "Stopped before anything burned." + only
    default:
      if current.deep == true {
        current.detail =
          total > 0
          ? "Deep hunt complete: \(freed) freed\(cost)."
          : "Deep hunt complete: nothing was safe to burn." + only
      } else {
        current.detail = "Hunt complete. I'll keep sweeping every \(interval) minutes."
      }
    }
    current.append(stopReason == nil ? "complete" : "stopped", current.detail, date: now)
    hunt = current
    saveHunt()
    hunt = nil
    huntRun = nil
    huntJudged = [:]
    programFloor = nil
  }

  /// What burned during a hunt, from its receipts: burned, or asked to stop and not failed since.
  static func reconcile(_ hunt: inout HuntSnapshot, receipts: [AutopilotReceipt]) {
    let kept = receipts.filter { $0.outcome == "burned" || $0.outcome == "verifying" }
    hunt.burned = kept.count
    hunt.memoryReclaimed = kept.filter { $0.kind == .process }.reduce(0) { $0 + $1.bytes }
    hunt.diskReclaimed = kept.filter { $0.kind != .process }.reduce(0) { $0 + $1.bytes }
    hunt.worktreesCleaned = kept.filter { $0.kind == .worktree }.count
    for kind in AutopilotKind.allCases {
      let mine = kept.filter { $0.kind == kind }
      hunt.update(lane: kind.rawValue) {
        $0.burned = mine.count
        $0.bytes = mine.reduce(0) { $0 + $1.bytes }
      }
    }
  }

  func saveHunt() {
    guard let hunt, let huntStore else { return }
    try? hunt.save(huntStore)
  }

  /// What the hunt is looking at: a name BZ built and a size, never a command line.
  static func focus(_ item: AutopilotItem) -> String {
    item.name + " · " + AutopilotPolicy.format(item.bytes)
  }

  static func back(_ kind: AutopilotKind, _ bytes: UInt64) -> String {
    let size = AutopilotPolicy.format(bytes)
    switch kind {
    case .process: return "\(size) of memory back."
    case .worktree: return "Restore point saved. \(size) back."
    case .disk: return "\(size) back."
    }
  }

  /// The AI's words as one short feed line: its first sentences, without Markdown.
  static func narration(_ words: String) -> String {
    let flat =
      words.split(whereSeparator: \.isNewline)
      .map { line -> String in
        var text = line.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "#-*>".contains(first) { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespaces)
      }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "`", with: "")
    guard flat.count > 220 else { return flat }
    let cut = flat.prefix(220)
    if let end = cut.lastIndex(where: { ".!?".contains($0) }),
      cut.distance(from: cut.startIndex, to: end) > 60
    {
      return String(cut[...end])
    }
    return cut.trimmingCharacters(in: .whitespaces) + "…"
  }
}

extension HuntOptions {
  /// "$5" for whole dollars, "$1.20" otherwise.
  public static func dollars(_ value: Double) -> String {
    let cents = (value * 100).rounded()
    return cents.truncatingRemainder(dividingBy: 100) == 0
      ? "$" + String(Int(cents / 100)) : String(format: "$%.2f", cents / 100)
  }
}
