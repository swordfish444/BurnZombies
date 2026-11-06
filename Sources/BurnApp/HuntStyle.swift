import BurnCore
import SwiftUI

/// The Hunt window's quiet parts: soft surfaces instead of outlines, pill buttons, column headers,
/// chips and the one grid that keeps the stats, the feed and Needs you in line.
enum HuntStyle {
  /// A stat card: a soft lift off the backdrop, never an outline.
  static let surface = Color.white.opacity(0.045)
  /// The Needs you card, a little brighter so it is the one thing that asks for the eye.
  static let card = Color.white.opacity(0.06)
  static let track = Color.white.opacity(0.08)
  static let hairline = Color.white.opacity(0.07)
  /// Quieter than muted: timestamps and the footer.
  static let faint = Color(white: 0.52)
  /// Yes on a Needs you card: Teach BZ's green, a shade deeper, so the card stays calm.
  static let yes = Color(red: 0.23, green: 0.53, blue: 0.28)
}

/// One grid for the whole window: four equal columns. The freed card and the three lanes fill them,
/// and below, the feed takes the first two and Needs you the other two.
struct HuntLayout {
  let size: CGSize
  var margin: CGFloat { size.width < 880 ? 24 : 28 }
  var gap: CGFloat { size.width < 880 ? 10 : 12 }
  var width: CGFloat { max(0, size.width - margin * 2) }
  var unit: CGFloat { max(0, (width - gap * 3) / 4) }
  var feed: CGFloat { unit * 2 + gap }
  var needs: CGFloat { max(0, width - feed - gap) }
  /// Narrow lanes tighten their sides a little.
  var roomyLanes: Bool { unit >= 205 }
  /// A quarter of the window, as the owner asked: the scene sets the mood; the numbers are the
  /// hunt.
  var scene: CGFloat { max(150, (size.height * 0.25).rounded()) }
  /// A short window keeps the same parts with tighter gaps between them, so Needs you still has
  /// the room to show a whole card.
  var short: Bool { size.height < 820 }
  var afterHeader: CGFloat { short ? 12 : 16 }
  var afterScene: CGFloat { short ? 14 : 20 }
  var afterStats: CGFloat { short ? 16 : 22 }
  var beforeFooter: CGFloat { short ? 8 : 10 }
  var bottom: CGFloat { short ? 12 : 16 }
}

/// A rounded pill for the header's actions: orange for the one that matters, quiet for the rest.
struct HuntPillStyle: ButtonStyle {
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    Pill(configuration: configuration, prominent: prominent)
  }

  private struct Pill: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
      configuration.label
        .labelStyle(HuntPillLabelStyle())
        .font(.system(size: 12.5, weight: .semibold))
        .lineLimit(1).fixedSize()
        .foregroundStyle(prominent ? Color.black.opacity(0.86) : BurnTheme.cream)
        .padding(.horizontal, 13).frame(height: 30)
        .background(fill, in: Capsule())
        .contentShape(Capsule())
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
    }

    private var fill: Color {
      if prominent {
        return BurnTheme.orange.opacity(configuration.isPressed ? 0.8 : 1)
      }
      return Color.white.opacity(configuration.isPressed ? 0.15 : hover && enabled ? 0.11 : 0.075)
    }
  }
}

struct HuntPillLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: 10.5, weight: .bold))
      configuration.title
    }
  }
}

/// A column's title with a short line under it, and its controls on the right.
struct HuntColumnHeader<Trailing: View>: View {
  let title: String
  let subtitle: String
  var live = false
  @ViewBuilder var trailing: Trailing

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 14, weight: .semibold)).fixedSize()
        if live { HuntTag(text: "Live", tint: BurnTheme.orange) }
        Spacer(minLength: 8)
        trailing
      }.frame(height: 22)
      Text(subtitle).font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted)
        .lineLimit(1).truncationMode(.tail)
    }
  }
}

/// A small capsule word: the feed's Live.
struct HuntTag: View {
  let text: String
  var tint: Color? = nil

  var body: some View {
    Text(text).font(.system(size: 10, weight: .semibold)).fixedSize()
      .foregroundStyle(tint ?? BurnTheme.muted)
      .padding(.horizontal, 7).padding(.vertical, 2.5)
      .background((tint ?? .white).opacity(tint == nil ? 0.07 : 0.15), in: Capsule())
  }
}

/// A fact on a Needs you card. The risky ones stand out in amber, as in Teach BZ.
struct HuntChip: View {
  let text: String
  var caution = false

  var body: some View {
    HStack(spacing: 4) {
      if caution { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)) }
      Text(text).lineLimit(1)
    }
    .font(.system(size: 11.5, weight: .medium))
    .foregroundStyle(caution ? Color.orange : BurnTheme.cream.opacity(0.88))
    .padding(.horizontal, 10).padding(.vertical, 4)
    .background(
      caution ? Color.orange.opacity(0.12) : Color.white.opacity(0.05),
      in: Capsule(style: .circular)
    )
    .overlay(
      Capsule(style: .circular).strokeBorder(
        caution ? Color.orange.opacity(0.35) : Color.white.opacity(0.11)))
  }
}

/// Even line breaks for a card's centered text, as CSS's `text-wrap: balance` does: the narrowest
/// width that still takes no more lines, so a headline never leaves one word alone on its last
/// line.
enum HuntType {
  static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
      ?? base
  }

  static func balanced(_ text: String, font: NSFont, in available: CGFloat) -> CGFloat {
    guard available > 0 else { return available }
    let line = font.ascender - font.descender + font.leading
    func lines(_ width: CGFloat) -> Int {
      let rect = (text as NSString).boundingRect(
        with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin],
        attributes: [.font: font])
      return Int((rect.height / line).rounded())
    }
    let target = lines(available)
    guard target > 1 else { return available }
    var narrow = available / CGFloat(target)
    var wide = available
    for _ in 0..<12 {
      let middle = (narrow + wide) / 2
      if lines(middle) <= target { wide = middle } else { narrow = middle }
    }
    // A little slack: SwiftUI and AppKit may round a glyph differently.
    return min(available, wide.rounded(.up) + 6)
  }
}

/// What was freed, in the brand's display face: the number big, its unit smaller.
struct HuntBytes: View {
  let bytes: UInt64
  var size: CGFloat = 38

  var body: some View {
    let value = ImpactNumbers.bytes(bytes)
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Text(parts.first ?? value).font(BurnTheme.display(size)).contentTransition(.numericText())
      if parts.count > 1 { Text(parts[1]).font(BurnTheme.display(size * 0.62)) }
    }
    // Nothing freed yet is quiet, not an orange zero.
    .foregroundStyle(bytes == 0 ? BurnTheme.cream.opacity(0.35) : BurnTheme.orange)
    .lineLimit(1).minimumScaleFactor(0.6)
    .antonTrimmed(size)
    .accessibilityElement(children: .ignore).accessibilityLabel(value)
  }
}

extension View {
  /// Anton's line box is half again its size, while capitals and digits stand only 0.86 of it tall
  /// with nothing below the baseline. Trimming the empty room keeps a display line from pushing
  /// everything under it down.
  func antonTrimmed(_ size: CGFloat) -> some View {
    padding(.top, -size * 0.28).padding(.bottom, -size * 0.3)
  }
}

/// Chips in centered rows, wrapping when the next one doesn't fit; one too wide for a row is cut
/// short rather than spilling out of the card.
struct HuntChipFlow: Layout {
  var spacing: CGFloat = 6
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(subviews, width: proposal.width ?? .infinity)
    let height =
      rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in rows(subviews, width: bounds.width) {
      var x = bounds.midX - row.width / 2
      for (index, size) in row.items {
        subviews[index].place(
          at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
          proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Row {
    var items: [(Int, CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    for index in subviews.indices {
      var size = subviews[index].sizeThatFits(.unspecified)
      size.width = min(size.width, width)
      if !row.items.isEmpty && row.width + spacing + size.width > width {
        rows.append(row)
        row = Row()
      }
      row.width += (row.items.isEmpty ? 0 : spacing) + size.width
      row.height = max(row.height, size.height)
      row.items.append((index, size))
    }
    if !row.items.isEmpty { rows.append(row) }
    return rows
  }
}
