import BurnCore
import SwiftUI

/// The Autopilot section of Settings: on/off, how often BZ sweeps, what it has learned from
/// the operator's answers, the starter rules and a way to start over.
struct AutopilotSettingsView: View {
  @ObservedObject var model: AppModel
  @State private var confirmReset = false
  static let intervals = [5, 15, 30, 60, 240]

  private var sweep: AutopilotSweepState { model.autopilot.sweep }
  private var learned: [AutopilotRule] { model.autopilot.rules.filter { $0.source == .`operator` } }
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
      Toggle(
        isOn: Binding(
          get: { model.autopilot.sweep.lookOnly == true }, set: { model.setLookOnly($0) })
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Look only").font(.callout)
          Text("Find, size and ask, but burn nothing. Turn it off to start burning.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }.toggleStyle(.switch).tint(BurnTheme.orange).clickPointer()
        .accessibilityIdentifier("autopilot-look-only")
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
      Divider()
      learnedSection
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

  private var learnedSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("What BZ has learned").font(.subheadline.weight(.semibold))
      if learned.isEmpty {
        Text("Nothing yet. Answer BZ's quick questions and the lessons show up here.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(learned) { rule in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          badge(rule)
          Text(AutopilotText.plainTitle(rule)).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 6)
          Button("Forget") { model.forgetRule(rule) }.buttonStyle(.borderless)
            .font(.callout).foregroundStyle(BurnTheme.orange).clickPointer()
        }
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

  private func badge(_ rule: AutopilotRule) -> some View {
    let burn = rule.verdict == .burn
    let color = burn ? BurnTheme.orange : AutopilotTheme.green
    return Text(burn ? "Burn" : "Keep")
      .font(.caption2.weight(.bold)).foregroundStyle(color)
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(color.opacity(0.16), in: Capsule())
  }
}
