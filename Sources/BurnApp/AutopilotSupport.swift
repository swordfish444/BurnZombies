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
  static func percent(_ value: Double) -> Int { max(0, min(100, Int((value * 100).rounded()))) }
  static func trained(_ progress: Double) -> String { "BZ is \(percent(progress))% trained" }
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
    if burn > 0 { clauses.append("I'll burn \(number(burn)) on my own") }
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
  /// The menu line: "Autopilot on · next sweep in 12 min", "Autopilot off", or the paused form.
  static func sweepLine(_ sweep: AutopilotSweepState, now: Date) -> String {
    guard sweep.enabled else { return "Autopilot off" }
    guard let next = nextSweep(sweep, now: now) else { return "Autopilot on" }
    if next.hasPrefix("retrying") { return "Autopilot paused — " + next }
    return "Autopilot on · " + next
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
  /// Rule titles come as "Burn: ..." or "Keep: ..."; the badge already says which.
  static func plainTitle(_ rule: AutopilotRule) -> String {
    for prefix in ["Burn: ", "Keep: "] where rule.title.hasPrefix(prefix) {
      return String(rule.title.dropFirst(prefix.count))
    }
    return rule.title
  }
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
    let burn = a == .yes
    let rule = AutopilotRule(
      kind: q.kind, match: q.match, verdict: burn ? .burn : .keep, source: .`operator`,
      title: AutopilotPolicy.ruleTitle(q, answer: a), enabled: true, created: now,
      questionID: q.id)
    s.rules.removeAll { $0.id == rule.id }
    s.rules.insert(rule, at: 0)
    for i in s.entries.indices
    where s.entries[i].status == .unsure && AutopilotPolicy.matches(rule, s.entries[i].item) {
      s.entries[i].status = burn ? .burn : .keep
      s.entries[i].authority = "rule:" + rule.id
      s.entries[i].why = burn ? "You told me to burn these." : "You told me to keep these."
    }
    recount(&s)
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
    s.rules.removeAll { $0.id == r.id }
    for i in s.entries.indices
    where s.entries[i].authority == "rule:" + r.id && isOpenToChange(s.entries[i].status) {
      askAgain(&s.entries[i], why: "I forgot that lesson, so I'm asking again.")
    }
    recount(&s)
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
    recount(&s)
  }

  static func sweepNow(_ s: inout AutopilotSnapshot, now: Date) {
    s.sweep.lastTick = now
    s.sweep.retryAfter = nil
    s.sweep.lastError = nil
    s.sweep.append("Swept just now.", date: now)
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

/// The training ring: how much of the way BZ is to running without help.
struct TrainingRing: View {
  let progress: Double
  var size: CGFloat = 46
  var body: some View {
    let value = max(0.0, min(1.0, progress))
    ZStack {
      Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
      Circle().trim(from: 0, to: max(0.004, value))
        .stroke(BurnTheme.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        .rotationEffect(.degrees(-90))
      Text("\(AutopilotText.percent(progress))%")
        .font(.system(size: size * 0.27, weight: .bold, design: .rounded)).monospacedDigit()
    }.frame(width: size, height: size)
  }
}

/// The Autopilot block at the top of the menu: one status line, an orange button when BZ has
/// questions, and the ways into Teach BZ and Findings.
struct AutopilotMenuSection: View {
  @ObservedObject var model: AppModel
  @State private var tick = Date()
  var openQuestions: Int { model.autopilot.questions.filter(\.isOpen).count }
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
      if openQuestions > 0 {
        Button {
          model.openTeach?()
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "questionmark.bubble.fill").font(.system(size: 18, weight: .semibold))
            Text(AutopilotText.questions(openQuestions)).font(.system(size: 15, weight: .bold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
          }
          .foregroundStyle(Color.black.opacity(0.86))
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(BurnTheme.orange, in: RoundedRectangle(cornerRadius: 12))
          .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).clickPointer()
          .accessibilityIdentifier("autopilot-questions")
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
  private func link(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
    }.buttonStyle(.plain).foregroundStyle(BurnTheme.cream).clickPointer()
  }
}
