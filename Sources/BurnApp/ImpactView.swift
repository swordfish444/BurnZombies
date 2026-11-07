import AppKit
import BurnCore
import CoreText
import SwiftUI

// The impact surfaces deliberately keep operational evidence one level deeper.
enum BurnTheme {
  static let cream = Color(red: 0.985, green: 0.976, blue: 0.94)
  static let orange = Color(red: 1, green: 0.33, blue: 0.12)
  static let ember = Color(red: 0.78, green: 0.28, blue: 0.09)
  static let muted = Color(white: 0.68)
  static let line = Color.white.opacity(0.10)
  static func display(_ size: CGFloat) -> Font { .custom("Anton-Regular", size: size) }
  static func registerFonts() {
    if let url = Bundle.module.url(forResource: "Anton-Regular", withExtension: "ttf") {
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }
}
struct BurnBackdrop: View {
  var body: some View {
    ZStack {
      Color(red: 0.073, green: 0.074, blue: 0.070)
      LinearGradient(
        colors: [.white.opacity(0.055), .clear, .white.opacity(0.035)], startPoint: .topLeading,
        endPoint: .bottomTrailing)
    }.ignoresSafeArea()
  }
}
struct Skull: View {
  var size: CGFloat
  var celebration = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var flare = false
  @State private var flight: CGFloat = 0
  var body: some View {
    ZStack {
      if size > 80 {
        RadialGradient(
          colors: [BurnTheme.orange.opacity(0.13), .clear], center: .center,
          startRadius: 0, endRadius: size * 0.55
        )
        .frame(width: size * 1.2, height: size * 1.2)
      }
      Image(
        nsImage: NSImage(
          contentsOf: Bundle.module.url(forResource: "EmberSkull", withExtension: "png")!)!
      )
      .resizable().interpolation(.high).scaledToFit()
      .frame(width: size, height: size)
      .shadow(color: BurnTheme.orange.opacity(flare ? 0.2 : 0.04), radius: flare ? 20 : 8)
      .scaleEffect(flare ? 1.065 : 1, anchor: .bottom)
      ForEach(0..<6) { index in
        Circle().fill(BurnTheme.orange).frame(
          width: max(2, size * 0.012), height: max(2, size * 0.018)
        )
        .modifier(EmberFlight(progress: flight, index: index, size: size))
      }
    }.frame(width: size, height: size).accessibilityHidden(true).allowsHitTesting(false)
      .task(id: celebration) {
        guard celebration > 0, !reduceMotion else { return }
        flight = 0
        withAnimation(.easeOut(duration: 0.18)) { flare = true }
        withAnimation(.easeOut(duration: 1.15)) { flight = 1 }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.65)) { flare = false }
      }
  }
}
struct EmberFlight: AnimatableModifier {
  var progress: CGFloat
  var index: Int
  var size: CGFloat
  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }
  func body(content: Content) -> some View {
    content.opacity(sin(Double.pi * Double(progress)))
      .offset(
        x: CGFloat(index - 3) * size * 0.09 * (1 + progress * 0.5),
        y: -size * (0.15 + progress * (0.5 + CGFloat(index % 3) * 0.12)))
  }
}
struct ImpactValue: View {
  let value: String
  let size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(parts.first ?? "—").font(BurnTheme.display(size))
        .contentTransition(.numericText())
      if parts.count > 1 { Text(parts[1]).font(BurnTheme.display(size * 0.64)) }
    }.fixedSize().padding(.vertical, -9)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: value)
      .accessibilityElement(children: .ignore).accessibilityLabel(value)
  }
}
struct Flame: View {
  var size: CGFloat = 26
  var body: some View {
    Image(systemName: "flame.fill").font(.system(size: size)).foregroundStyle(BurnTheme.orange)
      .accessibilityHidden(true)
  }
}
extension ImpactNumbers {
  @MainActor static func make(_ model: AppModel, period: ImpactPeriod) -> Self {
    make(catalog: model.state.catalog, autopilot: model.state.autopilotImpact, period: period)
  }
  /// "Nov 7". The log keeps 30 days, so the year would only get in the way.
  static func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
  static func cpuTime(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value >= 3600 { return String(format: "~%.1f h", value / 3600) }
    if value >= 60 { return String(format: "~%.0f min", value / 60) }
    return String(format: "~%.0f s", value)
  }
  static func latency(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value >= 1000 ? String(format: "%.1fs", value / 1000) : String(format: "%.1fms", value)
  }
  var benefitTitle: String {
    benefit == .speed || benefit == .firstBurn ? "AGENT SPEED BOOST" : "AGENT BOOST"
  }
  var benefitValue: String {
    switch benefit {
    case .memory: return Self.bytes(memory)
    case .disk: return Self.bytes(disk)
    case .worktrees: return "\(worktrees)"
    default: return "\(count)"
    }
  }
  var benefitCaption: String {
    switch benefit {
    case .memory: return "Memory released"
    case .disk: return "Disk reclaimed"
    case .worktrees: return "Worktrees cleaned"
    default: return "Zombies burned"
    }
  }
  var zombiesBurned: String {
    let trees = benefit == .ready ? lifetimeWorktrees : worktrees
    if (benefit == .ready ? lifetimeCount : count) == 0 && trees > 0 {
      return "\(trees) \(trees == 1 ? "worktree" : "worktrees") cleaned"
        + (benefit == .ready ? " all time" : "")
    }
    let total = benefit == .ready ? lifetimeCount : count
    return "\(total) \(total == 1 ? "zombie" : "zombies") burned"
      + (benefit == .ready ? " all time" : "")
  }
  var age: String {
    guard let last else { return "No burns yet" }
    return Self.age(since: last)
  }
  static func age(since date: Date) -> String {
    let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes)m ago" }
    return minutes < 48 * 60 ? "\(minutes / 60)h ago" : "\(minutes / (24 * 60))d ago"
  }
}
struct BurnStatus: View {
  @ObservedObject var model: AppModel
  var compact = false
  var status: String {
    if model.autopilotAvailable {
      let sweep = model.autopilot.sweep
      if sweep.running || model.huntRunning { return "Hunting Zombies" }
      if !sweep.enabled { return "Autopilot off" }
      if sweep.lookOnly == true { return "Look-only · nothing burns" }
      if let retry = sweep.retryAfter, retry > Date() { return "Autopilot on · AI waiting" }
      // Without Full Disk Access Autopilot skips only the places macOS protects; the banner says
      // so in plain words, and once it's dismissed the status keeps saying it.
      return model.accessReady || model.showsAccessBanner ? "Autopilot on" : "Autopilot on · limited"
    }
    if !model.accessReady { return "Setup required" }
    if model.state.error != nil { return "Needs attention" }
    if model.huntRunning { return "Hunting Zombies" }
    if model.machineReview.phase == "paused" { return "Review paused" }
    if compact {
      if !model.demo && !model.machineReviewEnabled { return "Automatic hunts off" }
      return "Agent-led cleanup"
    }
    return "Watching this Mac"
  }
  /// In the popup, Autopilot's switch takes the status dot's place: the row reads as before, and
  /// one click turns Autopilot off or back on.
  var showsSwitch: Bool { compact && model.autopilotAvailable }
  var body: some View {
    HStack(spacing: compact ? 9 : 12) {
      if showsSwitch {
        AutopilotSwitch(on: model.autopilot.sweep.enabled, alert: model.state.error != nil) {
          model.setAutopilot(enabled: !model.autopilot.sweep.enabled)
        }
      } else {
        Circle().fill(model.state.error != nil ? .red : BurnTheme.orange)
          .frame(width: compact ? 12 : 16, height: compact ? 12 : 16)
      }
      Text(status).font(.system(size: compact ? 13 : 18))
        .foregroundStyle(showsSwitch && !model.autopilot.sweep.enabled ? BurnTheme.muted : Color(white: 0.82))
      Button {
        if !model.accessReady && !model.autopilotAvailable {
          model.openFullDiskAccessSettings()
        } else if model.huntRunning {
          model.openHunt?()
        } else {
          model.requestAgentCleanup()
        }
      } label: {
        HStack(spacing: 6) {
          if (model.accessReady || model.autopilotAvailable) && model.huntRunning {
            Image(systemName: "arrow.up.right")
          } else {
            Text(!model.accessReady && !model.autopilotAvailable ? "Finish setup" : "Hunt Zombies")
          }
        }
        .font(.system(size: compact ? 10.5 : 12, weight: .semibold)).foregroundStyle(
          BurnTheme.orange
        )
        .padding(.horizontal, 9).padding(.vertical, compact ? 4 : 6)
        .background(BurnTheme.orange.opacity(0.08), in: Capsule()).contentShape(Capsule())
      }.buttonStyle(.plain).clickPointer().disabled(
        model.accessReady && !model.demo && !model.harnessConfigured
      )
      .accessibilityLabel(
        !model.accessReady
          ? "Finish setup" : model.huntRunning ? "View hunt progress" : "Hunt Zombies"
      )
      .accessibilityIdentifier(model.huntRunning ? "view-hunt-progress" : "start-hunt")
      .help(
        !model.accessReady
          ? "Enable Full Disk Access in Settings to begin."
          : model.huntRunning
            ? "Watch the hunt and its live activity log." : "Start a deep hunt across this Mac now."
      )
    }
  }
}
/// Autopilot's on/off switch, drawn in BZ's colors at the size of a small macOS switch. Off, BZ
/// still looks and asks but burns nothing on its own, and scheduled AI sweeps wait.
struct AutopilotSwitch: View {
  static let size = CGSize(width: 26, height: 15)
  let on: Bool
  /// Red instead of orange while the app reports an error, as the status dot was.
  var alert = false
  let toggle: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Button(action: toggle) {
      Capsule().fill(on ? (alert ? Color.red : BurnTheme.orange) : Color.white.opacity(0.17))
        .overlay(alignment: on ? .trailing : .leading) {
          Circle().fill(on ? BurnTheme.cream : Color(white: 0.62)).padding(2)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .padding(.vertical, 3).contentShape(Rectangle())
    }.buttonStyle(.plain).clickPointer()
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: on)
      .help(
        on
          ? "Turn Autopilot off. BZ stops burning on its own until you turn it back on."
          : "Turn Autopilot on. BZ burns what's safe and asks about the rest.")
      .accessibilityRepresentation {
        Toggle("Autopilot", isOn: Binding(get: { on }, set: { if $0 != on { toggle() } }))
      }
      .accessibilityIdentifier("autopilot-switch")
  }
}
struct MemoryPressureRow: View {
  @ObservedObject var model: AppModel
  var compact = false
  var body: some View {
    HStack(spacing: compact ? 9 : 18) {
      Circle().fill(
        model.pressure == "Low"
          ? Color(red: 0.48, green: 0.76, blue: 0.39) : model.pressure == "High" ? .red : .orange
      ).frame(width: compact ? 13 : 17, height: compact ? 13 : 17)
      Text("Memory pressure").font(.system(size: compact ? 13 : 17))
      if !compact {
        Rectangle().fill(BurnTheme.line).frame(width: 1, height: 23).padding(.horizontal, 24)
        Text(model.pressure == "Low" ? "Room for your next run." : "A little breathing room helps.")
          .foregroundStyle(BurnTheme.muted).font(.system(size: 16))
      }
      Spacer()
      Text(model.pressure).font(
        .system(size: compact ? 12 : 17, weight: compact ? .medium : .regular))
    }
  }
}
struct MiniImpactView: View {
  static let size = NSSize(width: 360, height: 550)
  static let tabWidth: CGFloat = 72
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var model: AppModel
  @State private var hoveredLink: String?
  var numbers: ImpactNumbers { .make(model, period: .today) }
  var totals: ImpactNumbers { .make(model, period: model.miniImpactPeriod) }
  /// What BZ burned on its own that the owner hasn't called good or undone yet.
  var openTells: [AutopilotTell] { model.autopilot.tellsWaiting }
  /// What Autopilot found and hasn't burned yet.
  var found: UInt64 {
    model.autopilot.entries.filter { $0.status == .unsure || $0.status == .burn }
      .reduce(0) { $0 + $1.item.bytes }
  }
  /// Look-only on a running Autopilot: the card says so and offers the one tap that starts burning.
  var lookOnly: Bool {
    model.autopilotAvailable && model.autopilot.sweep.enabled
      && model.autopilot.sweep.lookOnly == true
  }
  /// What BZ would burn on its own the moment burning starts.
  var wouldBurn: UInt64 {
    model.autopilot.entries.filter { $0.status == .burn }.reduce(0) { $0 + $1.item.bytes }
  }
  var lastBurn: String {
    let history = ImpactNumbers.make(model, period: .all)
    if history.last != nil { return "Last burn \(history.age)" }
    if !model.accessReady && !model.autopilotAvailable { return "Waiting for Full Disk Access" }
    guard history.count + history.worktrees == 0 else { return "No burns yet today" }
    // Before the first burn, what's waiting is the reward in sight.
    return found >= AutopilotPolicy.worthAsking
      ? "Found \(ImpactNumbers.bytes(found)) of leftovers" : "Ready for your first burn"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Skull(size: 34, celebration: model.burnPulse)
        Text("BURNZOMBIES").font(BurnTheme.display(22)).tracking(0.25)
        Spacer(minLength: 8)
        Button {
          model.quit()
        } label: {
          Image(systemName: "power").font(.system(size: 15, weight: .semibold)).foregroundStyle(.gray)
            .frame(width: 24, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).clickPointer().help("Quit BurnZombies").accessibilityLabel("Quit")
          .accessibilityIdentifier("quit")
        Button {
          model.openSettings?()
        } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundStyle(.gray)
            .frame(width: 28, height: 32).contentShape(Rectangle())
        }.clickPointer().help("Settings").accessibilityLabel("Settings")
      }.frame(height: 36)
      BurnStatus(model: model, compact: true).frame(height: 22).padding(.top, 9)
      if model.autopilotAvailable, !model.autopilot.questions.isEmpty {
        // Same 40 pt slot as the tagline, so the fixed popover layout never moves.
        Button {
          model.openTeach?()
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble.fill").font(.system(size: 16, weight: .bold))
            Text(
              "BZ has \(model.autopilot.questions.count) quick question\(model.autopilot.questions.count == 1 ? "" : "s")"
            ).font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            // What answering frees, beside the button that frees it.
            Text(ImpactNumbers.bytes(model.autopilot.questions.reduce(0) { $0 + $1.bytes }))
              .font(.system(size: 13, weight: .semibold)).fixedSize()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
          }.foregroundStyle(.black).padding(.horizontal, 14).frame(height: 40)
            .background(BurnTheme.orange, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).clickPointer().padding(.top, 16)
          .accessibilityLabel("Answer BZ's quick questions")
      } else if model.autopilotAvailable, !openTells.isEmpty {
        // BZ acts instead of asking, so a tell comes when there is no question to prompt: the same
        // slot. The sentence is the whole message, so it gets the room the questions' size takes.
        Button {
          model.openTeach?()
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "flame.fill").font(.system(size: 16, weight: .bold))
            Text(AutopilotText.burnedOnItsOwn(openTells))
              .font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
          }.foregroundStyle(.black).padding(.horizontal, 14).frame(height: 40)
            .background(BurnTheme.orange, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).clickPointer().padding(.top, 16)
          .accessibilityLabel("See what BZ burned on its own")
      } else {
        Text("Dead weight. Gone.").font(BurnTheme.display(28))
          .frame(height: 40, alignment: .leading).padding(.top, 16)
      }
      // The tabs take the old TODAY label's row and switch only the four totals below.
      HStack(spacing: 0) {
        ForEach(ImpactPeriod.allCases, id: \.self) { option in
          Button {
            model.miniImpactPeriod = option
          } label: {
            Text(option.rawValue.uppercased()).font(.system(size: 11, weight: .semibold))
              .tracking(0.5)
              .foregroundStyle(model.miniImpactPeriod == option ? BurnTheme.cream : BurnTheme.muted)
              .frame(width: Self.tabWidth, height: 14, alignment: .leading)
              .contentShape(Rectangle())
          }.clickPointer().accessibilityIdentifier("mini-period-" + option.rawValue)
            .accessibilityValue(model.miniImpactPeriod == option ? "Selected" : "Not selected")
        }
      }.frame(height: 14).padding(.top, 12)
      VStack(spacing: 10) {
        HStack(spacing: 18) {
          miniMetric("\(totals.count)", "Zombies burned", flame: true)
          Rectangle().fill(BurnTheme.line).frame(width: 1, height: 50)
          miniMetric(ImpactNumbers.bytes(totals.memory), "Memory released")
        }
        HStack(spacing: 18) {
          miniMetric(ImpactNumbers.bytes(totals.disk), "Disk reclaimed")
          Rectangle().fill(BurnTheme.line).frame(width: 1, height: 50)
          Button {
            model.openWorktrees?()
          } label: {
            miniMetric("\(totals.worktrees)", "Worktrees cleaned")
          }.clickPointer().help("Open worktree inventory and recovery")
        }
        // A tab switch replaces the totals immediately; new burns within a period still tick up.
      }.id(model.miniImpactPeriod).frame(height: 120).padding(.top, 6)
      Group {
        // Look-only comes first: nothing else on the panel says burning waits for a tap.
        if lookOnly {
          lookOnlyCard
        } else if model.autopilotAvailable, model.autopilot.recoveryKey != nil {
          keyCard
        } else if model.showsAccessBanner {
          accessCard
        } else {
          speedCard
        }
      }.padding(.top, 25)
      line.padding(.top, 16)
      MemoryPressureRow(model: model, compact: true).frame(height: 18).padding(.top, 12)
      Text(lastBurn).font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
        .frame(height: 14).padding(.top, 5)
      line.padding(.top, 18)
      // Three equal links in the same 48 pt row, each led by its own orange mark.
      HStack(spacing: 0) {
        footerLink("Impact", symbol: "chart.bar.fill", help: "See everything BZ freed") {
          model.openImpact?()
        }
        footerDivider
        footerLink(
          "Findings", symbol: "binoculars.fill",
          help: "Review discovered processes, worktrees and storage"
        ) { model.openFindings?() }
        footerDivider
        footerLink("Burn Log", symbol: "flame.fill", help: "Recent burns and what they freed") {
          model.openLog?()
        }
      }.frame(height: 48)
      Spacer(minLength: 0)
    }.padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 6)
      .frame(width: Self.size.width, height: Self.size.height)
      .foregroundStyle(BurnTheme.cream).buttonStyle(.plain).ignoresSafeArea()
      .background(BurnBackdrop()).preferredColorScheme(.dark)
  }
  var accessCard: some View {
    HStack(spacing: 0) {
      Button {
        model.openFullDiskAccessSettings()
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "lock.shield").font(.system(size: 23)).foregroundStyle(BurnTheme.orange)
          VStack(alignment: .leading, spacing: 5) {
            Text("Allow Full Disk Access").font(.system(size: 12.5, weight: .semibold))
            Text("Open System Settings ↗").font(.system(size: 10.5)).foregroundStyle(
              BurnTheme.muted)
          }
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity).frame(height: 68).padding(.leading, 13).contentShape(
          Rectangle())
      }.clickPointer().help("Open Full Disk Access in System Settings")
        .accessibilityIdentifier("compact-open-full-disk-access")
      Button {
        model.dismissAccessBanner()
      } label: {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(BurnTheme.muted).frame(width: 34, height: 68).contentShape(Rectangle())
      }.clickPointer().help("Dismiss banner. Access setup remains in Settings.")
        .accessibilityLabel("Dismiss access banner").accessibilityIdentifier(
          "dismiss-access-banner")
    }.background(BurnTheme.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7).stroke(BurnTheme.orange.opacity(0.55)).allowsHitTesting(
          false))
  }
  /// What waits for the backup key: old copies BZ would burn now.
  var waitingForKey: UInt64 {
    model.autopilot.entries.filter { $0.item.kind == .worktree && $0.status == .burn }
      .reduce(0) { $0 + $1.item.bytes }
  }
  /// Old copies wait for the owner's OK to use the backup key: one tap, and macOS asks.
  var keyCard: some View {
    let asking: Bool = model.autopilot.recoveryKey?.asking == true
    let waiting: UInt64 = waitingForKey
    let header: String =
      waiting > 0 ? "\(ImpactNumbers.bytes(waiting)) WAITS FOR YOUR OK" : "OLD COPIES WAIT FOR YOUR OK"
    return VStack(alignment: .leading, spacing: 8) {
      Text(header).font(.system(size: 10.5, weight: .bold)).tracking(0.3)
        .foregroundStyle(BurnTheme.orange).lineLimit(1).minimumScaleFactor(0.8)
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Let BZ use its backup key.").font(.system(size: 13, weight: .semibold))
          Text(asking ? "macOS is asking you now." : "Enter your password when macOS asks.")
            .font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
        }.lineLimit(1).minimumScaleFactor(0.8)
        Spacer(minLength: 0)
        Button {
          model.allowRecoveryKey()
        } label: {
          Text("Allow").font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.86)).padding(.horizontal, 14).frame(height: 32)
            .background(
              BurnTheme.orange.opacity(asking ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.clickPointer().disabled(asking)
          .help("macOS asks whether BZ may use its backup key, so it can back up old copies")
          .accessibilityIdentifier("allow-recovery-key")
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
      .frame(height: 84)
      .background(BurnTheme.orange.opacity(0.085), in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7).stroke(BurnTheme.orange.opacity(0.75))
          .allowsHitTesting(false))
  }
  var lookOnlyCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("LOOK-ONLY · NOTHING BURNS YET").font(.system(size: 10.5, weight: .bold)).tracking(0.3)
        .foregroundStyle(BurnTheme.orange)
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(wouldBurn > 0 ? "I'd burn \(ImpactNumbers.bytes(wouldBurn))." : "Nothing to burn yet.")
            .font(.system(size: 13, weight: .semibold))
          Button {
            model.openFindings?()
          } label: {
            Text("See what in Findings").font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
          }.clickPointer().help("See everything BZ found and what it would burn")
        }.lineLimit(1).minimumScaleFactor(0.85)
        Spacer(minLength: 0)
        Button {
          model.setLookOnly(false)
        } label: {
          Text("Start burning").font(.system(size: 12.5, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.86)).padding(.horizontal, 14).frame(height: 32)
            .background(BurnTheme.orange, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.clickPointer().help("Let BZ burn what it found, starting now")
          .accessibilityIdentifier("start-burning")
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
      .frame(height: 84)
      .background(BurnTheme.orange.opacity(0.085), in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7).stroke(BurnTheme.orange.opacity(0.75))
          .allowsHitTesting(false))
  }
  var speedCard: some View {
    Button {
      model.openImpact?()
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        Text(numbers.benefitTitle).font(.system(size: 10.5, weight: .bold)).tracking(0.3)
          .foregroundStyle(BurnTheme.orange)
        switch numbers.benefit {
        case .firstBurn, .ready:
          HStack(spacing: 12) {
            if numbers.benefit == .firstBurn { warmupGauge } else { Flame(size: 28) }
            VStack(alignment: .leading, spacing: 4) {
              Text(numbers.benefit == .firstBurn ? "Still warming up." : "Ready for the next burn.")
                .font(.system(size: 13, weight: .semibold))
              Text(
                numbers.benefit == .firstBurn
                  ? "Your first cleanup starts here." : numbers.zombiesBurned
              )
              .font(.system(size: 11))
              .foregroundStyle(BurnTheme.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
          }
        case .memory, .helpers, .disk, .worktrees:
          HStack(spacing: 10) {
            ImpactValue(value: numbers.benefitValue, size: 32).foregroundStyle(BurnTheme.orange)
            VStack(alignment: .leading, spacing: 4) {
              Text(numbers.benefitCaption).font(.system(size: 12, weight: .semibold))
              Text(numbers.benefit == .memory ? numbers.zombiesBurned : "Dead weight. Gone.")
                .font(.system(size: 10.5)).foregroundStyle(BurnTheme.muted)
            }.lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
          }.frame(height: 38)
        case .speed:
          HStack {
            Text(numbers.boost).font(BurnTheme.display(37)).foregroundStyle(BurnTheme.orange)
              .lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
          }.frame(height: 38)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
        .frame(height: 84).contentShape(RoundedRectangle(cornerRadius: 7))
        .background(BurnTheme.orange.opacity(0.085), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(BurnTheme.orange.opacity(0.75)))
    }.clickPointer().help("View impact")
  }
  var warmupGauge: some View {
    ZStack {
      Path { path in
        path.addArc(
          center: CGPoint(x: 17, y: 23), radius: 15,
          startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
      }.stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
      Path { path in
        path.move(to: CGPoint(x: 17, y: 23))
        path.addLine(to: CGPoint(x: 25, y: 15))
      }.stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }.foregroundStyle(BurnTheme.orange).frame(width: 34, height: 28).accessibilityHidden(true)
  }
  var line: some View { Rectangle().fill(BurnTheme.line).frame(height: 1) }
  var footerDivider: some View { Rectangle().fill(BurnTheme.line).frame(width: 1, height: 18) }
  /// A footer link: an orange mark that glows a little brighter under the pointer, then its name.
  func footerLink(
    _ title: String, symbol: String, help: String, action: @escaping () -> Void
  ) -> some View {
    let hovered = hoveredLink == title
    return Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(BurnTheme.orange)
          .shadow(color: BurnTheme.orange.opacity(hovered ? 0.7 : 0.4), radius: hovered ? 6 : 4)
          .accessibilityHidden(true)
        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
      }
      .frame(maxWidth: .infinity).frame(height: 32)
      .background(Color.white.opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
      .frame(height: 44).contentShape(Rectangle())
    }.clickPointer().help(help)
      .onHover { inside in
        if inside { hoveredLink = title } else if hoveredLink == title { hoveredLink = nil }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
      .accessibilityLabel(title)
  }
  func miniMetric(_ value: String, _ title: String, flame: Bool = false) -> some View {
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    return VStack(alignment: .leading, spacing: 2) {
      (Text(parts.first ?? "—").font(BurnTheme.display(34))
        + Text(parts.count > 1 ? " " + parts[1] : "").font(BurnTheme.display(21)))
        .lineLimit(1).minimumScaleFactor(0.65).frame(height: 40, alignment: .leading)
        .contentTransition(.numericText())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: value)
      HStack(spacing: 3) {
        if flame { Flame(size: 12) }
        Text(title).font(.system(size: 9.5)).foregroundStyle(Color(white: 0.82))
          .lineLimit(1).minimumScaleFactor(0.9)
      }.frame(height: 12)
    }.frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value)")
  }
}
struct ImpactWindowView: View {
  @ObservedObject var model: AppModel
  var period: ImpactPeriod { model.impactPeriod }
  @State private var showCalculation = false
  var numbers: ImpactNumbers { .make(model, period: period) }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 11) {
        Color.clear.frame(width: 87)
        Skull(size: 36, celebration: model.burnPulse)
        Text("BURNZOMBIES").font(BurnTheme.display(25)).tracking(1)
        Spacer()
        Button {
          model.openSettings?()
        } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 21)).foregroundStyle(.gray)
        }.clickPointer().help("Settings")
      }.padding(.horizontal, 20).frame(height: 57)
        .overlay {
          HStack(spacing: 20) {
            nav("Impact")
            nav("Burn Log")
          }.offset(x: 38)
        }
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      if model.impactTab == "Burn Log" { burnLog } else { impact }
    }.frame(width: 1008, height: 930).foregroundStyle(BurnTheme.cream).ignoresSafeArea()
      .buttonStyle(.plain).background(BurnBackdrop()).preferredColorScheme(.dark)
      .sheet(isPresented: $showCalculation) { calculation }
  }
  func nav(_ title: String) -> some View {
    Button {
      model.impactTab = title
    } label: {
      Text(title).font(.system(size: 17, weight: model.impactTab == title ? .semibold : .regular))
        .foregroundStyle(model.impactTab == title ? BurnTheme.cream : BurnTheme.muted)
        .padding(.horizontal, 12).frame(height: 57)
        .overlay(alignment: .bottom) {
          if model.impactTab == title { BurnTheme.orange.frame(height: 3) }
        }
    }.clickPointer()
  }
  var impact: some View {
    VStack(spacing: 0) {
      HStack {
        BurnStatus(model: model)
        Spacer()
        ForEach(ImpactPeriod.allCases, id: \.self) { option in
          Button {
            model.impactPeriod = option
          } label: {
            Text(option.rawValue).font(
              .system(size: 17, weight: period == option ? .semibold : .regular)
            )
            .foregroundStyle(period == option ? BurnTheme.cream : BurnTheme.muted)
            .frame(width: 96, height: 36)
            .contentShape(Rectangle())
            .background(
              period == option ? Color.white.opacity(0.08) : .clear,
              in: RoundedRectangle(cornerRadius: 11))
          }.clickPointer()
            .accessibilityIdentifier("impact-period-" + option.rawValue)
            .accessibilityValue(period == option ? "Selected" : "Not selected")
        }
      }.padding(.horizontal, 18).padding(.top, 22)
      HStack(alignment: .center, spacing: 28) {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 8) {
            BrandHeading(text: "TAME THE", size: 98).frame(height: 85)
            BrandHeading(text: "HORDE", size: 98).frame(height: 85)
          }.frame(height: 178)
          Text(
            model.accessReady ? "Your agents have room to run." : "One permission. Then we watch."
          ).font(.system(size: 29, weight: .medium))
            .foregroundStyle(BurnTheme.muted).padding(.top, 13)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Skull(size: 272, celebration: model.burnPulse).padding(.trailing, 125)
      }.padding(.leading, 54).frame(height: 282)
      HStack(spacing: 0) {
        metric("\(numbers.count)", "Zombies burned", flame: true)
        Rectangle().fill(BurnTheme.line).frame(width: 1, height: 92)
        metric(ImpactNumbers.bytes(numbers.memory), "Memory released")
        Rectangle().fill(BurnTheme.line).frame(width: 1, height: 92)
        metric(ImpactNumbers.bytes(numbers.disk), "Disk reclaimed")
        Rectangle().fill(BurnTheme.line).frame(width: 1, height: 92)
        metric("\(numbers.worktrees)", "Worktrees cleaned")
        // A period switch replaces the totals immediately; new burns within a period still tick up.
      }.id(period).frame(height: 112).padding(.top, 5)
      Text(period.caption)
        .font(.system(size: 15)).foregroundStyle(.gray).padding(.top, 3).padding(.bottom, 12)
      speedCard
      MemoryPressureRow(model: model).padding(.horizontal, 28).frame(height: 49)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BurnTheme.line)).padding(.top, 17)
      Button {
        model.impactTab = "Burn Log"
      } label: {
        let last = lastBurn
        HStack(spacing: 24) {
          Flame(size: 35)
          VStack(alignment: .leading, spacing: 5) {
            Text(last.map { "Last burn: " + $0.row.title } ?? "Your next cleanup starts here.")
              .font(.system(size: 18, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(
              last.map { "\($0.row.result) · \(ImpactNumbers.age(since: $0.finished))" }
                ?? "No burns yet."
            )
            .font(.system(size: 16)).foregroundStyle(BurnTheme.muted)
          }
          Spacer()
          Text("Burn Log").font(.system(size: 16))
          Image(systemName: "chevron.right").foregroundStyle(.gray)
        }.padding(.horizontal, 24).frame(height: 67)
          .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
          .overlay(RoundedRectangle(cornerRadius: 11).stroke(BurnTheme.line))
      }.clickPointer().padding(.top, 13)
      Spacer(minLength: 8)
      Text("You build. We burn.").font(.system(size: 14, design: .monospaced)).tracking(3)
        .foregroundStyle(.gray).padding(.bottom, 18)
    }.padding(.horizontal, 37)
  }
  /// The Burn Log's newest finished burn in this period, the row the link to the log names.
  var lastBurn: (row: BurnLogRow, finished: Date)? {
    let now = Date()
    let start = period.start(now: now, calendar: .current)
    for row in logRows {
      if let finished = row.finishedAt, finished >= start, finished <= now { return (row, finished) }
    }
    return nil
  }
  func metric(_ value: String, _ title: String, flame: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ImpactValue(value: value, size: 50)
      HStack(spacing: 12) {
        if flame { Flame() }
        Text(title).font(.system(size: 17))
      }
    }.frame(maxWidth: .infinity, alignment: .center)
  }
  var speedCard: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        Text(numbers.benefitTitle).font(.system(size: 17, weight: .semibold, design: .monospaced))
          .tracking(1).foregroundStyle(BurnTheme.orange)
        Group {
          switch numbers.benefit {
          case .speed:
            Text(numbers.boost).font(BurnTheme.display(94)).foregroundStyle(BurnTheme.orange)
          case .memory, .helpers, .disk, .worktrees:
            VStack(alignment: .leading, spacing: 3) {
              ImpactValue(value: numbers.benefitValue, size: 64).foregroundStyle(BurnTheme.orange)
              Text(numbers.benefitCaption).font(.system(size: 17))
            }
          case .firstBurn, .ready:
            Text(numbers.benefit == .firstBurn ? "Still warming up." : "Ready for the next burn.")
              .font(BurnTheme.display(27)).foregroundStyle(BurnTheme.orange)
          }
        }.frame(height: 96, alignment: .leading)
      }.frame(width: 324, alignment: .leading)
      Rectangle().fill(BurnTheme.line).frame(width: 1, height: 122)
      VStack(alignment: .leading, spacing: 10) {
        Text(numbers.benefit == .speed ? "LESS WAITING. MORE DOING." : "ROOM FOR YOUR NEXT RUN.")
          .font(BurnTheme.display(22)).tracking(1)
        if numbers.benefit == .speed {
          VStack(spacing: 14) {
            latencyRow("Before", numbers.before, color: Color(white: 0.43), fraction: 1)
            latencyRow(
              "Now", numbers.after, color: BurnTheme.orange,
              fraction: min(1, (numbers.after ?? 1) / max(0.0001, numbers.before ?? 1)))
          }.padding(.top, 1)
        } else {
          HStack(spacing: 14) {
            Flame(size: 30)
            VStack(alignment: .leading, spacing: 4) {
              Text(
                numbers.benefit == .firstBurn
                  ? "Your first cleanup starts here." : numbers.zombiesBurned
              )
              .font(.system(size: 20, weight: .semibold))
              if numbers.benefit != .firstBurn {
                Text("Less background baggage.").font(.system(size: 16)).foregroundStyle(
                  BurnTheme.muted)
              }
            }
          }.frame(height: 57, alignment: .leading)
        }
        Button {
          showCalculation = true
        } label: {
          HStack {
            Spacer()
            Text("How BZ counts")
            Image(systemName: "chevron.right")
          }.font(.system(size: 15))
        }.clickPointer().padding(.top, 4)
      }.padding(.leading, 51)
    }.padding(.horizontal, 37).frame(height: 160)
      .background(
        LinearGradient(
          colors: [BurnTheme.orange.opacity(0.11), BurnTheme.orange.opacity(0.055)],
          startPoint: .topLeading, endPoint: .bottomTrailing),
        in: RoundedRectangle(cornerRadius: 13)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 13).stroke(BurnTheme.orange.opacity(0.75), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
  }
  func latencyRow(_ label: String, _ value: Double?, color: Color, fraction: Double) -> some View {
    HStack(spacing: 14) {
      Text(label).font(.system(size: 18)).frame(width: 55, alignment: .leading)
      Text(ImpactNumbers.latency(value)).font(
        .system(size: 18, weight: .semibold, design: .monospaced)
      ).frame(width: 64, alignment: .leading)
      GeometryReader { geo in
        RoundedRectangle(cornerRadius: 4).fill(value == nil ? Color.white.opacity(0.06) : color)
          .frame(width: max(8, geo.size.width * fraction), height: 15)
      }.frame(height: 15)
    }
  }
  var logRows: [BurnLogRow] { model.state.catalog.burnLog(autopilot: model.autopilot.receipts) }
  var burnLog: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("THE BURN LOG.").font(BurnTheme.display(49))
        Text("A little less dead weight.").font(.system(size: 22)).foregroundStyle(BurnTheme.muted)
        if model.state.error != nil {
          Text("BZ hit a problem.").foregroundStyle(.orange)
          Button("Open Settings") { model.openSettings?() }.clickPointer()
        }
        HStack(spacing: 18) {
          Text("RECENT BURNS").font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(.gray)
          Spacer()
          // What each row's mark means.
          ForEach(BurnLogRow.Kind.allCases, id: \.self) { kind in
            HStack(spacing: 5) {
              BurnMark(kind: kind, size: 13)
              Text(kind.rawValue).font(.system(size: 13)).foregroundStyle(BurnTheme.muted)
            }
          }
        }
        let rows = logRows
        if rows.isEmpty {
          Text(
            model.demo
              ? "18 zombies burned · 1.2 GB released · 2m ago"
              : "No burns yet. Your work comes first."
          ).foregroundStyle(BurnTheme.muted).padding(.vertical, 24)
        }
        // Hundreds of rows, so they're tight and made only as they scroll into view.
        LazyVStack(spacing: 8) {
          ForEach(rows) { row in logRow(row) }
        }
      }.padding(38).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  func logRow(_ row: BurnLogRow) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text(row.words).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
        if case .output(let receipt) = row, ["prepared", "unverified"].contains(receipt.outcome) {
          HStack {
            Button("Check it") { model.reconcileDisk(receipt.id, restore: false) }.clickPointer()
            Button("Put it back") { model.reconcileDisk(receipt.id, restore: true) }.clickPointer()
          }
          Text(
            "This won't overwrite or delete anything, and it doesn't count as a burn. Anything that doesn't match stays put."
          ).font(.caption)
        }
      }.padding(.top, 8).padding(.leading, 17).frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      HStack(spacing: 10) {
        BurnMark(kind: row.kind)
        Text(row.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).help(row.title)
        Spacer(minLength: 16)
        Text(row.result).foregroundStyle(BurnTheme.muted).fixedSize()
        // The day, in a column of its own.
        Text(ImpactNumbers.day(row.date)).foregroundStyle(BurnTheme.muted)
          .frame(width: 62, alignment: .trailing)
      }
    }.disclosureGroupStyle(ClickDisclosureStyle()).padding(.horizontal, 18).padding(.vertical, 12)
      .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }
  var calculation: some View {
    BurnCountsSheet(
      numbers: numbers, demo: model.demo,
      done: { showCalculation = false },
      openLog: {
        showCalculation = false
        model.impactTab = "Burn Log"
      },
      previewBurn: {
        showCalculation = false
        model.previewBurn()
      })
  }
}

/// What a Burn Log row burned, as a mark that lines up whichever kind it is.
struct BurnMark: View {
  let kind: BurnLogRow.Kind
  var size: CGFloat = 16
  var symbol: String {
    switch kind {
    case .program: return "flame.fill"
    case .copy: return "folder.fill"
    case .folder: return "trash.fill"
    }
  }
  var body: some View {
    Image(systemName: symbol).font(.system(size: size)).foregroundStyle(BurnTheme.orange)
      // The same box whichever glyph it is, so every row is the same height.
      .frame(width: size + 6, height: size + 2).help(kind.rawValue)
      .accessibilityLabel(kind.rawValue)
  }
}

/// How the numbers are counted, in plain words.
struct BurnCountsSheet: View {
  /// One thing BZ counts: what it's called, and how it's counted.
  struct Fact: Identifiable {
    let name: String
    let words: String
    var id: String { name }
  }
  static let width: CGFloat = 520
  static let title = "HOW BZ COUNTS."
  static let facts: [Fact] = [
    Fact(
      name: "Programs",
      words:
        "A program counts once it stops and stays gone for 2 minutes. Memory is what it was using. Programs can share memory, so this may read a little high."
    ),
    Fact(
      name: "Old copies and junk folders",
      words:
        "They count once they're gone. Disk is their size, minus any backup BZ keeps. Files can share space, so this may read a little high too."
    ),
    Fact(
      name: "CPU time saved",
      words:
        "How busy a program was, times how long your Mac stayed awake after it stopped, up to a day per burn. Sleep, restarts and programs that come back add nothing."
    ),
    Fact(
      name: "Agent speed",
      words:
        "How fast commands start on this Mac, before and after. Slow results count too. A boost shows only when it's clear: at least 5% and 1 ms. It doesn't measure AI or network speed."
    ),
    Fact(
      name: "The Burn Log",
      words: "It keeps about 500 burns, for up to 30 days. Your totals keep counting."
    ),
  ]
  let numbers: ImpactNumbers
  let demo: Bool
  let done: () -> Void
  let openLog: () -> Void
  let previewBurn: () -> Void
  /// The number beside a fact, only once there is one.
  func value(_ fact: Fact) -> String? {
    switch fact.name {
    case "CPU time saved": return numbers.cpuSeconds.map { ImpactNumbers.cpuTime($0) }
    case "Agent speed":
      guard numbers.before != nil, numbers.after != nil else { return nil }
      return
        "Before \(ImpactNumbers.latency(numbers.before)) · Now \(ImpactNumbers.latency(numbers.after))"
    default: return nil
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(Self.title).font(BurnTheme.display(34))
        Spacer()
        Button("Done", action: done).clickPointer()
      }
      ForEach(Self.facts) { fact in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(fact.name).font(.system(size: 15, weight: .semibold))
            Spacer()
            if let value = value(fact) {
              Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(
                BurnTheme.orange)
            }
          }
          Text(fact.words).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if demo { Text("These numbers are made up for this preview.").font(.system(size: 14)) }
      HStack {
        if demo {
          Button("Preview success animation", action: previewBurn).clickPointer()
        }
        Spacer()
        Button("Open Burn Log", action: openLog).clickPointer()
      }
    }.padding(32).frame(width: Self.width).foregroundStyle(BurnTheme.cream)
      .background(BurnBackdrop())
  }
}

/// CoreText's ink bounds give the display face a deliberate cap-height line box.
/// Anton's built-in leading is designed for posters and is too tall for this two-line lockup.
struct BrandHeading: NSViewRepresentable {
  let text: String
  let size: CGFloat
  func makeNSView(context: Context) -> HeadingInk { HeadingInk() }
  func updateNSView(_ view: HeadingInk, context: Context) {
    view.text = text
    view.pointSize = size
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    view.setAccessibilityLabel(text)
    view.needsDisplay = true
  }
}
final class HeadingInk: NSView {
  var text = ""
  var pointSize: CGFloat = 109
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    // Core Text's text matrix is not restored by saveGState. A previous line can
    // leave its ending position here, shifting this line's measured ink bounds.
    let previousTextMatrix = context.textMatrix
    context.saveGState()
    defer {
      context.restoreGState()
      context.textMatrix = previousTextMatrix
    }
    context.textMatrix = .identity
    let font = NSFont(name: "Anton-Regular", size: pointSize) ?? .boldSystemFont(ofSize: pointSize)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          .font: font, .foregroundColor: NSColor(red: 0.985, green: 0.976, blue: 0.94, alpha: 1),
          .kern: -1,
        ]))
    let ink = CTLineGetImageBounds(line, context)
    let scale = min(1, bounds.width / max(1, ink.width), bounds.height / max(1, ink.height))
    context.translateBy(x: 0, y: (bounds.height - ink.height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    context.textPosition = CGPoint(x: -ink.minX, y: -ink.minY)
    CTLineDraw(line, context)
  }
}
