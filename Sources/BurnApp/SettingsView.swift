import AppKit
import BurnCore
import Charts
import ServiceManagement
import SwiftUI

/// The four ways Autopilot can behave, as one choice.
enum AutopilotLevel: String, CaseIterable, Identifiable {
  case off, lookOnly, askFirst, actWhenSure
  var id: Self { self }
  var label: String {
    switch self {
    case .off: return "Off"
    case .lookOnly: return "Look only"
    case .askFirst: return "Ask first"
    case .actWhenSure: return "Act when sure"
    }
  }
  var sentence: String {
    switch self {
    case .off: return "Burns nothing. Uses no AI."
    case .lookOnly: return "Looks and asks. Burns nothing."
    case .askFirst: return "Burns what your rules say. Asks about the rest."
    case .actWhenSure: return "Burns what it's sure about and tells you. Asks about the rest."
    }
  }
}

enum SettingsPage: Equatable {
  case home, burns, never, aiUse, access
}

/// One thing on Never touches, wherever the owner said it.
struct NeverTouchRow: Identifiable {
  let id: String
  let title: String
  var detail: String?
  let remove: @MainActor () -> Void
}

extension AppModel {
  var neverTouchRows: [NeverTouchRow] {
    func shown(_ path: String) -> String {
      (path as NSString).abbreviatingWithTildeInPath
    }
    var rows: [NeverTouchRow] = []
    for path in Set(autopilot.neverTouch + autopilot.keptPaths).sorted() {
      rows.append(
        NeverTouchRow(
          id: "path:" + path, title: (path as NSString).lastPathComponent, detail: shown(path)
        ) { [weak self] in self?.allowTouch(path: path) })
    }
    for path in state.catalog.preferences.protectedExecutables.sorted() {
      rows.append(
        NeverTouchRow(
          id: "program:" + path, title: (path as NSString).lastPathComponent, detail: shown(path)
        ) { [weak self] in self?.unprotect(path) })
    }
    for lesson in autopilot.lessons where lesson.verdict != .burn {
      rows.append(
        NeverTouchRow(id: lesson.id, title: lesson.sentence) { [weak self] in
          self?.forgetLesson(lesson)
        })
    }
    return rows
  }
  var burnLessons: [AutopilotLessonGroup] { autopilot.lessons.filter { $0.verdict == .burn } }
  var starterRules: [AutopilotRule] { autopilot.rules.filter { $0.source == .starter } }
}

/// What Settings shows and saves about the AI.
@MainActor final class AISettingsModel: ObservableObject {
  @Published private(set) var configuration: MachineReviewConfiguration?
  @Published private(set) var installed: [String] = []
  @Published private(set) var ledger = ReviewLedger()
  @Published private(set) var problem: String?
  let root: URL
  let bundle: URL
  /// Runs after a change is saved, so the app reads it again.
  var saved: () -> Void = {}

  init(root: URL = Store.defaultRoot, bundle: URL = Bundle.main.bundleURL) {
    self.root = root
    self.bundle = bundle
    reload()
  }

  func reload() {
    do {
      configuration = try MachineReviewConfiguration.load(root: root)
      ledger = try ReviewLedger.load(store: Store(root: root))
      problem = nil
    } catch { problem = error.localizedDescription }
    installed = ["claude", "codex"].filter { MachineReviewConfiguration.detect($0) != nil }
  }

  static func name(_ harness: String) -> String {
    switch harness {
    case "claude": return "Claude"
    case "codex": return "Codex"
    default: return harness.capitalized
    }
  }

  /// "off", or which AI judges what BZ isn't sure about.
  var choice: String {
    guard let configuration, configuration.enabled else { return "off" }
    return configuration.harness
  }
  var choices: [String] {
    var all = installed
    if let current = configuration?.harness, !all.contains(current) { all.append(current) }
    return all + ["off"]
  }
  var noAIInstalled: Bool { installed.isEmpty && configuration == nil }

  func choose(_ tag: String) {
    do {
      try MachineReviewConfiguration.choose(tag == "off" ? nil : tag, root: root, bundle: bundle)
      reload()
      saved()
    } catch { problem = error.localizedDescription }
  }

  /// A choice's name, with the model it means where that's a fixed one.
  func label(_ brain: AIBrain) -> String {
    let word: String
    switch brain {
    case .quick: word = "Quick"
    case .smart: word = "Smart"
    case .smartest: word = "Smartest"
    }
    guard configuration?.harness == "claude" else { return word }
    let model = ["quick": "Haiku", "smart": "Sonnet", "smartest": "Opus"][brain.rawValue] ?? ""
    return word + " · " + model
  }
  /// "smart", or "custom" for a model set from the command line.
  var brainTag: String { configuration?.brain?.rawValue ?? "custom" }
  var customBrain: String {
    "Custom · " + (configuration?.model ?? configuration?.reasoningEffort ?? "")
  }
  func setBrain(_ tag: String) {
    guard var updated = configuration, let brain = AIBrain(rawValue: tag) else { return }
    do {
      updated.set(brain)
      try updated.save(root: root)
      reload()
      saved()
    } catch { problem = error.localizedDescription }
  }

  func report(days: Int) -> UsageReport { .make(ledger, days: days, hourly: false) }
  static func about(_ usd: Double) -> String {
    if usd <= 0 { return "$0" }
    if usd < 1 { return "Under $1" }
    return "About $" + String(Int(usd.rounded()))
  }
}

/// A flat card of rows, under a small title.
private struct SettingsCard<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 2)
      VStack(spacing: 0) { content }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
  }
}

private struct SettingsRow<Trailing: View>: View {
  let title: String
  var divider = true
  @ViewBuilder var trailing: Trailing
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Text(title).font(.callout)
        Spacer(minLength: 8)
        trailing
      }.padding(.horizontal, 12).frame(height: 33)
      if divider { Divider().padding(.leading, 12) }
    }
  }
}

/// A row that opens a page: the whole row is the button.
private struct SettingsLink: View {
  let title: String
  let value: String
  var divider = true
  let open: () -> Void
  var body: some View {
    Button(action: open) {
      SettingsRow(title: title, divider: divider) {
        Text(value).font(.callout).foregroundStyle(.secondary)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).clickPointer().accessibilityLabel(title + ": " + value)
  }
}

/// The one switch Settings uses.
struct SettingsSwitch: View {
  let title: String
  @Binding var isOn: Bool
  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Capsule().fill(isOn ? BurnTheme.orange : Color.white.opacity(0.17))
        .overlay(alignment: isOn ? .trailing : .leading) {
          Circle().fill(isOn ? BurnTheme.cream : Color(white: 0.62)).padding(2)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
        }
        .frame(width: AutopilotSwitch.size.width, height: AutopilotSwitch.size.height)
        .padding(.vertical, 3).contentShape(Rectangle())
    }.buttonStyle(.borderless).clickPointer().help(title)
      .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
  }
}

private struct SettingsMenu: View {
  let title: String
  let options: [(tag: String, label: String)]
  let selection: Binding<String>
  var body: some View {
    Picker(title, selection: selection) {
      ForEach(options, id: \.tag) { Text($0.label).tag($0.tag) }
    }.pickerStyle(.menu).labelsHidden().buttonStyle(.borderless).fixedSize().clickPointer()
      .tint(.secondary)
  }
}

/// Settings: what BZ may do, what it burns and never touches, its AI, and this Mac.
struct SettingsHome: View {
  @ObservedObject var model: AppModel
  @ObservedObject var ai: AISettingsModel

  private var level: Binding<AutopilotLevel> {
    Binding(get: { model.autopilotLevel }, set: { model.setAutopilotLevel($0) })
  }
  private var burnCount: Int {
    let on = model.starterRules.filter(\.enabled).count
    return model.burnLessons.filter { $0.off != true }.count + on
  }
  private var neverValue: String {
    let count = model.neverTouchRows.count
    return count == 0 ? "Nothing yet" : count == 1 ? "1 thing" : "\(count) things"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 7) {
        Text("How much can BZ do on its own?").font(.callout.weight(.semibold))
        Picker("How much can BZ do on its own?", selection: level) {
          ForEach(AutopilotLevel.allCases) { Text($0.label).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().clickPointer()
          .accessibilityIdentifier("autopilot-level").disabled(!model.autopilotAvailable)
        Text(model.autopilotLevel.sentence).font(.caption).foregroundStyle(.secondary)
      }
      if let waiting = AutopilotText.aiProblem(
        model.autopilot.sweep, harness: ai.configuration?.harness, now: Date())
      {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "hourglass").font(.caption).foregroundStyle(BurnTheme.orange)
          Text(waiting).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(BurnTheme.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ai-waiting")
      }
      SettingsCard(title: "Rules") {
        SettingsLink(title: "Burns without asking", value: "\(burnCount) rules") {
          model.settingsPage = .burns
        }
        SettingsLink(title: "Never touches", value: neverValue, divider: false) {
          model.settingsPage = .never
        }
      }
      SettingsCard(title: "AI") {
        SettingsRow(title: "Which AI") {
          if ai.noAIInstalled {
            Text("None found").font(.callout).foregroundStyle(.secondary)
          } else {
            SettingsMenu(
              title: "Which AI",
              options: ai.choices.map { ($0, $0 == "off" ? "Off" : AISettingsModel.name($0)) },
              selection: Binding(get: { ai.choice }, set: { ai.choose($0) }))
          }
        }
        if ai.choice != "off" {
          SettingsRow(title: "How smart") {
            SettingsMenu(
              title: "How smart",
              options: brains,
              selection: Binding(get: { ai.brainTag }, set: { ai.setBrain($0) }))
          }
        }
        SettingsLink(
          title: "Used this week", value: AISettingsModel.about(ai.report(days: 7).total.estimatedUSD),
          divider: false
        ) { model.settingsPage = .aiUse }
      }
      SettingsCard(title: "This Mac") {
        if model.accessReady {
          SettingsRow(title: "Full Disk Access") {
            Image(systemName: "checkmark.circle.fill").font(.caption)
              .foregroundStyle(AutopilotTheme.green)
            Text("On").font(.callout).foregroundStyle(.secondary)
          }
        } else {
          SettingsLink(title: "Full Disk Access", value: "Turn on") { model.settingsPage = .access }
        }
        SettingsRow(title: "Tell me when BZ has a question") {
          SettingsSwitch(
            title: "Tell me when BZ has a question",
            isOn: Binding(
              get: { model.state.catalog.preferences.notifications }, set: model.setNotifications))
        }
        SettingsRow(title: "Start at login", divider: false) {
          SettingsSwitch(
            title: "Start at login",
            isOn: Binding(
              get: { SMAppService.mainApp.status == .enabled }, set: { model.login($0) })
          ).disabled(model.demo)
        }
      }
      if let problem = ai.problem {
        Text(problem).font(.caption).foregroundStyle(BurnTheme.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      Link(
        "How BZ works and stays private",
        destination: URL(string: "https://github.com/swordfish444/BurnZombies")!
      ).font(.caption).clickPointer().frame(maxWidth: .infinity, alignment: .center)
    }
    .onAppear { ai.reload() }
  }

  private var brains: [(tag: String, label: String)] {
    var all: [(tag: String, label: String)] = AIBrain.allCases.map { ($0.rawValue, ai.label($0)) }
    if ai.configuration?.brain == nil { all.append(("custom", ai.customBrain)) }
    return all
  }
}

/// The Settings window: BZ's name, version and updates on top, then Settings and its pages.
struct SettingsWindow: View {
  @StateObject private var ai: AISettingsModel
  @ObservedObject var model: AppModel
  /// Proofs pass a scratch-folder model so rendering never reads the real state folder. A demo has
  /// no real AI to change.
  init(model: AppModel, ai: AISettingsModel? = nil) {
    self.model = model
    let root =
      model.demo
      ? FileManager.default.temporaryDirectory.appendingPathComponent("bz-demo-ai") : Store.defaultRoot
    let settings = ai ?? AISettingsModel(root: root)
    if !model.demo { settings.saved = { [weak model] in model?.reloadReviewConfiguration() } }
    _ai = StateObject(wrappedValue: settings)
  }
  var body: some View {
    VStack(spacing: 0) {
      AboutHeader(
        updates: model.appUpdates,
        subtitle: model.demo ? "DEMO · synthetic data" : "Keep your work running",
        working: model.working
      ).disabled(model.demo).padding(20)
      Divider()
      if let error = model.state.error {
        Label(error, systemImage: "exclamationmark.shield").font(.callout).padding()
          .foregroundStyle(.red)
      }
      if model.settingsPage == .home {
        ScrollView {
          SettingsHome(model: model, ai: ai).padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        SettingsSubpage(model: model, ai: ai)
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(
          .vertical, 10
        ).frame(maxWidth: .infinity, alignment: .leading)
          .task(id: message) { await model.settleMessage(message) }
      }
    }.frame(width: 440, height: 660).background(Color(nsColor: .windowBackgroundColor))
      .tint(BurnTheme.ember)
  }
}

/// A page under Settings: the way back, a short title and sentence, then what it's about.
struct SettingsSubpage: View {
  @ObservedObject var model: AppModel
  @ObservedObject var ai: AISettingsModel
  @State private var confirmReset = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        model.settingsPage = .home
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
          Text("Settings").font(.callout)
        }.foregroundStyle(BurnTheme.orange).contentShape(Rectangle())
      }.buttonStyle(.borderless).clickPointer().padding(.horizontal, 20).padding(.top, 12)
        .accessibilityIdentifier("settings-back")
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          switch model.settingsPage {
          case .burns: burns
          case .never: never
          case .aiUse: aiUse
          case .access: FullDiskAccessView(model: model)
          case .home: EmptyView()
          }
        }.padding(.horizontal, 20).padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .alert("Start training over?", isPresented: $confirmReset) {
      Button("Start over", role: .destructive) { model.resetTraining() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("BZ forgets what you taught it. The starter rules stay.")
    }
  }

  private func heading(_ title: String, _ sentence: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.headline)
      Text(sentence).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func burnRow(
    title: String, detail: String?, isOn: Binding<Bool>, divider: Bool
  ) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "flame.fill").font(.system(size: 12)).foregroundStyle(BurnTheme.orange)
          .frame(width: 16).padding(.top, 2)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
          if let detail {
            Text(detail).font(.caption).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        SettingsSwitch(title: title, isOn: isOn)
      }.padding(.horizontal, 12).padding(.vertical, 8)
      if divider { Divider().padding(.leading, 37) }
    }
  }

  private var burns: some View {
    Group {
      heading("Burns without asking", "Switch off anything you don't want burned.")
      let lessons = model.burnLessons
      let starters = model.starterRules
      VStack(spacing: 0) {
        ForEach(Array(lessons.enumerated()), id: \.element.id) { index, lesson in
          burnRow(
            title: lesson.sentence, detail: lesson.did,
            isOn: Binding(
              get: { lesson.off != true }, set: { model.setLesson(lesson, on: $0) }),
            divider: index < lessons.count - 1 || !starters.isEmpty)
        }
        ForEach(Array(starters.enumerated()), id: \.element.id) { index, rule in
          burnRow(
            title: rule.title, detail: "Starter rule",
            isOn: Binding(
              get: { rule.enabled }, set: { model.setStarter(rule.id, enabled: $0) }),
            divider: index < starters.count - 1)
        }
      }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
      Button("Start training over") { confirmReset = true }
        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary).clickPointer()
        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
    }
  }

  private var never: some View {
    Group {
      heading("Never touches", "BZ leaves these alone, no matter what.")
      let rows = model.neverTouchRows
      VStack(spacing: 0) {
        ForEach(rows) { row in
          HStack(alignment: .top, spacing: 9) {
            Image(systemName: "hand.raised.fill").font(.system(size: 12))
              .foregroundStyle(AutopilotTheme.green).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title).font(.callout).fixedSize(horizontal: false, vertical: true)
              if let detail = row.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  .truncationMode(.middle).help(detail)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
              row.remove()
            } label: {
              Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 20, height: 20).contentShape(Rectangle())
            }.buttonStyle(.plain).clickPointer().help("Take this off the list")
              .accessibilityLabel("Take " + row.title + " off the list")
          }.padding(.horizontal, 12).padding(.vertical, 8)
          Divider().padding(.leading, 37)
        }
        Button {
          addToNeverTouches()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            Text("Add a folder or app…").font(.callout)
            Spacer(minLength: 0)
          }.foregroundStyle(BurnTheme.orange).padding(.horizontal, 12).frame(height: 33)
            .contentShape(Rectangle())
        }.buttonStyle(.borderless).clickPointer().accessibilityIdentifier("never-touch-add")
      }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
      Text("Always safe: your apps, macOS, your browsers, recordings and passwords.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func addToNeverTouches() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Never touch"
    panel.message = "Pick what BZ should never touch."
    panel.begin { [model] response in
      guard response == .OK else { return }
      let paths = panel.urls.map(\.path)
      Task { @MainActor in
        for path in paths { model.neverTouch(path: path) }
      }
    }
  }

  private var aiUse: some View {
    let week = ai.report(days: 7)
    let money: (Double) -> String = { "$" + String(Int($0.rounded())) }
    return Group {
      heading("AI used this week", "What this would cost if you paid per use.")
      Text(money(week.total.estimatedUSD))
        .font(.system(size: 40, weight: .semibold, design: .rounded)).foregroundStyle(BurnTheme.orange)
        .monospacedDigit()
      Chart(Array(week.buckets.suffix(7))) { bucket in
        BarMark(
          x: .value("Day", bucket.date, unit: .day), y: .value("Cost", bucket.totals.estimatedUSD)
        ).foregroundStyle(BurnTheme.orange).cornerRadius(2)
      }
      .chartYAxis(.hidden)
      .chartXAxis {
        AxisMarks(values: .stride(by: .day)) { _ in
          AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
        }
      }
      .frame(height: 110).accessibilityIdentifier("ai-use-chart")
      VStack(spacing: 0) {
        SettingsRow(title: "Today") {
          Text(money(ai.report(days: 1).total.estimatedUSD)).font(.callout).foregroundStyle(.secondary)
        }
        SettingsRow(title: "This month", divider: false) {
          Text(money(ai.report(days: 30).total.estimatedUSD)).font(.callout).foregroundStyle(.secondary)
        }
      }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
      Text("On a Claude or ChatGPT plan, it comes out of your plan instead.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
