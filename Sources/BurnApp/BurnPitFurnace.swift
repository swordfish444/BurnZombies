import BurnCore
import SwiftUI

enum BurnPitLayer: String, CaseIterable, Identifiable {
  case all = "All findings"
  case cache = "Caches"
  case worktree = "Worktrees"
  case folder = "Disk folders"
  case zombie = "Zombie signals"

  var id: Self { self }

  func includes(_ row: BlazerMap.Row) -> Bool {
    switch self {
    case .all: return true
    case .cache: return row.kind == .cache
    case .worktree: return row.kind == .worktree
    case .folder: return row.kind == .folder
    case .zombie: return row.kind == .zombie
    }
  }

  func maps(_ row: BlazerMap.Row) -> Bool {
    guard (row.diskBytes ?? 0) > 0 else { return false }
    if self == .folder { return row.kind == .folder }
    return row.kind == .cache || row.kind == .worktree
  }
}

extension BlazerMap.Row.Kind {
  var burnPitLabel: String {
    switch self {
    case .cache: return "Cache"
    case .worktree: return "Worktree"
    case .folder: return "Disk folder"
    case .zombie: return "Zombie signal"
    }
  }

  var burnPitTint: Color {
    switch self {
    case .cache: return Color(red: 1, green: 0.61, blue: 0.29)
    case .worktree: return Color(red: 0.81, green: 0.64, blue: 0.96)
    case .folder: return Color(red: 0.45, green: 0.84, blue: 0.78)
    case .zombie: return Color(red: 1, green: 0.55, blue: 0.64)
    }
  }
}

struct BurnPitInventory {
  let matches: [BlazerMap.Row]
  let slabs: [BlazerMap.Row]
  let overlapping: Int
  let smaller: Int

  init(rows: [BlazerMap.Row], layer: BurnPitLayer, search: String) {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    matches = rows.filter { row in
      layer.includes(row) && (query.isEmpty || [
        row.name, row.path ?? "", row.state, row.detail, row.kind.burnPitLabel,
      ].contains { $0.localizedCaseInsensitiveContains(query) })
    }.sorted(by: Self.ledgerOrder)

    // Only the furnace drops nested paths. The ledger preserves both observations.
    let candidates = matches.filter(layer.maps).sorted {
      let a = $0.path?.count ?? 0
      let b = $1.path?.count ?? 0
      return a == b ? Self.ledgerOrder($0, $1) : a < b
    }
    var paths = Set<String>()
    var measured = [BlazerMap.Row]()
    for row in candidates {
      if let path = row.path {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        var ancestor = ""
        var covered = false
        for (index, part) in parts.enumerated() {
          if index > 0 { ancestor += "/" }
          ancestor += part
          if paths.contains(ancestor) { covered = true; break }
        }
        guard !covered else { continue }
        paths.insert(path)
      }
      measured.append(row)
    }
    slabs = Array(measured.sorted(by: Self.ledgerOrder).prefix(24))
    overlapping = candidates.count - measured.count
    smaller = measured.count - slabs.count
  }

  private static func ledgerOrder(_ lhs: BlazerMap.Row, _ rhs: BlazerMap.Row) -> Bool {
    // Keep disk, RAM, and unknown sizes in separate groups.
    func group(_ row: BlazerMap.Row) -> Int {
      if row.diskBytes != nil { return 0 }
      return row.memoryBytes != nil ? 1 : 2
    }
    if group(lhs) != group(rhs) { return group(lhs) < group(rhs) }
    let a = lhs.diskBytes ?? lhs.memoryBytes ?? 0
    let b = rhs.diskBytes ?? rhs.memoryBytes ?? 0
    if a != b { return a > b }
    let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
    return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
  }
}

struct BurnPitSlab: Identifiable {
  let row: BlazerMap.Row
  let frame: CGRect
  var id: String { row.id }

  /// Weighted binary partition along the longer axis. Area remains proportional to disk bytes.
  static func layout(_ rows: [BlazerMap.Row], in frame: CGRect) -> [Self] {
    var slabs = [Self]()
    func split(_ range: Range<Int>, _ rect: CGRect) {
      guard let first = range.first else { return }
      if range.count == 1 {
        slabs.append(Self(row: rows[first], frame: rect))
        return
      }
      let total = range.reduce(0.0) { $0 + Double(rows[$1].diskBytes ?? 0) }
      guard total > 0 else { return }
      var pivot = first + 1
      var weight = Double(rows[first].diskBytes ?? 0)
      while pivot < range.upperBound - 1 {
        let next = weight + Double(rows[pivot].diskBytes ?? 0)
        guard abs(total / 2 - next) < abs(total / 2 - weight) else { break }
        weight = next
        pivot += 1
      }
      let horizontal = rect.width >= rect.height
      let distance = (horizontal ? rect.width : rect.height) * CGFloat(weight / total)
      let (leading, trailing) = rect.divided(
        atDistance: distance, from: horizontal ? .minXEdge : .minYEdge)
      split(first..<pivot, leading)
      split(pivot..<range.upperBound, trailing)
    }
    split(rows.indices, frame)
    return slabs
  }
}

struct BurnPitFurnace: View {
  let rows: [BlazerMap.Row]
  let selection: String?
  let choose: (String) -> Void

  var body: some View {
    VStack(spacing: 10) {
      GeometryReader { proxy in
        let slabs = BurnPitSlab.layout(rows, in: CGRect(origin: .zero, size: proxy.size))
        ZStack(alignment: .topLeading) {
          RadialGradient(
            colors: [Color(red: 1, green: 0.74, blue: 0.34), BurnTheme.orange, Color(red: 0.41, green: 0.12, blue: 0.06)],
            center: .bottom, startRadius: 0, endRadius: proxy.size.width * 0.8)
          ForEach(slabs) { slab in
            let rect = slab.frame
            let gap = min(2, rect.width * 0.12, rect.height * 0.12)
            let size = CGSize(width: rect.width - gap, height: rect.height - gap)
            Button { choose(slab.id) } label: {
              slabFace(slab.row, size: size, selected: selection == slab.id)
            }
            .buttonStyle(.plain)
            .clickPointer()
            .frame(width: size.width, height: size.height)
            .position(x: rect.midX, y: rect.midY)
            .help(slab.row.name)
            .accessibilityLabel(slab.row.name)
            .accessibilityValue(
              "\(slab.row.kind.burnPitLabel), \(BlazerXRay.formatBytes(slab.row.diskBytes ?? 0)), \(slab.row.state)")
            .accessibilityAddTraits(selection == slab.id ? .isSelected : [])
          }
        }
        .clipShape(.rect(cornerRadius: 4))
      }
      .padding(5)
      .background(Color(red: 0.18, green: 0.06, blue: 0.035), in: .rect(cornerRadius: 7))
      .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.orange.opacity(0.45)) }

      Canvas { context, size in
        for x in stride(from: 0.0, to: size.width, by: 10.0) {
          let slot = CGRect(x: x, y: 0, width: min(5, size.width - x), height: size.height)
          context.fill(Path(roundedRect: slot, cornerRadius: 1), with: .color(.black.opacity(0.7)))
        }
      }
      .frame(height: 8)
      .padding(.horizontal, 42)
      .accessibilityHidden(true)
    }
    .padding(13)
    .background {
      RoundedRectangle(cornerRadius: 11).fill(
        LinearGradient(
          colors: [Color(red: 0.39, green: 0.25, blue: 0.17), Color(red: 0.20, green: 0.12, blue: 0.085),
                   Color(red: 0.41, green: 0.23, blue: 0.14)],
          startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.35)) }
    .overlay {
      GeometryReader { proxy in
        let width = proxy.size.width
        let height = proxy.size.height
        ForEach(0..<4) { corner in
          Circle().fill(.black.opacity(0.7))
            .overlay { Circle().strokeBorder(Color.orange.opacity(0.7)) }
            .frame(width: 5, height: 5)
            .position(x: corner.isMultiple(of: 2) ? 7 : width - 7, y: corner < 2 ? 7 : height - 7)
        }
      }.allowsHitTesting(false).accessibilityHidden(true)
    }
  }

  private func slabFace(_ row: BlazerMap.Row, size: CGSize, selected: Bool) -> some View {
    let tint = row.kind.burnPitTint
    let shape = RoundedRectangle(cornerRadius: min(5, size.width / 3, size.height / 3))
    let shade = Color(red: 0.15, green: 0.075, blue: 0.06)
    return VStack(alignment: .leading, spacing: 2) {
      if size.width > 110 && size.height > 71 {
        Text(row.kind.burnPitLabel.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced))
          .foregroundStyle(tint).lineLimit(1)
      }
      if size.width > 70 && size.height > 43 {
        Text(row.name).font(.callout.weight(.semibold)).lineLimit(1)
      }
      if size.width > 46 && size.height > 22 {
        Text(BlazerXRay.formatBytes(row.diskBytes ?? 0))
          .font(.system(size: size.width > 112 && size.height > 58 ? 24 : 13, weight: .bold, design: .rounded))
          .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
      }
    }
    .padding(size.width > 110 && size.height > 62 ? 10 : 4)
    .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    .background {
      shape.fill(shade).overlay {
        shape.fill(LinearGradient(
          colors: [tint.opacity(selected ? 0.55 : 0.31), tint.opacity(0.09)],
          startPoint: .topLeading, endPoint: .bottomTrailing))
      }
    }
    .overlay {
      Canvas { context, geometry in
        var lines = Path()
        for y in stride(from: 0.0, to: geometry.height + 18, by: 12.0) {
          lines.move(to: CGPoint(x: 0, y: y))
          lines.addLine(to: CGPoint(x: geometry.width, y: y - 18))
        }
        context.stroke(lines, with: .color(tint.opacity(0.08)))
      }.allowsHitTesting(false).accessibilityHidden(true)
    }
    .clipShape(shape)
    .overlay { shape.strokeBorder(tint.opacity(selected ? 1 : 0.42), lineWidth: selected ? 2 : 1) }
    .contentShape(Rectangle())
  }
}
