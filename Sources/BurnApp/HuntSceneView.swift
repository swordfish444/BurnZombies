import SwiftUI

/// The scene is an atmospheric visualization. Only the caller can enter detection
/// or eradication modes, based on real hunt evidence; its scan percentage is local
/// animation progress and never represents backend completion.
enum HuntSceneMode: String, CaseIterable {
  case idle, searching, detected, burning, complete, paused
  var animates: Bool { self == .searching || self == .detected || self == .burning }
}

struct HuntSceneView: View {
  var mode: HuntSceneMode
  var celebrationTitle: String? = nil
  var isVisible = true
  var elapsedOverride: TimeInterval? = nil
  var reduceMotionOverride: Bool? = nil
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
  @State private var epoch = Date()

  private var animates: Bool { mode.animates && isVisible && !reduceMotion && elapsedOverride == nil }
  private var title: String {
    switch mode {
    case .idle: return "READY WHEN YOU ARE"
    case .searching: return "ON THE HUNT"
    case .detected: return "ZOMBIE DETECTED"
    case .burning: return celebrationTitle ?? "ZOMBIE ERADICATED"
    case .complete: return "HUNT COMPLETE"
    case .paused: return "HUNT PAUSED"
    }
  }
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
      let time = elapsedOverride ?? (animates ? max(0, timeline.date.timeIntervalSince(epoch)) : 5.8)
      ZStack(alignment: .topLeading) {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
          HuntScenePainter(mode: mode, time: time, reducedMotion: reduceMotion).draw(context, size: size)
        }
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text("THE NIGHT SHIFT").font(.system(size: 10, weight: .semibold, design: .monospaced))
              .tracking(2.6).foregroundStyle(Color(white: 0.60))
            Text(title).font(BurnTheme.display(mode == .burning || mode == .detected ? 24 : 20))
              .tracking(0.7)
              .foregroundStyle(mode == .detected || mode == .burning ? BurnTheme.orange : BurnTheme.cream)
              .lineLimit(2).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 16)
          HStack(spacing: 7) {
            Circle().fill(mode == .paused ? Color(white: 0.5) : BurnTheme.orange).frame(width: 6, height: 6)
            Text(mode == .searching ? "SEARCH / SCAN / BURN" : mode == .burning ? "VERIFIED CLEANUP" : "BURNZOMBIES")
              .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.1)
              .foregroundStyle(Color(white: 0.65))
          }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.black.opacity(0.20), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07)))
        }.padding(24)
      }
    }
    .frame(height: 310)
    .clipShape(RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09)))
    .onChange(of: mode) { _, _ in epoch = Date() }
    .onChange(of: isVisible) { _, visible in if visible { epoch = Date() } }
    .onAppear { epoch = Date() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Zombie hunt. \(title.lowercased()).")
    .allowsHitTesting(false)
  }
}

private struct HuntScenePainter {
  let mode: HuntSceneMode
  let time: TimeInterval
  let reducedMotion: Bool
  private let orange = Color(red: 1, green: 0.33, blue: 0.12)
  private let cream = Color(red: 0.985, green: 0.976, blue: 0.94)
  private var cycle: Double { time.truncatingRemainder(dividingBy: 12) }
  private var scanning: Bool { mode == .searching && cycle >= 3.5 && cycle < 9.5 }
  private var walking: Bool { mode == .searching && !scanning }
  private var scan: Double { min(1, max(0, (cycle - 3.5) / 5.5)) }

  func draw(_ original: GraphicsContext, size: CGSize) {
    var context = original
    // One world coordinate system keeps the characters and ground aligned while
    // allowing the window to become narrower without scaling the text overlays.
    let scale = size.width / 900
    context.scaleBy(x: scale, y: size.height / 310)
    let bounds = CGRect(x: 0, y: 0, width: 900, height: 310)
    context.fill(Path(bounds), with: .linearGradient(Gradient(colors: [
      Color(red: 0.071, green: 0.081, blue: 0.088), Color(red: 0.10, green: 0.12, blue: 0.13),
      Color(red: 0.12, green: 0.13, blue: 0.12)
    ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 310)))
    // Moon and a restrained halo behind the industrial skyline.
    context.fill(Path(ellipseIn: CGRect(x: 647, y: 12, width: 160, height: 160)),
      with: .radialGradient(Gradient(colors: [cream.opacity(0.07), .clear]), center: CGPoint(x: 727, y: 92), startRadius: 0, endRadius: 80))
    ellipse(&context, 708, 68, 32, 32, cream.opacity(0.40))
    ellipse(&context, 720, 62, 31, 31, Color(red: 0.075, green: 0.087, blue: 0.094))
    for i in 0..<32 {
      let x = Double((i * 151 + 53) % 900), y = Double((i * 61 + 79) % 118 + 43)
      rect(&context, x, y, i % 7 == 0 ? 2 : 1, 1, cream.opacity(i % 3 == 0 ? 0.22 : 0.10))
    }
    let travel = mode == .searching ? (floor(time / 12) * 150 + min(cycle, 3.5) * 28 + max(0, cycle - 9.5) * 21) : 0
    skyline(&context, shift: travel * 0.16, back: true)
    skyline(&context, shift: travel * 0.42, back: false)
    // Telegraph wires, roof exhausts, and distant warm windows keep the city alive.
    var cable = Path(); cable.move(to: CGPoint(x: 0, y: 149))
    cable.addQuadCurve(to: CGPoint(x: 332, y: 165), control: CGPoint(x: 175, y: 198))
    cable.addQuadCurve(to: CGPoint(x: 900, y: 145), control: CGPoint(x: 600, y: 199))
    context.stroke(cable, with: .color(Color.black.opacity(0.45)), lineWidth: 1.5)
    rect(&context, 0, 252, 900, 58, Color(red: 0.068, green: 0.071, blue: 0.067))
    rect(&context, 0, 252, 900, 3, Color(red: 0.31, green: 0.31, blue: 0.26))
    rect(&context, 0, 255, 900, 8, Color(red: 0.16, green: 0.17, blue: 0.15))
    for i in -1..<13 {
      let x = Double(i * 86) - travel.truncatingRemainder(dividingBy: 86)
      rect(&context, x, 263, 1, 47, Color.white.opacity(0.035))
      rect(&context, x + 8, 269, 24, 2, Color.white.opacity(0.035))
      rect(&context, x + 44, 294, 14, 2, Color.white.opacity(0.025))
    }
    for i in 0..<16 {
      let x = Double((i * 83 + 21) % 900)
      rect(&context, x, 248, 2, 4, Color(red: 0.19, green: 0.22, blue: 0.17))
      rect(&context, x + 3, 245, 2, 7, Color(red: 0.16, green: 0.20, blue: 0.15))
    }
    // Ground markings and the tiny trail of spent embers anchor the game plane.
    for i in 0..<6 { rect(&context, 376 + Double(i * 14), 257, 8, 2, orange.opacity(0.32)) }
    rect(&context, 34, 268, 69, 1, orange.opacity(0.22))
    label(&context, "DEAD WEIGHT. GONE.", x: 34, y: 282, size: 8, color: cream.opacity(0.23), anchor: .leading)
    label(&context, "YOU BUILD. WE BURN.", x: 868, y: 282, size: 8, color: cream.opacity(0.23), anchor: .trailing)

    let characterX = 225.0
    let targetX: Double = mode == .searching && cycle < 3.5 ? 960 - cycle * 104
      : mode == .searching && cycle >= 10.5 ? 596 - (cycle - 10.5) * 170 : 596
    let showTarget = mode == .searching || mode == .detected || mode == .burning
    ellipse(&context, characterX - 47, 246, 94, 10, .black.opacity(0.45))
    if showTarget {
      ellipse(&context, targetX - 31, 247, 62, 8, .black.opacity(0.4))
      drawTarget(&context, x: targetX, fill: mode == .detected ? 1 : scanning ? scan : 0,
        infected: mode == .detected || mode == .burning)
    }
    if scanning || mode == .detected {
      drawScanner(&context, targetX: targetX, progress: mode == .detected ? 1 : scan)
    }
    let gait = walking && !reducedMotion ? sin(time * 13) : 0
    drawHunter(&context, x: characterX, gait: gait, firing: mode == .burning,
      scanning: scanning || mode == .detected)
    if mode == .burning { drawFire(&context, targetX: targetX) }
    if mode == .complete {
      label(&context, "CLEAR FOR YOUR NEXT RUN", x: 584, y: 184, size: 12, color: cream.opacity(0.65))
      line(&context, from: CGPoint(x: 515, y: 204), to: CGPoint(x: 653, y: 204), color: orange.opacity(0.45), width: 1)
    }
    if mode == .paused || mode == .idle {
      label(&context, mode == .paused ? "HOLDING POSITION" : "LET’S CLEAR SOME SPACE", x: 587, y: 188, size: 11, color: cream.opacity(0.38))
    }
    // Fine screen texture, static rather than flashing, is deliberately subtle.
    for y in stride(from: 1, to: 310, by: 4) { rect(&context, 0, Double(y), 900, 1, .black.opacity(0.035)) }
  }

  private func skyline(_ context: inout GraphicsContext, shift: Double, back: Bool) {
    let widths = [83.0, 49, 104, 68, 89, 57, 119, 74, 96, 80, 91, 64]
    let heights = [67.0, 115, 83, 139, 95, 62, 124, 85, 106, 70, 131, 87]
    let offset = shift.truncatingRemainder(dividingBy: 1050)
    let baseline = back ? 228.0 : 252.0
    for repeatIndex in -1...1 {
      var cursor = Double(repeatIndex * 1050) - offset
      for i in widths.indices {
        let height = heights[i] * (back ? 0.78 : 0.75), top = baseline - height
        let color = back ? Color(red: 0.14, green: 0.17, blue: 0.18) : Color(red: 0.095, green: 0.115, blue: 0.12)
        rect(&context, cursor, top, widths[i], height, color)
        rect(&context, cursor + 3, top - 3, widths[i] - 6, 3, color)
        if i % 3 == 0 {
          rect(&context, cursor + 12, top - 16, 3, 16, color)
          line(&context, from: CGPoint(x: cursor + 4, y: top - 11), to: CGPoint(x: cursor + 24, y: top - 11), color: color, width: 2)
        }
        if !back {
          for row in 0..<Int(height / 17) {
            for col in 0..<Int(widths[i] / 17) where (row * 7 + col * 3 + i) % 5 == 0 {
              rect(&context, cursor + 9 + Double(col * 15), top + 13 + Double(row * 17), 4, 6, cream.opacity((col + i) % 3 == 0 ? 0.13 : 0.04))
            }
          }
          if i == 2 || i == 7 {
            rect(&context, cursor + widths[i] - 9, top + 12, 2, height - 12, Color.white.opacity(0.04))
          }
        }
        cursor += widths[i] + 8
      }
    }
  }

  private func drawHunter(_ original: inout GraphicsContext, x: Double, gait: Double, firing: Bool, scanning: Bool) {
    var c = original
    c.translateBy(x: x - 41, y: 151 + abs(gait) * 1.6)
    c.scaleBy(x: 2.45, y: 2.45)
    let edge = Color(red: 0.045, green: 0.054, blue: 0.055)
    let jacket = Color(red: 0.24, green: 0.28, blue: 0.25)
    let jacketLight = Color(red: 0.35, green: 0.39, blue: 0.32)
    // Tank, straps, helmet and little white visor make a recognizable silhouette.
    rect(&c, 2, 16, 7, 17, edge); rect(&c, 3, 17, 5, 13, orange.opacity(0.85))
    rect(&c, 3, 21, 5, 2, Color(red: 0.45, green: 0.18, blue: 0.08))
    rect(&c, 5, 14, 3, 3, cream.opacity(0.45))
    rect(&c, 8, 13, 15, 17, edge); rect(&c, 9, 14, 12, 15, jacket)
    rect(&c, 10, 15, 3, 11, jacketLight); rect(&c, 9, 25, 13, 3, edge)
    rect(&c, 17, 19, 4, 5, cream.opacity(0.65))
    rect(&c, 9, 3, 13, 11, edge); rect(&c, 11, 2, 10, 2, edge)
    rect(&c, 10, 4, 11, 5, jacketLight); rect(&c, 20, 6, 4, 4, edge)
    rect(&c, 15, 7, 8, 3, cream); rect(&c, 21, 7, 2, 3, orange)
    rect(&c, 12, 11, 10, 4, edge); rect(&c, 16, 12, 4, 2, cream.opacity(0.52))
    rect(&c, 9, 14, 13, 2, orange); rect(&c, 7, 15, 3, 8, orange.opacity(0.9))
    // Swinging boot blocks keep walking crisp instead of deforming the sprite.
    let step = gait * 3
    rect(&c, 10 + step, 29, 5, 8, jacket); rect(&c, 10 + step, 35, 7, 5, edge)
    rect(&c, 17 - step, 29, 5, 8, jacketLight); rect(&c, 17 - step, 36, 8, 4, edge)
    if firing {
      rect(&c, 21, 17, 7, 5, jacketLight); rect(&c, 27, 18, 3, 3, cream.opacity(0.75))
      rect(&c, 25, 20, 13, 4, edge); rect(&c, 34, 19, 8, 4, Color(white: 0.4))
      rect(&c, 39, 19, 3, 5, orange); rect(&c, 29, 24, 3, 4, edge)
      var hose = Path(); hose.move(to: CGPoint(x: 5, y: 28))
      hose.addCurve(to: CGPoint(x: 28, y: 24), control1: CGPoint(x: 4, y: 37), control2: CGPoint(x: 28, y: 37))
      c.stroke(hose, with: .color(edge), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    } else if scanning {
      rect(&c, 21, 17, 7, 5, jacketLight); rect(&c, 27, 18, 3, 3, cream.opacity(0.75))
      rect(&c, 29, 16, 4, 7, edge); rect(&c, 30, 17, 3, 4, orange.opacity(0.9))
    } else {
      rect(&c, 21, 18 + gait, 5, 10, jacketLight); rect(&c, 22, 27 + gait, 4, 3, cream.opacity(0.68))
      rect(&c, 24, 27 + gait, 9, 3, edge); rect(&c, 31, 26 + gait, 4, 3, Color(white: 0.32))
    }
  }

  private func drawTarget(_ original: inout GraphicsContext, x: Double, fill: Double, infected: Bool) {
    var c = original
    c.translateBy(x: x - 30, y: 158); c.scaleBy(x: 2.35, y: 2.35)
    var body = Path()
    for r in [CGRect(x: 8, y: 0, width: 11, height: 10), CGRect(x: 5, y: 11, width: 17, height: 16),
      CGRect(x: 1, y: 13, width: 4, height: 16), CGRect(x: 22, y: 13, width: 4, height: 16),
      CGRect(x: 6, y: 27, width: 6, height: 12), CGRect(x: 16, y: 27, width: 6, height: 12)] { body.addRect(r) }
    c.fill(body, with: .color(infected ? Color(red: 0.39, green: 0.42, blue: 0.24) : Color(red: 0.31, green: 0.35, blue: 0.32)))
    rect(&c, 8, 1, 11, 2, .black.opacity(0.28))
    rect(&c, 7, 13, 3, 11, .white.opacity(0.10))
    if fill > 0 {
      var clipped = c; clipped.clip(to: body)
      rect(&clipped, 0, 39 * (1 - fill), 27, 39 * fill, cream.opacity(0.93))
      rect(&clipped, 0, 39 * (1 - fill), 27, 1.5, .white)
    }
    rect(&c, 10, 5, 2, 2, infected ? orange : .black.opacity(0.7))
    rect(&c, 16, 5, 2, 2, infected ? orange : .black.opacity(0.7))
    rect(&c, 12, 8, 4, 1, .black.opacity(0.5))
    if infected { c.stroke(body, with: .color(orange.opacity(0.7)), lineWidth: 0.7) }
  }

  private func drawScanner(_ c: inout GraphicsContext, targetX: Double, progress: Double) {
    let scanY = 250 - 92 * progress
    var cone = Path(); cone.move(to: CGPoint(x: 264, y: 197))
    cone.addLine(to: CGPoint(x: targetX + 37, y: 158)); cone.addLine(to: CGPoint(x: targetX + 37, y: 250)); cone.closeSubpath()
    c.fill(cone, with: .linearGradient(Gradient(colors: [orange.opacity(0.01), cream.opacity(0.035)]), startPoint: CGPoint(x: 264, y: 197), endPoint: CGPoint(x: targetX, y: 197)))
    line(&c, from: CGPoint(x: targetX - 38, y: scanY), to: CGPoint(x: targetX + 38, y: scanY), color: cream.opacity(0.85), width: 1)
    let brackets = Color.white.opacity(0.28)
    for sx in [-1.0, 1.0] {
      for sy in [0.0, 1.0] {
        let x = targetX + sx * 39, y = 153 + sy * 101
        line(&c, from: CGPoint(x: x, y: y), to: CGPoint(x: x - sx * 9, y: y), color: brackets, width: 1)
        line(&c, from: CGPoint(x: x, y: y), to: CGPoint(x: x, y: y + (sy == 0 ? 8 : -8)), color: brackets, width: 1)
      }
    }
    let text = mode == .detected ? "DETECTED" : "\(Int(progress * 100))%"
    let width = mode == .detected ? 86.0 : 56.0
    c.fill(Path(roundedRect: CGRect(x: targetX - width / 2, y: 117, width: width, height: 25), cornerRadius: 4), with: .color(mode == .detected ? orange.opacity(0.18) : .black.opacity(0.42)))
    label(&c, text, x: targetX, y: 130, size: 12, color: mode == .detected ? orange : cream)
    label(&c, mode == .detected ? "THREAT IDENTIFIED" : "SCANNING", x: targetX, y: 103, size: 8, color: cream.opacity(0.46))
  }

  private func drawFire(_ c: inout GraphicsContext, targetX: Double) {
    let t = reducedMotion ? 0 : time
    let origin = CGPoint(x: 286, y: 203)
    c.fill(Path(ellipseIn: CGRect(x: targetX - 92, y: 124, width: 184, height: 162)),
      with: .radialGradient(Gradient(colors: [orange.opacity(0.25), .clear]), center: CGPoint(x: targetX, y: 205), startRadius: 0, endRadius: 100))
    var flame = Path(); flame.move(to: origin)
    for i in 0...24 {
      let p = Double(i) / 24, x = origin.x + (targetX + 25 - origin.x) * p
      let wobble = sin(Double(i) * 1.8 + t * 19) * (4 + p * 10)
      flame.addLine(to: CGPoint(x: x, y: origin.y - 5 - p * 29 + wobble))
    }
    for i in stride(from: 24, through: 0, by: -1) {
      let p = Double(i) / 24, x = origin.x + (targetX + 25 - origin.x) * p
      flame.addLine(to: CGPoint(x: x, y: origin.y + 5 + p * 27 + sin(Double(i) * 2 + t * 17) * (3 + p * 7)))
    }
    flame.closeSubpath()
    c.fill(flame, with: .linearGradient(Gradient(colors: [cream, Color(red: 1, green: 0.72, blue: 0.20), orange, orange.opacity(0.8)]), startPoint: origin, endPoint: CGPoint(x: targetX + 25, y: 203)))
    for i in 0..<13 {
      let phase = (t * 0.55 + Double(i) * 0.183).truncatingRemainder(dividingBy: 1)
      let x = targetX - 35 + Double((i * 17) % 80) + sin(Double(i) + t) * 8
      let y = 235 - phase * 126
      rect(&c, x, y, i % 2 == 0 ? 4 : 2, i % 3 == 0 ? 7 : 3, orange.opacity(1 - phase))
    }
    for i in 0..<7 {
      let x = targetX - 26 + Double(i * 10)
      let height = 32 + sin(t * 8 + Double(i) * 2.3) * 18
      var tongue = Path(); tongue.move(to: CGPoint(x: x - 8, y: 249)); tongue.addQuadCurve(to: CGPoint(x: x + 4, y: 249 - height), control: CGPoint(x: x - 12, y: 235 - height)); tongue.addQuadCurve(to: CGPoint(x: x + 9, y: 249), control: CGPoint(x: x + 14, y: 231)); tongue.closeSubpath()
      c.fill(tongue, with: .linearGradient(Gradient(colors: [orange, Color(red: 1, green: 0.75, blue: 0.28)]), startPoint: CGPoint(x: x, y: 249), endPoint: CGPoint(x: x, y: 249 - height)))
    }
  }

  private func rect(_ c: inout GraphicsContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
    c.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: .color(color))
  }
  private func ellipse(_ c: inout GraphicsContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
    c.fill(Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)), with: .color(color))
  }
  private func line(_ c: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, width: Double) {
    var p = Path(); p.move(to: from); p.addLine(to: to)
    c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .square))
  }
  private func label(_ c: inout GraphicsContext, _ value: String, x: Double, y: Double, size: Double, color: Color, anchor: UnitPoint = .center) {
    c.draw(Text(value).font(.system(size: size, weight: .semibold, design: .monospaced)).foregroundColor(color), at: CGPoint(x: x, y: y), anchor: anchor)
  }
}
