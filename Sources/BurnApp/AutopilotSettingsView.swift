import BurnCore
import SwiftUI

/// The Autopilot section of Settings: on/off, how often BZ sweeps, whether it acts on its own when
/// it is sure, what it has learned from the operator's answers, how it is doing, the starter rules
/// and a way to start over.
struct AutopilotSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var confirmReset = false
  static let intervals = [5, 15, 30, 60, 240]
  /// Under the toggle. Only copies can be undone, so it says so.
  static let actsCaption =
    "When I'm sure, I'll do it and tell you after. Copies can be undone. Off means I always ask first."

  private var sweep: AutopilotSweepState { model.autopilot.sweep }
  private var lessons: [AutopilotLessonGroup] { model.autopilot.lessons }
  private var progress: [String] { model.autopilot.progress.lines }
  private var starters: [AutopilotRule] { model.autopilot.rules.filter { $0.source == .starter } }

  static func label(_ minutes: Int) -> String {
    switch minutes {
    case 15: return "15 minutes · Default"
    case 60: return "1 hour"
    case 240: return "4 hours"
    default: return minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hours"
    }
  }

  private var intervalChoices: [Int] {
    Self.intervals.contains(sweep.intervalMinutes)
      ? Self.intervals : (Self.intervals + [sweep.intervalMinutes]).sorted()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        Image(systemName: "flame.fill").foregroundStyle(BurnTheme.orange)
        Text("Autopilot").font(.headline)
        Spacer()
        Toggle(
          "Autopilot",
          isOn: Binding(get: { model.autopilot.sweep.enabled }, set: { model.setAutopilot(enabled: $0) })
        )
        .labelsHidden().toggleStyle(.switch).tint(BurnTheme.orange).clickPointer()
        .accessibilityLabel("Autopilot on or off")
      }
      Text("BZ burns leftovers on its own and only asks you when it isn't sure.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Picker(
        "Sweep every",
        selection: Binding(
          get: { model.autopilot.sweep.intervalMinutes },
          set: { model.setSweepInterval(minutes: $0) })
      ) {
        ForEach(intervalChoices, id: \.self) { minutes in
          Text(Self.label(minutes)).tag(minutes)
        }
      }.clickPointer().disabled(!sweep.enabled)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(sweepSentence).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 4)
        Button("Sweep now") { model.sweepNow() }.buttonStyle(.bordered).controlSize(.small)
          .clickPointer().disabled(!sweep.enabled)
      }
      actsOnItsOwn
      Divider()
      learnedSection
      if !progress.isEmpty {
        Divider()
        doingSection
      }
      Divider()
      startersSection
      Divider()
      HStack {
        Button(role: .destructive) {
          confirmReset = true
        } label: {
          Text("Start training over")
        }.clickPointer()
        Spacer()
      }
    }
    .padding(16)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    .alert("Start training over?", isPresented: $confirmReset) {
      Button("Start over", role: .destructive) { model.resetTraining() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("BZ forgets everything you taught it. The starter rules stay.")
    }
  }

  private var sweepSentence: String {
    let now = Date()
    var text = AutopilotText.lastSweep(sweep, now: now)
    if let next = AutopilotText.nextSweep(sweep, now: now) { text += " · " + next }
    return text
  }

  /// Whether BZ burns what it is sure of and tells the owner after, or always asks first.
  private var actsOnItsOwn: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Text("Act on its own when sure").font(.callout)
        Spacer(minLength: 8)
        Toggle(
          "Act on its own when sure",
          isOn: Binding(
            get: { model.autopilot.actsOnItsOwn }, set: { model.setActsOnItsOwn($0) })
        )
        .labelsHidden().toggleStyle(.switch).tint(BurnTheme.orange).clickPointer()
        .accessibilityIdentifier("autopilot-acts-on-its-own")
      }
      Text(Self.actsCaption)
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Lessons as plain sentences, each with what it rests on and what it did.
  private var learnedSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(AutopilotText.learnedHeading).font(.subheadline.weight(.semibold))
      if lessons.isEmpty {
        Text("Nothing yet. Answer BZ's quick questions and the lessons show up here.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(lessons) { group in lessonRow(group) }
    }
  }

  private func lessonRow(_ group: AutopilotLessonGroup) -> some View {
    HStack(alignment: .top, spacing: 10) {
      lessonSymbol(group.verdict)
      VStack(alignment: .leading, spacing: 3) {
        Text(group.sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
        Text(group.evidence).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 6)
      Button("Forget") { model.forgetLesson(group) }.buttonStyle(.borderless)
        .font(.callout).foregroundStyle(BurnTheme.orange).clickPointer()
        .accessibilityLabel(AutopilotText.forgetLabel(group))
        .accessibilityIdentifier("forget-lesson-" + group.id)
    }
  }

  /// A lesson to burn is the flame, a lesson to keep the open hand: the same marks as the answers.
  private func lessonSymbol(_ verdict: AutopilotVerdict) -> some View {
    let burn = verdict == .burn
    return Image(systemName: burn ? "flame.fill" : "hand.raised.fill")
      .font(.system(size: 14)).foregroundStyle(burn ? BurnTheme.orange : AutopilotTheme.green)
      .frame(width: 18, alignment: .center).padding(.top, 2)
  }

  /// How I'm doing: plain counts, one sentence each, as BZ worked them out.
  private var doingSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("How I'm doing").font(.subheadline.weight(.semibold))
      ForEach(Array(progress.enumerated()), id: \.offset) { _, line in
        Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var startersSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Starter rules").font(.subheadline.weight(.semibold))
      Text("Safe habits BZ starts with. Switch off any you don't like.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(starters) { rule in
        Toggle(
          isOn: Binding(
            get: { model.autopilot.rules.first { $0.id == rule.id }?.enabled ?? rule.enabled },
            set: { model.setStarter(rule.id, enabled: $0) })
        ) {
          Text(rule.title).font(.callout).fixedSize(horizontal: false, vertical: true)
        }.toggleStyle(.switch).tint(BurnTheme.orange).clickPointer()
      }
    }
  }
}
