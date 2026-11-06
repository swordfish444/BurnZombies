import BurnCore
import SwiftUI

/// The game is atmosphere, a strip at the top; the stats, the live feed and the questions below
/// it are the hunt itself, and every number there comes from the hunt's receipts. Top to bottom:
/// what was freed, how far each area got, then the feed beside what needs the owner.
struct HuntView: View {
  @ObservedObject var model: AppModel
  var sceneTime: TimeInterval? = nil
  /// Starts Needs you on an answer's note, for offscreen renders.
  var needsYouConfirmation: HuntConfirmation? = nil
  @State private var visible = false
  @State private var followLive = true
  @State private var celebration: HuntSceneMode?
  @State private var celebrationTitle: String?
  @State private var seen = Set<String>()
  @State private var effectQueue: [HuntLogEntry] = []
  @State private var runID: UUID?
  @State private var showLimit = false
  /// The limit panel says to raise it: Keep hunting found nothing left under it.
  @State private var limitNote = false
  var snapshot: HuntSnapshot? { model.huntSnapshot }
  var activeVisuals: Bool { visible && model.huntProgressVisible }
  /// Autopilot hunts show lanes, the live ticker and the questions; older hunts their totals.
  var autopilot: Bool { snapshot?.isAutopilot == true || (snapshot == nil && model.autopilotAvailable) }
  var deep: Bool { snapshot?.deep == true }
  var stoppedDeep: Bool { deep && snapshot?.phase == "stopped" && !model.huntRunning }
  var needsYou: Bool { autopilot && model.autopilotAvailable }
  var sceneMode: HuntSceneMode {
    if let celebration { return celebration }
    return model.huntRunning
      ? .searching : snapshot?.phase == "paused" ? .paused : snapshot == nil ? .idle : .complete
  }

  var body: some View {
    GeometryReader { proxy in
      let layout = HuntLayout(size: proxy.size)
      VStack(alignment: .leading, spacing: 0) {
        header
        HuntSceneView(
          mode: sceneMode, celebrationTitle: celebrationTitle, isVisible: activeVisuals,
          elapsedOverride: sceneTime, height: layout.scene
        ).padding(.top, 16)
        if let snapshot {
          Group {
            if snapshot.isAutopilot || !(snapshot.lanes ?? []).isEmpty {
              HuntStats(snapshot: snapshot, running: model.huntRunning, layout: layout)
            } else {
              HuntTotals(snapshot: snapshot, layout: layout)
            }
          }.padding(.top, 20)
        }
        columns(layout).padding(.top, 22)
        footer.padding(.top, 10)
      }
      // The header starts below the titlebar's 28 points, where every control takes its clicks.
      .padding(.horizontal, layout.margin).padding(.top, 30).padding(.bottom, 12)
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .frame(minWidth: 800, idealWidth: 948, minHeight: 760, idealHeight: 860)
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
      celebrationTitle = Self.celebration(for: event)
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

  /// What the scene shouts for a feed line: copies, junk and programs each have their own.
  static func celebration(for event: HuntLogEntry) -> String {
    let text = event.message
    if text.localizedCaseInsensitiveContains("worktree") || text.contains("Restore point saved") {
      return "WORKTREE ERADICATED"
    }
    if text.localizedCaseInsensitiveContains("disk cleanup")
      || (event.kind == "burn" && text.hasSuffix(" back.") && !text.contains("of memory back"))
    {
      return "DEAD WEIGHT ERADICATED"
    }
    return "ZOMBIE ERADICATED"
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Skull(size: 36)
      VStack(alignment: .leading, spacing: 7) {
        Text("HUNT ZOMBIES").font(BurnTheme.display(26)).tracking(0.5).antonTrimmed(26)
        // Narrow, a deep hunt's line keeps its point in fewer words rather than trailing off.
        ViewThatFits(in: .horizontal) {
          ForEach(subtitles, id: \.self) { line in
            Text(line).font(.system(size: 12.5)).foregroundStyle(BurnTheme.muted).lineLimit(1)
          }
        }
      }.layoutPriority(1)
      Spacer(minLength: 16)
      VStack(alignment: .trailing, spacing: 7) {
        HStack(spacing: 8) { controls }
        if !model.huntRunning && !stoppedDeep && model.deepHuntAvailable {
          // The one notice a deep hunt needs; the details wait behind the limit.
          Text("A deep hunt uses more AI and burns as it goes.")
            .font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted).lineLimit(1)
        }
      }.fixedSize()
    }
  }

  private var subtitles: [String] {
    guard deep && (model.huntRunning || stoppedDeep) else { return ["Your Mac. Less dead weight."] }
    return [
      "Deep hunt · uses more AI than a regular hunt. Burns as it goes.",
      "Deep hunt · uses more AI. Burns as it goes.",
    ]
  }

  /// The action that matters most sits on the right, in orange: Hunt Zombies or Keep hunting. While
  /// a hunt runs, what's running and Stop.
  @ViewBuilder private var controls: some View {
    if model.huntRunning {
      livePill
      if deep { limitChip }
      if autopilot && model.autopilotAvailable {
        Button { model.stopHunt() } label: { Label("Stop", systemImage: "stop.fill") }
          .buttonStyle(HuntPillStyle()).clickPointer().accessibilityIdentifier("hunt-stop")
          .help("Ends the hunt now. Everything it burned stays burned.")
      }
    } else if stoppedDeep {
      Button { model.requestAgentCleanup() } label: { Label("Hunt Zombies", systemImage: "scope") }
        .buttonStyle(HuntPillStyle()).clickPointer().accessibilityIdentifier("hunt-again")
        .disabled(!model.accessReady || !model.harnessConfigured)
      limitChip
      Button {
        if !model.keepHunting() {
          limitNote = true
          showLimit = true
        }
      } label: {
        Label("Keep hunting", systemImage: "play.fill")
      }
      .buttonStyle(HuntPillStyle(prominent: true)).clickPointer()
      .accessibilityIdentifier("hunt-keep").disabled(!model.accessReady)
    } else {
      if model.deepHuntAvailable {
        Button { model.requestDeepHunt() } label: { Label("Deep hunt", systemImage: "flame") }
          .buttonStyle(HuntPillStyle()).clickPointer().accessibilityIdentifier("hunt-deep")
          .disabled(!model.accessReady)
          .help("The AI goes through everything, small programs too, and burns as it goes.")
        limitChip
      }
      Button { model.requestAgentCleanup() } label: { Label("Hunt Zombies", systemImage: "scope") }
        .buttonStyle(HuntPillStyle(prominent: true)).clickPointer()
        .accessibilityIdentifier("hunt-again")
        .disabled(!model.accessReady || !model.harnessConfigured)
        .padding(.leading, model.deepHuntAvailable ? 4 : 0)
    }
  }

  /// "Deep hunt" or "Hunting Zombies", with a live dot: what's running, not a button.
  private var livePill: some View {
    HStack(spacing: 7) {
      Circle().fill(BurnTheme.orange).frame(width: 7, height: 7)
        .shadow(color: BurnTheme.orange.opacity(0.7), radius: 3)
      Text(deep ? "Deep hunt" : "Hunting Zombies").font(.system(size: 12.5, weight: .semibold))
    }
    .padding(.horizontal, 12).frame(height: 30)
    .background(BurnTheme.orange.opacity(0.13), in: Capsule())
  }

  /// "$1.20 of $5" while a deep hunt runs, "Up to $5" otherwise. The details open on a click.
  private var limitChip: some View {
    Button {
      limitNote = false
      showLimit.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "dollarsign.circle").font(.system(size: 11.5, weight: .medium))
        Text(chipText).monospacedDigit()
        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
          .foregroundStyle(BurnTheme.muted)
      }
    }
    .buttonStyle(HuntPillStyle()).clickPointer().accessibilityIdentifier("hunt-limit")
    .popover(isPresented: $showLimit, arrowEdge: .bottom) {
      HuntLimitPanel(model: model, note: limitNote, running: model.huntRunning && deep)
    }
  }

  private var chipText: String {
    if model.huntRunning && deep, let snapshot {
      return HuntOptions.dollars(snapshot.spentUSD ?? 0) + " of "
        + HuntOptions.dollars(snapshot.limitUSD ?? model.deepLimitUSD)
    }
    return "Up to " + HuntOptions.dollars(model.deepLimitUSD)
  }

  // MARK: Feed and Needs you

  /// The feed beside what needs the owner, on the stats' columns. Older hunts have no questions, so
  /// their feed takes the whole width.
  @ViewBuilder private func columns(_ layout: HuntLayout) -> some View {
    if needsYou {
      HStack(alignment: .top, spacing: layout.gap) {
        feed.frame(width: layout.feed)
        HuntNeedsYou(
          model: model, running: model.huntRunning, width: layout.needs,
          confirmation: needsYouConfirmation
        ).frame(width: layout.needs)
      }.frame(maxHeight: .infinity, alignment: .top)
    } else {
      feed.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }

  private var feed: some View {
    VStack(alignment: .leading, spacing: 0) {
      HuntColumnHeader(title: "Hunt feed", subtitle: feedSummary, live: model.huntRunning) {
        Button {
          followLive.toggle()
        } label: {
          Label(
            followLive ? "Following" : "Follow live",
            systemImage: followLive ? "arrow.down.circle.fill" : "arrow.down.circle"
          )
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(followLive ? BurnTheme.orange : BurnTheme.muted)
        }.buttonStyle(.plain).clickPointer().fixedSize()
          .accessibilityIdentifier("follow-hunt-feed")
      }
      Rectangle().fill(HuntStyle.hairline).frame(height: 1).padding(.top, 9)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 11) {
            if let snapshot, !snapshot.log.isEmpty {
              ForEach(snapshot.log) { entry in logRow(entry).id(entry.id) }
            }
            Color.clear.frame(height: 1).id("feed-bottom")
          }.padding(.top, 14).padding(.bottom, 6).padding(.trailing, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.never)
        .mask(
          VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
              .frame(height: 24)
            Color.black
          }
        )
        .overlay {
          if snapshot?.log.isEmpty != false { emptyFeed }
        }
        .frame(minHeight: 90, maxHeight: .infinity)
        .onChange(of: snapshot?.log.map(\.id) ?? []) { _, _ in
          if followLive { reader.scrollTo("feed-bottom", anchor: .bottom) }
          receiveEffects()
        }
        .onChange(of: followLive) { _, following in
          if following { reader.scrollTo("feed-bottom", anchor: .bottom) }
        }
      }
      if autopilot, model.huntRunning, let focus = snapshot?.focus {
        ticker(focus).padding(.top, 8)
      }
    }
  }

  /// Before the first line: what the feed will show.
  private var emptyFeed: some View {
    VStack(spacing: 7) {
      Image(systemName: "scope").font(.system(size: 22, weight: .light))
        .foregroundStyle(BurnTheme.orange).padding(.bottom, 3)
      Text(model.huntRunning ? "The hunt is getting underway." : "Ready to clear the dead weight.")
        .font(.system(size: 14, weight: .semibold))
      Text(
        model.huntRunning
          ? "Measuring processes and storage before the AI reviews them."
          : "Start a hunt to see what it checks, judges and burns, as it happens."
      )
      .font(.system(size: 12.5)).foregroundStyle(BurnTheme.muted)
      .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 300)
    }.padding(20)
  }

  /// What the hunt is looking at this second, at the live end of the feed.
  private func ticker(_ focus: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(BurnTheme.orange)
      (Text("Now: ").foregroundColor(BurnTheme.muted) + Text(focus))
        .lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .font(.system(size: 11.5, design: .monospaced))
    .padding(.horizontal, 12).frame(height: 30)
    .background(HuntStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("hunt-now")
  }

  private var feedSummary: String {
    guard let snapshot else { return "What the hunt checks, judges and burns, as it happens." }
    let lanes = snapshot.lanes ?? []
    guard snapshot.isAutopilot || !lanes.isEmpty else {
      return "\(snapshot.evidenceReviewed) evidence groups · \(snapshot.attempts) review passes"
    }
    let judged = lanes.reduce(0) { $0 + $1.judged }
    var parts = ["\(judged.formatted()) judged", "\(snapshot.burned.formatted()) burned"]
    if let tokens = snapshot.tokens, tokens > 0 { parts.append(Self.tokens(tokens) + " tokens") }
    return parts.joined(separator: " · ")
  }

  static func tokens(_ count: Int) -> String {
    count >= 1_000_000
      ? String(format: "%.1fM", Double(count) / 1_000_000)
      : count >= 1000 ? "\(count / 1000)k" : "\(count)"
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

  private func logRow(_ entry: HuntLogEntry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(Image(systemName: Self.symbol(entry.kind)))
        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Self.tint(entry.kind))
        .frame(width: 16)
      Text(entry.message).font(.system(size: 12.5)).lineSpacing(2.5).textSelection(.enabled)
        .foregroundStyle(entry.kind == "thinking" ? BurnTheme.muted : BurnTheme.cream)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(
        entry.date,
        format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
      )
      .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(HuntStyle.faint)
    }
  }

  static func symbol(_ kind: String) -> String {
    switch kind {
    case "burn": return "flame.fill"
    case "warning": return "exclamationmark.shield"
    case "detected": return "scope"
    case "ask": return "questionmark.circle"
    case "thinking": return "text.bubble"
    case "stopped": return "stop.circle"
    case "complete": return "checkmark.seal"
    default: return "waveform.path"
    }
  }

  static func tint(_ kind: String) -> Color {
    switch kind {
    case "burn", "detected", "ask": return BurnTheme.orange
    case "complete": return AutopilotTheme.green
    default: return BurnTheme.muted
    }
  }

  // MARK: Footer

  private var footer: some View {
    let paused = snapshot?.phase == "paused"
    return HStack(spacing: 7) {
      Image(systemName: paused ? "pause.circle" : "shield.lefthalf.filled")
        .font(.system(size: 11)).foregroundStyle(paused ? BurnTheme.orange : HuntStyle.faint)
      Text(snapshot?.detail ?? "Active work stays protected. Every cleanup earns a receipt.")
        .font(.system(size: 11.5)).foregroundStyle(HuntStyle.faint).lineLimit(1)
      Spacer(minLength: 0)
    }
  }
}

/// The deep hunt's spending limit and what it means, behind the chip. Nothing here shows unless
/// the owner opens it, or Keep hunting finds nothing left under the limit.
struct HuntLimitPanel: View {
  @ObservedObject var model: AppModel
  let note: Bool
  let running: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Spending limit").font(.system(size: 14, weight: .semibold))
      HStack(spacing: 6) {
        Text("Stop at").font(.system(size: 12)).foregroundStyle(.secondary)
        ForEach(HuntOptions.limits, id: \.self) { limit in
          Button(HuntOptions.dollars(limit)) { model.deepLimitUSD = limit }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(model.deepLimitUSD == limit ? .accentColor : nil)
            .disabled(running)
            .accessibilityIdentifier("hunt-limit-\(Int(limit))")
        }
      }
      if running {
        Text("You can change it once this hunt stops.").font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      if note {
        Text("Raise the limit to keep hunting.").font(.system(size: 12, weight: .medium))
          .foregroundStyle(.orange)
      }
      VStack(alignment: .leading, spacing: 6) {
        if let hunt = model.huntSnapshot, hunt.deep == true, let spent = hunt.spentUSD {
          Text(
            "Spent \(HuntOptions.dollars(spent)) so far"
              + (hunt.tokens.map { ", about \(HuntView.tokens($0)) tokens" } ?? "")
              + ". A regular hunt costs about $0.10.")
        } else {
          Text("A regular hunt costs about $0.10. A deep hunt reads everything, so it costs more.")
        }
        Text(
          "It burns as it goes, so stopping or reaching the limit keeps everything already burned.")
        Text("On a Claude plan this counts toward your usage limits.")
      }
      .font(.system(size: 12)).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14).frame(width: 300)
  }
}
