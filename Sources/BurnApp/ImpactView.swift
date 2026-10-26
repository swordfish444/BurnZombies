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
    }.frame(width: size, height: size).accessibilityHidden(true)
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
  var age: String {
    guard let last else { return "No burns yet" }
    let minutes = max(0, Int(Date().timeIntervalSince(last) / 60))
    return minutes < 1 ? "just now" : minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
  }
}
struct BurnStatus: View {
  @ObservedObject var model: AppModel
  var body: some View {
    HStack(spacing: 12) {
      Circle().fill(model.state.error != nil ? .red : BurnTheme.orange).frame(width: 16, height: 16)
      Text(
        model.state.error != nil
          ? "Needs attention"
          : model.machineReview.phase == "paused" ? "Review paused" : "Watching this Mac"
      )
      .font(.system(size: 18)).foregroundStyle(Color(white: 0.82))
      Button(model.cleanupQueued ? "Queued" : "Safe cleanup") { model.requestAgentCleanup() }
        .disabled(!model.demo && !model.machineReviewEnabled)
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(BurnTheme.orange)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(BurnTheme.orange.opacity(0.08), in: Capsule())
        .help("Review buildup across this Mac now. No active chat or reboot needed.")
    }
  }
}
struct MemoryPressureRow: View {
  @ObservedObject var model: AppModel
  var compact = false
  var body: some View {
    HStack(spacing: 18) {
      Circle().fill(
        model.pressure == "Low"
          ? Color(red: 0.48, green: 0.76, blue: 0.39) : model.pressure == "High" ? .red : .orange
      ).frame(width: 17, height: 17)
      Text("Memory pressure").font(.system(size: 17))
      if !compact {
        Rectangle().fill(BurnTheme.line).frame(width: 1, height: 23).padding(.horizontal, 24)
        Text(model.pressure == "Low" ? "Room for your next run." : "A little breathing room helps.")
          .foregroundStyle(BurnTheme.muted).font(.system(size: 16))
      }
      Spacer()
      Text(model.pressure).font(.system(size: 17))
    }
  }
}
struct MiniImpactView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var model: AppModel
  var numbers: ImpactNumbers { .make(model, period: .today) }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Skull(size: 49, celebration: model.burnPulse)
        Text("BURNZOMBIES").font(BurnTheme.display(29)).tracking(0.8)
        Spacer()
        Button {
          model.openSettings?()
        } label: {
          Image(systemName: "gearshape.fill").font(.system(size: 25)).foregroundStyle(.gray)
        }.help("Settings")
      }.padding(.horizontal, 23).frame(height: 76)
      line
      VStack(alignment: .leading, spacing: 0) {
        BurnStatus(model: model).padding(.top, 19)
        Text("Dead weight. Gone.").font(BurnTheme.display(43)).padding(.top, 9)
        Text("TODAY").font(.system(size: 17, weight: .medium, design: .monospaced)).tracking(1)
          .foregroundStyle(.gray).padding(.top, 16)
        Text("\(numbers.count)").font(BurnTheme.display(91)).frame(height: 100, alignment: .leading)
          .contentTransition(.numericText()).animation(
            reduceMotion ? nil : .easeOut(duration: 0.65), value: numbers.count)
        HStack(spacing: 12) {
          Flame()
          Text("Zombies burned").font(.system(size: 22))
        }.padding(.bottom, 21)
        line
        HStack(alignment: .top, spacing: 26) {
          miniMetric(ImpactNumbers.bytes(numbers.memory), "Memory released")
          Rectangle().fill(BurnTheme.line).frame(width: 1, height: 73)
          miniMetric(ImpactNumbers.cpuTime(numbers.cpuSeconds), "CPU time saved")
        }.padding(.top, 20).padding(.bottom, 27)
        Button {
          model.openImpact?()
        } label: {
          HStack(spacing: 16) {
            Text(numbers.boost).font(BurnTheme.display(51)).foregroundStyle(BurnTheme.orange)
              .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 7) {
              Text("Agent speed boost").font(.system(size: 18, weight: .semibold))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .light))
          }.padding(.horizontal, 16).frame(height: 84)
            .background(BurnTheme.orange.opacity(0.095), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BurnTheme.orange.opacity(0.65)))
        }.padding(.horizontal, -10)
        MemoryPressureRow(model: model, compact: true).padding(.top, 30).padding(.bottom, 22)
        line
        Text(numbers.last == nil ? "Ready for your first burn" : "Last burn \(numbers.age)")
          .font(.system(size: 16, design: .monospaced)).foregroundStyle(BurnTheme.muted).padding(
            .top, 14)
      }.padding(.horizontal, 26)
      Spacer(minLength: 16)
      line
      HStack {
        Button {
          model.openImpact?()
        } label: {
          HStack(spacing: 16) {
            Text("View impact").fontWeight(.semibold)
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .light))
          }
        }
        Spacer()
        Rectangle().fill(BurnTheme.line).frame(width: 1, height: 24)
        Button {
          model.openLog?()
        } label: {
          HStack(spacing: 12) {
            Text("Burn Log")
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .light))
          }
        }.padding(.leading, 14)
      }.font(.system(size: 19)).padding(.horizontal, 26).frame(height: 66)
    }.frame(width: 428, height: 795).foregroundStyle(BurnTheme.cream).buttonStyle(.plain)
      .ignoresSafeArea()
      .background(BurnBackdrop()).preferredColorScheme(.dark)
  }
  var line: some View { Rectangle().fill(BurnTheme.line).frame(height: 1) }
  func miniMetric(_ value: String, _ title: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ImpactValue(value: value, size: 44)
      Text(title).font(.system(size: 18)).foregroundStyle(Color(white: 0.82))
    }.frame(maxWidth: .infinity, alignment: .leading)
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
        metric(ImpactNumbers.cpuTime(numbers.cpuSeconds), "CPU time saved")
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
                : "\(ImpactNumbers.bytes(numbers.latestMemory)) released · \(numbers.age)"
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
      ImpactValue(value: value, size: 64)
      HStack(spacing: 12) {
        if flame { Flame() }
        Text(title).font(.system(size: 21))
      }
    }.frame(maxWidth: .infinity, alignment: .center)
  }
  var speedCard: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        Text("AGENT SPEED BOOST").font(.system(size: 17, weight: .semibold, design: .monospaced))
          .tracking(1).foregroundStyle(BurnTheme.orange)
        Text(numbers.boost).font(BurnTheme.display(94)).foregroundStyle(BurnTheme.orange)
          .fixedSize().frame(
            height: 96
          ).minimumScaleFactor(0.6)

      }.frame(width: 324, alignment: .leading)
      Rectangle().fill(BurnTheme.line).frame(width: 1, height: 122)
      VStack(alignment: .leading, spacing: 10) {
        Text("LESS WAITING. MORE DOING.").font(BurnTheme.display(22)).tracking(1)
        VStack(spacing: 14) {
          latencyRow("Before", numbers.before, color: Color(white: 0.43), fraction: 1)
          latencyRow(
            "Now", numbers.after, color: BurnTheme.orange,
            fraction: min(1, (numbers.after ?? 1) / max(0.0001, numbers.before ?? 1)))
        }.padding(.top, 1)
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
        if model.state.catalog.events.isEmpty {
          Text(
            model.demo
              ? "18 disposable helpers · 1.2 GB released · 2m ago"
              : "No burns yet. Your work comes first."
          ).foregroundStyle(BurnTheme.muted).padding(.vertical, 24)
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
      Text(
        "Every burned helper has a verified exit receipt. Memory released uses its resident footprint before the stop; shared pages can overlap. CPU time saved projects the helpers’ observed CPU rate over the next hour, counted once per verified cleanup. It does not count CPU they already used."
      )
      Text(
        model.demo
          ? "This visual preview uses synthetic numbers from the supplied design."
          : "Agent speed compares the median of seven local command launches before and after a verified cleanup. It describes this small local responsiveness probe; model, network and workload latency can differ."
      )
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
    context.saveGState()
    context.translateBy(x: 0, y: (bounds.height - ink.height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    context.textPosition = CGPoint(x: -ink.minX, y: -ink.minY)
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
