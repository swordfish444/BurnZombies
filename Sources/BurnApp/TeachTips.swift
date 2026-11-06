import BurnCore
import SwiftUI

/// The tips in Teach BZ's quiet corner, the way games show loading-screen tips: one short tip fades
/// in, stays `shownFor`, fades out, and the next comes `gap` later. The pointer on it stops its
/// clock; Next skips ahead. Which tip comes next is `AutopilotTipDeck`'s: tips for where the owner
/// is come first, each shows a few times at most, and doing what one teaches retires it for good.
/// What was shown and what the owner did are kept across launches.
@MainActor final class TeachTipsModel: ObservableObject {
  static let firstAfter: TimeInterval = 2.5
  static let shownFor: TimeInterval = 12
  static let gap: TimeInterval = 8
  private static let shownKey = "teachTipsShown"
  private static let doneKey = "teachTipsDone"

  @Published private(set) var tip: AutopilotTip?
  @Published private(set) var visible = false
  /// How long the tip on screen has shown. Nothing on screen counts it down: the tip just changes.
  private var held: TimeInterval = 0
  /// The pointer rests on the tip: its clock stands still.
  var paused = false
  private var deck = AutopilotTipDeck(tips: [])
  private var place: AutopilotTip.Place = .question
  private var waiting = false
  private var waitLeft: TimeInterval = 0
  private var skipping = false
  private var loop: Task<Void, Never>?
  private let defaults: UserDefaults?
  /// An offscreen render's tip: it stays, and nothing rotates.
  private let fixed: Bool

  /// `defaults` keeps what was shown and done across launches; nil keeps nothing (demo and
  /// proofs). `showing` puts a tip on screen at once, for offscreen renders.
  init(defaults: UserDefaults?, showing: AutopilotTip? = nil) {
    self.defaults = defaults
    fixed = showing != nil
    if let showing {
      tip = showing
      visible = true
    }
  }

  /// A question about `kind` is on screen: its tips from now on, the first after a moment. A card
  /// about copies with big unsaved files (`bigFiles`) gets tips that never say it can be undone.
  func start(kind: AutopilotKind, filters: Bool, bigFiles: Bool = false) {
    let shown = defaults?.dictionary(forKey: Self.shownKey) as? [String: Int] ?? [:]
    let done = Set(defaults?.stringArray(forKey: Self.doneKey) ?? [])
    let tips: [AutopilotTip] = AutopilotPolicy.tips(
      for: kind, filters: filters, bigFiles: bigFiles)
    deck = AutopilotTipDeck(tips: tips, shown: shown, done: done)
    loop?.cancel()
    guard !fixed else { return }
    visible = false
    loop = Task { [weak self] in await self?.run() }
  }

  func stop() {
    loop?.cancel()
    loop = nil
    visible = false
  }

  /// The owner moved to `place`: an unseen tip for it comes soon instead of after the whole gap.
  func at(_ place: AutopilotTip.Place) {
    self.place = place
    guard waiting, place > .question else { return }
    let unseen = deck.tips.contains { tip in
      tip.place == place && deck.live(tip) && deck.shown[tip.id, default: 0] == 0
    }
    if unseen { waitLeft = min(waitLeft, 1.8) }
  }

  /// The owner did `action`: tips it teaches retire, and one on screen leaves at once.
  func did(_ action: String) {
    if deck.did(action, showing: visible ? tip : nil) {
      withAnimation(.easeIn(duration: 0.22)) { visible = false }
    }
    defaults?.set(Array(deck.done).sorted(), forKey: Self.doneKey)
  }

  /// Next: this tip goes and another comes right away.
  func next() {
    skipping = true
    withAnimation(.easeIn(duration: 0.22)) { visible = false }
  }

  private func run() async {
    waitLeft = Self.firstAfter
    while !Task.isCancelled {
      waiting = true
      while waitLeft > 0 {
        try? await Task.sleep(for: .milliseconds(100))
        if Task.isCancelled { return }
        waitLeft -= 0.1
      }
      waiting = false
      guard let next = deck.next(at: place) else {
        waitLeft = Self.gap
        continue
      }
      defaults?.set(deck.shown, forKey: Self.shownKey)
      tip = next
      held = 0
      skipping = false
      withAnimation(.easeOut(duration: 0.5)) { visible = true }
      // It stays `shownFor`, counting only while the pointer isn't on it; Next or doing what it
      // teaches ends it sooner.
      while held < Self.shownFor && visible {
        try? await Task.sleep(for: .milliseconds(100))
        if Task.isCancelled { return }
        if !paused { held += 0.1 }
      }
      if visible { withAnimation(.easeIn(duration: 0.7)) { visible = false } }
      try? await Task.sleep(for: .milliseconds(skipping ? 220 : 700))
      if Task.isCancelled { return }
      waitLeft = skipping ? 0.1 : Self.gap
    }
  }
}

/// The tip on screen, top left above the question: a bulb, TIP and one line. Pointing at it pauses
/// it and offers Next.
struct TeachTipsView: View {
  @ObservedObject var model: TeachTipsModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    if let tip = model.tip {
      HStack(spacing: 7) {
        Image(systemName: "lightbulb.fill").font(.system(size: 12))
          .foregroundStyle(AutopilotTheme.yellow)
          .shadow(color: AutopilotTheme.yellow.opacity(0.35), radius: 4)
        Text("TIP").font(BurnTheme.display(13)).tracking(1.1).foregroundStyle(BurnTheme.orange)
        Text(tip.text).font(.system(size: 12.5)).foregroundStyle(BurnTheme.cream.opacity(0.84))
          .lineLimit(1).truncationMode(.tail)
        Button {
          model.next()
        } label: {
          Text("Next ›").font(.system(size: 12)).underline().foregroundStyle(BurnTheme.muted)
        }
        .buttonStyle(.plain).clickPointer().opacity(hovering ? 1 : 0)
        .accessibilityIdentifier("teach-tip-next")
      }
      .opacity(model.visible ? 1 : 0)
      .offset(x: model.visible || reduceMotion ? 0 : -8)
      .contentShape(Rectangle())
      .onHover { inside in
        hovering = inside
        model.paused = inside
      }
      .allowsHitTesting(model.visible)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Tip: " + tip.text)
      .accessibilityIdentifier("teach-tip")
    }
  }
}
