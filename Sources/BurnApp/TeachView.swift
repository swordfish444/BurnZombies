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
    /// A Yes in look-only: what it taught burns once the owner starts burning.
    var waits = false
    /// How many the owner spared on the card answered: they stay.
    var spared = 0

    struct Taught: Equatable {
      var questionID: String
    }
  }

  /// Which card shows now.
  enum Card: Equatable {
    case confirmation
    case tell(String)
    case question(String)
    case caughtUp

    var isTell: Bool {
      if case .tell = self { return true }
      return false
    }
  }

  @ObservedObject var model: AppModel
  @State private var confirmation: Confirmation?
  @State private var answeredHere = 0
  @State private var answeredIDs = Set<String>()
  /// The question on screen. It stays until it is answered or gone, whatever arrives meanwhile.
  @State private var pinnedQuestionID: String?
  /// View details for the question on screen.
  @State private var details: TeachDetailsState
  /// The row the pointer rests on, once its card is up.
  @State private var hover: TeachHover?
  @StateObject private var tips: TeachTipsModel

  /// `details` and `tip` start the window in a given state, for offscreen renders.
  init(
    model: AppModel, confirmation: Confirmation? = nil,
    details: TeachDetailsState = TeachDetailsState(), tip: AutopilotTip? = nil
  ) {
    self.model = model
    _confirmation = State(initialValue: confirmation)
    _details = State(initialValue: details)
    _tips = StateObject(
      wrappedValue: TeachTipsModel(defaults: model.demo ? nil : .standard, showing: tip))
  }

  /// The window's coordinate space, where a row's hover card is placed.
  static let space = "teach"
  /// Room kept above a question for the tips.
  static let tipRoom: CGFloat = 30

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
  /// What BZ did on its own that still waits for the owner, oldest first. One called good, or whose
  /// note was seen, is gone at once; one being undone stays, with its buttons off.
  private var tells: [AutopilotTell] {
    snapshot.tellsWaiting.filter { tell in
      let pressed: AppModel.TellAction? = model.tellActions[tell.id]
      return pressed != .good && pressed != .seen
    }
  }
  private var showing: Card {
    Self.card(
      confirming: confirmation != nil, pinned: pinnedQuestionID, tells: tells, waiting: waiting)
  }

  /// Which card shows. A question already on screen stays until it is answered or gone, even when
  /// a tell has arrived since: a card never changes under the owner's hands, it changes at its
  /// boundary. At a boundary, what BZ did on its own comes before any question.
  static func card(
    confirming: Bool, pinned: String?, tells: [AutopilotTell], waiting: [AutopilotQuestion]
  ) -> Card {
    if confirming { return .confirmation }
    if let pinned, waiting.contains(where: { $0.id == pinned }) { return .question(pinned) }
    if let tell = tells.first { return .tell(tell.id) }
    if let question = waiting.first { return .question(question.id) }
    return .caughtUp
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .coordinateSpace(.named(Self.space))
    .overlay { TeachHoverLayer(hover: hover) }
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
    switch showing {
    case .confirmation:
      if let confirmation { confirmationCard(confirmation) }
    case .tell(let id):
      if let tell = tells.first(where: { $0.id == id }) {
        if tell.waitsForOK { undoneCard(tell) } else { tellCard(tell) }
      }
    case .question(let id):
      if let question = waiting.first(where: { $0.id == id }) { questionCard(question) }
    case .caughtUp:
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
    if total > 0 && !showing.isTell {
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

  /// A short headline, what it frees, one safe line, the things it is about and View details.
  /// Each part is there only when the question has something to say, so no card has an empty gap.
  /// Opened, the details take the place of the chips and rows; what the owner spares there leaves
  /// the headline, the size and the answer at once. Tips come and go in the corner above.
  private func questionCard(_ question: AutopilotQuestion) -> some View {
    let state = details.questionID == question.id ? details : TeachDetailsState()
    let listed = Self.listed(question, entries: snapshot.entries, overrides: state.overrides)
    // The engine's numbers stand until the owner spares or unspares something here; what was
    // spared before is already left out of them.
    let drawn =
      state.overrides.isEmpty
      ? question : AutopilotPolicy.sparing(question, details: listed, changed: true)
    let card = AutopilotPolicy.card(drawn)
    let spared = listed.filter(\.spared).count
    let allSpared = drawn.count == 0 && spared > 0
    let open = state.open && !listed.isEmpty
    let place: AutopilotTip.Place = !open ? .question : state.opened == nil ? .list : .entry
    return TeachCardFrame(topInset: Self.tipRoom) {
      VStack(spacing: 8) {
        if !open {
          Text(AutopilotLook.emoji(question.kind)).font(.system(size: 34))
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
        headline(allSpared ? "Nothing left to burn" : card.headline)
        sizeLine(allSpared ? "You spared all \(spared)" : card.frees)
        if open {
          TeachDetailsPanel(
            listed: listed, noun: Self.noun(question.kind), state: $details, hover: $hover,
            spare: toggleSpare, did: { tips.did($0) }
          )
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        } else {
          VStack(spacing: 8) {
            if let line = card.line, !line.isEmpty { safeLine(line) }
            if !card.facts.isEmpty || spared > 0 {
              facts(card.facts, cautions: Set(card.cautions), spared: spared)
            }
            TeachRows(rows: card.rows, more: card.more)
          }
          .transition(.opacity)
        }
        // What a Yes deletes for good is said before anything is pressed, details open or not.
        if let cost = card.cost { costLine(cost) }
        if listed.isEmpty {
          if card.cost == nil {
            Text(card.note).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
              .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
          }
        } else {
          Button {
            toggleDetails(question)
          } label: {
            Text(open ? "Hide details" : "View details").font(.system(size: 13)).underline()
              .foregroundStyle(BurnTheme.muted)
          }
          .buttonStyle(.plain).clickPointer().accessibilityIdentifier("teach-details")
          .keyboardShortcut(open && state.opened == nil ? .cancelAction : nil)
        }
      }
    } actions: {
      HStack(spacing: 14) {
        answerButton(
          card.yes, fill: AutopilotTheme.green, text: Color.black.opacity(0.86),
          stroke: Color.clear, id: "teach-yes", off: allSpared
        ) { answer(drawn, .yes, spared: spared) }
        answerButton(
          card.no, fill: Color.white.opacity(0.10), text: BurnTheme.cream,
          stroke: Color.white.opacity(0.22), id: "teach-no"
        ) { answer(drawn, .no) }
      }
      Button {
        answer(drawn, .skip)
      } label: {
        Text("Not sure — skip").font(.system(size: 13)).underline()
          .foregroundStyle(BurnTheme.muted)
      }.buttonStyle(.plain).clickPointer().accessibilityIdentifier("teach-skip")
    }
    .overlay(alignment: .topLeading) {
      TeachTipsView(model: tips).padding(.leading, 28).padding(.trailing, 28).padding(.top, 12)
    }
    .onChange(of: question.id, initial: true) { _, id in
      pinnedQuestionID = id
      if details.questionID != id {
        details = TeachDetailsState(questionID: id)
        hover = nil
      }
      let filters = AutopilotPolicy.detailFilters(listed).contains(where: \.risky)
      let bigFiles: Bool = AutopilotPolicy.bigFilesCost(question) != nil
      tips.start(kind: question.kind, filters: filters, bigFiles: bigFiles)
    }
    .onChange(of: place, initial: true) { _, now in tips.at(now) }
    .onDisappear { tips.stop() }
  }

  /// What a question's details list, with what the owner spared or unspared on its card shown that
  /// way before the engine says so.
  static func listed(
    _ question: AutopilotQuestion, entries: [AutopilotEntry], overrides: [String: Bool]
  ) -> [AutopilotDetail] {
    let found = AutopilotPolicy.details(
      question, entries: entries, now: Date(), calendar: .current, including: Set(overrides.keys))
    return found.map { detail in
      guard let spared = overrides[detail.id] else { return detail }
      var changed = detail
      changed.spared = spared
      return changed
    }
  }

  /// What one of the things a question is about is called.
  static func noun(_ kind: AutopilotKind) -> String {
    switch kind {
    case .worktree: return "copy"
    case .process: return "program"
    case .disk: return "folder"
    }
  }

  private func toggleDetails(_ question: AutopilotQuestion) {
    hover = nil
    let opening = !(details.questionID == question.id && details.open)
    withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
      if details.questionID != question.id { details = TeachDetailsState(questionID: question.id) }
      details.open = opening
      details.opened = nil
    }
    if opening { tips.did("details") }
  }

  /// Spare or Unspare: the card shows it at once and the engine is told right away, so it holds
  /// even if the window closes before an answer. If the engine can't, the card shows what it holds.
  private func toggleSpare(_ detail: AutopilotDetail) {
    let sparing = !detail.spared
    hover = nil
    withAnimation(.easeOut(duration: 0.2)) { details.overrides[detail.id] = sparing }
    let id = detail.id
    let undo: @MainActor (String?) -> Void = { problem in
      if problem != nil { details.overrides[id] = nil }
    }
    if sparing {
      tips.did("spare")
      model.keepForever(detail.entry, finished: undo)
    } else {
      model.unkeep(detail.entry, finished: undo)
    }
  }

  /// What a Yes deletes for good, which Undo can't bring back: amber, like a card's cautions.
  private func costLine(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
      Text(text).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.orange)
    .frame(maxWidth: 540)
    .accessibilityIdentifier("teach-cost")
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

  /// Two chips per row, so no fact is ever cut short; the risky ones stand out in amber, and what
  /// the owner spared shows in green.
  private func facts(_ facts: [String], cautions: Set<String>, spared: Int = 0) -> some View {
    let sparedChip: String = "\(spared) spared"
    let chips: [String] = spared > 0 ? facts + [sparedChip] : facts
    return VStack(spacing: 6) {
      ForEach(Array(stride(from: 0, to: chips.count, by: 2)), id: \.self) { start in
        HStack(spacing: 8) {
          ForEach(chips[start..<min(start + 2, chips.count)], id: \.self) { fact in
            let caution = cautions.contains(fact)
            let kept = spared > 0 && fact == sparedChip
            HStack(spacing: 5) {
              if caution { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)) }
              if kept { Image(systemName: "hand.raised.fill").font(.system(size: 11)) }
              Text(fact)
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(caution ? Color.orange : kept ? AutopilotTheme.green : BurnTheme.cream)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(chipFill(caution: caution, kept: kept), in: Capsule())
            .overlay(Capsule().strokeBorder(chipStroke(caution: caution, kept: kept)))
          }
        }
      }
    }
  }

  private func chipFill(caution: Bool, kept: Bool) -> Color {
    if caution { return Color.orange.opacity(0.14) }
    return kept ? AutopilotTheme.green.opacity(0.12) : Color.white.opacity(0.08)
  }

  private func chipStroke(caution: Bool, kept: Bool) -> Color {
    if caution { return Color.orange.opacity(0.5) }
    return kept ? AutopilotTheme.green.opacity(0.4) : BurnTheme.line
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
  /// call and the second button wait at the bottom.
  /// - Copies: the second button is Undo. Once it is pressed both buttons are off and the card says
  ///   the copies are coming back.
  /// - Programs and folders: nothing comes back, so the card says so before any press, the second
  ///   button is "I'd have said no", and pressing it says BZ will ask next time.
  /// - A tell the engine still lists as undoing with nothing under way from here was cut short by a
  ///   quit: Good call stays off but the second button is there to finish it, because nothing
  ///   else will and Teach BZ shows tells first.
  private func tellCard(_ tell: AutopilotTell) -> some View {
    let working = model.tellActions[tell.id] == .undo
    let undoing = working || tell.state == "undoing"
    let rows = AutopilotText.tellRows(tell, now: Date(), calendar: .current)
    // Before Undo is pressed: what it can't bring back, such as big unsaved files a burn deleted.
    let gone: String? = AutopilotPolicy.bigFilesTold(tell) ?? AutopilotText.tellCantComeBack(tell.kind)
    let cantComeBack: String? = undoing ? nil : gone
    return TeachCardFrame {
      VStack(spacing: 8) {
        Text(AutopilotLook.emoji(tell.kind)).font(.system(size: 34))
        headline(AutopilotText.tellHeadline(tell))
        sizeLine(AutopilotText.tellSize(tell))
        TeachRows(rows: rows, more: AutopilotText.tellMore(tell))
        tellLine(tell, working: working, undoing: undoing)
        if let cantComeBack {
          softLine(cantComeBack).accessibilityIdentifier("teach-cant-come-back")
        }
        if let note = tell.note, !note.isEmpty { softLine(note, size: 13.5) }
        problemLine(tell)
      }
    } actions: {
      HStack(spacing: 14) {
        answerButton(
          "Good call", fill: AutopilotTheme.green, text: Color.black.opacity(0.86),
          stroke: Color.clear, id: "teach-good", off: undoing
        ) { model.tellGood(tell) }
        answerButton(
          AutopilotText.tellUndoLabel(tell.kind), fill: Color.white.opacity(0.10),
          text: BurnTheme.cream, stroke: Color.white.opacity(0.22), id: "teach-undo", off: working
        ) { model.tellUndo(tell) }
      }
    }
  }

  /// An Undo that left something to read, such as a copy that couldn't come back and why: the tell
  /// as it was, that the Undo finished, and the note, with one OK that closes it.
  private func undoneCard(_ tell: AutopilotTell) -> some View {
    let rows = AutopilotText.tellRows(tell, now: Date(), calendar: .current)
    return TeachCardFrame {
      VStack(spacing: 8) {
        Text(AutopilotLook.emoji(tell.kind)).font(.system(size: 34))
        headline(AutopilotText.tellHeadline(tell))
        TeachRows(rows: rows, more: AutopilotText.tellMore(tell))
        statusLine(AutopilotText.tellUndoneLine).accessibilityIdentifier("teach-undone")
        if let note = tell.note, !note.isEmpty {
          Text(note).font(.system(size: 15, weight: .semibold)).foregroundStyle(BurnTheme.cream)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("teach-note")
        }
        problemLine(tell)
      }
    } actions: {
      answerButton(
        "OK", fill: AutopilotTheme.green, text: Color.black.opacity(0.86), stroke: Color.clear,
        id: "teach-ok"
      ) { model.tellSeen(tell) }
    }
  }

  /// Why the last press on a tell couldn't be done, when it couldn't.
  @ViewBuilder private func problemLine(_ tell: AutopilotTell) -> some View {
    if let problem = model.tellProblems[tell.id] {
      Text(problem)
        .font(.system(size: 14, weight: .semibold)).foregroundStyle(AutopilotTheme.red)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("teach-problem")
    }
  }

  /// What the card says under its rows: why BZ acted; once the second button is pressed, what is
  /// happening; or that an earlier press didn't finish.
  @ViewBuilder private func tellLine(_ tell: AutopilotTell, working: Bool, undoing: Bool)
    -> some View
  {
    if working {
      statusLine(AutopilotText.tellWorking(tell.kind)).accessibilityIdentifier("teach-undoing")
    } else if undoing {
      statusLine(AutopilotText.tellStalled(tell.kind)).accessibilityIdentifier("teach-stalled")
    } else {
      softLine(AutopilotText.tellWhy(tell))
    }
  }

  private func statusLine(_ text: String) -> some View {
    Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(AutopilotTheme.yellow)
      .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
  }

  private func softLine(_ text: String, size: CGFloat = 14) -> some View {
    Text(text).font(.system(size: size)).foregroundStyle(BurnTheme.muted)
      .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
  }

  // MARK: After an answer

  /// "Got it!", then the lesson the answer taught, in one sentence, and what BZ does from now on.
  /// The lesson is looked up as the card shows: the engine may take a moment to hand it over.
  private func confirmationCard(_ note: Confirmation) -> some View {
    var lesson: String?
    if let taught = note.taught {
      lesson = AutopilotText.lesson(taughtBy: taught.questionID, in: snapshot)?.sentence
    }
    let next = AutopilotText.whatsNext(tells: tells.count, questions: waiting.count)
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
      if note.spared > 0 {
        Label(Self.sparedLine(note.spared), systemImage: "hand.raised.fill")
          .font(.system(size: 15, weight: .semibold)).foregroundStyle(AutopilotTheme.green)
          .accessibilityIdentifier("teach-spared")
      }
      if note.taught != nil {
        Text(note.waits ? AutopilotText.handlingLookOnly : AutopilotText.handling)
          .font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 460)
      }
      Text(next).font(.system(size: 15)).foregroundStyle(BurnTheme.muted)
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

  /// `question` is the one its card was drawn from, with what the owner spared left out: the answer
  /// carries the risks that card showed, and what was spared or unspared on it goes first.
  private func answer(_ question: AutopilotQuestion, _ answer: AutopilotAnswer, spared: Int = 0) {
    confirmation = Self.confirmation(
      for: question, answer, lookOnly: model.autopilot.sweep.lookOnly == true, spared: spared)
    answeredHere += 1
    answeredIDs.insert(question.id)
    pinnedQuestionID = nil
    let changes = details.questionID == question.id ? details.overrides : [:]
    let sparing: [String] = changes.filter(\.value).map(\.key).sorted()
    let releasing: [String] = changes.filter { !$0.value }.map(\.key).sorted()
    model.answer(question, answer, sparing: sparing, releasing: releasing)
    details = TeachDetailsState()
    hover = nil
  }

  /// "The 2 you spared stay, now and later."
  static func sparedLine(_ spared: Int) -> String {
    spared == 1
      ? "The one you spared stays, now and later." : "The \(spared) you spared stay, now and later."
  }

  /// The note after an answer: "Got it!" for a Yes or No, which also says what it taught, or the
  /// words for a skip, which teaches nothing. In look-only a Yes says its burns wait; a Yes says
  /// what the owner spared stays.
  static func confirmation(
    for question: AutopilotQuestion, _ answer: AutopilotAnswer, lookOnly: Bool = false,
    spared: Int = 0
  ) -> Confirmation {
    let taught = Confirmation.Taught(questionID: question.id)
    switch answer {
    case .yes:
      return Confirmation(
        text: "Got it!", symbol: "flame.fill", taught: taught, waits: lookOnly, spared: spared)
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
  /// Room kept clear above, for the tips: what it says is centered below it.
  let topInset: CGFloat

  init(
    topInset: CGFloat = 0, @ViewBuilder _ details: () -> Details,
    @ViewBuilder actions: () -> Actions
  ) {
    self.topInset = topInset
    self.details = details()
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: 12) {
      GeometryReader { proxy in
        ScrollView(.vertical) {
          details.frame(maxWidth: .infinity)
            .frame(minHeight: max(0, proxy.size.height - topInset)).padding(.top, topInset)
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
    VStack(alignment: .leading, spacing: 2) {
      line
      // A copy's big unsaved files: what a Yes deletes, or what a burn deleted, for good.
      ForEach(Array(row.details.enumerated()), id: \.offset) { _, detail in
        Text(detail).font(.system(size: 12.5)).foregroundStyle(Color.orange.opacity(0.85))
          .lineLimit(1).truncationMode(.middle).accessibilityIdentifier("teach-row-detail")
      }
    }.padding(.vertical, 7).padding(.horizontal, 2)
  }

  private var line: some View {
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
    }
  }
}
