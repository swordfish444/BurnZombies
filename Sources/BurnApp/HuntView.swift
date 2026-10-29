import BurnCore
import SwiftUI

/// The game is atmosphere; this feed and its counters come from the hunt's receipts.
struct HuntView: View {
  @ObservedObject var model: AppModel
  var sceneTime: TimeInterval? = nil
  @State private var visible = false
  @State private var followLive = true
  @State private var celebration: HuntSceneMode?
  @State private var celebrationTitle: String?
  @State private var seen = Set<String>()
  @State private var effectQueue: [HuntLogEntry] = []
  @State private var runID: UUID?
  var snapshot: HuntSnapshot? { model.huntSnapshot }
  var receiptsAvailable: Bool { snapshot?.receiptEvidenceAvailable != false }
  var activeVisuals: Bool { visible && model.huntProgressVisible }
  var phase: String {
    model.huntRunning
      ? "Hunting Zombies"
      : snapshot?.phase == "paused"
        ? "Hunt paused" : snapshot == nil ? "Ready to hunt" : "Hunt complete"
  }
  var sceneMode: HuntSceneMode {
    if let celebration { return celebration }
    return model.huntRunning
      ? .searching : snapshot?.phase == "paused" ? .paused : snapshot == nil ? .idle : .complete
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Skull(size: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text("HUNT ZOMBIES").font(BurnTheme.display(28)).tracking(0.4)
          Text("Your Mac. Less dead weight.").font(.system(size: 12)).foregroundStyle(
            BurnTheme.muted)
        }
        Spacer()
        if model.huntRunning {
          HStack(spacing: 8) {
            Circle().fill(BurnTheme.orange).frame(width: 7, height: 7)
            Text("Hunting Zombies").font(.system(size: 12, weight: .semibold))
          }.padding(.horizontal, 12).padding(.vertical, 9)
            .background(BurnTheme.orange.opacity(0.10), in: Capsule())
        } else {
          Button {
            model.requestAgentCleanup()
          } label: {
            Label("Hunt Zombies", systemImage: "scope")
              .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(
                .vertical, 9
              )
              .background(BurnTheme.orange, in: Capsule()).foregroundStyle(
                Color.black.opacity(0.85))
          }.buttonStyle(.plain).clickPointer().disabled(
            !model.accessReady || !model.harnessConfigured
          )
          .accessibilityIdentifier("hunt-again")
        }
      }
      HuntSceneView(
        mode: sceneMode, celebrationTitle: celebrationTitle, isVisible: activeVisuals,
        elapsedOverride: sceneTime)
      HStack(spacing: 0) {
        metric(String(snapshot?.processCount ?? 0), "Processes seen")
        metric(receiptsAvailable ? String(snapshot?.burned ?? 0) : "—", "Zombies burned")
        metric(
          receiptsAvailable ? ImpactNumbers.bytes(snapshot?.memoryReclaimed ?? 0) : "—",
          "Memory released")
        metric(
          receiptsAvailable ? ImpactNumbers.bytes(snapshot?.diskReclaimed ?? 0) : "—",
          "Disk reclaimed")
        metric(
          receiptsAvailable ? String(snapshot?.worktreesCleaned ?? 0) : "—", "Worktrees cleaned",
          last: true)
      }.padding(.vertical, 12)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.line))
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Label("HUNT FEED", systemImage: "text.bubble").font(
            .system(size: 11, weight: .semibold, design: .monospaced)
          ).tracking(1)
          if model.huntRunning {
            Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(BurnTheme.orange)
          }
          Spacer()
          Text(
            "\(snapshot?.evidenceReviewed ?? 0) evidence groups · \(snapshot?.attempts ?? 0) review passes"
          )
          .font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
          Button {
            followLive.toggle()
          } label: {
            Label(
              followLive ? "Following" : "Follow live",
              systemImage: followLive ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
            .font(.system(size: 11)).foregroundStyle(
              followLive ? BurnTheme.orange : BurnTheme.muted)
          }.buttonStyle(.plain).clickPointer().padding(.leading, 10)
            .accessibilityIdentifier("follow-hunt-feed")
        }.padding(.horizontal, 16).padding(.vertical, 13)
        Rectangle().fill(BurnTheme.line).frame(height: 1)
        ScrollViewReader { reader in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
              if let snapshot, !snapshot.log.isEmpty {
                ForEach(snapshot.log) { entry in logRow(entry).id(entry.id) }
              } else {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: "scope").foregroundStyle(BurnTheme.orange)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(
                      model.huntRunning
                        ? "The hunt is getting underway." : "Ready to clear the dead weight."
                    )
                    .font(.system(size: 13, weight: .medium))
                    Text(
                      model.huntRunning
                        ? "Measuring processes and storage before the harness reviews the evidence."
                        : "Start a hunt to see the findings, safety decisions and verified cleanups here."
                    )
                    .font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
                  }
                }.padding(.vertical, 10)
              }
              Color.clear.frame(height: 1).id("feed-bottom")
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
          }.defaultScrollAnchor(.bottom).frame(minHeight: 140, maxHeight: .infinity)
            .onChange(of: snapshot?.log.map(\.id) ?? []) { _, _ in
              if followLive { reader.scrollTo("feed-bottom", anchor: .bottom) }
              receiveEffects()
            }
            .onChange(of: followLive) { _, following in
              if following { reader.scrollTo("feed-bottom", anchor: .bottom) }
            }
        }
      }.background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.line))
      HStack(spacing: 8) {
        Image(systemName: snapshot?.phase == "paused" ? "pause.circle" : "shield.lefthalf.filled")
          .foregroundStyle(snapshot?.phase == "paused" ? BurnTheme.orange : BurnTheme.muted)
        Text(snapshot?.detail ?? "Active work stays protected. Every cleanup earns a receipt.")
          .font(.system(size: 11)).foregroundStyle(BurnTheme.muted).lineLimit(2)
        Spacer(minLength: 0)
      }
    }.padding(24).padding(.top, 12)
      .frame(minWidth: 800, idealWidth: 948, minHeight: 740, idealHeight: 780)
      .foregroundStyle(BurnTheme.cream).background(BurnBackdrop())
      .onAppear {
        visible = true
        runID = snapshot?.id
        seen = Set(snapshot?.log.map(\.id) ?? [])
        model.setHuntProgressVisible(true)
      }
      .onDisappear {
        visible = false
        effectQueue = []
        celebration = nil
        model.setHuntProgressVisible(false)
      }
      .onChange(of: model.huntProgressVisible) { _, shown in
        if shown {
          seen = Set(snapshot?.log.map(\.id) ?? [])
          effectQueue = []
        }
      }
      .task(id: "\(effectQueue.first?.id ?? "none")-\(activeVisuals)") {
        guard let event = effectQueue.first, activeVisuals else {
          celebration = nil
          return
        }
        celebrationTitle =
          event.message.localizedCaseInsensitiveContains("worktree")
          ? "WORKTREE ERADICATED"
          : event.message.localizedCaseInsensitiveContains("disk cleanup")
            ? "DEAD WEIGHT ERADICATED" : "ZOMBIE ERADICATED"
        celebration = .detected
        do {
          try await Task.sleep(for: .seconds(1.7))
          if event.kind == "burn" {
            celebration = .burning
            try await Task.sleep(for: .seconds(3.2))
          }
          celebration = nil
          celebrationTitle = nil
          if effectQueue.first?.id == event.id { effectQueue.removeFirst() }
        } catch {
          celebration = nil
          celebrationTitle = nil
        }
      }
  }
  private func receiveEffects() {
    guard activeVisuals, let snapshot else { return }
    if runID != snapshot.id {
      runID = snapshot.id
      seen = []
      effectQueue = []
    }
    let new = snapshot.newCelebrations(since: seen)
    seen.formUnion(snapshot.log.map(\.id))
    effectQueue += new
    effectQueue = Array(effectQueue.suffix(12))
  }
  private func metric(_ value: String, _ label: String, last: Bool = false) -> some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text(value).font(BurnTheme.display(25)).contentTransition(.numericText())
        Text(label).font(.system(size: 11)).foregroundStyle(BurnTheme.muted).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17)
      if !last { Rectangle().fill(BurnTheme.line).frame(width: 1, height: 38) }
    }
  }
  private func logRow(_ entry: HuntLogEntry) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(
        systemName: entry.kind == "burn"
          ? "flame.fill"
          : entry.kind == "warning"
            ? "exclamationmark.shield" : entry.kind == "detected" ? "scope" : "waveform.path"
      )
      .font(.system(size: 13)).foregroundStyle(
        entry.kind == "burn" || entry.kind == "detected" ? BurnTheme.orange : BurnTheme.muted
      )
      .frame(width: 18).padding(.top, 2)
      Text(entry.message).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(entry.date, format: .dateTime.hour().minute().second()).font(
        .system(size: 10, design: .monospaced)
      )
      .foregroundStyle(BurnTheme.muted).padding(.top, 2)
    }
  }
}
