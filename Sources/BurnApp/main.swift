import AppKit
import BurnCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor final class AppModel: ObservableObject {
  @Published var state = ViewState() {
    didSet {
      if !restoringAccessPresentation && state.fullDiskAccess.canScan {
        accessPreferences?.removeObject(forKey: Self.accessVerificationPendingKey)
        if accessBannerDismissed {
          accessBannerDismissed = false
          accessPreferences?.removeObject(forKey: Self.accessBannerDismissedKey)
        }
      }
      let pending = Set(oldValue.catalog.events.filter { $0.outcome == "verifying" }.map(\.id))
      if let finished = state.catalog.events.last(where: {
        pending.contains($0.id) && $0.outcome != "verifying"
      }) {
        message = finished.outcome == "verified" ? "Cleanup verified." : finished.detail
      }
      if didLoadState
        && state.catalog.lifetimeVerified + (state.catalog.lifetimeWorktreesCleaned ?? 0) > oldValue
          .catalog.lifetimeVerified + (oldValue.catalog.lifetimeWorktreesCleaned ?? 0)
      {
        burnPulse += 1
      }
      didLoadState = true
    }
  }
  private var didLoadState = false
  private var restoringAccessPresentation = true
  @Published var burnPulse = 0
  func previewBurn() {
    guard demo else { return }
    Demo.recordBurn(in: &state.catalog)
  }
  @Published var selection: Finding?
  @Published var tab = "Overview"
  @Published var preview = false
  @Published var cleanupQueued = false
  @Published var machineReview = MachineReviewState()
  @Published var machineReviewEnabled = false
  @Published var harnessConfigured = false
  /// The harness Settings chose. A deep hunt needs Claude Code: it streams and stops at a limit.
  @Published private(set) var harness: String?
  static let deepLimitKey = "deepHuntLimitUSD"
  /// The deep hunt's spending limit in US dollars, kept for next time.
  @Published var deepLimitUSD = HuntOptions.defaultLimit {
    didSet { accessPreferences?.set(deepLimitUSD, forKey: Self.deepLimitKey) }
  }
  @Published var huntSnapshot: HuntSnapshot?
  @Published private(set) var huntLaunching = false
  var huntRunning: Bool {
    huntLaunching || huntSnapshot?.isRunning == true || machineReview.phase == "reviewing"
  }
  private var reviewTaskActive = false
  private var pendingManualHunt = false
  private var huntProgressTimer: Timer?
  @Published private(set) var huntProgressVisible = false
  private var huntPollBusy = false
  private let huntAction: (() async -> Void)?
  static let accessBannerDismissedKey = "fullDiskAccessBannerDismissed"
  static let accessVerificationPendingKey = "fullDiskAccessVerificationPending"
  @Published private(set) var accessBannerDismissed = false
  private let accessPreferences: UserDefaults?
  private let accessOpener: (URL) -> Bool
  private let accessChecker: (() async throws -> FullDiskAccessStatus)?
  private var awaitingAccessReturn = false
  private var leftForAccessSettings = false
  private var accessReturnPending = false
  var accessReady: Bool { state.fullDiskAccess.canScan }
  var showsAccessBanner: Bool { !accessReady && !accessBannerDismissed }
  var installedAppPath: String {
    Bundle.main.bundleURL.pathExtension == "app"
      ? Bundle.main.bundleURL.path : "~/Applications/BurnZombies.app"
  }
  func dismissAccessBanner() {
    accessBannerDismissed = true
    accessPreferences?.set(true, forKey: Self.accessBannerDismissedKey)
  }
  func copyInstalledAppPath() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(installedAppPath, forType: .string)
    message = "App path copied. Use +, then Command-Shift-G in Full Disk Access."
  }

  /// Explicit setup arms one return check and survives macOS Quit & Reopen.
  /// The saved intent authorizes a check, never a permission grant.
  func openFullDiskAccessSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    else { return }
    awaitingAccessReturn = true
    leftForAccessSettings = false
    accessReturnPending = false
    accessPreferences?.set(true, forKey: Self.accessVerificationPendingKey)
    guard accessOpener(url) else {
      awaitingAccessReturn = false
      accessPreferences?.removeObject(forKey: Self.accessVerificationPendingKey)
      message =
        "Open System Settings → Privacy & Security → Full Disk Access and enable BurnZombies."
      return
    }
  }
  private func restoreAccessVerificationAfterRelaunch() {
    guard accessPreferences?.bool(forKey: Self.accessVerificationPendingKey) == true else { return }
    // Consume before checking so denial, errors or another relaunch cannot loop.
    accessPreferences?.removeObject(forKey: Self.accessVerificationPendingKey)
    accessReturnPending = true
  }
  func accessSetupDidResignActive() {
    if awaitingAccessReturn { leftForAccessSettings = true }
  }
  func accessSetupDidBecomeActive() {
    guard awaitingAccessReturn && leftForAccessSettings else { return }
    awaitingAccessReturn = false
    leftForAccessSettings = false
    accessReturnPending = true
    checkAccessAfterReturnIfReady()
  }
  private func checkAccessAfterReturnIfReady() {
    guard accessReturnPending && !working else { return }
    accessReturnPending = false
    recheckFullDiskAccess()
  }
  func recheckFullDiskAccess() {
    guard !working, accessChecker != nil || (!demo && monitor != nil) else { return }
    awaitingAccessReturn = false
    leftForAccessSettings = false
    accessReturnPending = false
    working = true
    Task {
      do {
        if let accessChecker {
          state.fullDiskAccess = try await accessChecker()
        } else if let monitor {
          state = try await monitor.recheckFullDiskAccess()
        }
        message =
          accessReady
          ? "Access is available. Observation continues on its normal schedule."
          : state.fullDiskAccess.detail
      } catch { message = error.localizedDescription }
      working = false
      onUpdate?()
      if !demo { schedule() }
    }
  }

  func requestAgentCleanup() {
    if let runtime = autopilotRuntime {
      guard harnessConfigured else {
        message = "Choose Claude Code or Codex in Settings so BZ can think through new things."
        return
      }
      message =
        autopilot.sweep.lookOnly == true
        ? "Hunting now. Look-only: I'll judge and ask, but burn nothing."
        : "Hunting now. I'll burn what's safe and ask if I'm unsure."
      openHunt?()
      launchHunt(runtime, HuntOptions())
      return
    }
    guard accessReady else {
      message = state.fullDiskAccess.detail
      return
    }
    if huntRunning {
      openHunt?()
      return
    }
    guard demo || harnessConfigured else {
      message = "Choose a harness in Settings before hunting."
      return
    }
    openHunt?()
    guard !demo || huntAction != nil else { return }
    huntLaunching = true
    runHunt(manual: true)
  }
  /// Deep hunts need Claude Code: it streams what it does and stops itself at a spending limit.
  var deepHuntAvailable: Bool { harness == "claude" && (demo || autopilotRuntime != nil) }

  /// A deep hunt: the AI reads everything, small programs too, and burns as it goes until it has
  /// spent the limit or the owner stops it.
  func requestDeepHunt() {
    guard let runtime = autopilotRuntime else {
      message = "Deep hunts need Autopilot."
      return
    }
    guard harness == "claude" else {
      message = AutopilotCoordinator.deepNeedsClaude
      return
    }
    guard !huntRunning else {
      openHunt?()
      return
    }
    message =
      "Deep hunt started. It stops at \(HuntOptions.dollars(deepLimitUSD)) and burns as it goes."
    openHunt?()
    launchHunt(runtime, HuntOptions(deep: true, limitUSD: deepLimitUSD))
  }

  /// "Keep hunting": a deep hunt that stopped goes on with what is left under the limit. Returns
  /// false when nothing is left, so the window can say to raise the limit.
  @discardableResult func keepHunting() -> Bool {
    guard let runtime = autopilotRuntime, let hunt = huntSnapshot, hunt.deep == true,
      hunt.phase == "stopped"
    else {
      requestDeepHunt()
      return true
    }
    let left = deepLimitUSD - (hunt.spentUSD ?? 0)
    guard left >= HuntOptions.smallestRun else { return false }
    message = "Hunting again from where it stopped."
    launchHunt(runtime, HuntOptions(deep: true, limitUSD: left, continuing: true))
    return true
  }

  /// Ends the hunt under way. What it burned stays burned.
  func stopHunt() {
    guard let runtime = autopilotRuntime else { return }
    Task {
      await runtime.stop()
      await receiveReviewState()
    }
  }

  private func launchHunt(_ runtime: AutopilotRuntime, _ options: HuntOptions) {
    huntLaunching = true
    startHuntProgressTimer()
    Task {
      autopilot = await runtime.tick(manual: true, options: options)
      huntLaunching = false
      await receiveReviewState()
    }
  }

  func reloadReviewConfiguration() {
    guard !demo else { return }
    do {
      let config = try MachineReviewConfiguration.load(root: Store.defaultRoot)
      harnessConfigured = config != nil
      harness = config?.harness
      machineReviewEnabled = config?.enabled ?? false
    } catch { message = error.localizedDescription }
  }
  func runScheduledHunt() { runHunt(manual: false) }
  private func runHunt(manual: Bool) {
    guard !demo || huntAction != nil else { return }
    if reviewTaskActive {
      if manual { pendingManualHunt = true }
      return
    }
    reviewTaskActive = true
    startHuntProgressTimer()
    Task {
      let previousReview = await reviewer?.snapshot()
      if let huntAction {
        await huntAction()
      } else if manual {
        await reviewer?.hunt()
      } else {
        await reviewer?.tick()
      }
      await receiveReviewState()
      if let monitor { state = await monitor.snapshot() }
      let beganHunt = machineReview.lastStarted != previousReview?.lastStarted
      let followUp = pendingManualHunt && !beganHunt
      pendingManualHunt = false
      huntLaunching = followUp
      reviewTaskActive = false
      if followUp { runHunt(manual: true) }
      if !huntProgressVisible && !reviewTaskActive {
        huntProgressTimer?.invalidate()
        huntProgressTimer = nil
      }
      onUpdate?()
    }
  }
  func setHuntProgressVisible(_ visible: Bool) {
    huntProgressVisible = visible
    if visible {
      startHuntProgressTimer()
      pollHuntProgress()
    } else if !reviewTaskActive {
      huntProgressTimer?.invalidate()
      huntProgressTimer = nil
    } else {
      startHuntProgressTimer()
    }
  }
  private func startHuntProgressTimer() {
    guard !demo else { return }
    let interval: TimeInterval = huntProgressVisible ? 1 : 5
    guard huntProgressTimer?.timeInterval != interval else { return }
    huntProgressTimer?.invalidate()
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pollHuntProgress() }
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    huntProgressTimer = timer
  }
  private func pollHuntProgress() {
    guard !huntPollBusy, !demo else { return }
    huntPollBusy = true
    Task {
      await receiveReviewState(includeHunt: huntProgressVisible)
      huntPollBusy = false
    }
    if huntProgressVisible { refreshAutopilotForHunt() }
  }
  private var autopilotRefreshBusy = false
  private var autopilotRefreshed = Date.distantPast
  /// The Hunt window's questions come from the engine: what the AI asks shows while it hunts. Apart
  /// from the feed's poll, so a busy engine never holds the feed up.
  private func refreshAutopilotForHunt() {
    guard let runtime = autopilotRuntime, !autopilotRefreshBusy,
      Date().timeIntervalSince(autopilotRefreshed) >= 2
    else { return }
    autopilotRefreshBusy = true
    Task {
      let next = await runtime.engine.snapshot()
      if next != autopilot { autopilot = next }
      autopilotRefreshed = Date()
      autopilotRefreshBusy = false
    }
  }
  @Published var working = false {
    didSet { if oldValue && !working { checkAccessAfterReturnIfReady() } }
  }
  @Published var message: String?
  @Published var technical = [String]()
  @Published var impactTab = "Impact"
  @Published var impactPeriod = ImpactPeriod.today
  /// The menu bar popup's own period, so its tabs never move the Impact window's.
  @Published var miniImpactPeriod = ImpactPeriod.today
  @Published var pressure = "—"
  var openImpact: (() -> Void)?
  var openLog: (() -> Void)?
  var openSettings: (() -> Void)?
  var openAudit: (() -> Void)?
  var openWorktrees: (() -> Void)?
  var openHunt: (() -> Void)?
  var openFindings: (() -> Void)?
  var openAdvancedFindings: (() -> Void)?
  var openTeach: (() -> Void)?
  var openWorktreeID: ((String) -> Void)?
  /// Autopilot as the windows see it. The engine replaces this after every sweep and command.
  @Published var autopilot = AutopilotSnapshot()
  /// Applies one operator command in the engine and returns the new snapshot, or throws why it
  /// couldn't. While nil (demo and offscreen proofs) the model applies the same change to
  /// `autopilot` in memory instead.
  var autopilotRunner: ((AutopilotCommand) async throws -> AutopilotSnapshot)?
  /// The Autopilot surfaces appear once an engine is attached, or in the demo.
  var autopilotAvailable: Bool { demo || autopilotRunner != nil }
  /// What the owner pressed on a tell that the engine hasn't finished yet, by tell id. Teach BZ
  /// hides a tell called good or seen at once and shows one being undone as under way; a command the
  /// engine couldn't do clears its entry and the tell comes back with its buttons.
  enum TellAction { case good, undo, seen }
  @Published private(set) var tellActions: [String: TellAction] = [:]
  /// Why the last Good call or Undo on a tell couldn't be done, by tell id, so Teach BZ can say so
  /// on the card and not only in the footer. A new press clears it.
  @Published private(set) var tellProblems: [String: String] = [:]
  @Published var findingSelection: String?
  @Published var findingBusy = Set<String>()
  let demo: Bool
  private var monitor: Monitor?
  private var agentListener: AgentListener?
  private var agentSnapshotTask: Task<Void, Never>?
  private var reviewer: MachineReviewer?
  private var autopilotRuntime: AutopilotRuntime?
  private var timer: Timer?
  private var observationSuspended = false
  private var observationStopped = false
  private var notificationPermissionError: String?
  private var notificationDeliveryInFlight = false
  #if DEBUG
    private var timerDispatchForProof: (() -> Void)?
  #endif
  var onUpdate: (() -> Void)?
  init(
    demo: Bool = CommandLine.arguments.contains("--demo"), accessPreferences: UserDefaults? = nil,
    accessOpener: ((URL) -> Bool)? = nil,
    accessChecker: (() async throws -> FullDiskAccessStatus)? = nil,
    huntAction: (() async -> Void)? = nil
  ) {
    self.demo = demo
    self.accessPreferences = accessPreferences ?? (demo ? nil : .standard)
    self.accessOpener = accessOpener ?? { NSWorkspace.shared.open($0) }
    self.accessChecker = accessChecker
    self.huntAction = huntAction
    accessBannerDismissed =
      self.accessPreferences?.bool(forKey: Self.accessBannerDismissedKey) ?? false
    if let saved = self.accessPreferences?.double(forKey: Self.deepLimitKey),
      HuntOptions.limits.contains(saved)
    {
      deepLimitUSD = saved
    }
    if demo {
      state = Demo.state()
      state.fullDiskAccess = .init(state: .granted, detail: "Preview access state.")
      autopilot = Demo.autopilot()
      pressure = "Low"
      harnessConfigured = true
      harness = "claude"
      machineReviewEnabled = true
      restoringAccessPresentation = false
      restoreAccessVerificationAfterRelaunch()
      checkAccessAfterReturnIfReady()
      return
    }
    restoringAccessPresentation = false
    startAtLoginOnFirstLaunch()
    do {
      let observer = try Monitor()
      monitor = observer
      reviewer = try MachineReviewer(
        prepareHunt: { _ = try await observer.prepareHunt() },
        settleHunt: { _ = try await observer.settleHuntDiscovery() })
      reloadReviewConfiguration()
      if let runtime = try? AutopilotRuntime(monitor: observer) {
        autopilotRuntime = runtime
        autopilotRunner = { command in try await runtime.run(command) }
      }
    } catch {
      state.error = error.localizedDescription
      return
    }
    if let monitor {
      let service = AgentService(monitor: monitor, autopilot: autopilotRuntime?.engine)
      do {
        agentListener = try AgentListener { [weak self] request in
          let reply = await service.call(request)
          await self?.requestAgentSnapshot()
          return reply
        }
      } catch { message = error.localizedDescription }
    }
    restoreAccessVerificationAfterRelaunch()
    refresh()
  }
  func worktree(_ request: WorktreeRequest) async throws -> WorktreeReply {
    if demo { return WorktreeExamples.snapshot() }
    guard let monitor else { return WorktreeReply() }
    let reply = try await monitor.worktreeRequest(request, caller: "native-operator")
    if !["list", "operations"].contains(request.action) { state = await monitor.snapshot() }
    return reply
  }
  func decideFinding(_ p: CleanupProposal, decision: String, reason: String = "") {
    guard let monitor else { return }
    Task {
      findingBusy.insert(p.id)
      defer { findingBusy.remove(p.id) }
      do {
        try await monitor.decideFinding(
          p.id, revision: p.revision, decision: decision, reason: reason)
        state = await monitor.snapshot()
        if decision == "approve" {
          message = try await monitor.executeApprovedFinding(p.id, revision: p.revision)
        } else {
          message = decision == "keep" ? "Kept until you clear this decision." : "Decision saved."
        }
      } catch { message = error.localizedDescription }
      state = await monitor.snapshot()
    }
  }
  func grantRule(_ p: CleanupProposal, cap: Int, expires: Date, shadow: Bool = false) {
    guard let monitor else { return }
    Task {
      do {
        try await monitor.grantFindingRule(
          p.id, revision: p.revision, maximumPerDay: cap, expires: expires, shadow: shadow)
      } catch { message = error.localizedDescription }
      state = await monitor.snapshot()
    }
  }
  func refreshFinding(_ id: String) async {
    guard let monitor else { return }
    do { try await monitor.refreshFinding(id) } catch { message = error.localizedDescription }
    state = await monitor.snapshot()
  }
  func findingDetail(_ id: String) async -> CleanupProposal? {
    guard let monitor else { return nil }
    return try? await monitor.finding(id)
  }
  func findingPage(_ offset: Int) async -> FindingsSnapshot? {
    guard let monitor else { return nil }
    return try? await monitor.findingPage(offset: offset)
  }
  func findingHistory(_ workflow: String) async -> [CleanupDecision] {
    guard let monitor else { return [] }
    return (try? await monitor.findingHistory(workflow: workflow)) ?? []
  }
  func forgetWorkflow(_ workflow: String) {
    guard let monitor else { return }
    Task {
      do { try await monitor.forgetFindingWorkflow(workflow) } catch {
        message = error.localizedDescription
      }
      state = await monitor.snapshot()
    }
  }
  func reconcileDisk(_ id: UUID, restore: Bool) {
    guard let monitor else { return }
    Task {
      do { message = try await monitor.reconcileDisk(id, restore: restore) } catch {
        message = error.localizedDescription
      }
      state = await monitor.snapshot()
    }
  }
  func reconcileFindingFeedback() {
    guard let monitor else { return }
    Task {
      do {
        try await monitor.reconcileFindingFeedback()
        message =
          "Recovery feedback saved. Affected workflows remain paused pending explicit review."
      } catch { message = error.localizedDescription }
      state = await monitor.snapshot()
    }
  }
  func setNotificationBudget(_ budget: Int) {
    var p = state.catalog.preferences
    p.notificationBudget = max(1, min(5, budget))
    save(p)
  }
  func pauseRule(_ rule: CleanupRule) {
    guard let monitor else { return }
    Task {
      do { try await monitor.pauseFindingRule(rule.id) } catch {
        message = error.localizedDescription
      }
      state = await monitor.snapshot()
    }
  }
  func notificationAction(id: String, revision: String, action: String) {
    Task {
      if let monitor { state = await monitor.snapshot() }
      // These notifications are about the detailed inbox, so they open the advanced window.
      if id == "digest" {
        openAdvancedFindings?()
        return
      }
      guard let monitor, let p = try? await monitor.finding(id), p.revision == revision else {
        message = "That finding changed. Review its current evidence."
        openAdvancedFindings?()
        return
      }
      if action == "approve" || action == "keep" || action == "snooze" {
        decideFinding(p, decision: action)
      } else {
        findingSelection = p.id
        openAdvancedFindings?()
      }
    }
  }
  func setNotificationDetails(_ enabled: Bool) {
    var p = state.catalog.preferences
    p.notificationDetails = enabled
    save(p)
  }
  func setDecisionSharing(_ enabled: Bool) {
    var p = state.catalog.preferences
    p.shareDecisionHistory = enabled
    save(p)
  }
  deinit { agentSnapshotTask?.cancel() }
  private func requestAgentSnapshot() {
    guard agentSnapshotTask == nil, let monitor else { return }
    agentSnapshotTask = Task { [weak self] in
      let snapshot = await monitor.snapshot()
      guard let self else { return }
      self.agentSnapshotTask = nil
      if !Task.isCancelled { self.receiveAgentSnapshot(snapshot) }
    }
  }
  private func receiveAgentSnapshot(_ snapshot: ViewState) {
    state = snapshot
    cleanupQueued = FileManager.default.fileExists(
      atPath: Store.defaultRoot.appendingPathComponent("review-request").path)
    pressure = Native().memoryPressure()
    onUpdate?()
    schedule()
  }
  func refresh() {
    guard !working, !observationSuspended, !observationStopped, let monitor else { return }
    working = true
    Task {
      _ = await monitor.refresh()
      state = await monitor.snapshot()
      cleanupQueued = FileManager.default.fileExists(
        atPath: Store.defaultRoot.appendingPathComponent("review-request").path)
      pressure = Native().memoryPressure()
      working = false
      guard !observationSuspended, !observationStopped else { return }
      if let selected = selection { selection = state.findings.first { $0.id == selected.id } }
      if state.error == nil {
        do {
          if state.catalog.preferences.notifications {
            try await deliverFindingNotification(
              next: { try await monitor.findingNotification() },
              send: { proposal in
                try await FindingNotifications.deliver(
                  proposal, details: self.state.catalog.preferences.notificationDetails == true)
              },
              record: { try await monitor.findingNotificationDelivered($0) })
          }
        } catch { message = "Notification delivery unavailable: \(error.localizedDescription)" }

      }
      guard !observationSuspended, !observationStopped else { return }
      onUpdate?()
      schedule()
      Task {
        guard !observationSuspended, !observationStopped else { return }
        await monitor.worktreeTick()
      }
      if let runtime = autopilotRuntime {
        autopilot = await runtime.tick()
      } else if accessReady && state.error == nil && !state.partial {
        // Observation continues on its own timer while a bounded review runs.
        runScheduledHunt()
      }
    }
  }
  private func deliverFindingNotification(
    next: () async throws -> CleanupProposal?,
    send: (CleanupProposal) async throws -> Void,
    record: (CleanupProposal) async throws -> Void
  ) async throws {
    guard !observationSuspended, !observationStopped, !notificationDeliveryInFlight else { return }
    notificationDeliveryInFlight = true
    defer { notificationDeliveryInFlight = false }
    guard let proposal = try await next(), !observationSuspended, !observationStopped else {
      return
    }
    try await send(proposal)
    // A successful delivery must be recorded even if sleep/shutdown happened
    // while the system notification service was answering.
    try await record(proposal)
  }
  private func receiveReviewState(includeHunt: Bool = true) async {
    if let reviewer { machineReview = await reviewer.snapshot() }
    if !demo && includeHunt {
      huntSnapshot = try? HuntSnapshot.load(root: Store.defaultRoot)
      if let monitor { huntSnapshot?.includeMonitorReceipts(await monitor.snapshot()) }
    }
    cleanupQueued = FileManager.default.fileExists(
      atPath: Store.defaultRoot.appendingPathComponent("review-request").path)
  }
  private func schedule() {
    guard !observationSuspended, !observationStopped else { return }
    let tolerance = min(10, state.interval / 6)
    // Read-only agent traffic must never push observation or notification delivery
    // into the future. A shorter verification cadence may bring it forward.
    if let timer, timer.isValid,
      timer.fireDate <= Date().addingTimeInterval(state.interval)
    {
      timer.tolerance = min(timer.tolerance, tolerance)
      return
    }
    timer?.invalidate()
    let next = Timer(timeInterval: state.interval, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        #if DEBUG
          self?.timerDispatchForProof?()
        #endif
        self?.refresh()
      }
    }
    next.tolerance = tolerance
    // MainActor execution does not select a Foundation run loop. Attach explicitly,
    // and keep observing during AppKit menu tracking and modal interactions.
    RunLoop.main.add(next, forMode: .common)
    timer = next
  }
  func shutdownWorktrees() async {
    observationStopped = true
    timer?.invalidate()
    await monitor?.shutdownWorktrees()
  }
  func suspend() {
    observationSuspended = true
    timer?.invalidate()
    Task { try? await monitor?.checkpoint() }
  }
  func wake() {
    guard !observationStopped else { return }
    observationSuspended = false
    Task {
      await monitor?.resetContinuity()
      refresh()
    }
  }
  func choose(_ f: Finding) {
    selection = f
    preview = false
    technical = []
    message = nil
  }
  func protect() {
    guard let selected = selection else { return }
    if demo {
      state.findings.removeAll { $0.id == selected.id }
      selection = nil
      message = "Demo protection applied."
      return
    }
    Task {
      do {
        try await monitor?.protect(selected)
        state = await monitor?.snapshot() ?? state
        selection = nil
        message = "Protected this executable, including future instances."
      } catch { message = error.localizedDescription }
    }
  }
  func snooze() {
    guard let selected = selection else { return }
    if demo {
      state.findings.removeAll { $0.id == selected.id }
      selection = nil
      return
    }
    Task {
      do {
        try await monitor?.snooze(selected)
        state = await monitor?.snapshot() ?? state
        selection = nil
        message = "Notifications snoozed for these identities for 24 hours."
      } catch { message = error.localizedDescription }
    }
  }
  func inspect() {
    guard let f = selection else { return }
    Task {
      technical =
        await monitor?.details(f) ?? [
          "Demo process · synthetic identity · 4 descriptors · no live inspection"
        ]
    }
  }
  func clean() {
    guard let f = selection, !working else { return }
    working = true
    if demo {
      message = "Demo only: no process was signaled."
      preview = false
      working = false
      return
    }
    Task {
      do {
        message = try await monitor?.cleanup(f)
        state = await monitor?.snapshot() ?? state
        selection = nil
        tab = "History"
      } catch { message = error.localizedDescription }
      working = false
      preview = false
      schedule()
    }
  }
  func setAutomatic(_ enabled: Bool) {
    guard !enabled || accessReady else {
      message = state.fullDiskAccess.detail
      return
    }
    do {
      guard var config = try MachineReviewConfiguration.load(root: Store.defaultRoot) else {
        message = "Run BurnZombies setup to select an installed harness."
        return
      }
      config.enabled = enabled
      try config.save(root: Store.defaultRoot)
      machineReviewEnabled = enabled
      if enabled {
        Task {
          try? await reviewer?.resume()
          await receiveReviewState()
          runHunt(manual: false)
        }
      }
    } catch { message = error.localizedDescription }
  }
  func setNotifications(_ enabled: Bool) {
    if enabled && !demo {
      Task {
        do {
          let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert
          ])
          applyNotificationAuthorization(allowed)
        } catch {
          notificationPermissionError = error.localizedDescription
          message = notificationPermissionError
        }
      }
    } else {
      var p = state.catalog.preferences
      p.notifications = enabled
      save(p)
    }
  }
  private func applyNotificationAuthorization(_ allowed: Bool) {
    var p = state.catalog.preferences
    p.notifications = allowed
    save(p)
    if allowed {
      if message == notificationPermissionError { message = nil }
      notificationPermissionError = nil
    } else {
      notificationPermissionError =
        "Notifications remain off. You can allow them in System Settings."
      message = notificationPermissionError
    }
  }
  private func save(_ p: Preferences) {
    if demo {
      state.catalog.preferences = p
      return
    }
    Task {
      do {
        try await monitor?.updatePreferences(p)
        state = await monitor?.snapshot() ?? state
      } catch { message = error.localizedDescription }
    }
  }
  func unprotect(_ path: String) {
    Task {
      do {
        try await monitor?.removeProtection(path)
        state = await monitor?.snapshot() ?? state
      } catch { message = error.localizedDescription }
    }
  }
  func login(_ enabled: Bool) {
    let item = SMAppService.mainApp
    do {
      try StartAtLogin.choose(
        enabled, root: Store.defaultRoot, register: { try item.register() },
        unregister: { try item.unregister() })
      objectWillChange.send()
    } catch { message = "Login item could not be changed: \(error.localizedDescription)" }
  }
  /// A fresh install starts at login. This runs before the observer saves its first catalog,
  /// which is how an update from an older version tells itself apart from a new install.
  private func startAtLoginOnFirstLaunch() {
    guard
      StartAtLogin.applies(
        bundle: Bundle.main.bundleURL, environment: ProcessInfo.processInfo.environment)
    else { return }
    let item = SMAppService.mainApp
    let outcome = StartAtLogin.decideAtLaunch(
      root: Store.defaultRoot, isEnabled: { item.status == .enabled },
      register: { try item.register() })
    if case .refused(let reason) = outcome {
      message = "Start at login could not be turned on: \(reason)"
    }
  }
  // MARK: Autopilot commands
  // Each sends its AutopilotCommand through `autopilotRunner` and shows the snapshot it returns.
  // With no runner (demo and offscreen proofs) the same change is applied in memory so the
  // windows visibly react. A real model without a runner changes nothing and says so.
  /// `q` is the question as its card was drawn, so the answer carries the risks the owner saw.
  /// What the owner spared or unspared on the card (`sparing`, `releasing`) goes first, in the same
  /// task, so a Spare still on its way can't be overtaken by the Yes.
  func answer(
    _ q: AutopilotQuestion, _ a: AutopilotAnswer, sparing spared: [String] = [],
    releasing released: [String] = []
  ) {
    var commands: [AutopilotCommand] = released.map { AutopilotCommand.unkeep(itemID: $0) }
    commands += spared.map { AutopilotCommand.keep(itemID: $0) }
    commands.append(.answer(questionID: q.id, answer: a, risks: q.risks))
    sendAutopilot(commands) { AutopilotLocal.answer(&$0, question: q, answer: a, now: Date()) }
  }
  func burnNow(_ e: AutopilotEntry) {
    sendAutopilot(.burnNow(itemID: e.id)) { AutopilotLocal.burnNow(&$0, entry: e, now: Date()) }
  }
  /// Keep forever in Findings, Spare in Teach BZ. `finished` says why it couldn't be done, or nil.
  func keepForever(_ e: AutopilotEntry, finished: (@MainActor (String?) -> Void)? = nil) {
    sendAutopilot(
      [.keep(itemID: e.id)], local: { AutopilotLocal.keep(&$0, entry: e) }, finished: finished)
  }
  /// Unspare in Teach BZ: the owner's keep goes, and BZ decides about it again.
  func unkeep(_ e: AutopilotEntry, finished: (@MainActor (String?) -> Void)? = nil) {
    sendAutopilot(
      [.unkeep(itemID: e.id)], local: { AutopilotLocal.unkeep(&$0, entry: e) }, finished: finished)
  }
  func restore(_ r: AutopilotReceipt) {
    sendAutopilot(.restore(receiptID: r.id)) { AutopilotLocal.restore(&$0, receipt: r, now: Date()) }
  }
  func forgetRule(_ r: AutopilotRule) {
    sendAutopilot(.forgetRule(ruleID: r.id)) { AutopilotLocal.forget(&$0, rule: r) }
  }
  /// Forgets every lesson of a group, with the answers they were made from.
  func forgetLesson(_ group: AutopilotLessonGroup) {
    let ids = group.ruleIDs
    sendAutopilot(.forgetLesson(ruleIDs: ids)) { AutopilotLocal.forgetLesson(&$0, ruleIDs: ids) }
  }
  /// "Good call": the owner agrees with what BZ did on its own.
  func tellGood(_ tell: AutopilotTell) {
    guard tellActions[tell.id] == nil else { return }
    tellActions[tell.id] = .good
    tellProblems[tell.id] = nil
    sendAutopilot(
      .tellGood(id: tell.id), local: { AutopilotLocal.tellGood(&$0, id: tell.id) },
      finished: { [weak self] problem in
        self?.tellActions[tell.id] = nil
        self?.tellProblems[tell.id] = problem
      })
  }
  /// "Undo": the owner takes back what BZ did on its own. Copies come back over a few moments, so
  /// the tell shows as under way until the engine answers.
  func tellUndo(_ tell: AutopilotTell) {
    guard tellActions[tell.id] == nil else { return }
    tellActions[tell.id] = .undo
    tellProblems[tell.id] = nil
    sendAutopilot(
      .tellUndo(id: tell.id), local: { AutopilotLocal.tellUndo(&$0, id: tell.id, now: Date()) },
      finished: { [weak self] problem in
        self?.tellActions[tell.id] = nil
        self?.tellProblems[tell.id] = problem
      })
  }
  /// OK on what an Undo left the owner to read, such as a copy that couldn't come back: the tell
  /// leaves Teach BZ.
  func tellSeen(_ tell: AutopilotTell) {
    guard tellActions[tell.id] == nil else { return }
    tellActions[tell.id] = .seen
    tellProblems[tell.id] = nil
    sendAutopilot(
      .tellSeen(id: tell.id), local: { AutopilotLocal.tellSeen(&$0, id: tell.id) },
      finished: { [weak self] problem in
        self?.tellActions[tell.id] = nil
        self?.tellProblems[tell.id] = problem
      })
  }
  /// Settings → Autopilot → Act on its own when sure.
  func setActsOnItsOwn(_ acts: Bool) {
    sendAutopilot(.setActsOnItsOwn(acts)) { $0.actsOnItsOwn = acts }
  }
  func setStarter(_ id: String, enabled: Bool) {
    sendAutopilot(.setStarter(ruleID: id, enabled: enabled)) {
      AutopilotLocal.setStarter(&$0, id: id, enabled: enabled)
    }
  }
  /// The switch moves at once, even while the engine is busy with a burn pass. If the engine
  /// can't save the change, it moves back and the footer says why.
  func setAutopilot(enabled: Bool) {
    let before = autopilot.sweep.enabled
    autopilot.sweep.enabled = enabled
    sendAutopilot(.setEnabled(enabled), local: { $0.sweep.enabled = enabled }) { [weak self] reason in
      if reason != nil { self?.autopilot.sweep.enabled = before }
    }
  }
  /// Look-only holds every burn BZ would make on its own; turning it off starts burning.
  func setLookOnly(_ on: Bool) {
    sendAutopilot(.setLookOnly(on)) { $0.sweep.lookOnly = on ? true : nil }
  }
  func setSweepInterval(minutes: Int) {
    sendAutopilot(.setInterval(minutes: minutes)) { $0.sweep.intervalMinutes = minutes }
  }
  func resetTraining() {
    sendAutopilot(.resetTraining) { AutopilotLocal.reset(&$0) }
  }
  func sweepNow() {
    sendAutopilot(.sweepNow) { AutopilotLocal.sweepNow(&$0, now: Date()) }
  }
  static let keyAllowed = "Thanks. Old copies can burn again."
  /// The menu's Allow while old copies wait for the backup key: macOS asks the owner now, right
  /// after the click, and what waited burns once it can. The card says macOS is asking meanwhile.
  func allowRecoveryKey() {
    guard autopilot.recoveryKey?.asking != true else { return }
    autopilot.recoveryKey?.asking = true
    sendAutopilot(.allowRecoveryKey, local: { $0.recoveryKey = nil }) { [weak self] reason in
      if reason == nil {
        self?.message = Self.keyAllowed
      } else {
        self?.autopilot.recoveryKey?.asking = false
      }
    }
  }
  static let couldntFinish = "Autopilot couldn't finish that. Try again in a moment."
  /// `finished` runs once the command is done, with why the engine couldn't do it, or nil. The
  /// reason is also the footer's message.
  private func sendAutopilot(
    _ command: AutopilotCommand, local: (inout AutopilotSnapshot) -> Void,
    finished: (@MainActor (String?) -> Void)? = nil
  ) {
    sendAutopilot([command], local: local, finished: finished)
  }
  /// Several commands, one after another in one task, so none can overtake another; the snapshot
  /// after the last one shows. The first that fails stops the rest.
  private func sendAutopilot(
    _ commands: [AutopilotCommand], local: (inout AutopilotSnapshot) -> Void,
    finished: (@MainActor (String?) -> Void)? = nil
  ) {
    if let runner = autopilotRunner {
      Task { [weak self] in
        do {
          var next: AutopilotSnapshot?
          for command in commands { next = try await runner(command) }
          if let next { self?.autopilot = next }
          finished?(nil)
        } catch {
          let said: String = error.localizedDescription
          let reason: String = said.isEmpty ? Self.couldntFinish : said
          self?.message = reason
          finished?(reason)
        }
      }
      return
    }
    guard demo else {
      let reason = "Autopilot isn't connected yet."
      message = reason
      finished?(reason)
      return
    }
    var next = autopilot
    local(&next)
    autopilot = next
    finished?(nil)
  }
  func quit() {
    Task {
      do { try await monitor?.checkpoint() } catch {
        message = "Could not save state: \(error.localizedDescription)"
      }
      NSApp.terminate(nil)
    }
  }
}

private let ember = Color(red: 0.78, green: 0.28, blue: 0.09)
private func bytes(_ n: UInt64) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .memory)
}
private func color(_ d: Disposition) -> Color {
  switch d {
  case .eligible: return ember
  case .investigate: return .orange
  case .protected: return .secondary
  case .healthy: return .green
  }
}
private func status(_ d: Disposition) -> String {
  switch d {
  case .eligible: return "READY TO REVIEW"
  case .investigate: return "WORTH A LOOK"
  case .protected: return "PROTECTED"
  case .healthy: return "HEALTHY"
  }
}

struct Dashboard: View {
  @StateObject private var reviewerSettings: ReviewSettingsModel
  @StateObject private var huntSettings: HuntSettingsModel
  @ObservedObject var model: AppModel
  /// Proofs pass scratch-folder models so rendering never reads the real state folder.
  init(
    model: AppModel, reviewerSettings: ReviewSettingsModel? = nil,
    huntSettings: HuntSettingsModel? = nil
  ) {
    self.model = model
    _reviewerSettings = StateObject(wrappedValue: reviewerSettings ?? ReviewSettingsModel())
    _huntSettings = StateObject(wrappedValue: huntSettings ?? HuntSettingsModel())
  }
  var eligible: Int { model.state.findings.filter { $0.disposition == .eligible }.count }
  var attention: Int {
    model.state.findings.filter { $0.disposition == .eligible || $0.disposition == .investigate }
      .count
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "flame.fill").font(.title2).foregroundStyle(ember)
        VStack(alignment: .leading, spacing: 2) {
          Text("BurnZombies").font(.headline)
          Text(model.demo ? "DEMO · synthetic data" : "Keep your work running").font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.working { ProgressView().controlSize(.small) }
        Button {
          model.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.clickPointer().buttonStyle(.borderless).help("Refresh observations").accessibilityLabel(
          "Refresh observations")
      }.padding(20)
      Divider()
      if model.autopilotAvailable && model.selection == nil {
        AutopilotMenuSection(model: model)
        Divider()
      }
      if let error = model.state.error {
        Label(error, systemImage: "exclamationmark.shield").font(.callout).padding()
          .foregroundStyle(.red)
      }
      if let selected = model.selection {
        detail(selected)
      } else {
        Picker("View", selection: $model.tab) {
          Text("Overview").tag("Overview")
          Text("History").tag("History")
          Text("Settings").tag("Settings")
        }.clickPointer().pickerStyle(.segmented).padding([.horizontal, .top], 16)
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if model.tab == "Overview" {
              overview
            } else if model.tab == "History" {
              history
            } else {
              settings
            }
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(
          .vertical, 10
        ).frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      HStack {
        Label(
          model.demo
            ? "Preview mode"
            : model.accessReady ? "Agent-led cleanup" : "Setup required",
          systemImage: "lock.shield"
        ).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Quit") { model.quit() }.clickPointer().buttonStyle(.borderless).font(.caption)
      }.padding(14)
    }.frame(width: 440, height: 660).background(Color(nsColor: .windowBackgroundColor)).tint(ember)
  }
  var overview: some View {
    Group {
      if !model.accessReady { FullDiskAccessView(model: model) }
      VStack(alignment: .leading, spacing: 8) {
        Text(
          !model.accessReady
            ? "One step before cleanup."
            : attention == 0
              ? "Room to keep going." : eligible > 0 ? "A few loose ends." : "Worth a closer look."
        ).font(.system(size: 25, weight: .semibold, design: .rounded))
        Text(
          !model.accessReady
            ? "Turn on Full Disk Access to run background reviews and cover the places macOS protects."
            : attention == 0
              ? "Your connected agent reviews live evidence and decides what is safe to stop."
              : "\(attention) activities need a look. \(eligible) have enough ownership evidence to review for cleanup."
        ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 0) {
        metric("\(model.state.catalog.lifetimeVerified)", "Helpers verified stopped")
        Divider().frame(height: 40)
        metric("\(model.state.catalog.lifetimeActions)", "Verified cleanups")
      }.padding(.vertical, 14).background(
        .quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
      HStack {
        Text("ACTIVITIES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        Text("\(model.state.processCount) processes observed").font(.caption).foregroundStyle(
          .secondary)
      }
      if model.state.findings.isEmpty && model.accessReady {
        VStack(alignment: .leading, spacing: 10) {
          Label("Your agent takes it from here", systemImage: "leaf").font(.headline)
          Text(
            "BurnZombies watches this Mac across every project and session. Background reviews use your selected harness while the app records verified impact."
          ).font(.callout).foregroundStyle(.secondary)
          Text(
            "Use Hunt Zombies for a deep review now. Scheduled hunts keep watch between runs."
          ).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
          .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
      }
      ForEach(model.state.findings.prefix(30)) { f in
        Button {
          model.choose(f)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            Image(
              systemName: f.disposition == .protected
                ? "shield" : f.disposition == .eligible ? "sparkle" : "waveform.path"
            ).foregroundStyle(color(f.disposition)).frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
              Text(status(f.disposition)).font(.system(size: 9, weight: .bold)).foregroundStyle(
                color(f.disposition))
              Text(f.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
              Text(f.reason).font(.callout).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
              Text("\(f.members.count) helpers · \(bytes(f.rss)) resident footprint").font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }.clickPointer().buttonStyle(.plain).accessibilityLabel("Review \(f.title)")
      }
      Text("See Impact for local responsiveness.").font(.caption).foregroundStyle(.secondary)
      if model.state.partial || model.state.hiddenCount > 0 {
        Text(
          "Visibility is limited. \(model.state.hiddenCount) process reads were unavailable. \(model.state.partial ? "Cleanup is paused because the scan is incomplete." : "Other users and restricted processes are outside monitoring scope.")"
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  func metric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
  }
  func detail(_ f: Finding) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        model.selection = nil
        model.preview = false
        model.message = nil
      } label: {
        Label("All activities", systemImage: "chevron.left")
      }.clickPointer().buttonStyle(.borderless).padding(20)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(status(f.disposition)).font(.caption.weight(.semibold)).foregroundStyle(
            color(f.disposition))
          Text(f.title).font(.title2.weight(.semibold))
          Text(f.reason).font(.body)
          Text(
            "\(f.members.count) \(f.members.count == 1 ? "helper" : "helpers") · \(bytes(f.rss)) resident footprint"
          ).font(.callout)
            .foregroundStyle(.secondary)
          Divider()
          Text("Why this finding exists").font(.headline)
          ForEach(f.evidence, id: \.self) {
            Text("• " + $0).font(.callout).fixedSize(horizontal: false, vertical: true)
          }
          Text(f.uncertainty).font(.callout).foregroundStyle(.secondary)
          if model.preview {
            VStack(alignment: .leading, spacing: 10) {
              Text("Review the stop request").font(.headline)
              Text(
                "Send SIGTERM to \(f.members.count) explicitly registered helpers. Allow 15 seconds to exit, then watch 120 seconds for reappearance. Termination cannot be undone. No force kill or file deletion."
              ).font(.callout)
              Text(
                "Use the owning tool's supported shutdown first when it is available. These helpers must be disposable; idle CPU cannot prove that work is safe to discard."
              ).font(.caption).foregroundStyle(.secondary)
              Button("Request graceful stop") { model.clean() }.clickPointer().buttonStyle(
                .borderedProminent
              )
              .disabled(model.working)
            }.padding(14).background(ember.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          } else if f.disposition == .eligible {
            Button("Preview cleanup") { model.preview = true }.clickPointer().buttonStyle(
              .borderedProminent)
          }
          HStack {
            Button("Protect executable") { model.protect() }.clickPointer()
            Button("Snooze 24 hours") { model.snooze() }.clickPointer()
          }.disabled(f.members.isEmpty)
          DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 10) {
              Button("Inspect descriptors") { model.inspect() }.clickPointer()
              ForEach(model.technical, id: \.self) {
                Text($0).font(.caption.monospaced()).textSelection(.enabled)
              }
            }.padding(.top, 8)
          }.disclosureGroupStyle(ClickDisclosureStyle()).font(.callout)
        }.padding(.horizontal, 20).padding(.bottom, 20).frame(
          maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  var history: some View {
    Group {
      Text("Wins with receipts.").font(.title2.weight(.semibold))
      Text(
        "A cleanup counts only after exact targets exit and no matching executable returns during the observation window."
      ).font(.callout).foregroundStyle(.secondary)
      if model.state.catalog.events.isEmpty {
        Label("No cleanup attempts yet", systemImage: "clock").padding(.vertical, 24)
          .foregroundStyle(.secondary)
      }
      ForEach(model.state.catalog.events.reversed()) { e in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(e.label).font(.headline)
            Spacer()
            Text(e.outcome.capitalized).font(.caption.weight(.semibold)).foregroundStyle(
              e.outcome == "verified" ? .green : .secondary)
          }
          Text(e.date, style: .date).font(.caption).foregroundStyle(.secondary)
          Text(e.detail).font(.callout)
          Text(
            "\(e.verifiedCount) verified helpers · \(bytes(e.residentBefore)) pre-stop resident footprint"
          ).font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
      }
      Text(
        "Memory released uses the resident footprint of verified exits; shared pages can overlap. Impact shows a local command-launch comparison when available. CPU time saved accumulates from the observed pre-stop CPU rate during observed awake time after verified exit. Agent speed is shown only when the timing samples establish a stable improvement."
      ).font(.caption).foregroundStyle(.secondary)
      Text(
        "Detailed history: 30 days, up to 500 attempts. Lifetime counts retain only verified outcomes."
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  var settings: some View {
    Group {
      FullDiskAccessView(model: model)
      if model.autopilotAvailable {
        AutopilotSettingsView(model: model)
      } else {
        Text("Quiet by default.").font(.title2.weight(.semibold))
        Text("Your whole Mac. One observer.").font(.headline)
        Text(
          "BurnZombies watches processes across all projects and sessions. Your selected harness reviews buildup in the background, even with no active chat. Active and uncertain work stays running."
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(
          model.accessReady
            ? model.machineReview.detail
            : "Background reviews wait until Full Disk Access is available."
        ).font(.caption).foregroundStyle(.secondary)
        if model.accessReady && model.machineReview.phase == "paused" {
          Button("Resume scheduled hunts") { model.setAutomatic(true) }.clickPointer()
        }
        // Autopilot replaces the evidence-led hunt schedule when it is available.
        HuntSettingsView(settings: huntSettings, onSaved: model.reloadReviewConfiguration)
          .disabled(model.demo)
      }
      ReviewSettingsView(settings: reviewerSettings).disabled(model.demo)
      UsageHistoryView().disabled(model.demo)
      DiskSettingsView(accessReady: model.accessReady).disabled(model.demo)
      Toggle(
        "Grouped notifications",
        isOn: Binding(
          get: { model.state.catalog.preferences.notifications }, set: model.setNotifications)
      ).clickPointer()
      Text(
        "Off by default. A finding notifies once; materially worse impact can notify again after a day. Snoozed and protected activities stay quiet."
      ).font(.caption).foregroundStyle(.secondary)
      Toggle(
        "Start at login",
        isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: model.login)
      ).clickPointer().disabled(model.demo)
      Text(
        "On for a new install, so Autopilot keeps running after a restart. Updates keep your choice."
      ).font(.caption).foregroundStyle(.secondary)
      Divider()
      Text("Protected executables").font(.headline)
      if model.state.catalog.preferences.protectedExecutables.isEmpty {
        Text(
          "App bundles, system services, browsers, device tools, recordings, transfers, and credential tools are always protected."
        ).font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(model.state.catalog.preferences.protectedExecutables).sorted(), id: \.self) {
        p in
        HStack {
          Text((p as NSString).lastPathComponent).font(.callout)
          Spacer()
          Button("Remove") { model.unprotect(p) }.clickPointer()
        }
      }
      Divider()
      Text("Local and bounded").font(.headline)
      Text(
        "No BurnZombies account or analytics. Reviews use your selected harness's existing account and usage allowance. Process evidence can reach that harness's model provider. No command arguments or environment collected. At most 4,096 process records, eight samples each."
      ).font(.caption).foregroundStyle(.secondary)
      Text(
        String(
          format: "Last scan %.1f ms · checkpoint %@", model.state.scanMS,
          bytes(UInt64(model.state.checkpointBytes)))
      ).font(.caption.monospaced()).foregroundStyle(.secondary)
      if let observed = model.state.catalog.lastSample {
        Text("Last observation \(observed.formatted(date: .omitted, time: .standard))")
          .font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      Link(
        "Build, safety, and uninstall guide",
        destination: URL(string: "https://github.com/swordfish444/BurnZombies")!
      ).clickPointer().font(.callout)
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var item: NSStatusItem!
  var popover: NSPopover!
  var window: NSWindow?
  var worktreeWindow: NSWindow?
  var auditWindow: NSWindow?
  var menuPreviewWindow: NSWindow?
  var huntWindow: NSWindow?
  var findingsWindow: NSWindow?
  var autopilotFindingsWindow: NSWindow?
  var teachWindow: NSWindow?
  var findingNotifications: FindingNotifications?
  var model: AppModel!
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    BurnTheme.registerFonts()
    model = AppModel()
    model.openImpact = { [weak self] in self?.showImpact("Impact") }
    model.openLog = { [weak self] in self?.showImpact("Burn Log") }
    model.openSettings = { [weak self] in
      self?.model.selection = nil
      self?.model.tab = "Settings"
      self?.showAudit()
    }
    model.openWorktrees = { [weak self] in self?.showWorktrees() }
    model.openWorktreeID = { [weak self] id in self?.showWorktrees(selectedID: id) }
    model.openFindings = { [weak self] in self?.showFindings() }
    model.openAdvancedFindings = { [weak self] in self?.showAdvancedFindings() }
    model.openTeach = { [weak self] in self?.showTeach() }
    findingNotifications = FindingNotifications { [weak self] id, revision, action in
      self?.model.notificationAction(id: id, revision: revision, action: action)
    }
    model.openAudit = { [weak self] in self?.showAudit() }
    model.openHunt = { [weak self] in self?.showHunt() }
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let icon = NSImage(
      contentsOf: Bundle.module.url(forResource: "EmberSkull", withExtension: "png")!)!
    icon.size = NSSize(width: 23, height: 23)
    item.button?.image = icon
    item.button?.toolTip = "BurnZombies"
    item.button?.setAccessibilityLabel("BurnZombies")
    item.button?.target = self
    item.button?.action = #selector(toggle)
    popover = NSPopover()
    popover.behavior = .transient
    popover.contentSize = MiniImpactView.size
    popover.contentViewController = NSHostingController(rootView: MiniImpactView(model: model))
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
    if CommandLine.arguments.contains("--show-worktrees") { showWorktrees() }
    if CommandLine.arguments.contains("--show-findings") { showFindings() }
    if CommandLine.arguments.contains("--show-advanced-findings") { showAdvancedFindings() }
    if CommandLine.arguments.contains("--show-teach") { showTeach() }
    if CommandLine.arguments.contains("--show-window") { showImpact("Impact") }
    if CommandLine.arguments.contains("--show-popover") { toggle() }
    if CommandLine.arguments.contains("--show-mini-window") {
      let panel = NSWindow(
        contentRect: NSRect(origin: .zero, size: MiniImpactView.size),
        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
      panel.title = "BurnZombies — Menu Preview"
      panel.titlebarAppearsTransparent = true
      panel.titleVisibility = .hidden
      panel.standardWindowButton(.closeButton)?.isHidden = true
      panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
      panel.standardWindowButton(.zoomButton)?.isHidden = true
      let hosting = NSHostingView(rootView: MiniImpactView(model: model))
      hosting.sizingOptions = []
      panel.contentView = hosting
      panel.setFrame(NSRect(origin: .zero, size: MiniImpactView.size), display: false)
      panel.center()
      panel.makeKeyAndOrderFront(nil)
      menuPreviewWindow = panel
    }
  }
  func showImpact(_ tab: String) {
    model.impactTab = tab
    popover?.performClose(nil)
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1008, height: 930),
        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered,
        defer: false)
      w.title = model.demo ? "BurnZombies — Demo" : "BurnZombies"
      w.titlebarAppearsTransparent = true
      w.titleVisibility = .hidden
      w.isMovableByWindowBackground = true
      w.isReleasedWhenClosed = false
      let hosting = NSHostingView(rootView: ImpactWindowView(model: model))
      hosting.sizingOptions = []
      w.contentView = hosting
      w.setFrame(NSRect(x: 0, y: 0, width: 1008, height: 930), display: false)
      w.center()
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showWorktrees(selectedID: String? = nil) {
    popover?.performClose(nil)
    if worktreeWindow == nil {
      worktreeWindow = WorktreesView.makeWindow(model: model, selectedID: selectedID)
    }
    if let selectedID {
      worktreeWindow?.contentView = WorktreesView.hostingView(model: model, selectedID: selectedID)
    }
    worktreeWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  /// The simple Findings window. Until an Autopilot engine is attached there is nothing for it
  /// to show, so the detailed window opens instead and the menu keeps working as before.
  func showFindings() {
    guard model.autopilotAvailable else {
      showAdvancedFindings()
      return
    }
    popover?.performClose(nil)
    if autopilotFindingsWindow == nil {
      autopilotFindingsWindow = AutopilotFindingsView.makeWindow(model: model)
    }
    autopilotFindingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showAdvancedFindings() {
    popover?.performClose(nil)
    if findingsWindow == nil {
      findingsWindow = FindingsView.makeWindow(model: model)
    }
    findingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showTeach() {
    popover?.performClose(nil)
    if teachWindow == nil {
      teachWindow = TeachView.makeWindow(model: model)
    }
    teachWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showAudit() {
    popover.performClose(nil)
    if auditWindow == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 660), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      w.title = "BurnZombies — Details"
      w.isReleasedWhenClosed = false
      w.contentView = NSHostingView(rootView: Dashboard(model: model))
      w.center()
      auditWindow = w
    }
    auditWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func showHunt() {
    popover?.performClose(nil)
    if huntWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 948, height: 860),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = "BurnZombies — Hunt Zombies"
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.contentMinSize = NSSize(width: 800, height: 760)
      let hosting = NSHostingView(rootView: HuntView(model: model))
      hosting.sizingOptions = []
      window.contentView = hosting
      window.center()
      huntWindow = window
    }
    model.setHuntProgressVisible(true)
    huntWindow?.deminiaturize(nil)
    huntWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === huntWindow {
      model.setHuntProgressVisible(false)
    }
  }
  func windowDidMiniaturize(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === huntWindow {
      model.setHuntProgressVisible(false)
    }
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === huntWindow {
      model.setHuntProgressVisible(
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }
  }
  @objc func toggle() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = item.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
  func applicationDidResignActive(_ notification: Notification) {
    model?.accessSetupDidResignActive()
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    model?.accessSetupDidBecomeActive()
  }
  @objc func sleeping() { model.suspend() }
  @objc func waking() { model.wake() }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    // Background connections and installers can send reopen events. Only an explicit
    // menu-bar click or window action may present UI and take keyboard focus.
    return false
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await model.shutdownWorktrees()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#if DEBUG
  extension AppModel {
    /// Exercise the real snapshot callback and Foundation timer without an observer or window.
    func proveObservationSchedule() async throws {
      guard demo else { throw StoreError.message("Scheduling proof requires a demo model") }
      defer { timer?.invalidate() }
      var dispatches = 0
      timerDispatchForProof = { dispatches += 1 }
      state.interval = 0.5
      schedule()
      guard let original = timer else { throw StoreError.message("Observer timer missing") }
      for _ in 0..<5 {
        receiveAgentSnapshot(state)
        guard timer === original, original.isValid else {
          throw StoreError.message("Read-only status snapshots postponed the observer timer")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      try await Task.sleep(for: .milliseconds(600))
      guard !original.isValid, dispatches == 1 else {
        throw StoreError.message("Observer timer never dispatched after status traffic")
      }
      state.interval = 60
      receiveAgentSnapshot(state)
      guard let long = timer, long.isValid, long !== original else {
        throw StoreError.message("A fired timer was not replaced")
      }
      let longDeadline = long.fireDate
      state.interval = 15
      receiveAgentSnapshot(state)
      guard let urgent = timer, urgent !== long, urgent.fireDate < longDeadline else {
        throw StoreError.message("Exit verification did not shorten the observer deadline")
      }
      state.interval = 60
      receiveAgentSnapshot(state)
      guard timer === urgent, urgent.tolerance <= 2.5 else {
        throw StoreError.message("A later snapshot postponed an earlier observer deadline")
      }
      suspend()
      guard !urgent.isValid else {
        throw StoreError.message("Suspend left the observer timer active")
      }
      receiveAgentSnapshot(state)
      guard timer?.isValid != true else {
        throw StoreError.message("A late snapshot revived suspended observation")
      }
      wake()
      state.interval = 0.05
      working = true
      receiveAgentSnapshot(state)
      try await Task.sleep(for: .milliseconds(150))
      guard dispatches == 2, timer?.isValid == false else {
        throw StoreError.message("Busy observation did not consume its one-shot timer")
      }
      working = false
      receiveAgentSnapshot(state)
      guard timer?.isValid == true else {
        throw StoreError.message("Completed snapshot did not rearm observation")
      }
      await shutdownWorktrees()
      receiveAgentSnapshot(state)
      wake()
      receiveAgentSnapshot(state)
      guard timer?.isValid != true else {
        throw StoreError.message("Shutdown observation was revived")
      }
      applyNotificationAuthorization(false)
      guard message == notificationPermissionError, !state.catalog.preferences.notifications else {
        throw StoreError.message("Notification refusal was not shown")
      }
      applyNotificationAuthorization(true)
      guard message == nil, state.catalog.preferences.notifications else {
        throw StoreError.message("Successful permission kept its previous refusal")
      }
      applyNotificationAuthorization(false)
      message = "Unrelated recovery failure"
      applyNotificationAuthorization(true)
      guard message == "Unrelated recovery failure" else {
        throw StoreError.message("Permission success hid an unrelated failure")
      }
      let proposal = CleanupProposal(
        action: .worktree, resources: ["synthetic"], revision: "proof", title: "Synthetic finding",
        detail: "Offscreen notification lifecycle proof", recovery: "No files changed", ready: true)
      let overlapping = AppModel(demo: true)
      var notificationSends = 0
      try await overlapping.deliverFindingNotification(
        next: { proposal },
        send: { _ in
          notificationSends += 1
          try await overlapping.deliverFindingNotification(
            next: { proposal }, send: { _ in notificationSends += 1 }, record: { _ in })
        }, record: { _ in })
      guard notificationSends == 1 else {
        throw StoreError.message("Overlapping observation delivered the same notification twice")
      }
      do {
        try await overlapping.deliverFindingNotification(
          next: { proposal }, send: { _ in throw StoreError.message("Synthetic send failure") },
          record: { _ in })
      } catch {}
      try await overlapping.deliverFindingNotification(
        next: { proposal }, send: { _ in notificationSends += 1 }, record: { _ in })
      guard notificationSends == 2 else {
        throw StoreError.message("Failed notification delivery blocked later notifications")
      }
      for stopping in [false, true] {
        let beforeDelivery = AppModel(demo: true)
        var sent = 0
        var recorded = 0
        try await beforeDelivery.deliverFindingNotification(
          next: {
            if stopping {
              await beforeDelivery.shutdownWorktrees()
            } else {
              beforeDelivery.suspend()
            }
            return proposal
          }, send: { _ in sent += 1 }, record: { _ in recorded += 1 })
        guard sent == 0, recorded == 0 else {
          throw StoreError.message("Inactive observer delivered a late notification candidate")
        }
        let duringDelivery = AppModel(demo: true)
        try await duringDelivery.deliverFindingNotification(
          next: { proposal },
          send: { _ in
            sent += 1
            if stopping {
              await duringDelivery.shutdownWorktrees()
            } else {
              duringDelivery.suspend()
            }
          }, record: { _ in recorded += 1 })
        duringDelivery.receiveAgentSnapshot(duringDelivery.state)
        guard sent == 1, recorded == 1, duringDelivery.timer?.isValid != true else {
          throw StoreError.message(
            "Successful delivery lost its receipt or revived inactive observation")
        }
      }
      print(
        "PASS native timer dispatch under status traffic, urgent cadence, busy rearming, suspend/shutdown across notification awaits, and scoped permission messages"
      )
    }
  }
#endif
MainActor.assumeIsolated {
  let app = NSApplication.shared
  #if DEBUG
    if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--observer-schedule-proof" {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in
        do {
          try await AppModel(demo: true).proveObservationSchedule()
          exit(0)
        } catch {
          print("FAIL \(error.localizedDescription)")
          exit(1)
        }
      }
      app.run()
      exit(1)
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--findings-proof" {
      do {
        try findingsProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--autopilot-proof" {
      do {
        try autopilotProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--worktree-inventory-proof"
    {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in
        do {
          try await worktreeInventoryProof()
          exit(0)
        } catch {
          print("FAIL \(error.localizedDescription)")
          exit(1)
        }
      }
      app.run()
      exit(1)
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--worktree-view-proof" {
      do {
        try worktreeViewProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--hunt-proof" {
      do {
        try huntProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--hunt-scene-proof" {
      do {
        try huntSceneProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--access-banner-proof" {
      do {
        try accessBannerProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--settings-proof" {
      do {
        try settingsProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--impact-proof" {
      do {
        try impactProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--mini-proof" {
      do {
        try miniProof(output: CommandLine.arguments[2])
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
    if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--receipt-proof" {
      do {
        let catalog = try Store(root: URL(fileURLWithPath: CommandLine.arguments[2])).load()
        try miniProof(output: CommandLine.arguments[3], catalog: catalog)
        exit(0)
      } catch {
        print("FAIL \(error.localizedDescription)")
        exit(1)
      }
    }
  #endif
  let delegate = AppDelegate()
  app.delegate = delegate
  app.run()
}
