import BurnCore
import SwiftUI

/// The short moment after an answer: what happens now, in a line.
struct HuntConfirmation: Equatable {
  var title: String
  var line: String
  var symbol: String
}

/// What a hunt runs into that needs the owner, one card at a time like Teach BZ, answered while it
/// keeps going: BZ's questions, and things the AI is sure about but may not burn on its own. A card
/// stays until it is answered; new ones add a dot. Biggest first.
struct HuntNeedsYou: View {
  @ObservedObject var model: AppModel
  let running: Bool
  /// The column's width, so a two-line headline can break evenly.
  var width: CGFloat? = nil
  @State private var pinned: String?
  @State private var answered = Set<String>()
  @State private var confirmation: HuntConfirmation?

  /// `confirmation` starts the card on an answer's note, for offscreen renders.
  init(
    model: AppModel, running: Bool, width: CGFloat? = nil, confirmation: HuntConfirmation? = nil
  ) {
    self.model = model
    self.running = running
    self.width = width
    _confirmation = State(initialValue: confirmation)
  }

  /// Room for what a card says, inside its padding.
  private var measure: CGFloat? { width.map { max(0, $0 - 40) } }

  enum Card: Identifiable {
    case question(AutopilotQuestion)
    case ok(AutopilotEntry)
    var id: String {
      switch self {
      case .question(let q): return "q:" + q.id
      case .ok(let e): return "ok:" + e.id
      }
    }
    var bytes: UInt64 {
      switch self {
      case .question(let q): return q.bytes
      case .ok(let e): return e.item.bytes
      }
    }
  }

  /// What a card shows, worked out once from a question or an entry.
  private struct Face {
    var emoji: String
    var headline: String
    var name: String?
    var frees: String
    var line: String?
    var chips: [String]
    var cautions: Set<String>
    var cost: String?
    var yes: String
    var no: String
  }

  private var cards: [Card] {
    let questions = model.autopilot.questions.filter(\.isOpen).map(Card.question)
    let waiting = model.autopilot.entries.filter { $0.needsOK == true && $0.status == .unsure }
      .map(Card.ok)
    return (questions + waiting).filter { !answered.contains($0.id) }.sorted { $0.bytes > $1.bytes }
  }
  private var current: Card? {
    let all = cards
    return all.first { $0.id == pinned } ?? all.first
  }

  var body: some View {
    let all = cards
    return VStack(alignment: .leading, spacing: 0) {
      HuntColumnHeader(
        title: "Needs you",
        subtitle: running
          ? "The hunt keeps going. A yes burns right away."
          : "A yes still burns right away. Questions also wait in Teach BZ."
      ) {
        if all.count > 1, confirmation == nil, let current,
          let index = all.firstIndex(where: { $0.id == current.id })
        {
          carousel(index: index, count: all.count)
        }
      }
      card.padding(.top, 9)
      Spacer(minLength: 0)
    }
    .onChange(of: all.map(\.id), initial: true) { _, ids in
      if pinned == nil || !ids.contains(pinned!) { pinned = ids.first }
    }
    .accessibilityIdentifier("hunt-needs-you")
  }

  /// Dots, "2 of 3" and the arrows.
  private func carousel(index: Int, count: Int) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 5) {
        ForEach(0..<min(count, 8), id: \.self) { i in
          Circle().fill(i == index ? BurnTheme.orange : Color.white.opacity(0.18))
            .frame(width: 6, height: 6)
        }
      }
      Text("\(index + 1) of \(count)").font(.system(size: 11.5)).monospacedDigit()
        .foregroundStyle(BurnTheme.muted).fixedSize()
      HStack(spacing: 4) {
        arrow("chevron.left", label: "Previous") { step(-1) }
        arrow("chevron.right", label: "Next") { step(1) }
      }
    }
  }

  private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 10, weight: .bold))
        .foregroundStyle(BurnTheme.cream.opacity(0.85))
        .frame(width: 22, height: 22)
        .background(Color.white.opacity(0.07), in: Circle())
        .contentShape(Circle())
    }.buttonStyle(.plain).clickPointer().accessibilityLabel(label)
  }

  private func step(_ by: Int) {
    let list = cards
    guard !list.isEmpty, confirmation == nil else { return }
    let index = list.firstIndex { $0.id == current?.id } ?? 0
    pinned = list[(index + by + list.count) % list.count].id
  }

  // MARK: The card

  /// One soft card that takes the room the column gives it, up to a calm height: what it says and
  /// the answers stay together in the middle. With nothing to ask, the same card rests with its
  /// note in the middle and ends with the feed beside it, and the next card takes its place
  /// without anything moving.
  private var card: some View {
    surface(
      ZStack {
        if let confirmation {
          note(confirmation).transition(.opacity)
        } else if let current {
          face(current).id(current.id).transition(.opacity)
        } else {
          empty.transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: 360))
  }

  private func surface(_ content: some View) -> some View {
    content
      .background(HuntStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(HuntStyle.hairline)
      )
      .animation(.easeOut(duration: 0.22), value: confirmation)
      .animation(.easeOut(duration: 0.22), value: current?.id)
  }

  @ViewBuilder private func face(_ card: Card) -> some View {
    switch card {
    case .question(let question):
      let made = AutopilotPolicy.card(question)
      layout(
        Face(
          emoji: AutopilotLook.emoji(question.kind), headline: made.headline, name: nil,
          frees: made.frees, line: made.line, chips: Array(made.facts.prefix(3)),
          cautions: Set(made.cautions), cost: made.cost, yes: made.yes, no: made.no),
        onYes: { respond(question, .yes) }, onNo: { respond(question, .no) },
        onSkip: { respond(question, .skip) }, details: { model.openTeach?() })
    case .ok(let entry):
      // One thing the AI is sure should burn but may not burn itself: the owner's Yes is Burn now.
      let reason = AutopilotPolicy.needsOK(entry.item)
      layout(
        Face(
          emoji: AutopilotLook.emoji(entry.item.kind),
          headline: "Burn this \(TeachView.noun(entry.item.kind))?", name: entry.item.name,
          frees: "Frees " + AutopilotPolicy.roughly(entry.item.bytes)
            + (entry.item.kind == .process ? " of memory" : ""),
          line: entry.aiWhy, chips: [reason, "AI is sure"], cautions: [reason], cost: nil,
          yes: "Yes, burn it", no: "No, keep it"),
        onYes: { decide(entry, burn: true) }, onNo: { decide(entry, burn: false) },
        onSkip: { skip(entry) }, details: { model.openFindings?() })
    }
  }

  /// Roomy when the column is tall enough, with the emoji on top; tighter when it isn't, so nothing
  /// is ever cut off; and if even that won't fit, what it says scrolls above the answers.
  private func layout(
    _ face: Face, onYes: @escaping () -> Void, onNo: @escaping () -> Void,
    onSkip: @escaping () -> Void, details: @escaping () -> Void
  ) -> some View {
    ViewThatFits(in: .vertical) {
      arranged(face, roomy: true, onYes: onYes, onNo: onNo, onSkip: onSkip, details: details)
      arranged(face, roomy: false, onYes: onYes, onNo: onNo, onSkip: onSkip, details: details)
      VStack(spacing: 0) {
        ScrollView(.vertical) { words(face, roomy: false).padding(.vertical, 4) }
          .scrollBounceBehavior(.basedOnSize)
          // Anything below the fold fades instead of being cut by the answers.
          .mask(
            VStack(spacing: 0) {
              Color.black
              LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
            })
        answers(face, roomy: false, onYes: onYes, onNo: onNo, onSkip: onSkip, details: details)
          .padding(.top, 8)
      }.padding(.horizontal, 18).padding(.vertical, 12)
    }
  }

  private func arranged(
    _ face: Face, roomy: Bool, onYes: @escaping () -> Void, onNo: @escaping () -> Void,
    onSkip: @escaping () -> Void, details: @escaping () -> Void
  ) -> some View {
    // What it says and the answers stay together, centered in whatever room the card has.
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      words(face, roomy: roomy)
      Spacer(minLength: roomy ? 16 : 12)
        .frame(minHeight: roomy ? 16 : 12, maxHeight: roomy ? 30 : 18)
      answers(face, roomy: roomy, onYes: onYes, onNo: onNo, onSkip: onSkip, details: details)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20).padding(.top, roomy ? 18 : 12).padding(.bottom, roomy ? 16 : 11)
  }

  /// Only what the owner needs to decide: the headline, what it frees, one safe line and the chips.
  private func words(_ face: Face, roomy: Bool) -> some View {
    VStack(spacing: 0) {
      if roomy { Text(face.emoji).font(.system(size: 26)).padding(.bottom, 7) }
      Text(face.headline)
        .font(.system(size: roomy ? 18.5 : 17, weight: .semibold, design: .rounded))
        .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: balanced(face.headline, HuntType.rounded(roomy ? 18.5 : 17, .semibold)))
      if let name = face.name {
        Text(name).font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(BurnTheme.cream.opacity(0.82))
          .lineLimit(1).truncationMode(.middle).padding(.top, 3)
      }
      Text(face.frees)
        .font(.system(size: roomy ? 16 : 15, weight: .bold, design: .rounded))
        .foregroundStyle(BurnTheme.orange).padding(.top, roomy ? 6 : 4)
      if let line = face.line, !line.isEmpty {
        Text(line).font(.system(size: 12.5)).foregroundStyle(BurnTheme.muted)
          .multilineTextAlignment(.center).lineLimit(roomy ? 3 : 2)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: balanced(line, NSFont.systemFont(ofSize: 12.5)))
          .padding(.top, roomy ? 7 : 5)
      }
      if !face.chips.isEmpty {
        HuntChipFlow {
          ForEach(face.chips, id: \.self) { chip in
            HuntChip(text: chip, caution: face.cautions.contains(chip))
          }
        }.padding(.top, roomy ? 11 : 9)
      }
      if let cost = face.cost {
        Label(cost, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.orange)
          .multilineTextAlignment(.center).lineLimit(2)
          .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
      }
    }.frame(maxWidth: .infinity)
  }

  private func balanced(_ text: String, _ font: NSFont) -> CGFloat {
    guard let measure else { return .infinity }
    return HuntType.balanced(text, font: font, in: measure)
  }

  /// Two wide pills, Yes in green, then "Not sure — skip" and View details under them.
  private func answers(
    _ face: Face, roomy: Bool, onYes: @escaping () -> Void, onNo: @escaping () -> Void,
    onSkip: @escaping () -> Void, details: @escaping () -> Void
  ) -> some View {
    VStack(spacing: roomy ? 11 : 8) {
      HStack(spacing: 10) {
        answer(face.yes, fill: HuntStyle.yes, stroke: .clear, roomy: roomy, id: "hunt-yes",
          action: onYes)
        answer(face.no, fill: .clear, stroke: Color.white.opacity(0.18), roomy: roomy,
          id: "hunt-no", action: onNo)
      }.frame(maxWidth: 420)
      HStack(spacing: 14) {
        link("Not sure — skip", id: "hunt-skip", action: onSkip)
        Circle().fill(BurnTheme.muted.opacity(0.5)).frame(width: 2.5, height: 2.5)
        link("View details", id: "hunt-details", action: details)
      }
    }
  }

  private func answer(
    _ title: String, fill: Color, stroke: Color, roomy: Bool, id: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: roomy ? 14.5 : 14, weight: .semibold, design: .rounded))
        .foregroundStyle(BurnTheme.cream).lineLimit(1).minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity).frame(height: roomy ? 38 : 34)
        // Circular ends: a continuous capsule's flatter ends show as straight lines in an outline.
        .background(fill, in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).strokeBorder(stroke))
        .contentShape(Capsule())
    }.buttonStyle(.plain).clickPointer().accessibilityIdentifier(id)
  }

  private func link(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 11.5)).underline().foregroundStyle(BurnTheme.muted)
    }.buttonStyle(.plain).clickPointer().accessibilityIdentifier(id)
  }

  /// After an answer: what happens now, centered where the card was.
  private func note(_ note: HuntConfirmation) -> some View {
    VStack(spacing: 8) {
      Image(systemName: note.symbol).font(.system(size: 30, weight: .semibold))
        .foregroundStyle(tint(note.symbol)).padding(.bottom, 4)
      Text(note.title).font(.system(size: 18, weight: .bold, design: .rounded))
        .multilineTextAlignment(.center)
      Text(note.line).font(.system(size: 12.5)).foregroundStyle(BurnTheme.muted)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }.padding(24)
  }

  private func tint(_ symbol: String) -> Color {
    switch symbol {
    case "flame.fill": return BurnTheme.orange
    case "hand.raised.fill": return AutopilotTheme.green
    default: return BurnTheme.muted
    }
  }

  private var empty: some View {
    VStack(spacing: 7) {
      Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .regular))
        .foregroundStyle(AutopilotTheme.green.opacity(0.9)).padding(.bottom, 3)
      Text("Nothing needs you right now").font(.system(size: 14, weight: .semibold))
      Text("Cards show up here when the hunt finds something it isn't sure about.")
        .font(.system(size: 12.5)).foregroundStyle(BurnTheme.muted)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 280)
    }.padding(.horizontal, 24).padding(.vertical, 26)
  }

  // MARK: Answers

  private func respond(_ question: AutopilotQuestion, _ answer: AutopilotAnswer) {
    guard confirmation == nil else { return }
    model.answer(question, answer)
    answered.insert(Card.question(question).id)
    switch answer {
    case .yes:
      show("Burning them now", "BZ handles ones like these on its own from now on.", "flame.fill")
    case .no:
      show("Keeping them", "BZ won't ask about these again.", "hand.raised.fill")
    default:
      show("Skipped", "It waits in Teach BZ for later.", "clock")
    }
  }

  /// Yes is the owner's Burn now; No keeps it for good, as Keep forever does.
  private func decide(_ entry: AutopilotEntry, burn: Bool) {
    guard confirmation == nil else { return }
    answered.insert(Card.ok(entry).id)
    if burn {
      model.burnNow(entry)
      let line: String
      switch entry.item.kind {
      case .worktree: line = "It's saved in a restore point first, so you can undo it."
      case .process: line = "It just gets asked to quit."
      case .disk: line = "Your tools rebuild it when needed."
      }
      show("Burning it now", line, "flame.fill")
    } else {
      model.keepForever(entry)
      show("Keeping it", "BZ won't burn it.", "hand.raised.fill")
    }
  }

  private func skip(_ entry: AutopilotEntry) {
    guard confirmation == nil else { return }
    answered.insert(Card.ok(entry).id)
    show("Skipped", "It stays as it is for now.", "clock")
  }

  private func show(_ title: String, _ line: String, _ symbol: String) {
    confirmation = HuntConfirmation(title: title, line: line, symbol: symbol)
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.6))
      confirmation = nil
      pinned = nil
    }
  }
}
