import AppKit
import BurnCore
import SwiftUI

/// The status tabs across the top of Findings.
enum AutopilotTab: String, CaseIterable, Identifiable {
  case everything = "Everything"
  case willBurn = "Will burn"
  case needsYou = "Needs you"
  case keeping = "Keeping"
  case burned = "Burned"
  var id: String { rawValue }

  func includes(_ status: AutopilotStatus) -> Bool {
    switch self {
    case .everything: return true
    case .willBurn: return status == .burn
    case .needsYou: return status == .unsure || status == .failed
    case .keeping: return status == .keep
    case .burned: return status == .burned
    }
  }
  func count(in snapshot: AutopilotSnapshot) -> Int {
    switch self {
    case .everything: return snapshot.counts.values.reduce(0, +)
    case .willBurn: return snapshot.count(.burn)
    case .needsYou: return snapshot.count(.unsure) + snapshot.count(.failed)
    case .keeping: return snapshot.count(.keep)
    case .burned: return snapshot.count(.burned)
    }
  }
}

/// One of the three friendly groups: leftover programs, old project copies, junk folders.
struct AutopilotSection: Identifiable {
  let kind: AutopilotKind
  let entries: [AutopilotEntry]
  var id: String { kind.rawValue }
  /// Space still in use. Things already burned are gone.
  var bytes: UInt64 {
    entries.reduce(UInt64(0)) { $0 + ($1.status == .burned ? 0 : $1.item.bytes) }
  }
  var freed: UInt64 {
    entries.reduce(UInt64(0)) { $0 + ($1.status == .burned ? $1.item.bytes : 0) }
  }
}

enum AutopilotGrouping {
  /// Things that need the operator come first inside each group.
  static func rank(_ status: AutopilotStatus) -> Int {
    switch status {
    case .unsure: return 0
    case .failed: return 1
    case .burn: return 2
    case .keep: return 3
    case .protected: return 4
    case .burned: return 5
    }
  }
  static func sections(_ entries: [AutopilotEntry], tab: AutopilotTab) -> [AutopilotSection] {
    var buckets = [AutopilotKind: [AutopilotEntry]]()
    for entry in entries where tab.includes(entry.status) {
      buckets[entry.item.kind, default: []].append(entry)
    }
    let order: [AutopilotKind] = [.process, .worktree, .disk]
    var result = [AutopilotSection]()
    for kind in order {
      guard var rows = buckets[kind], !rows.isEmpty else { continue }
      rows.sort { a, b in
        let ra = rank(a.status)
        let rb = rank(b.status)
        if ra != rb { return ra < rb }
        if a.item.bytes != b.item.bytes { return a.item.bytes > b.item.bytes }
        return a.id < b.id
      }
      result.append(AutopilotSection(kind: kind, entries: rows))
    }
    return result
  }
}

/// The simple Findings window: one sentence on top, status tabs, three friendly groups, and a
/// plain detail card for whatever is selected. Built for thousands of entries (lazy rows).
struct AutopilotFindingsView: View {
  static let size = NSSize(width: 1000, height: 700)
  @ObservedObject var model: AppModel
  @State private var tab: AutopilotTab
  @State private var selection: String?

  init(model: AppModel, tab: AutopilotTab = .everything, selection: String? = nil) {
    self.model = model
    _tab = State(initialValue: tab)
    _selection = State(initialValue: selection)
  }

  @MainActor static func makeWindow(
    model: AppModel, tab: AutopilotTab = .everything, selection: String? = nil
  ) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title = "BurnZombies — Findings"
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 820, height: 560)
    window.contentMaxSize = NSSize(width: 1400, height: 1000)
    // The window owns the viewport; the list and detail card scroll inside it.
    let host = NSHostingView(
      rootView: AutopilotFindingsView(model: model, tab: tab, selection: selection))
    host.sizingOptions = []
    window.contentView = host
    window.center()
    return window
  }

  private var snapshot: AutopilotSnapshot { model.autopilot }
  private var openQuestions: Int { snapshot.questions.filter(\.isOpen).count }
  private var selected: AutopilotEntry? {
    guard let selection else { return nil }
    return snapshot.entries.first { $0.id == selection }
  }

  var body: some View {
    let sections = AutopilotGrouping.sections(snapshot.entries, tab: tab)
    VStack(spacing: 0) {
      header
      tabBar
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      HStack(spacing: 0) {
        list(sections).frame(maxWidth: .infinity, maxHeight: .infinity)
        Rectangle().fill(BurnTheme.line).frame(width: 1)
        detail.frame(width: 400).frame(maxHeight: .infinity)
      }
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      footer
    }
    .foregroundStyle(BurnTheme.cream)
    .background(BurnBackdrop())
    .preferredColorScheme(.dark)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      Skull(size: 46)
      VStack(alignment: .leading, spacing: 5) {
        Text(AutopilotText.summary(snapshot))
          .font(.system(size: 22, weight: .bold, design: .rounded))
          .fixedSize(horizontal: false, vertical: true)
        Text(AutopilotText.subtitle(snapshot, now: Date()))
          .font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
      }
      Spacer(minLength: 16)
      if openQuestions > 0 {
        Button {
          model.openTeach?()
        } label: {
          Text(AutopilotText.questions(openQuestions))
            .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(BurnTheme.orange, in: Capsule())
        }.buttonStyle(.plain).clickPointer()
      }
    }.padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 10)
  }

  private var tabBar: some View {
    HStack(spacing: 8) {
      ForEach(AutopilotTab.allCases) { option in tabButton(option) }
      Spacer(minLength: 0)
    }.padding(.horizontal, 22).padding(.bottom, 10)
  }

  private func tabButton(_ option: AutopilotTab) -> some View {
    let on = tab == option
    let count = option.count(in: snapshot)
    return Button {
      tab = option
    } label: {
      HStack(spacing: 7) {
        Text(option.rawValue).font(.system(size: 14, weight: on ? .bold : .medium))
        Text(count.formatted()).font(.system(size: 12, weight: .semibold, design: .rounded))
          .foregroundStyle(on ? BurnTheme.orange : BurnTheme.muted)
      }
      .foregroundStyle(on ? BurnTheme.cream : BurnTheme.muted)
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(on ? BurnTheme.orange.opacity(0.18) : Color.white.opacity(0.05), in: Capsule())
      .overlay(Capsule().strokeBorder(on ? BurnTheme.orange.opacity(0.6) : Color.clear))
    }.buttonStyle(.plain).clickPointer().accessibilityLabel("\(option.rawValue), \(count)")
  }

  private func list(_ sections: [AutopilotSection]) -> some View {
    Group {
      if sections.isEmpty {
        emptyList
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
              Section {
                ForEach(section.entries) { entry in
                  AutopilotRow(entry: entry, selected: selection == entry.id) {
                    selection = entry.id
                  }
                }
              } header: {
                sectionHeader(section)
              }
            }
          }.padding(.horizontal, 14).padding(.bottom, 14)
        }
      }
    }
  }

  private func sectionHeader(_ section: AutopilotSection) -> some View {
    HStack(spacing: 8) {
      Text(AutopilotLook.emoji(section.kind)).font(.system(size: 16))
      Text(AutopilotLook.sectionTitle(section.kind))
        .font(.system(size: 16, weight: .bold, design: .rounded))
      Spacer()
      Text(totals(section)).font(.system(size: 13)).foregroundStyle(BurnTheme.muted)
    }
    .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 8)
    .frame(maxWidth: .infinity)
    .background(AutopilotTheme.window)
  }

  private func totals(_ section: AutopilotSection) -> String {
    let count = section.entries.count
    var text = AutopilotText.things(count)
    if tab == .burned {
      if section.freed > 0 { text += " · freed " + AutopilotText.size(section.freed) }
    } else if section.bytes > 0 {
      text += " · " + AutopilotText.size(section.bytes)
    }
    return text
  }

  private var emptyTitle: String {
    switch tab {
    case .everything, .needsYou: return "Nothing needs you right now."
    case .willBurn: return "Nothing is waiting to be burned."
    case .keeping: return "Nothing is being kept yet."
    case .burned: return "Nothing burned yet."
    }
  }
  private var emptyDetail: String {
    switch tab {
    case .everything, .needsYou: return "I'll let you know when I have a question."
    case .willBurn: return "When I find leftovers I'm sure about, they show up here."
    case .keeping: return "Things you tell me to keep show up here."
    case .burned: return "Things I burn show up here, and old copies can be restored."
    }
  }

  private var emptyList: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill").font(.system(size: 54))
        .foregroundStyle(AutopilotTheme.green)
      Text(emptyTitle).font(.system(size: 24, weight: .bold, design: .rounded))
      Text(emptyDetail).font(.system(size: 15)).foregroundStyle(BurnTheme.muted)
        .multilineTextAlignment(.center)
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var detail: some View {
    Group {
      if let entry = selected {
        ScrollView { AutopilotDetailCard(model: model, entry: entry).id(entry.id) }
      } else {
        VStack(spacing: 10) {
          Text("👈").font(.system(size: 44))
          Text("Pick anything on the left").font(.system(size: 18, weight: .bold, design: .rounded))
          Text("I'll tell you what it is, why I think so, and what happens if I burn it.")
            .font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
            .multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.background(Color.white.opacity(0.025))
  }

  private var footer: some View {
    HStack(spacing: 14) {
      if !snapshot.coverageNotes.isEmpty {
        Text(snapshot.coverageNotes.joined(separator: " "))
          .font(.system(size: 12)).foregroundStyle(BurnTheme.muted).lineLimit(1)
      }
      Spacer(minLength: 0)
      Button("Advanced findings…") { model.openAdvancedFindings?() }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
        .clickPointer()
    }.padding(.horizontal, 26).padding(.vertical, 8)
  }
}

/// One line per thing: an icon, its name, one line about it, its status and its size.
struct AutopilotRow: View {
  let entry: AutopilotEntry
  let selected: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Text(AutopilotLook.emoji(entry.item.kind)).font(.system(size: 20))
          .frame(width: 38, height: 38)
          .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 3) {
          Text(entry.label).font(.system(size: 15, weight: .semibold)).lineLimit(1)
          Text(entry.item.detail).font(.system(size: 12.5)).foregroundStyle(BurnTheme.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 10)
        AutopilotPill(status: entry.status)
        Text(AutopilotText.size(entry.item.bytes))
          .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
          .foregroundStyle(BurnTheme.muted).frame(width: 64, alignment: .trailing)
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(
        selected ? BurnTheme.orange.opacity(0.14) : Color.clear,
        in: RoundedRectangle(cornerRadius: 12)
      )
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain).clickPointer()
      .accessibilityLabel(
        "\(entry.label), \(AutopilotLook.pill(entry.status)), \(AutopilotText.size(entry.item.bytes))"
      )
  }
}

/// What it is, why BZ thinks so, what happens if it burns, and the buttons. Everything with a
/// technical name (paths, process ids, facts) is folded into one disclosure at the bottom.
struct AutopilotDetailCard: View {
  @ObservedObject var model: AppModel
  let entry: AutopilotEntry
  @State private var technical = false

  /// Restore appears only for a burned thing that kept a way back.
  static func canRestore(_ entry: AutopilotEntry) -> Bool {
    entry.status == .burned && entry.receipt?.outcome == "burned" && entry.receipt?.restore != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        Text(entry.label).font(.system(size: 22, weight: .bold, design: .rounded))
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          AutopilotPill(status: entry.status, large: true)
          if entry.item.bytes > 0 {
            Text(AutopilotText.size(entry.item.bytes))
              .font(.system(size: 14, weight: .medium)).foregroundStyle(BurnTheme.muted)
          }
        }
      }
      block("What is it?", entry.item.detail)
      block("Why I think so", entry.why)
      outcome
      actions
      DisclosureGroup("Technical details", isExpanded: $technical) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(technicalLines, id: \.self) { line in
            Text(line).font(.system(size: 11.5, design: .monospaced))
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          }
        }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
      }.disclosureGroupStyle(ClickDisclosureStyle())
        .font(.system(size: 13)).foregroundStyle(BurnTheme.muted)
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var outcome: some View {
    switch entry.status {
    case .burned:
      block("What happened", entry.receipt?.detail ?? entry.consequence)
    case .protected:
      block("If I burn it", "I won't. Protected things are off limits, so I never touch them.")
    case .failed:
      block("If I burn it", entry.consequence)
      if let detail = entry.receipt?.detail { block("What happened", detail) }
    default:
      block("If I burn it", entry.consequence)
    }
  }

  private func block(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(BurnTheme.orange)
      Text(text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        if entry.status != .protected && entry.status != .burned {
          actionButton(
            "Burn now", symbol: "flame.fill", fill: BurnTheme.orange,
            text: Color.black.opacity(0.86)
          ) { model.burnNow(entry) }
          actionButton(
            "Keep forever", symbol: "hand.raised.fill", fill: Color.white.opacity(0.10),
            text: BurnTheme.cream
          ) { model.keepForever(entry) }
          .disabled(entry.status == .keep && entry.authority == "operator")
        }
        if Self.canRestore(entry), let receipt = entry.receipt {
          actionButton(
            "Restore", symbol: "arrow.uturn.backward", fill: AutopilotTheme.green.opacity(0.22),
            text: AutopilotTheme.green
          ) { model.restore(receipt) }
        }
      }
      if entry.status == .protected {
        Text("This one is protected, so there is no Burn button.")
          .font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
      }
    }
  }

  private func actionButton(
    _ title: String, symbol: String, fill: Color, text: Color, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol)
        Text(title)
      }
      .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(text)
      .padding(.horizontal, 16).frame(height: 42)
      .background(fill, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14)))
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain).clickPointer()
  }

  private var technicalLines: [String] {
    var lines = [String]()
    if let path = entry.item.path { lines.append("path: " + path) }
    if let pid = entry.item.pid { lines.append("pid: \(pid)") }
    for fact in entry.item.facts.sorted(by: { $0.key < $1.key }) {
      lines.append("\(fact.key): \(fact.value)")
    }
    lines.append("authority: " + (entry.authority ?? "none"))
    lines.append("revision: " + entry.item.revision)
    return lines
  }
}
