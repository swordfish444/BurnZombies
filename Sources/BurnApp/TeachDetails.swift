import AppKit
import BurnCore
import SwiftUI

/// Teach BZ's details for the question on screen: open or not, the list or one thing opened, the
/// filter, and what the owner spared or unspared here that the engine hasn't shown back yet.
struct TeachDetailsState: Equatable {
  var open = false
  /// The question these belong to: another question starts afresh.
  var questionID: String?
  var filter = "all"
  /// The thing opened, by id; nil shows the list.
  var opened: String?
  /// The last thing opened, so the list comes back to it.
  var lastOpened: String?
  /// Which way the page last flipped: 1 forward, -1 back.
  var flip = 1
  /// Spared (true) or unspared (false) on this card, by id.
  var overrides: [String: Bool] = [:]
}

/// What the hover card shows and where its row is, in Teach BZ's coordinate space.
struct TeachHover: Equatable {
  /// How long the pointer rests on a row before its card comes up.
  static let delay: Duration = .milliseconds(1500)
  var detail: AutopilotDetail
  var frame: CGRect
}

/// The details, in the space the line and chips had: everything the card is about with filters, or
/// one thing opened, with ‹ › to flip through and Back to return to the same spot in the list.
struct TeachDetailsPanel: View {
  static let height: CGFloat = 256
  let listed: [AutopilotDetail]
  let noun: String
  /// What a Yes deletes for good, for the warning beside the filters.
  let cost: String?
  @Binding var state: TeachDetailsState
  @Binding var hover: TeachHover?
  let spare: (AutopilotDetail) -> Void
  let did: (String) -> Void

  var body: some View {
    let filters = AutopilotPolicy.detailFilters(listed)
    let filter = filters.contains { $0.id == state.filter } ? state.filter : "all"
    let shown = AutopilotPolicy.filtered(listed, by: filter)
    let index: Int? = state.opened.flatMap { id in shown.firstIndex { $0.id == id } }
    ZStack {
      TeachDetailList(
        filters: filters, filter: filter, shown: shown, noun: noun, cost: cost, state: $state,
        hover: $hover, open: open, spare: spare, did: did
      )
      .opacity(index == nil ? 1 : 0)
      .offset(x: index == nil ? 0 : -28)
      .allowsHitTesting(index == nil)
      .accessibilityHidden(index != nil)
      if let index {
        TeachDetailPage(
          detail: shown[index], position: index, total: shown.count,
          backLabel: filter == "all"
            ? "All " + Self.plural(noun) : filters.first { $0.id == filter }?.label ?? "Back",
          noun: noun, flip: state.flip, back: back, step: { step($0, in: shown) },
          spare: { spare(shown[index]) }
        )
        .transition(.offset(x: 28).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity).frame(height: Self.height)
    .background(Color.white.opacity(0.035))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.line))
  }

  static func plural(_ noun: String) -> String { noun == "copy" ? "copies" : noun + "s" }

  private func open(_ detail: AutopilotDetail) {
    hover = nil
    withAnimation(.snappy(duration: 0.26)) {
      state.flip = 1
      state.opened = detail.id
      state.lastOpened = detail.id
    }
  }

  private func back() {
    withAnimation(.snappy(duration: 0.26)) { state.opened = nil }
  }

  private func step(_ by: Int, in shown: [AutopilotDetail]) {
    guard let id = state.opened, let at = shown.firstIndex(where: { $0.id == id }) else { return }
    let to = at + by
    guard shown.indices.contains(to) else { return }
    state.flip = by
    withAnimation(.snappy(duration: 0.22)) {
      state.opened = shown[to].id
      state.lastOpened = shown[to].id
    }
    did("flip")
  }
}

/// The list: filters on top, then a row for each thing, biggest first. Coming back from one thing
/// opened, its row is brought into view and glows for a moment, so the owner never loses the spot.
private struct TeachDetailList: View {
  let filters: [AutopilotDetailFilter]
  let filter: String
  let shown: [AutopilotDetail]
  let noun: String
  let cost: String?
  @Binding var state: TeachDetailsState
  @Binding var hover: TeachHover?
  let open: (AutopilotDetail) -> Void
  let spare: (AutopilotDetail) -> Void
  let did: (String) -> Void
  @State private var glow: String?

  var body: some View {
    VStack(spacing: 0) {
      filterBar
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(shown) { detail in
              TeachDetailRow(
                detail: detail, glowing: glow == detail.id, noun: noun, hover: $hover,
                open: { open(detail) }, spare: { spare(detail) }, did: did
              )
              .id(detail.id)
              if detail.id != shown.last?.id { Rectangle().fill(BurnTheme.line).frame(height: 1) }
            }
            if shown.isEmpty {
              Text("Nothing spared yet.").font(.system(size: 13)).foregroundStyle(BurnTheme.muted)
                .padding(.vertical, 28)
            }
          }
        }
        .scrollIndicators(.visible)
        // macOS hides its scroller until a scroll; a flash as the list opens shows there's more.
        .scrollIndicatorsFlash(onAppear: true)
        .onChange(of: state.opened) { _, opened in
          guard opened == nil, let back = state.lastOpened else { return }
          proxy.scrollTo(back, anchor: .center)
          glow = back
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeOut(duration: 0.7)) { if glow == back { glow = nil } }
          }
        }
      }
    }
  }

  private var filterBar: some View {
    HStack(spacing: 16) {
      ForEach(filters) { item in
        Button {
          guard state.filter != item.id else { return }
          hover = nil
          state.filter = item.id
          did("filter")
        } label: {
          HStack(spacing: 5) {
            if item.risky {
              Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                .foregroundStyle(Color.orange)
            }
            Text(item.label).font(.system(size: 12.5, weight: .semibold))
            Text("\(item.count)").font(.system(size: 12.5)).opacity(0.8)
          }
          .foregroundStyle(filter == item.id ? BurnTheme.cream : BurnTheme.muted)
          .frame(maxHeight: .infinity)
          .overlay(alignment: .bottom) {
            if filter == item.id { Capsule().fill(BurnTheme.orange).frame(height: 2) }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickPointer().accessibilityIdentifier("teach-filter-" + item.id)
      }
      Spacer(minLength: 0)
      // What a Yes deletes for good, which Undo can't bring back: an amber warning whose tooltip
      // says it, rather than a paragraph on the card.
      if let cost {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
          .foregroundStyle(Color.orange)
          .frame(width: 26, height: 26).contentShape(Rectangle())
          .help(cost)
          .accessibilityElement().accessibilityLabel(cost)
          .accessibilityIdentifier("teach-cost")
      }
    }
    .padding(.horizontal, 14).frame(height: 34)
  }
}

/// One row: what it is and its project, when it was last used and its few words, its size, Spare,
/// and the way in. Resting on it brings up everything BZ knows about it.
private struct TeachDetailRow: View {
  let detail: AutopilotDetail
  let glowing: Bool
  let noun: String
  @Binding var hover: TeachHover?
  let open: () -> Void
  let spare: () -> Void
  let did: (String) -> Void
  @State private var hovering = false
  @State private var onButton = false
  @State private var frame: CGRect = .zero
  @State private var resting: Task<Void, Never>?

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(detail.title).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
            .truncationMode(.tail)
          if let subtitle = detail.subtitle {
            Text(subtitle).font(.system(size: 12)).foregroundStyle(BurnTheme.muted).lineLimit(1)
              .fixedSize()
          }
        }
        HStack(spacing: 9) {
          if !detail.when.isEmpty { Text(detail.when).foregroundStyle(BurnTheme.muted) }
          ForEach(detail.tags, id: \.text) { tag in TeachTagText(tag: tag) }
        }
        .font(.system(size: 11.5)).lineLimit(1)
      }
      .opacity(detail.spared ? 0.4 : 1)
      Spacer(minLength: 8)
      Text(detail.size).font(.system(size: 13, weight: .semibold)).monospacedDigit().fixedSize()
        .opacity(detail.spared ? 0.4 : 1)
      TeachSpareButton(spared: detail.spared, noun: noun, rowHovered: hovering, action: spare)
        .onHover { inside in
          onButton = inside
          if inside { endHover() } else if hovering { waitToShow() }
        }
      Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
        .foregroundStyle(hovering ? BurnTheme.cream : BurnTheme.muted.opacity(0.6))
    }
    .padding(.vertical, 7).padding(.leading, 14).padding(.trailing, 8)
    .background(background)
    .contentShape(Rectangle())
    .onTapGesture {
      endHover()
      open()
    }
    .onHover { inside in
      hovering = inside
      if inside && !onButton { waitToShow() } else { endHover() }
    }
    .background {
      GeometryReader { geo in
        Color.clear
          .onAppear { frame = geo.frame(in: .named(TeachView.space)) }
          .onChange(of: geo.frame(in: .named(TeachView.space))) { _, moved in
            // A card already up is left where the row was, so it goes; a wait under a still
            // pointer goes on, and the card comes up where the row is now.
            frame = moved
            if hover?.detail.id == detail.id {
              withAnimation(.easeOut(duration: 0.1)) { hover = nil }
            }
          }
      }
    }
    .onDisappear { endHover() }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("teach-detail-row")
  }

  private var background: Color {
    if hovering { return Color.white.opacity(0.045) }
    return glowing ? BurnTheme.orange.opacity(0.17) : .clear
  }

  private func waitToShow() {
    resting?.cancel()
    resting = Task { @MainActor in
      try? await Task.sleep(for: TeachHover.delay)
      guard !Task.isCancelled, hovering, !onButton else { return }
      withAnimation(.easeOut(duration: 0.14)) { hover = TeachHover(detail: detail, frame: frame) }
      did("hover")
    }
  }

  private func endHover() {
    resting?.cancel()
    resting = nil
    if hover?.detail.id == detail.id { withAnimation(.easeOut(duration: 0.1)) { hover = nil } }
  }
}

private struct TeachTagText: View {
  let tag: AutopilotDetail.Tag
  var body: some View {
    HStack(spacing: 3) {
      if tag.risky { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)) }
      Text(tag.text)
    }
    .foregroundStyle(tag.risky ? Color.orange : BurnTheme.muted.opacity(0.8))
  }
}

/// Spare, Spared and Unspare in one button. Spare keeps a thing out of the fire, now and later;
/// spared, it says so, and turns into Unspare under the pointer, the way Following turns into
/// Unfollow. Right after a click it keeps saying Spared until the pointer leaves, so the click
/// doesn't read as undone.
struct TeachSpareButton: View {
  let spared: Bool
  let noun: String
  var big = false
  var rowHovered = false
  let action: () -> Void
  @State private var hovering = false
  @State private var fresh = false

  var body: some View {
    let unspare = spared && hovering && !fresh
    Button {
      fresh = !spared
      action()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: unspare ? "flame.fill" : spared ? "hand.raised.fill" : "hand.raised")
          .font(.system(size: big ? 11.5 : 11))
        Text(unspare ? "Unspare" : spared ? "Spared" : big ? "Spare this " + noun : "Spare")
      }
      .font(.system(size: big ? 12.5 : 12, weight: .semibold))
      .foregroundStyle(textColor(unspare))
      .padding(.horizontal, 10)
      .frame(minWidth: big ? 150 : 86, minHeight: big ? 28 : 24)
      .background(fillColor(unspare), in: Capsule())
      .overlay(Capsule().strokeBorder(strokeColor(unspare)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain).clickPointer()
    .onHover { inside in
      hovering = inside
      if !inside { fresh = false }
    }
    .help(
      spared
        ? "Unspare: BZ decides about it again." : "Spare: keep it out of the fire, now and later."
    )
    .accessibilityLabel(spared ? "Spared. Unspare" : "Spare")
    .accessibilityIdentifier(spared ? "teach-unspare" : "teach-spare")
  }

  private func textColor(_ unspare: Bool) -> Color {
    if unspare { return BurnTheme.orange }
    if spared { return AutopilotTheme.green }
    return big || rowHovered || hovering ? BurnTheme.cream : BurnTheme.muted
  }

  private func fillColor(_ unspare: Bool) -> Color {
    if unspare { return BurnTheme.orange.opacity(0.12) }
    if spared { return AutopilotTheme.green.opacity(0.12) }
    if hovering { return Color.white.opacity(0.16) }
    return big || rowHovered ? Color.white.opacity(0.08) : .clear
  }

  private func strokeColor(_ unspare: Bool) -> Color {
    if unspare { return BurnTheme.orange.opacity(0.55) }
    if spared { return AutopilotTheme.green.opacity(0.4) }
    return Color.white.opacity(big || rowHovered ? 0.18 : 0.12)
  }
}

/// One thing opened: what it is, where it lives, the facts behind its row, and Spare. ‹ › and the
/// arrow keys flip to the next one in the same list; Back and Esc return to it.
private struct TeachDetailPage: View {
  let detail: AutopilotDetail
  let position: Int
  let total: Int
  let backLabel: String
  let noun: String
  let flip: Int
  let back: () -> Void
  let step: (Int) -> Void
  let spare: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Button(action: back) {
          HStack(spacing: 2) {
            Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
            Text(backLabel)
          }
          .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(BurnTheme.cream)
          .padding(.horizontal, 7).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickPointer().keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("teach-detail-back")
        Spacer(minLength: 8)
        pager(-1, symbol: "chevron.left", key: .leftArrow, off: position == 0)
        Text("\(position + 1) of \(total)").font(.system(size: 12, weight: .semibold))
          .monospacedDigit().foregroundStyle(BurnTheme.muted).frame(minWidth: 62)
        pager(1, symbol: "chevron.right", key: .rightArrow, off: position >= total - 1)
      }
      .padding(.leading, 5).padding(.trailing, 8).frame(height: 34)
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      ScrollView(.vertical) {
        content.id(detail.id)
          .transition(
            .asymmetric(
              insertion: .offset(x: CGFloat(flip) * 18).combined(with: .opacity),
              removal: .opacity))
      }
      .scrollIndicators(.automatic)
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(detail.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
          .opacity(detail.spared ? 0.45 : 1)
        if let subtitle = detail.subtitle {
          Text(subtitle).font(.system(size: 12.5)).foregroundStyle(BurnTheme.muted).fixedSize()
            .opacity(detail.spared ? 0.45 : 1)
        }
        if detail.spared {
          Label("Spared", systemImage: "hand.raised.fill").font(
            .system(size: 11, weight: .semibold)
          )
          .foregroundStyle(AutopilotTheme.green).padding(.horizontal, 7).padding(.vertical, 2)
          .background(AutopilotTheme.green.opacity(0.12), in: Capsule())
          .overlay(Capsule().strokeBorder(AutopilotTheme.green.opacity(0.4)))
          .fixedSize()
        }
      }
      if let path = detail.item.path {
        HStack(spacing: 10) {
          Text(path).font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Color(white: 0.6)).lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          } label: {
            Text("Show in Finder").font(.system(size: 12)).underline()
              .foregroundStyle(BurnTheme.muted)
          }
          .buttonStyle(.plain).clickPointer().fixedSize()
        }
        .padding(.top, 3).opacity(detail.spared ? 0.45 : 1)
      }
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        ForEach(Array(stride(from: 0, to: detail.facts.count, by: 2)), id: \.self) { start in
          GridRow {
            ForEach(detail.facts[start..<min(start + 2, detail.facts.count)], id: \.label) { fact in
              VStack(alignment: .leading, spacing: 1) {
                Text(fact.label).font(.system(size: 11)).foregroundStyle(Color(white: 0.56))
                HStack(spacing: 4) {
                  if fact.risky {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                  }
                  Text(fact.value).lineLimit(1)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(fact.risky ? Color.orange : BurnTheme.cream)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      .padding(.top, 11).opacity(detail.spared ? 0.45 : 1)
      HStack(spacing: 12) {
        TeachSpareButton(spared: detail.spared, noun: noun, big: true, action: spare)
        Spacer(minLength: 8)
        Text("← → flip · esc back").font(.system(size: 11.5)).foregroundStyle(Color(white: 0.54))
      }
      .padding(.top, 11)
    }
    .padding(.horizontal, 16).padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func pager(_ by: Int, symbol: String, key: KeyEquivalent, off: Bool) -> some View {
    Button {
      step(by)
    } label: {
      Image(systemName: symbol).font(.system(size: 11, weight: .bold))
        .foregroundStyle(BurnTheme.cream).frame(width: 24, height: 24)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain).clickPointer().disabled(off).opacity(off ? 0.3 : 1)
    .keyboardShortcut(key, modifiers: [])
    .accessibilityLabel(by < 0 ? "Previous " + noun : "Next " + noun)
  }
}

/// What comes up when the pointer rests on a row: everything BZ knows about it, and what burning it
/// does.
struct TeachHoverCard: View {
  let detail: AutopilotDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(detail.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
        if let subtitle = detail.subtitle {
          Text(subtitle).font(.system(size: 12)).foregroundStyle(BurnTheme.muted).lineLimit(1)
        }
        Spacer(minLength: 8)
        Text(detail.size).font(.system(size: 12.5, weight: .semibold)).fixedSize()
      }
      if let path = detail.item.path {
        Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(white: 0.6))
          .lineLimit(2).truncationMode(.middle).padding(.top, 3)
      }
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
        ForEach(detail.facts.dropFirst(), id: \.label) { fact in
          GridRow {
            Text(fact.label).foregroundStyle(Color(white: 0.56))
            Text(fact.value).foregroundStyle(fact.risky ? Color.orange : BurnTheme.cream)
          }
        }
      }
      .font(.system(size: 12)).padding(.top, 8)
      Rectangle().fill(BurnTheme.line).frame(height: 1).padding(.top, 8)
      Text(detail.spared ? "Spared: I won't burn it, now or later." : detail.consequence)
        .font(.system(size: 11.5)).foregroundStyle(Color(white: 0.6))
        .fixedSize(horizontal: false, vertical: true).padding(.top, 7)
    }
    .padding(.horizontal, 13).padding(.vertical, 11)
    .frame(width: 352, alignment: .leading)
    .background(
      Color(red: 0.145, green: 0.145, blue: 0.141).opacity(0.98),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.14)))
    .shadow(color: .black.opacity(0.55), radius: 17, y: 14)
  }
}

/// Draws the hover card over the whole window, below its row when it fits and above it when not,
/// never past an edge.
struct TeachHoverLayer: View {
  let hover: TeachHover?
  @State private var size: CGSize = .zero

  var body: some View {
    GeometryReader { geo in
      if let hover {
        let below = hover.frame.maxY + 6 + size.height <= geo.size.height - 8
        let y = below ? hover.frame.maxY + 6 : hover.frame.minY - 6 - size.height
        let x = min(max(12, hover.frame.minX + 34), geo.size.width - 352 - 12)
        TeachHoverCard(detail: hover.detail)
          .fixedSize()
          .background {
            GeometryReader { card in
              Color.clear
                .onAppear { size = card.size }
                .onChange(of: card.size) { _, measured in size = measured }
            }
          }
          .offset(x: x, y: y)
          .opacity(size == .zero ? 0 : 1)
          .transition(.opacity)
          .accessibilityIdentifier("teach-hover-card")
      }
    }
    .allowsHitTesting(false)
  }
}
