import AppKit
import BurnCore
import SwiftUI

/// "Teach BZ": one big yes/no question at a time, in words a ten-year-old can follow.
/// Each answer becomes a rule, so a dozen answers is usually enough for BZ to run alone.
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
      HStack(spacing: 10) {
        TrainingRing(progress: snapshot.trainingProgress)
        VStack(alignment: .leading, spacing: 2) {
          Text(AutopilotText.trained(snapshot.trainingProgress))
            .font(.system(size: 14, weight: .semibold))
          if !snapshot.entries.isEmpty {
            Text("I handle \(AutopilotText.percent(snapshot.coverage))% on my own")
              .font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
          }
        }
      }
    }.padding(.horizontal, 28).padding(.vertical, 16)
  }

  private func questionCard(_ question: AutopilotQuestion) -> some View {
    VStack(spacing: 16) {
      Text("Question \(answeredHere + 1) of \(answeredHere + waiting.count)")
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(BurnTheme.muted)
      Text(AutopilotLook.emoji(question.kind)).font(.system(size: 50))
      Text(question.question)
        .font(.system(size: 26, weight: .bold, design: .rounded))
        .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.75)
        .fixedSize(horizontal: false, vertical: true)
      if !question.why.isEmpty {
        Text(question.why).font(.system(size: 16)).foregroundStyle(BurnTheme.muted)
          .multilineTextAlignment(.center)
      }
      if !question.examples.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(question.examples.prefix(3).enumerated()), id: \.offset) { pair in
            AutopilotChip(text: pair.element)
          }
        }
      }
      HStack(spacing: 14) {
        answerButton(
          "Yes, burn them", fill: AutopilotTheme.green, text: Color.black.opacity(0.86),
          stroke: Color.clear, id: "teach-yes"
        ) { answer(question, .yes) }
        answerButton(
          "No, keep them", fill: Color.white.opacity(0.10), text: BurnTheme.cream,
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
      Text("BZ doesn't need anything from you right now.")
        .font(.system(size: 18)).foregroundStyle(BurnTheme.muted)
        .multilineTextAlignment(.center)
      Text("I'll let you know if I have new questions.")
        .font(.system(size: 14)).foregroundStyle(BurnTheme.muted)
      HStack(spacing: 10) {
        TrainingRing(progress: snapshot.trainingProgress, size: 56)
        Text(AutopilotText.trained(snapshot.trainingProgress))
          .font(.system(size: 17, weight: .semibold))
      }.padding(.top, 8)
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
