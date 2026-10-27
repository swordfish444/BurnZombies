import AppKit
import BurnCore
import CoreText
import SwiftUI

// The impact surfaces deliberately keep operational evidence one level deeper.
enum BurnTheme {
  static let cream = Color(red: 0.985, green: 0.976, blue: 0.94)
  static let orange = Color(red: 1, green: 0.33, blue: 0.12)
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
    make(catalog: model.state.catalog, period: period)
  }
  static func bytes(_ n: UInt64) -> String {
    if n == 0 { return "0 GB" }
    if n >= 1_000_000_000 { return String(format: "%.1f GB", Double(n) / 1e9) }
    if n >= 1_000_000 { return String(format: "%.0f MB", Double(n) / 1e6) }
    return String(format: "%.0f KB", Double(n) / 1e3)
  }
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
    case .memory: return "Memory reclaimed"
    case .disk: return "Disk reclaimed"
    case .worktrees: return "Worktrees cleaned"
    default: return "Helpers cleared"
    }
  }
  var clearedHelpers: String {
    let trees = benefit == .ready ? lifetimeWorktrees : worktrees
    if (benefit == .ready ? lifetimeCount : count) == 0 && trees > 0 { return "\(trees) \(trees == 1 ? "worktree" : "worktrees") cleaned" + (benefit == .ready ? " all time" : "") }
    let total = benefit == .ready ? lifetimeCount : count
    return "\(total) \(total == 1 ? "helper" : "helpers") cleared" + (benefit == .ready ? " all time" : "")
  }
  var age: String {
    guard let last else { return "No burns yet" }
    let minutes = max(0, Int(Date().timeIntervalSince(last) / 60))
    return minutes < 1 ? "just now" : minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
  }
}
struct BurnStatus: View {
  @ObservedObject var model: AppModel
  var compact = false
  var status: String {
    if model.state.error != nil { return "Needs attention" }
    if model.machineReview.phase == "paused" { return "Review paused" }
    if compact {
      if !model.demo && !model.machineReviewEnabled { return "Reviews off" }
      return model.machineReview.phase == "reviewing" ? "Reviewing this Mac" : "Agent-led cleanup"
    }
    return "Watching this Mac"
  }
  var body: some View {
    HStack(spacing: compact ? 9 : 12) {
      Circle().fill(model.state.error != nil ? .red : BurnTheme.orange)
        .frame(width: compact ? 12 : 16, height: compact ? 12 : 16)
      Text(status).font(.system(size: compact ? 13 : 18)).foregroundStyle(Color(white: 0.82))
      Button { model.requestAgentCleanup() } label: {
        Text(model.cleanupQueued ? "Queued" : "Safe cleanup")
          .font(.system(size: compact ? 10.5 : 12, weight: .semibold)).foregroundStyle(BurnTheme.orange)
          .padding(.horizontal, 9).padding(.vertical, compact ? 4 : 6)
          .background(BurnTheme.orange.opacity(0.08), in: Capsule()).contentShape(Capsule())
      }.disabled(!model.demo && !model.machineReviewEnabled)
        .help("Review buildup across this Mac now. No active chat or reboot needed.")
    }
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
      Text(model.pressure).font(.system(size: compact ? 12 : 17, weight: compact ? .medium : .regular))
    }
  }
}
struct MiniImpactView: View {
  static let size = NSSize(width: 360, height: 550)
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var model: AppModel
  var numbers: ImpactNumbers { .make(model, period: .today) }
  var lastBurn: String {
    let history = ImpactNumbers.make(model, period: .all)
    if history.last != nil { return "Last burn \(history.age)" }
    return history.count + history.worktrees == 0 ? "Ready for your first burn" : "No burns yet today"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Skull(size: 34, celebration: model.burnPulse)
        Text("BURNZOMBIES").font(BurnTheme.display(22)).tracking(0.25)
        Spacer(minLength: 8)
        Button { model.openSettings?() } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundStyle(.gray)
            .frame(width: 28, height: 32).contentShape(Rectangle())
        }.help("Settings").accessibilityLabel("Settings")
      }.frame(height: 36)
      BurnStatus(model: model, compact: true).frame(height: 22).padding(.top, 9)
      Text("Dead weight. Gone.").font(BurnTheme.display(28))
        .frame(height: 40, alignment: .leading).padding(.top, 16)
      Text("TODAY").font(.system(size: 11, weight: .semibold)).tracking(0.5)
        .foregroundStyle(BurnTheme.muted).frame(height: 14).padding(.top, 12)
      VStack(spacing: 10) {
        HStack(spacing: 18) {
          miniMetric("\(numbers.count)", "Zombies burned", flame: true)
          Rectangle().fill(BurnTheme.line).frame(width: 1, height: 50)
          miniMetric(ImpactNumbers.bytes(numbers.memory), "Memory released")
        }
        HStack(spacing: 18) {
          miniMetric(ImpactNumbers.bytes(numbers.disk), "Disk reclaimed")
          Rectangle().fill(BurnTheme.line).frame(width: 1, height: 50)
          miniMetric("\(numbers.worktrees)", "Worktrees cleaned")
        }
      }.frame(height: 120).padding(.top, 6)
      speedCard.padding(.top, 25)
      line.padding(.top, 16)
      MemoryPressureRow(model: model, compact: true).frame(height: 18).padding(.top, 12)
      Text(lastBurn).font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
        .frame(height: 14).padding(.top, 5)
      line.padding(.top, 18)
      HStack(spacing: 0) {
        Button { model.openImpact?() } label: {
          HStack(spacing: 10) {
            Text("View impact").fontWeight(.semibold)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
          }.frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
        }
        Rectangle().fill(BurnTheme.line).frame(width: 1, height: 22)
        Button { model.openLog?() } label: {
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("Burn Log").fontWeight(.medium)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
          }.frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
        }
      }.font(.system(size: 13)).frame(height: 48)
      Spacer(minLength: 0)
    }.padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 6)
      .frame(width: Self.size.width, height: Self.size.height)
      .foregroundStyle(BurnTheme.cream).buttonStyle(.plain).ignoresSafeArea()
      .background(BurnBackdrop()).preferredColorScheme(.dark)
  }
  var speedCard: some View {
    Button { model.openImpact?() } label: {
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
              Text(numbers.benefit == .firstBurn ? "Your first cleanup starts here." : numbers.clearedHelpers)
                .font(.system(size: 11))
                .foregroundStyle(BurnTheme.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
          }
        case .memory, .helpers, .disk, .worktrees:
          HStack(spacing: 10) {
            ImpactValue(value: numbers.benefitValue, size: 32).foregroundStyle(BurnTheme.orange)
            VStack(alignment: .leading, spacing: 4) {
              Text(numbers.benefitCaption).font(.system(size: 12, weight: .semibold))
              Text(numbers.benefit == .memory ? numbers.clearedHelpers : "Dead weight. Gone.")
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
    }.help("View impact")
  }
  var warmupGauge: some View {
    ZStack {
      Path { path in
        path.addArc(center: CGPoint(x: 17, y: 23), radius: 15,
          startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
      }.stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
      Path { path in
        path.move(to: CGPoint(x: 17, y: 23))
        path.addLine(to: CGPoint(x: 25, y: 15))
      }.stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }.foregroundStyle(BurnTheme.orange).frame(width: 34, height: 28).accessibilityHidden(true)
  }
  var line: some View { Rectangle().fill(BurnTheme.line).frame(height: 1) }
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
  @State private var hoveredPeriod: ImpactPeriod?
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
        }.help("Settings")
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
      .onDisappear {
        if hoveredPeriod != nil { NSCursor.pop(); hoveredPeriod = nil }
      }
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
    }
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
          }
          .accessibilityIdentifier("impact-period-" + option.rawValue)
          .accessibilityValue(period == option ? "Selected" : "Not selected")
          .onHover { inside in
            if inside {
              if hoveredPeriod == nil { NSCursor.pointingHand.push() }
              hoveredPeriod = option
            } else if hoveredPeriod == option {
              NSCursor.pop(); hoveredPeriod = nil
            }
          }
        }
      }.padding(.horizontal, 18).padding(.top, 22)
      HStack(alignment: .center, spacing: 28) {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 8) {
            BrandHeading(text: "TAME THE", size: 98).frame(height: 85)
            BrandHeading(text: "HORDE", size: 98).frame(height: 85)
          }.frame(height: 178)
          Text("Your agents have room to run.").font(.system(size: 29, weight: .medium))
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
        HStack(spacing: 24) {
          Flame(size: 35)
          VStack(alignment: .leading, spacing: 5) {
            Text(numbers.latestLabel ?? "Your next cleanup starts here.").font(
              .system(size: 18, weight: .semibold))
            Text(
              numbers.last == nil
                ? "Review the helpers ready to go."
                : "\(ImpactNumbers.bytes(numbers.latestIsWorkspace ? numbers.latestDisk : numbers.latestMemory)) \(numbers.latestIsWorkspace ? "disk reclaimed" : "released") · \(numbers.age)"
            )
            .font(.system(size: 16)).foregroundStyle(BurnTheme.muted)
          }
          Spacer()
          Text("Burn Log").font(.system(size: 16))
          Image(systemName: "chevron.right").foregroundStyle(.gray)
        }.padding(.horizontal, 24).frame(height: 67)
          .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
          .overlay(RoundedRectangle(cornerRadius: 11).stroke(BurnTheme.line))
      }.padding(.top, 13)
      Spacer(minLength: 8)
      Text("You build. We burn.").font(.system(size: 14, design: .monospaced)).tracking(3)
        .foregroundStyle(.gray).padding(.bottom, 18)
    }.padding(.horizontal, 37)
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
              Text(numbers.benefit == .firstBurn ? "Your first cleanup starts here." : numbers.clearedHelpers)
                .font(.system(size: 20, weight: .semibold))
              if numbers.benefit != .firstBurn {
                Text("Less background baggage.").font(.system(size: 16)).foregroundStyle(BurnTheme.muted)
              }
            }
          }.frame(height: 57, alignment: .leading)
        }
        Button {
          showCalculation = true
        } label: {
          HStack {
            Spacer()
            Text("View impact details")
            Image(systemName: "chevron.right")
          }.font(.system(size: 15))
        }.padding(.top, 4)
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
  var burnLog: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("THE BURN LOG.").font(BurnTheme.display(49))
        HStack {
          Text("A little less dead weight.").font(.system(size: 22)).foregroundStyle(
            BurnTheme.muted)
          Spacer()
          Button("Refresh") { model.refresh() }
        }
        if model.state.error != nil {
          Text("Monitoring needs attention.").foregroundStyle(.orange)
          Button("Open details") { model.openAudit?() }
        }
        if !model.state.findings.isEmpty {
          Text("WORTH A LOOK").font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(BurnTheme.orange)
          ForEach(model.state.findings.prefix(12)) { finding in
            Button {
              model.choose(finding)
              model.openAudit?()
            } label: {
              HStack {
                Flame(size: 23)
                VStack(alignment: .leading, spacing: 5) {
                  Text(finding.title).fontWeight(.semibold)
                  Text(finding.reason).font(.system(size: 15)).foregroundStyle(BurnTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
              }
              .padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
        Text("RECENT BURNS").font(.system(size: 14, weight: .semibold, design: .monospaced))
          .foregroundStyle(.gray)
        if model.state.catalog.events.isEmpty && (model.state.catalog.workspaceReceipts ?? []).isEmpty {
          Text(
            model.demo
              ? "18 disposable helpers · 1.2 GB released · 2m ago"
              : "No burns yet. Your work comes first."
          ).foregroundStyle(BurnTheme.muted).padding(.vertical, 24)
        }
        ForEach((model.state.catalog.workspaceReceipts ?? []).reversed(), id: \.id) { receipt in
          DisclosureGroup {
            Text(receipt.detail).font(.system(size: 15)).foregroundStyle(BurnTheme.muted).padding(.top, 8)
          } label: {
            HStack {
              Image(systemName: "folder.badge.minus").foregroundStyle(BurnTheme.orange)
              Text(receipt.label).fontWeight(.semibold)
              Spacer()
              Text(receipt.outcome == "verified" ? "1 worktree · \(ImpactNumbers.bytes(receipt.diskReclaimedBytes))" : receipt.outcome.capitalized)
                .foregroundStyle(BurnTheme.muted)
            }
          }.padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
        ForEach(model.state.catalog.events.reversed()) { event in
          DisclosureGroup {
            Text(event.detail).font(.system(size: 15)).foregroundStyle(BurnTheme.muted).padding(
              .top, 8)
          } label: {
            HStack {
              Flame(size: 24)
              Text(event.label).fontWeight(.semibold)
              Spacer()
              Text(
                event.outcome == "verified"
                  ? "\(event.verifiedCount) burned · \(ImpactNumbers.bytes(event.residentBefore))"
                  : event.outcome.capitalized
              ).foregroundStyle(BurnTheme.muted)
            }
          }.padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
      }.padding(38).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  var calculation: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Behind the burn.").font(BurnTheme.display(34))
        Spacer()
        Button("Done") { showCalculation = false }
      }
      Text("Worktrees count only after native removal and receipt verification. Disk reclaimed is the observed free-space increase capped by allocated files removed; shared APFS blocks and concurrent disk activity can reduce attribution. Commits remain recoverable in the receipt’s Git ref. Existing checkouts, unsaved/ignored files and uncertain work are preserved.")
      Text(
        "Every burned helper has a verified exit receipt. Memory released uses its resident footprint before the stop; shared pages can overlap. CPU time saved applies the pre-stop CPU rate to observed awake time after verified exit, up to 24 hours per cleanup. Sleep, observation gaps, reboot and detected replacements add no credit. Older one-hour estimates are preserved until new observed time exceeds that credit. CPU already consumed is never counted as saved."
      )
      Text(
        model.demo
          ? "This visual preview uses synthetic numbers from the supplied design."
          : "Agent speed uses the middle matched command-launch comparison across this period, including slower results. A boost needs stable samples, separated timing ranges, at least 5% improvement and a 1 ms difference. No clear improvement stays neutral. Legacy timings without sample dispersion cannot establish a boost. This measures local launches, not model or network speed."
      )
      Text("CPU time saved: \(ImpactNumbers.cpuTime(numbers.cpuSeconds))").foregroundStyle(BurnTheme.muted)
      Text(
        "Before \(ImpactNumbers.latency(numbers.before)) · Now \(ImpactNumbers.latency(numbers.after))"
      ).font(.system(.body, design: .monospaced))
      if model.demo {
        Button("Preview success animation") {
          showCalculation = false
          model.previewBurn()
        }
      }
      Button("Open Burn Log") {
        showCalculation = false
        model.impactTab = "Burn Log"
      }
    }.padding(32).frame(width: 520).foregroundStyle(BurnTheme.cream).background(BurnBackdrop())
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
