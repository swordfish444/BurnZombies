import AppKit
import BurnCore
import SwiftUI

/// Colors for the Autopilot surfaces. Statuses use the traffic-light meaning a child already knows.
enum AutopilotTheme {
  static let green = Color(red: 0.36, green: 0.80, blue: 0.42)
  static let yellow = Color(red: 1.0, green: 0.78, blue: 0.22)
  static let red = Color(red: 1.0, green: 0.40, blue: 0.36)
  static let blue = Color(red: 0.45, green: 0.72, blue: 1.0)
  /// Opaque on purpose: offscreen renders and OCR must never see a transparent background.
  static let window = Color(red: 0.073, green: 0.074, blue: 0.070)
}

/// Plain names, emoji and colors for the kinds and statuses BZ shows.
enum AutopilotLook {
  static func pill(_ status: AutopilotStatus) -> String {
    switch status {
    case .burn: return "Will burn"
    case .unsure: return "Needs you"
    case .keep: return "Keeping"
    case .burned: return "Burned"
    case .protected: return "Protected"
    case .failed: return "Couldn't burn"
    }
  }
  static func color(_ status: AutopilotStatus) -> Color {
    switch status {
    case .burn: return BurnTheme.orange
    case .unsure: return AutopilotTheme.yellow
    case .keep: return AutopilotTheme.green
    case .burned: return AutopilotTheme.blue
    case .protected: return BurnTheme.muted
    case .failed: return AutopilotTheme.red
    }
  }
  static func emoji(_ kind: AutopilotKind) -> String {
    switch kind {
    case .process: return "🧟"
    case .worktree: return "📁"
    case .disk: return "🗑️"
    }
  }
  static func sectionTitle(_ kind: AutopilotKind) -> String {
    switch kind {
    case .process: return "Leftover programs"
    case .worktree: return "Old project copies"
    case .disk: return "Junk folders"
    }
  }
}

/// Every sentence the Autopilot windows build from numbers. Pure, so a proof can check them.
enum AutopilotText {
  static func number(_ n: Int) -> String { n.formatted() }
  static func things(_ n: Int) -> String { n == 1 ? "1 thing" : "\(n.formatted()) things" }
  static func size(_ bytes: UInt64) -> String { bytes == 0 ? "—" : AutopilotPolicy.format(bytes) }
  static func questions(_ n: Int) -> String { "BZ has \(n) quick question" + (n == 1 ? "" : "s") }

  /// "I found 1,014 things. I'll burn 812 on my own, I'm keeping 199, and I need your help with 3."
  static func summary(_ snapshot: AutopilotSnapshot) -> String {
    let burn = snapshot.count(.burn)
    let keeping = snapshot.count(.keep) + snapshot.count(.protected)
    let help = snapshot.count(.unsure) + snapshot.count(.failed)
    let found = burn + keeping + help
    guard found > 0 else {
      let done = snapshot.count(.burned)
      return done > 0
        ? "Everything is taken care of. I've burned \(things(done)) so far."
        : "I haven't found anything yet."
    }
    var clauses = [String]()
    if burn > 0 {
      clauses.append(
        snapshot.sweep.lookOnly == true
          ? "I'd burn \(number(burn)) once you start burning" : "I'll burn \(number(burn)) on my own")
    }
    if keeping > 0 { clauses.append("I'm keeping \(number(keeping))") }
    clauses.append(help > 0 ? "I need your help with \(number(help))" : "nothing needs your help")
    return "I found \(things(found)). " + sentence(clauses) + "."
  }
  static func sentence(_ clauses: [String]) -> String {
    switch clauses.count {
    case 0: return ""
    case 1: return clauses[0]
    case 2: return clauses[0] + " and " + clauses[1]
    default:
      return clauses.dropLast().joined(separator: ", ") + ", and " + clauses[clauses.count - 1]
    }
  }

  /// "next sweep in 12 min", "retrying at 3:40 PM", or nil when Autopilot is off.
  static func nextSweep(_ sweep: AutopilotSweepState, now: Date) -> String? {
    guard sweep.enabled else { return nil }
    if let retry = sweep.retryAfter, retry > now {
      return "retrying at " + retry.formatted(date: .omitted, time: .shortened)
    }
    if sweep.running { return "sweeping now" }
    guard let last = sweep.lastTick else { return "first sweep soon" }
    let next = last.addingTimeInterval(Double(max(1, sweep.intervalMinutes)) * 60)
    let minutes = Int((next.timeIntervalSince(now) / 60).rounded(.up))
    if minutes <= 0 { return "next sweep any moment" }
    if minutes < 90 { return "next sweep in \(minutes) min" }
    return "next sweep in \(Int((Double(minutes) / 60).rounded())) hr"
  }
  /// "Sunday 2 PM", "2:30 PM" today, or "Nov 20" a week or more away.
  static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    let time = date.formatted(
      calendar.component(.minute, from: date) == 0
        ? .dateTime.hour() : .dateTime.hour().minute())
    if calendar.isDate(date, inSameDayAs: now) { return time }
    guard date.timeIntervalSince(now) < 6 * 86_400 else {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.weekday(.wide)) + " " + time
  }
  /// When the AI is back, while it's waiting.
  static func aiBack(_ sweep: AutopilotSweepState, now: Date) -> String? {
    guard let retry = sweep.retryAfter, retry > now else { return nil }
    return when(sweep.limitResetsAt ?? retry, now: now)
  }
  /// One plain sentence while the AI can't help, for the top of Settings. Nil when all is well.
  static func aiProblem(_ sweep: AutopilotSweepState, harness: String?, now: Date) -> String? {
    guard sweep.enabled, let back = aiBack(sweep, now: now) else { return nil }
    let name = harness == "codex" ? "Codex" : "Claude"
    if let limit = sweep.limitResetsAt, limit > now {
      return "AI is out of \(name) usage until \(back). Your rules still burn."
    }
    if sweep.lastError.map(AutopilotSweeper.accountProblem) == true {
      return "AI needs a \(name) login or more usage. Trying again \(back). Your rules still burn."
    }
    return "AI hit a snag. Trying again \(back). Your rules still burn."
  }
  /// What a notification says when BZ has questions nobody was told about yet.
  static func questionAlert(_ open: [AutopilotQuestion], told: Set<String>)
    -> (title: String, body: String)?
  {
    guard open.contains(where: { !told.contains($0.id) }) else { return nil }
    let total = open.reduce(UInt64(0)) { $0 + $1.bytes }
    let title = open.count == 1 ? "BZ has a question" : "BZ has \(open.count) questions"
    return (title, "Answer to free " + AutopilotPolicy.format(total) + ".")
  }
  /// The menu line: "Autopilot on · next sweep in 12 min", "Look-only · next sweep in 12 min",
  /// "Autopilot off", or the paused form.
  static func sweepLine(_ sweep: AutopilotSweepState, now: Date) -> String {
    guard sweep.enabled else { return "Autopilot off" }
    let mode = sweep.lookOnly == true ? "Look-only" : "Autopilot on"
    guard let next = nextSweep(sweep, now: now) else { return mode }
    // Only the AI waits; rules keep burning.
    if next.hasPrefix("retrying"), let back = aiBack(sweep, now: now) {
      return mode + " · AI back " + back
    }
    return mode + " · " + next
  }
  static func lastSweep(_ sweep: AutopilotSweepState, now: Date) -> String {
    guard let last = sweep.lastTick else { return "No sweep yet" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Last sweep " + formatter.localizedString(for: last, relativeTo: now)
  }
  /// Findings subtitle: the sweep line plus what has already been burned.
  static func subtitle(_ snapshot: AutopilotSnapshot, now: Date) -> String {
    var parts = [sweepLine(snapshot.sweep, now: now)]
    let burned = snapshot.count(.burned)
    if burned > 0 {
      var text = "Burned so far: \(number(burned))"
      let freed = snapshot.bytes[AutopilotStatus.burned.rawValue] ?? 0
      if freed > 0 { text += ", freed \(AutopilotPolicy.format(freed))" }
      parts.append(text)
    }
    return parts.joined(separator: " · ")
  }
  // MARK: Tells: what BZ did on its own

  /// What a tell calls the things BZ burned: "copy" and "copies", "program" and "programs",
  /// "folder" and "folders".
  static func noun(_ kind: AutopilotKind, count: Int) -> String {
    switch kind {
    case .worktree: return count == 1 ? "copy" : "copies"
    case .process: return count == 1 ? "program" : "programs"
    case .disk: return count == 1 ? "folder" : "folders"
    }
  }
  /// "Burned 3 copies on my own."
  static func tellHeadline(_ tell: AutopilotTell) -> String {
    let things: String = noun(tell.kind, count: tell.count)
    return "Burned \(tell.count) \(things) on my own."
  }
  /// How much it was, the way a question card says what it frees: "Freed 2.4 GB" for copies and
  /// folders, "412 MB of memory" for programs.
  static func tellSize(_ tell: AutopilotTell) -> String {
    let size: String = AutopilotPolicy.roughly(tell.bytes)
    return tell.kind == .process ? "\(size) of memory" : "Freed \(size)"
  }
  static let tellWhyPrefix = "You'd have said yes: "
  /// "You'd have said yes: you said yes to 6 like these." The reason's first letter drops to lower
  /// case when it starts with "You", so the two read as one sentence; a reason like "I think
  /// you'll say yes." keeps its capital I.
  static func tellWhy(_ tell: AutopilotTell) -> String {
    var reason: String = tell.why
    if reason.hasPrefix("You ") {
      let first: String = reason.prefix(1).lowercased()
      let rest: String = String(reason.dropFirst())
      reason = first + rest
    }
    return tellWhyPrefix + reason
  }
  /// The line a tell for programs or folders gives before any Undo, because Undo can't bring them
  /// back. Copies come back, so theirs has none.
  static func tellCantComeBack(_ kind: AutopilotKind) -> String? {
    switch kind {
    case .worktree: return nil
    case .process: return "Stopped programs can't be restarted by me; I'll ask next time."
    case .disk: return "Your tools rebuild deleted folders; I'll ask next time."
    }
  }
  /// The second button: Undo for copies, which can be brought back. For programs and folders it is
  /// the owner's real answer, because nothing comes back.
  static func tellUndoLabel(_ kind: AutopilotKind) -> String {
    kind == .worktree ? "Undo" : "I'd have said no"
  }
  /// Shown in place of the reason while copies are coming back.
  static let undoingLine = "Bringing them back…"
  /// Shown in place of the reason while that button's work is under way: copies are coming back;
  /// for programs and folders there is nothing to bring back, so it says what BZ does next time.
  static func tellWorking(_ kind: AutopilotKind) -> String {
    kind == .worktree ? undoingLine : "Got it. I'll ask next time."
  }
  /// Shown for a tell the engine still lists as undoing after a quit, whose button is there to
  /// finish it.
  static func tellStalled(_ kind: AutopilotKind) -> String {
    if kind == .worktree { return "Undo didn't finish. Tap Undo to bring them back." }
    return "That didn't finish. Tap I'd have said no to finish it."
  }
  /// How many more than its rows it burned.
  static func tellMore(_ tell: AutopilotTell) -> Int { max(0, tell.count - tell.rows.count) }
  /// Shown on an undone tell above what the Undo left the owner to read.
  static let tellUndoneLine = "Undo finished."
  /// A tell worth showing: still open, being undone, or undone with a note the owner hasn't pressed
  /// OK on, and it burned something. When every burn in its act was refused it burned nothing and
  /// says nothing.
  static func shows(_ tell: AutopilotTell) -> Bool {
    (tell.isOpen || tell.state == "undoing" || tell.waitsForOK) && tell.count > 0
  }
  /// The prompt in the menu while tells wait: "BZ burned 3 things on its own".
  static func burnedOnItsOwn(_ tells: [AutopilotTell]) -> String {
    var count: Int = 0
    for tell in tells { count += tell.count }
    return "BZ burned \(things(count)) on its own"
  }
  /// The tell's rows, worded by the same function a question card's rows are. A program says how
  /// long it sat idle when BZ stopped it, which stays true as time passes. A copy or folder says
  /// "used Oct 26" or "used yesterday 5 pm", so a date beside a burned thing isn't read as the day
  /// it was burned.
  static func tellRows(_ tell: AutopilotTell, now: Date, calendar: Calendar) -> [AutopilotCardRow] {
    let at: Date = tell.kind == .process ? tell.date : now
    let rows: [AutopilotCardRow] = AutopilotPolicy.cardRows(
      tell.rows, kind: tell.kind, now: at, calendar: calendar)
    guard tell.kind != .process else { return rows }
    return rows.map { (row: AutopilotCardRow) -> AutopilotCardRow in
      var shown: AutopilotCardRow = row
      if !shown.when.isEmpty { shown.when = "used " + shown.when }
      return shown
    }
  }

  // MARK: Teach: what an answer taught

  /// Settings' heading for the lessons, which the "Got it!" card points the owner to.
  static let learnedHeading = "What BZ has learned"
  /// The lesson group that now holds the lesson an answer to `questionID` taught: the rule whose
  /// answers include the question (a lesson that took it in lists it), then the group that lists
  /// that rule. Nil while the engine hasn't caught up, or when the answer taught nothing.
  static func lesson(taughtBy questionID: String, in snapshot: AutopilotSnapshot)
    -> AutopilotLessonGroup?
  {
    let rule: AutopilotRule? = snapshot.rules.first { rule in
      AutopilotPolicy.questionIDs(rule).contains(questionID)
    }
    guard let rule else { return nil }
    return snapshot.lessons.first { $0.ruleIDs.contains(rule.id) }
  }
  /// Under the lesson on the "Got it!" card, for a Yes and a No alike: the lesson says what it
  /// covers, this says what BZ does and how to change it.
  static let handling =
    "I'll handle these on my own from now on. To change it, use Forget in \(learnedHeading)."
  /// The same line for a Yes in look-only, where nothing burns until the owner starts burning.
  static let handlingLookOnly =
    "I'll burn these once you start burning. To change it, use Forget in \(learnedHeading)."
  /// The last line of the "Got it!" card: what comes next. A tell comes before any question.
  static func whatsNext(tells: Int, questions: Int) -> String {
    if tells > 0 { return "Next up…" }
    return questions > 0 ? "Next question coming up…" : "That's everything for now."
  }
}

extension AutopilotSnapshot {
  /// What BZ did on its own that still waits for the owner. Every surface that lists or counts
  /// tells goes through this one filter.
  var tellsWaiting: [AutopilotTell] { tells.filter { AutopilotText.shows($0) } }
}

/// What the model does itself when no engine is attached (demo and offscreen proofs). Each
/// function mirrors the change the real engine makes for the same command, entirely in memory.
enum AutopilotLocal {
  static func recount(_ s: inout AutopilotSnapshot) {
    var counts = [String: Int]()
    var bytes = [String: UInt64]()
    for entry in s.entries {
      counts[entry.status.rawValue, default: 0] += 1
      bytes[entry.status.rawValue, default: 0] += entry.item.bytes
    }
    s.counts = counts
    s.bytes = bytes
    s.coverage = AutopilotPolicy.coverage(s.entries)
    s.trainingProgress = min(1, Double(s.answers) / Double(AutopilotPolicy.trainingTarget))
  }

  static func answer(
    _ s: inout AutopilotSnapshot, question q: AutopilotQuestion, answer a: AutopilotAnswer,
    now: Date
  ) {
    guard let index = s.questions.firstIndex(where: { $0.id == q.id }) else { return }
    s.questions.remove(at: index)
    // Skip hides the question for a day and teaches nothing.
    guard a != .skip else { return }
    s.answers += 1
    // The answer teaches why, not which project: the engine's own lesson, taken in or joined the
    // way the engine does, with operator lessons first and the starter rules after them.
    var lessons: [AutopilotRule] = s.rules.filter { $0.source == .`operator` }
    let starters: [AutopilotRule] = s.rules.filter { $0.source == .starter }
    lessons.removeAll { $0.questionID == q.id }
    let verdict: AutopilotVerdict = a == .yes ? .burn : .keep
    let taught: AutopilotRule = AutopilotPolicy.lesson(for: q, verdict: verdict, created: now)
    AutopilotPolicy.learn(taught, into: &lessons)
    s.rules = lessons + starters
    decideUnsure(&s)
    regroup(&s)
    recount(&s)
  }

  /// Whatever the rules now say about the things BZ was unsure of: the engine's own decision for
  /// each, so a lesson that took another in covers what both covered.
  private static func decideUnsure(_ s: inout AutopilotSnapshot) {
    var memory = AutopilotMemory()
    memory.rules = s.rules.filter { $0.source == .`operator` }
    for rule in s.rules where rule.source == .starter && !rule.enabled {
      memory.starterDisabled.insert(rule.id)
    }
    for i in s.entries.indices where s.entries[i].status == .unsure {
      let decision = AutopilotPolicy.decide(s.entries[i].item, memory: memory)
      // Only a lesson moves a thing here; starter rules have their own switch.
      guard let authority = decision.authority, authority.hasPrefix("rule:") else { continue }
      switch decision.status {
      case .burn:
        s.entries[i].status = .burn
        s.entries[i].why = "You told me to burn these."
      case .keep:
        s.entries[i].status = .keep
        s.entries[i].why = "You told me to keep these."
      default:
        continue
      }
      s.entries[i].authority = authority
    }
  }

  /// Writes `lessons` again from `rules`, with the engine's own sentences, so a new lesson shows in
  /// its group the way it does after a real answer. A group whose lessons didn't change keeps its
  /// evidence: what each lesson burned isn't in the snapshot to work out again.
  private static func regroup(_ s: inout AutopilotSnapshot) {
    var memory = AutopilotMemory()
    memory.rules = s.rules.filter { $0.source == .`operator` }
    var seen = Set<String>()
    for rule in memory.rules {
      for id in AutopilotPolicy.questionIDs(rule) where seen.insert(id).inserted {
        var answered = AutopilotQuestion(
          kind: rule.kind, match: rule.match, question: "", why: "", examples: [], count: 0,
          bytes: 0)
        answered.id = id
        answered.answer = rule.verdict == .burn ? .yes : .no
        // The lesson of a call BZ made on its own comes from that call.
        answered.answeredBy = rule.tellID == nil ? nil : "bz"
        memory.questions.append(answered)
      }
    }
    var before = [String: AutopilotLessonGroup]()
    for group in s.lessons { before[group.id] = group }
    var groups = [AutopilotLessonGroup]()
    for group in AutopilotPolicy.lessonGroups(memory) {
      if let old = before[group.id], Set(old.ruleIDs) == Set(group.ruleIDs) {
        groups.append(old)
      } else {
        groups.append(group)
      }
    }
    s.lessons = groups
  }

  static func burnNow(_ s: inout AutopilotSnapshot, entry e: AutopilotEntry, now: Date) {
    guard let i = s.entries.firstIndex(where: { $0.id == e.id }),
      s.entries[i].status != .protected, s.entries[i].status != .burned
    else { return }
    let item = s.entries[i].item
    let detail: String
    var restore: AutopilotRestore?
    switch item.kind {
    case .process:
      detail = "Stopped it and checked: it's gone."
    case .worktree:
      detail = "Saved a backup, removed the folder and checked it's gone."
      restore = AutopilotRestore(
        repository: "/example/work/.git", path: item.path ?? "/example/work/" + item.name,
        ref: "refs/burnzombies/retired/" + String(item.revision.prefix(12)),
        head: String(repeating: "0", count: 40), branch: nil, snapshot: false)
    case .disk:
      detail = "Deleted the folder and checked it's gone."
    }
    let receipt = AutopilotReceipt(
      itemID: item.id, kind: item.kind, name: item.name, authority: "operator",
      outcome: "burned", detail: detail, bytes: item.bytes, date: now, restore: restore)
    s.entries[i].status = .burned
    s.entries[i].authority = "operator"
    s.entries[i].why = "You told me to burn this one."
    s.entries[i].receipt = receipt
    s.receipts.insert(receipt, at: 0)
    recount(&s)
  }

  static func keep(_ s: inout AutopilotSnapshot, entry e: AutopilotEntry) {
    guard let i = s.entries.firstIndex(where: { $0.id == e.id }),
      s.entries[i].status != .protected, s.entries[i].status != .burned
    else { return }
    s.entries[i].status = .keep
    s.entries[i].authority = "operator"
    s.entries[i].why = "You told me to keep this one forever."
    recount(&s)
  }

  /// Unspare: the owner's keep is gone, so it's BZ's to decide again; until the engine says, it
  /// waits as unsure.
  static func unkeep(_ s: inout AutopilotSnapshot, entry e: AutopilotEntry) {
    guard let i = s.entries.firstIndex(where: { $0.id == e.id }),
      AutopilotPolicy.isSpared(s.entries[i])
    else { return }
    s.entries[i].status = .unsure
    s.entries[i].authority = nil
    s.entries[i].why = "You took back your keep, so I'll decide again."
    recount(&s)
  }

  static func restore(_ s: inout AutopilotSnapshot, receipt r: AutopilotReceipt, now: Date) {
    guard let i = s.entries.firstIndex(where: { $0.receipt?.id == r.id }) else { return }
    var receipt = r
    receipt.outcome = "restored"
    receipt.detail = "Put back where it was."
    receipt.date = now
    s.entries[i].receipt = receipt
    s.entries[i].status = .keep
    s.entries[i].authority = "operator"
    s.entries[i].why = "You restored this one, so I'll leave it alone."
    if let j = s.receipts.firstIndex(where: { $0.id == r.id }) { s.receipts[j] = receipt }
    recount(&s)
  }

  /// Statuses a rule decided and can take back. Burned things are history and stay burned.
  private static func isOpenToChange(_ status: AutopilotStatus) -> Bool {
    status == .burn || status == .keep || status == .failed
  }
  private static func askAgain(_ entry: inout AutopilotEntry, why: String) {
    entry.status = .unsure
    entry.authority = nil
    entry.why = why
  }

  static func forget(_ s: inout AutopilotSnapshot, rule r: AutopilotRule) {
    guard r.source == .`operator` else { return }
    forgetLesson(&s, ruleIDs: [r.id])
  }

  /// Forgets lessons, each with every answer it was made from, so those things can be asked again
  /// (the engine's `forget`). A tell whose lesson is forgotten closes, without a score.
  static func forgetLesson(_ s: inout AutopilotSnapshot, ruleIDs: [String]) {
    let gone = Set(ruleIDs)
    var answers = Set<String>()
    // The ids things may carry as their authority: the lesson's own and those it took in.
    var names = Set<String>()
    for rule in s.rules where rule.source == .`operator` && gone.contains(rule.id) {
      answers.formUnion(AutopilotPolicy.questionIDs(rule))
      names.insert(rule.id)
      names.formUnion(rule.formerIDs ?? [])
    }
    guard !names.isEmpty else { return }
    s.rules.removeAll { $0.source == .`operator` && gone.contains($0.id) }
    s.questions.removeAll { answers.contains($0.id) }
    for i in s.entries.indices where isOpenToChange(s.entries[i].status) {
      guard let authority = s.entries[i].authority, authority.hasPrefix("rule:") else { continue }
      if names.contains(String(authority.dropFirst("rule:".count))) {
        askAgain(&s.entries[i], why: "I forgot that lesson, so I'm asking again.")
      }
    }
    s.tells.removeAll { gone.contains($0.ruleID) || answers.contains($0.questionID) }
    regroup(&s)
    recount(&s)
  }

  /// Good call: the tell closes.
  static func tellGood(_ s: inout AutopilotSnapshot, id: String) {
    s.tells.removeAll { $0.id == id && $0.isOpen }
  }

  /// OK on what an Undo left to read: the tell leaves the list.
  static func tellSeen(_ s: inout AutopilotSnapshot, id: String) {
    s.tells.removeAll { $0.id == id && $0.waitsForOK }
  }

  /// Undo, without the real restores: the tell closes, what its lesson burned comes back and is
  /// kept, and the lesson becomes the keep a No teaches. When a newer answer took the lesson in,
  /// no keep is learned and the tell stays, saying so, until the owner's OK.
  static func tellUndo(_ s: inout AutopilotSnapshot, id: String, now: Date) {
    guard let index = s.tells.firstIndex(where: { $0.id == id && $0.isOpen }) else { return }
    let tell: AutopilotTell = s.tells.remove(at: index)
    let authority: String = "rule:" + tell.ruleID
    let burned: [AutopilotReceipt] = s.receipts.filter { receipt in
      receipt.authority == authority && receipt.outcome == "burned" && receipt.restore != nil
    }
    for receipt in burned { restore(&s, receipt: receipt, now: now) }
    if let act = s.rules.first(where: { $0.id == tell.ruleID }) {
      var lessons: [AutopilotRule] = s.rules.filter { $0.source == .`operator` }
      let starters: [AutopilotRule] = s.rules.filter { $0.source == .starter }
      lessons.removeAll { $0.id == tell.ruleID }
      var asked = AutopilotQuestion(
        kind: act.kind, match: pattern(of: act), question: "", why: "", examples: [],
        count: tell.count, bytes: tell.bytes, asked: tell.date)
      asked.id = tell.questionID
      let keep = AutopilotPolicy.lesson(for: asked, verdict: .keep, created: now)
      AutopilotPolicy.learn(keep, into: &lessons)
      s.rules = lessons + starters
    } else if s.rules.contains(where: { $0.formerIDs?.contains(tell.ruleID) == true }) {
      var undone: AutopilotTell = tell
      undone.state = "undone"
      undone.note = AutopilotPolicy.newerAnswerStands
      undone.seen = false
      s.tells.insert(undone, at: index)
    }
    regroup(&s)
    recount(&s)
  }

  /// The question a lesson BZ made on its own answered, as its pattern: what it asked about, how
  /// long it sat unused and its subject, without the safe values the lesson added around it.
  private static func pattern(of rule: AutopilotRule) -> [String: [String]] {
    var match = [String: [String]]()
    let recency: String = rule.kind == .process ? "idle" : "stale"
    if let floor = rule.match[recency]?.first { match[recency] = [floor] }
    let subject: String = rule.kind == .process ? "family" : "folder"
    if rule.kind != .worktree, let kept = rule.match[subject] { match[subject] = kept }
    return match
  }

  static func setStarter(_ s: inout AutopilotSnapshot, id: String, enabled: Bool) {
    guard let r = s.rules.firstIndex(where: { $0.id == id && $0.source == .starter }) else {
      return
    }
    s.rules[r].enabled = enabled
    let rule = s.rules[r]
    for i in s.entries.indices {
      if !enabled && s.entries[i].authority == "starter:" + id
        && isOpenToChange(s.entries[i].status)
      {
        askAgain(&s.entries[i], why: "You switched that starter rule off, so I'm asking again.")
      } else if enabled && s.entries[i].status == .unsure
        && AutopilotPolicy.matches(rule, s.entries[i].item)
      {
        s.entries[i].status = .burn
        s.entries[i].authority = "starter:" + id
        s.entries[i].why = "This matches one of my starter rules."
      }
    }
    recount(&s)
  }

  static func reset(_ s: inout AutopilotSnapshot) {
    let learned = Set(s.rules.filter { $0.source == .`operator` }.map { "rule:" + $0.id })
    s.rules.removeAll { $0.source == .`operator` }
    for i in s.entries.indices
    where learned.contains(s.entries[i].authority ?? "") && isOpenToChange(s.entries[i].status) {
      askAgain(&s.entries[i], why: "You started my training over, so I'm asking again.")
    }
    s.answers = 0
    // Nothing is learned or trusted anymore, so there is nothing to show or to tell; whether BZ may
    // act on its own is the owner's setting and stays.
    s.lessons = []
    s.tells = []
    s.progress = AutopilotProgress()
    recount(&s)
  }
}

/// A colored status pill: Will burn, Needs you, Keeping, Burned, Protected.
struct AutopilotPill: View {
  let status: AutopilotStatus
  var large = false
  var body: some View {
    let color = AutopilotLook.color(status)
    Text(AutopilotLook.pill(status))
      .font(.system(size: large ? 14 : 11.5, weight: .semibold))
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, large ? 12 : 9)
      .padding(.vertical, large ? 5 : 4)
      .background(color.opacity(0.16), in: Capsule())
      .overlay(Capsule().strokeBorder(color.opacity(0.4)))
      .fixedSize()
  }
}

/// A small rounded name tag, used for the example items on a question.
struct AutopilotChip: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 13, weight: .medium))
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: 190)
      .background(Color.white.opacity(0.08), in: Capsule())
      .overlay(Capsule().strokeBorder(BurnTheme.line))
  }
}

/// The Autopilot block at the top of the menu: one status line, an orange button when BZ has
/// questions, and the ways into Teach BZ and Findings.
struct AutopilotMenuSection: View {
  @ObservedObject var model: AppModel
  @State private var tick = Date()
  var openQuestions: Int { model.autopilot.questions.filter(\.isOpen).count }
  var openTells: [AutopilotTell] { model.autopilot.tellsWaiting }
  var dot: Color {
    let sweep = model.autopilot.sweep
    if !sweep.enabled { return BurnTheme.muted }
    if let retry = sweep.retryAfter, retry > tick { return AutopilotTheme.yellow }
    return AutopilotTheme.green
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Circle().fill(dot).frame(width: 9, height: 9)
        Text(AutopilotText.sweepLine(model.autopilot.sweep, now: tick))
          .font(.system(size: 13, weight: .medium))
        Spacer(minLength: 0)
      }
      if let wait = model.autopilot.recoveryKey {
        // Old copies wait for the backup key: this comes before any question.
        prompt(
          symbol: "key.fill",
          text: wait.asking ? "macOS is asking you now" : "Allow BZ's backup key",
          id: "allow-recovery-key"
        ) { model.allowRecoveryKey() }
      }
      if openQuestions > 0 {
        prompt(
          symbol: "questionmark.bubble.fill", text: AutopilotText.questions(openQuestions),
          id: "autopilot-questions")
      } else if !openTells.isEmpty {
        // BZ acts instead of asking, so a tell comes exactly when there is no question to prompt.
        prompt(
          symbol: "flame.fill", text: AutopilotText.burnedOnItsOwn(openTells),
          id: "autopilot-tells")
      }
      HStack(spacing: 16) {
        link("Teach BZ", symbol: "graduationcap.fill") { model.openTeach?() }
        link("Findings", symbol: "list.bullet.rectangle") { model.openFindings?() }
        Spacer(minLength: 0)
        Button("Advanced findings…") { model.openAdvancedFindings?() }
          .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).clickPointer()
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { tick = $0 }
  }
  /// The orange button that takes the owner to Teach BZ, or does `action`.
  private func prompt(
    symbol: String, text: String, id: String, action: (() -> Void)? = nil
  ) -> some View {
    Button {
      if let action { action() } else { model.openTeach?() }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
        Text(text).font(.system(size: 15, weight: .bold))
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
      }
      .foregroundStyle(Color.black.opacity(0.86))
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(BurnTheme.orange, in: RoundedRectangle(cornerRadius: 12))
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain).clickPointer()
      .accessibilityIdentifier(id)
  }
  private func link(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
    }.buttonStyle(.plain).foregroundStyle(BurnTheme.cream).clickPointer()
  }
}
