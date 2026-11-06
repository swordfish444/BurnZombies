import BurnCore
import SwiftUI

/// The game is atmosphere, a strip at the top; the stats, the live feed and the questions below
/// it are the hunt itself, and every number there comes from the hunt's receipts.
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
  @State private var showLimit = false
  /// The limit panel says to raise it: Keep hunting found nothing left under it.
  @State private var limitNote = false
  var snapshot: HuntSnapshot? { model.huntSnapshot }
  var receiptsAvailable: Bool { snapshot?.receiptEvidenceAvailable != false }
  var activeVisuals: Bool { visible && model.huntProgressVisible }
  /// Autopilot hunts show lanes, the live ticker and the questions; older hunts their totals.
  var autopilot: Bool { snapshot?.isAutopilot == true || (snapshot == nil && model.autopilotAvailable) }
  var deep: Bool { snapshot?.deep == true }
  var stoppedDeep: Bool { deep && snapshot?.phase == "stopped" && !model.huntRunning }
  var sceneMode: HuntSceneMode {
    if let celebration { return celebration }
    return model.huntRunning
      ? .searching : snapshot?.phase == "paused" ? .paused : snapshot == nil ? .idle : .complete
  }
  var body: some View {
    GeometryReader { proxy in
      VStack(alignment: .leading, spacing: 12) {
        header
        // A quarter of the window: the scene sets the mood, the numbers below are the hunt.
        HuntSceneView(
          mode: sceneMode, celebrationTitle: celebrationTitle, isVisible: activeVisuals,
          elapsedOverride: sceneTime, height: max(140, (proxy.size.height * 0.25).rounded()))
        if let lanes = snapshot?.lanes, !lanes.isEmpty {
          HuntStats(snapshot: snapshot!, running: model.huntRunning)
        } else {
          totals
        }
        if autopilot, model.huntRunning, let focus = snapshot?.focus {
          ticker(focus)
        }
        feed
        if autopilot && model.autopilotAvailable {
          HuntNeedsYou(model: model, running: model.huntRunning)
        }
        HStack(spacing: 8) {
          Image(systemName: snapshot?.phase == "paused" ? "pause.circle" : "shield.lefthalf.filled")
            .foregroundStyle(snapshot?.phase == "paused" ? BurnTheme.orange : BurnTheme.muted)
          Text(snapshot?.detail ?? "Active work stays protected. Every cleanup earns a receipt.")
            .font(.system(size: 11)).foregroundStyle(BurnTheme.muted).lineLimit(1)
          Spacer(minLength: 0)
        }
      }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 16)
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
    HStack(alignment: .top, spacing: 12) {
      Skull(size: 38)
      VStack(alignment: .leading, spacing: 2) {
        Text("HUNT ZOMBIES").font(BurnTheme.display(28)).tracking(0.4)
        Text(
          deep && (model.huntRunning || stoppedDeep)
            ? "Deep hunt · uses more AI than a regular hunt. Burns as it goes."
            : "Your Mac. Less dead weight."
        )
        .font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 5) {
        HStack(spacing: 8) { controls }
        if !model.huntRunning && !stoppedDeep && model.deepHuntAvailable {
          // The one notice a deep hunt needs; the details wait behind the limit.
          Text("A deep hunt uses more AI and burns as it goes.")
            .font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
        }
      }
    }
  }

  @ViewBuilder private var controls: some View {
    if model.huntRunning {
      HStack(spacing: 8) {
        Circle().fill(BurnTheme.orange).frame(width: 7, height: 7)
        Text(deep ? "Deep hunt" : "Hunting Zombies").font(.system(size: 12, weight: .semibold))
      }.padding(.horizontal, 12).padding(.vertical, 9)
        .background(BurnTheme.orange.opacity(0.10), in: Capsule())
      if deep { limitChip }
      if autopilot && model.autopilotAvailable {
        capsule("Stop", symbol: "stop.fill", filled: false, id: "hunt-stop") { model.stopHunt() }
          .help("Ends the hunt now. Everything it burned stays burned.")
      }
    } else if stoppedDeep {
      limitChip
      capsule("Keep hunting", symbol: "play.fill", filled: true, id: "hunt-keep") {
        if !model.keepHunting() {
          limitNote = true
          showLimit = true
        }
      }.disabled(!model.accessReady)
      capsule("Hunt Zombies", symbol: "scope", filled: false, id: "hunt-again") {
        model.requestAgentCleanup()
      }.disabled(!model.accessReady || !model.harnessConfigured)
    } else {
      capsule("Hunt Zombies", symbol: "scope", filled: true, id: "hunt-again") {
        model.requestAgentCleanup()
      }.disabled(!model.accessReady || !model.harnessConfigured)
      if model.deepHuntAvailable {
        capsule("Deep hunt", symbol: "flame", filled: false, id: "hunt-deep") {
          model.requestDeepHunt()
        }.disabled(!model.accessReady)
          .help("The AI goes through everything, small programs too, and burns as it goes.")
        limitChip
      }
    }
  }

  /// "$1.20 of $5" while a deep hunt runs, "Up to $5" otherwise. The details open on a click.
  private var limitChip: some View {
    Button {
      limitNote = false
      showLimit.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "dollarsign.circle")
        Text(chipText).monospacedDigit()
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
      }
      .font(.system(size: 12, weight: .medium)).foregroundStyle(BurnTheme.cream)
      .padding(.horizontal, 11).padding(.vertical, 8)
      .background(Color.white.opacity(0.06), in: Capsule())
      .overlay(Capsule().strokeBorder(BurnTheme.line))
    }
    .buttonStyle(.plain).clickPointer().accessibilityIdentifier("hunt-limit")
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

  private func capsule(
    _ title: String, symbol: String, filled: Bool, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9)
        .background(filled ? BurnTheme.orange : Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(filled ? Color.clear : BurnTheme.line))
        .foregroundStyle(filled ? Color.black.opacity(0.85) : BurnTheme.cream)
    }.buttonStyle(.plain).clickPointer().accessibilityIdentifier(id)
  }

  // MARK: Stats

  /// Hunts from before Autopilot: their totals, as they always read.
  private var totals: some View {
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
  }

  private func ticker(_ focus: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(BurnTheme.orange)
      Text("Now:").foregroundStyle(BurnTheme.muted)
      Text(focus).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .font(.system(size: 12, design: .monospaced))
    .padding(.horizontal, 12).padding(.vertical, 7)
    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier("hunt-now")
  }

  // MARK: Feed

  private var feed: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("HUNT FEED", systemImage: "text.bubble").font(
          .system(size: 11, weight: .semibold, design: .monospaced)
        ).tracking(1)
        if model.huntRunning {
          Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(BurnTheme.orange)
        }
        Spacer()
        Text(feedSummary).font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
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
      }.padding(.horizontal, 16).padding(.vertical, 11)
      Rectangle().fill(BurnTheme.line).frame(height: 1)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
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
                      ? "Measuring processes and storage before the AI reviews them."
                      : "Start a hunt to see what it checks, judges and burns, as it happens."
                  )
                  .font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
                }
              }.padding(.vertical, 10)
            }
            Color.clear.frame(height: 1).id("feed-bottom")
          }.padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.defaultScrollAnchor(.bottom).frame(minHeight: 110, maxHeight: .infinity)
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
  }

  private var feedSummary: String {
    guard let snapshot else { return "" }
    guard let lanes = snapshot.lanes, !lanes.isEmpty else {
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
      Image(systemName: Self.symbol(entry.kind))
        .font(.system(size: 13)).foregroundStyle(Self.tint(entry.kind))
        .frame(width: 18).padding(.top, 2)
      Text(entry.message).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
        .foregroundStyle(entry.kind == "thinking" ? BurnTheme.muted : BurnTheme.cream)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(entry.date, format: .dateTime.hour().minute().second()).font(
        .system(size: 10, design: .monospaced)
      )
      .foregroundStyle(BurnTheme.muted).padding(.top, 2)
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
}

/// Freed so far, then one card per area: what the AI judged there, what burned and what BZ saw.
struct HuntStats: View {
  let snapshot: HuntSnapshot
  let running: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      hero.frame(width: 210)
      ForEach(order(snapshot.lanes ?? [])) { lane in card(lane) }
    }.fixedSize(horizontal: false, vertical: true)
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(running ? "FREED SO FAR" : "FREED THIS HUNT")
        .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
        .foregroundStyle(BurnTheme.muted)
      Text(ImpactNumbers.bytes(snapshot.memoryReclaimed + snapshot.diskReclaimed))
        .font(BurnTheme.display(30)).foregroundStyle(BurnTheme.orange)
        .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
      Text("\(snapshot.burned.formatted()) zombie\(snapshot.burned == 1 ? "" : "s") burned")
        .font(.system(size: 13, weight: .medium))
      Text(
        ImpactNumbers.bytes(snapshot.memoryReclaimed) + " memory · "
          + ImpactNumbers.bytes(snapshot.diskReclaimed) + " disk"
      )
      .font(.system(size: 11)).foregroundStyle(BurnTheme.muted).lineLimit(1)
      if snapshot.deep == true, !running, let spent = snapshot.spentUSD {
        Text("for " + HuntOptions.dollars(spent) + " of AI")
          .font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.line))
    .accessibilityIdentifier("hunt-freed")
  }

  private func order(_ lanes: [HuntLane]) -> [HuntLane] {
    let kinds = ["process", "worktree", "disk"]
    return lanes.sorted { (kinds.firstIndex(of: $0.kind) ?? 9) < (kinds.firstIndex(of: $1.kind) ?? 9) }
  }

  private func card(_ lane: HuntLane) -> some View {
    let total = max(lane.toJudge, lane.judged)
    let (title, symbol, found): (String, String, String) = {
      switch lane.kind {
      case "process": return ("Programs", "cpu", "\(lane.seen.formatted()) running")
      case "worktree":
        return ("Old copies", "arrow.triangle.branch", "\(lane.seen.formatted()) copies found")
      default: return ("Junk and caches", "folder", "\(lane.seen.formatted()) folders found")
      }
    }()
    let state: String =
      total == 0
      ? (running ? "Clear" : "Done")
      : lane.judged >= total ? "Done" : running ? "AI" : snapshot.phase == "stopped" ? "Stopped" : "Done"
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
          .lineLimit(1).minimumScaleFactor(0.8)
        Spacer(minLength: 4)
        Text(state).font(.system(size: 10, weight: .semibold))
          .foregroundStyle(state == "AI" ? BurnTheme.orange : BurnTheme.muted)
          .padding(.horizontal, 7).padding(.vertical, 2)
          .background(
            (state == "AI" ? BurnTheme.orange.opacity(0.14) : Color.white.opacity(0.06)),
            in: Capsule())
      }
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(lane.judged.formatted()).font(BurnTheme.display(20)).contentTransition(.numericText())
        Text("of \(total.formatted()) judged").font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
      }
      ProgressView(value: Double(min(lane.judged, total)), total: Double(max(total, 1)))
        .progressViewStyle(.linear).tint(BurnTheme.orange).controlSize(.small)
      Text(
        lane.burned > 0
          ? "Burned \(lane.burned.formatted()) · " + ImpactNumbers.bytes(lane.bytes)
          : "Nothing burned yet"
      )
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(lane.burned > 0 ? BurnTheme.cream : BurnTheme.muted)
      Text(found).font(.system(size: 11)).foregroundStyle(BurnTheme.muted).lineLimit(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(12)
    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.line))
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

/// The questions a hunt runs into, one card at a time like Teach BZ, answered while it keeps going.
/// A card stays until it is answered; new ones add a dot. Biggest first.
struct HuntNeedsYou: View {
  @ObservedObject var model: AppModel
  let running: Bool
  @State private var pinned: String?
  @State private var answered = Set<String>()
  @State private var confirmation: (title: String, line: String, symbol: String)?

  private var questions: [AutopilotQuestion] {
    model.autopilot.questions.filter { $0.isOpen && !answered.contains($0.id) }
      .sorted { $0.bytes > $1.bytes }
  }
  private var current: AutopilotQuestion? {
    questions.first { $0.id == pinned } ?? questions.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        Label("NEEDS YOU", systemImage: "hand.raised")
          .font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1)
          .fixedSize()
        Text(
          running
            ? "The hunt keeps going. A yes burns them right away and teaches BZ."
            : "A yes still burns them right away. The rest wait in Teach BZ."
        )
        .font(.system(size: 11)).foregroundStyle(BurnTheme.muted).lineLimit(1)
        Spacer(minLength: 8)
        if questions.count > 1, let current, let index = questions.firstIndex(where: { $0.id == current.id }) {
          HStack(spacing: 8) {
            HStack(spacing: 5) {
              ForEach(Array(questions.prefix(8).enumerated()), id: \.offset) { i, _ in
                Circle().fill(i == index ? BurnTheme.orange : Color.white.opacity(0.2))
                  .frame(width: 7, height: 7)
              }
            }
            Text("\(index + 1) of \(questions.count)").font(.system(size: 11))
              .foregroundStyle(BurnTheme.muted).monospacedDigit()
            arrow("chevron.left") { step(-1) }
            arrow("chevron.right") { step(1) }
          }
        }
      }
      if let confirmation {
        HStack(spacing: 12) {
          Image(systemName: confirmation.symbol).font(.system(size: 22))
            .foregroundStyle(BurnTheme.orange)
          VStack(alignment: .leading, spacing: 2) {
            Text(confirmation.title).font(.system(size: 16, weight: .bold, design: .rounded))
            Text(confirmation.line).font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
          }
          Spacer()
        }.frame(minHeight: 84)
      } else if let question = current {
        card(question)
      } else {
        Text("Nothing needs you right now. Cards show up here when the hunt finds something it isn't sure about.")
          .font(.system(size: 12)).foregroundStyle(BurnTheme.muted)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.line))
    .onChange(of: questions.map(\.id), initial: true) { _, ids in
      if pinned == nil || !ids.contains(pinned!) { pinned = ids.first }
    }
    .accessibilityIdentifier("hunt-needs-you")
  }

  private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        .frame(width: 22, height: 22)
        .background(Color.white.opacity(0.06), in: Circle())
    }.buttonStyle(.plain).clickPointer()
  }

  private func step(_ by: Int) {
    let list = questions
    guard !list.isEmpty, confirmation == nil else { return }
    let index = list.firstIndex { $0.id == current?.id } ?? 0
    pinned = list[(index + by + list.count) % list.count].id
  }

  private func card(_ question: AutopilotQuestion) -> some View {
    let card = AutopilotPolicy.card(question)
    let cautions = Set(card.cautions)
    return HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(AutopilotLook.emoji(question.kind)).font(.system(size: 20))
          Text(card.headline).font(.system(size: 18, weight: .bold, design: .rounded))
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        Text(card.frees).font(.system(size: 15, weight: .heavy, design: .rounded))
          .foregroundStyle(BurnTheme.orange)
        if let line = card.line, !line.isEmpty {
          Text(line).font(.system(size: 12)).foregroundStyle(BurnTheme.muted).lineLimit(2)
        }
        if !card.facts.isEmpty {
          HStack(spacing: 6) {
            ForEach(Array(card.facts.prefix(3)), id: \.self) { fact in
              let caution = cautions.contains(fact)
              HStack(spacing: 4) {
                if caution {
                  Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                }
                Text(fact).lineLimit(1)
              }
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(caution ? Color.orange : BurnTheme.cream)
              .padding(.horizontal, 9).padding(.vertical, 4)
              .background(
                caution ? Color.orange.opacity(0.14) : Color.white.opacity(0.07), in: Capsule())
            }
          }
        }
        if let cost = card.cost {
          Label(cost, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.orange).lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      VStack(spacing: 6) {
        answer(card.yes, fill: AutopilotTheme.green, text: Color.black.opacity(0.86), id: "hunt-yes") {
          respond(question, .yes)
        }
        answer(card.no, fill: Color.white.opacity(0.08), text: BurnTheme.cream, id: "hunt-no") {
          respond(question, .no)
        }
        HStack(spacing: 12) {
          link("Not sure — skip") { respond(question, .skip) }
          link("View details") { model.openTeach?() }
        }
      }.frame(width: 196)
    }
  }

  private func answer(
    _ title: String, fill: Color, text: Color, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(text).frame(maxWidth: .infinity).frame(height: 30)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BurnTheme.line))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain).clickPointer().accessibilityIdentifier(id)
  }

  private func link(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 11)).underline().foregroundStyle(BurnTheme.muted)
    }.buttonStyle(.plain).clickPointer()
  }

  private func respond(_ question: AutopilotQuestion, _ answer: AutopilotAnswer) {
    guard confirmation == nil else { return }
    model.answer(question, answer)
    answered.insert(question.id)
    switch answer {
    case .yes:
      confirmation = (
        "Burning them now", "BZ handles ones like these on its own from now on.", "flame.fill"
      )
    case .no:
      confirmation = ("Keeping them", "BZ won't ask about these again.", "hand.raised.fill")
    default:
      confirmation = ("Skipped", "It waits in Teach BZ for later.", "clock")
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.6))
      confirmation = nil
      pinned = nil
    }
  }
}
