import AppKit
import BurnCore
import SwiftUI

/// "Teach BZ": one big yes/no question at a time, in words a ten-year-old can follow.
/// Each answer becomes a rule that BZ applies on its own from then on.
struct TeachView: View {
  static let size = NSSize(width: 640, height: 560)

  /// The friendly note shown for about two seconds after an answer.
  struct Confirmation: Equatable {
    var id = UUID()
    var text: String
    var symbol: String
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

  /// The friendly note stays for about two seconds, then the next question (or "All caught up").
  @MainActor private func dismissConfirmationSoon() async {
    guard confirmation != nil else { return }
    try? await Task.sleep(for: .seconds(2))
    guard !Task.isCancelled else { return }
    confirmation = nil
    if waiting.isEmpty { answeredHere = 0 }
  }

  @ViewBuilder private var content: some View {
    if let confirmation {
      confirmationCard(confirmation)
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

  /// Where this round of questions stands: one dot per question, filled once answered.
  @ViewBuilder private var progress: some View {
    let total = answeredHere + waiting.count
    if total > 0 {
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

  /// A short headline, what it frees, a few facts as chips and one reassuring line.
  private func questionCard(_ question: AutopilotQuestion) -> some View {
    let card = AutopilotPolicy.card(question)
    return VStack(spacing: 14) {
      Text(AutopilotLook.emoji(question.kind)).font(.system(size: 48))
      Text(card.headline)
        .font(.system(size: 32, weight: .bold, design: .rounded))
        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
      Text(card.frees)
        .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(BurnTheme.orange)
      facts(card.facts, cautions: Set(card.cautions))
      Text(card.note).font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
        .multilineTextAlignment(.center)
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
    }.padding(.horizontal, 36).padding(.vertical, 18)
  }

  /// Two chips per row, so no fact is ever cut short; the risky ones stand out in amber.
  private func facts(_ facts: [String], cautions: Set<String>) -> some View {
    VStack(spacing: 8) {
      ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { start in
        HStack(spacing: 8) {
          ForEach(facts[start..<min(start + 2, facts.count)], id: \.self) { fact in
            let caution = cautions.contains(fact)
            HStack(spacing: 5) {
              if caution { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)) }
              Text(fact)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(caution ? Color.orange : BurnTheme.cream)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(caution ? Color.orange.opacity(0.14) : Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(caution ? Color.orange.opacity(0.5) : BurnTheme.line))
          }
        }
      }
    }
  }

  private func answerButton(
    _ title: String, fill: Color, text: Color, stroke: Color, id: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(text)
        .frame(maxWidth: .infinity).frame(height: 62)
        .background(fill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(stroke))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }.buttonStyle(.plain).clickPointer().accessibilityIdentifier(id)
  }

  private func confirmationCard(_ note: Confirmation) -> some View {
    VStack(spacing: 16) {
      Image(systemName: note.symbol).font(.system(size: 54)).foregroundStyle(AutopilotTheme.green)
      Text(note.text)
        .font(.system(size: 26, weight: .bold, design: .rounded))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      Text(waiting.isEmpty ? "That's everything for now." : "Next question coming up…")
        .font(.system(size: 15)).foregroundStyle(BurnTheme.muted)
    }.padding(.horizontal, 48).padding(.vertical, 24)
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
    switch answer {
    case .yes:
      confirmation = Confirmation(
        text: "Got it! I'll burn these on my own from now on.", symbol: "flame.fill")
    case .no:
      confirmation = Confirmation(
        text: "Got it! I'll leave these alone.", symbol: "hand.raised.fill")
    case .skip:
      confirmation = Confirmation(
        text: "No problem. I'll ask again tomorrow.", symbol: "clock.fill")
    }
    answeredHere += 1
    answeredIDs.insert(question.id)
    model.answer(question, answer)
  }
}
