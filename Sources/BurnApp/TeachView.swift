import AppKit
import BurnCore
import SwiftUI

/// "Teach BZ": one big card at a time, in words a ten-year-old can follow. First what BZ did on its
/// own, for the owner to call good or undo; then the quick yes/no questions. Each answer becomes a
/// lesson that BZ applies on its own from then on.
struct TeachView: View {
  static let size = NSSize(width: 640, height: 620)

  /// The friendly note shown for a few seconds after an answer.
  struct Confirmation: Equatable {
    var id = UUID()
    var text: String
    var symbol: String
    /// For a Yes or No: the question it answered, so the note can say what it taught.
    var taught: Taught?

    struct Taught: Equatable {
      var questionID: String
      var kind: AutopilotKind
      var answer: AutopilotAnswer
    }
  }

  @ObservedObject var model: AppModel
  @State private var confirmation: Confirmation?
  @State private var answeredHere = 0
  @State private var answeredIDs = Set<String>()

  init(model: AppModel, confirmation: Confirmation? = nil) {
    self.model = model
    _confirmation = State(initialValue: confirmation)
  }

  @MainActor static func makeWindow(model: AppModel) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "BurnZombies — Teach BZ"
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: TeachView(model: model))
    host.sizingOptions = []
    window.contentView = host
    window.center()
    return window
  }

  private var snapshot: AutopilotSnapshot { model.autopilot }
  /// Questions still waiting, minus any answered here that the engine has not caught up with.
  private var waiting: [AutopilotQuestion] {
    snapshot.questions.filter { $0.isOpen && !answeredIDs.contains($0.id) }
  }
  /// What BZ did on its own that still waits for the owner, oldest first. One called good is gone
  /// at once; one being undone stays, with its buttons off.
  private var tells: [AutopilotTell] {
    snapshot.tells.filter { AutopilotText.shows($0) && model.tellActions[$0.id] != .good }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .foregroundStyle(BurnTheme.cream)
    .background(BurnBackdrop())
    .preferredColorScheme(.dark)
    .task(id: confirmation?.id) { await dismissConfirmationSoon() }
    .onChange(of: snapshot.questions.map(\.id)) { _, ids in
      answeredIDs.formIntersection(ids)
    }
  }

  /// The note stays for a couple of seconds, or longer when it says what BZ learned, then the next
  /// card (or "All caught up"). A click on it moves on at once.
  @MainActor private func dismissConfirmationSoon() async {
    guard let shown = confirmation else { return }
    let seconds: Double = shown.taught == nil ? 2 : 6
    try? await Task.sleep(for: .seconds(seconds))
    guard !Task.isCancelled else { return }
    dismissConfirmation()
  }

  @MainActor private func dismissConfirmation() {
    confirmation = nil
    if waiting.isEmpty { answeredHere = 0 }
  }

  @ViewBuilder private var content: some View {
    if let confirmation {
      confirmationCard(confirmation)
    } else if let tell = tells.first {
      tellCard(tell)
    } else if let question = waiting.first {
      questionCard(question)
    } else {
      caughtUp
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Skull(size: 40)
      VStack(alignment: .leading, spacing: 3) {
        Text("TEACH BZ").font(BurnTheme.display(28)).tracking(0.4)
        Text("A few quick answers and I'll handle the boring stuff for you.")
          .font(.system(size: 13)).foregroundStyle(BurnTheme.muted)
      }
      Spacer(minLength: 12)
      progress
    }.padding(.horizontal, 28).padding(.vertical, 16)
  }

  /// Where this round of questions stands: one dot per question, filled once answered. A tell is
  /// not one of them, so it shows no count.
  @ViewBuilder private var progress: some View {
    let total = answeredHere + waiting.count
    if total > 0 && (confirmation != nil || tells.isEmpty) {
      VStack(alignment: .trailing, spacing: 6) {
        HStack(spacing: 6) {
          ForEach(0..<min(total, 8), id: \.self) { index in
            Circle().fill(index < answeredHere ? BurnTheme.orange : Color.white.opacity(0.2))
              .overlay(Circle().strokeBorder(index == answeredHere ? BurnTheme.orange : .clear, lineWidth: 2))
              .frame(width: 10, height: 10)
          }
        }
        Text(waiting.isEmpty ? "All done" : "Question \(answeredHere + 1) of \(total)")
          .font(.system(size: 13, weight: .semibold)).foregroundStyle(BurnTheme.muted)
      }
    }
  }

  // MARK: Question

  /// A short headline, what it frees, one safe line, the things it is about and a reassuring note.
  /// Each part is there only when the question has something to say, so no card has an empty gap.
  private func questionCard(_ question: AutopilotQuestion) -> some View {
    let card = AutopilotPolicy.card(question)
    return TeachCardFrame {
      VStack(spacing: 8) {
        Text(AutopilotLook.emoji(question.kind)).font(.system(size: 34))
        headline(card.headline)
        sizeLine(card.frees)
        if let line = card.line, !line.isEmpty { safeLine(line) }
        if !card.facts.isEmpty { facts(card.facts, cautions: Set(card.cautions)) }
        TeachRows(rows: card.rows, more: card.more)
        Text(card.note).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
    } actions: {
      HStack(spacing: 14) {
        answerButton(
          card.yes, fill: AutopilotTheme.green, text: Color.black.opacity(0.86),
          stroke: Color.clear, id: "teach-yes"
        ) { answer(question, .yes) }
        answerButton(
          card.no, fill: Color.white.opacity(0.10), text: BurnTheme.cream,
          stroke: Color.white.opacity(0.22), id: "teach-no"
        ) { answer(question, .no) }
      }
      Button {
        answer(question, .skip)
      } label: {
        Text("Not sure — skip").font(.system(size: 13)).underline()
          .foregroundStyle(BurnTheme.muted)
      }.buttonStyle(.plain).clickPointer().accessibilityIdentifier("teach-skip")
    }
  }

  private func headline(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 30, weight: .bold, design: .rounded))
      .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
  }

  /// What it frees, or how much BZ burned: the number the owner decides on.
  private func sizeLine(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 21, weight: .heavy, design: .rounded)).foregroundStyle(BurnTheme.orange)
  }

  private func safeLine(_ text: String) -> some View {
    Text(text).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
      .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
  }

  /// Two chips per row, so no fact is ever cut short; the risky ones stand out in amber.
  private func facts(_ facts: [String], cautions: Set<String>) -> some View {
    VStack(spacing: 6) {
      ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { start in
        HStack(spacing: 8) {
          ForEach(facts[start..<min(start + 2, facts.count)], id: \.self) { fact in
            let caution = cautions.contains(fact)
            HStack(spacing: 5) {
              if caution { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)) }
              Text(fact)
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(caution ? Color.orange : BurnTheme.cream)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(caution ? Color.orange.opacity(0.14) : Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(caution ? Color.orange.opacity(0.5) : BurnTheme.line))
          }
        }
      }
    }
  }

  /// A big answer button. Off, it keeps its words but loses its color, so it reads as waiting and
  /// not as something to press.
  private func answerButton(
    _ title: String, fill: Color, text: Color, stroke: Color, id: String, off: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 19, weight: .bold, design: .rounded))
        .foregroundStyle(off ? BurnTheme.muted : text)
        .frame(maxWidth: .infinity).frame(height: 56)
        .background(off ? Color.white.opacity(0.04) : fill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(off ? BurnTheme.line : stroke))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }.buttonStyle(.plain).clickPointer().accessibilityIdentifier(id).disabled(off)
  }

  // MARK: Tell

  /// What BZ did on its own: how much, which things, and why the owner would have said yes. Good
  /// call and Undo wait at the bottom. Once Undo is pressed both are off and the card says the
  /// copies are coming back. A tell the engine still lists as undoing, with no Undo under way from
  /// here, was cut short by a quit: Good call stays off but Undo is there to finish it, because
  /// nothing else will and Teach BZ shows tells first.
  private func tellCard(_ tell: AutopilotTell) -> some View {
    let working = model.tellActions[tell.id] == .undo
    let undoing = working || tell.state == "undoing"
    let rows = AutopilotText.tellRows(tell, now: Date(), calendar: .current)
    return TeachCardFrame {
      VStack(spacing: 8) {
        Text(AutopilotLook.emoji(tell.kind)).font(.system(size: 34))
        headline(AutopilotText.tellHeadline(tell))
        sizeLine(AutopilotText.tellSize(tell))
        TeachRows(rows: rows, more: AutopilotText.tellMore(tell))
        if undoing {
          Text(AutopilotText.undoingLine)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(AutopilotTheme.yellow)
            .accessibilityIdentifier("teach-undoing")
        } else {
          Text(AutopilotText.tellWhy(tell)).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        if let note = tell.note, !note.isEmpty {
          Text(note).font(.system(size: 13.5)).foregroundStyle(BurnTheme.muted)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
      }
    } actions: {
      HStack(spacing: 14) {
        answerButton(
          "Good call", fill: AutopilotTheme.green, text: Color.black.opacity(0.86),
          stroke: Color.clear, id: "teach-good", off: undoing
        ) { model.tellGood(tell) }
        answerButton(
          "Undo", fill: Color.white.opacity(0.10), text: BurnTheme.cream,
          stroke: Color.white.opacity(0.22), id: "teach-undo", off: working
        ) { model.tellUndo(tell) }
      }
    }
  }

  // MARK: After an answer

  /// "Got it!", then the lesson the answer taught, in one sentence, and what BZ does from now on.
  /// The lesson is looked up as the card shows: the engine may take a moment to hand it over.
  private func confirmationCard(_ note: Confirmation) -> some View {
    var lesson: String?
    var handling: String?
    if let taught = note.taught {
      lesson = AutopilotText.lesson(taughtBy: taught.questionID, in: snapshot)?.sentence
      handling = AutopilotText.handling(taught.kind, answer: taught.answer)
    }
    let done = waiting.isEmpty && tells.isEmpty
    return VStack(spacing: 14) {
      Image(systemName: note.symbol).font(.system(size: 46)).foregroundStyle(AutopilotTheme.green)
      Text(note.text)
        .font(.system(size: 26, weight: .bold, design: .rounded))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      if let lesson {
        Text(lesson)
          .font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 500)
          .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.line))
          .accessibilityIdentifier("teach-lesson")
      }
      if let handling {
        Text(handling).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 460)
      }
      Text(done ? "That's everything for now." : "Next question coming up…")
        .font(.system(size: 15)).foregroundStyle(BurnTheme.muted)
    }
    .padding(.horizontal, 48).padding(.vertical, 24)
    .contentShape(Rectangle())
    .onTapGesture { dismissConfirmation() }
  }

  private var caughtUp: some View {
    VStack(spacing: 14) {
      Text("🎉").font(.system(size: 60))
      Text("All caught up!").font(.system(size: 32, weight: .bold, design: .rounded))
      Text("Nothing big needs you right now.")
        .font(.system(size: 18)).foregroundStyle(BurnTheme.muted)
        .multilineTextAlignment(.center)
      Text("I'll ask when I find something worth it.")
        .font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
    }.padding(36)
  }

  private func answer(_ question: AutopilotQuestion, _ answer: AutopilotAnswer) {
    confirmation = Self.confirmation(for: question, answer)
    answeredHere += 1
    answeredIDs.insert(question.id)
    model.answer(question, answer)
  }

  /// The note after an answer: "Got it!" for a Yes or No, which also says what it taught, or the
  /// words for a skip, which teaches nothing.
  static func confirmation(for question: AutopilotQuestion, _ answer: AutopilotAnswer)
    -> Confirmation
  {
    let taught = Confirmation.Taught(questionID: question.id, kind: question.kind, answer: answer)
    switch answer {
    case .yes: return Confirmation(text: "Got it!", symbol: "flame.fill", taught: taught)
    case .no: return Confirmation(text: "Got it!", symbol: "hand.raised.fill", taught: taught)
    case .skip:
      return Confirmation(text: "No problem. I'll ask again tomorrow.", symbol: "clock.fill")
    }
  }
}

/// A card's frame: what it says on top, centered while it fits and scrolling if it ever doesn't, and
/// its buttons docked below, so an answer is never pushed off the window.
private struct TeachCardFrame<Details: View, Actions: View>: View {
  let details: Details
  let actions: Actions

  init(@ViewBuilder _ details: () -> Details, @ViewBuilder actions: () -> Actions) {
    self.details = details()
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: 12) {
      GeometryReader { proxy in
        ScrollView(.vertical) {
          details.frame(maxWidth: .infinity).frame(minHeight: proxy.size.height)
        }.scrollBounceBehavior(.basedOnSize)
      }
      VStack(spacing: 10) { actions }
    }.padding(.horizontal, 36).padding(.top, 10).padding(.bottom, 16)
  }
}

/// The things a card is about: each with its title in bold, its project dim and, on the right, when
/// it was last used; then how many more there are. Nothing is drawn when there are no rows.
private struct TeachRows: View {
  let rows: [AutopilotCardRow]
  let more: Int

  var body: some View {
    if !rows.isEmpty {
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          TeachRow(row: row)
          Rectangle().fill(BurnTheme.line).frame(height: 1)
        }
        if more > 0 {
          Text("+ \(more) more").font(.system(size: 13)).foregroundStyle(BurnTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6).padding(.horizontal, 2)
            .accessibilityIdentifier("teach-more")
        }
      }
      .overlay(alignment: .top) { Rectangle().fill(BurnTheme.line).frame(height: 1) }
      .frame(maxWidth: 540)
    }
  }
}

private struct TeachRow: View {
  let row: AutopilotCardRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      // A long title gives way, never the project beside it or the time on the right.
      Text(row.title).font(.system(size: 15, weight: .bold)).lineLimit(1).truncationMode(.tail)
      if let subtitle = row.subtitle, !subtitle.isEmpty {
        Text(subtitle).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
          .lineLimit(1).fixedSize()
      }
      Spacer(minLength: 10)
      if !row.when.isEmpty {
        Text(row.when).font(.system(size: 14)).foregroundStyle(BurnTheme.cream)
          .lineLimit(1).fixedSize()
      }
    }.padding(.vertical, 7).padding(.horizontal, 2)
  }
}
