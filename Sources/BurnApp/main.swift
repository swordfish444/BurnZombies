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
      message = "Choose an AI in Settings before hunting."
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
  /// How long the Settings window's footer shows a message. Proofs make it short.
  var messageSeconds: Double = 8
  /// What the footer says is true for a moment. Anything lasting has its own place on the page.
  func settleMessage(_ shown: String) async {
    try? await Task.sleep(nanoseconds: UInt64(messageSeconds * 1_000_000_000))
    if !Task.isCancelled, message == shown { message = nil }
  }
  @Published var impactTab = "Impact"
  @Published var impactPeriod = ImpactPeriod.today
  /// The menu bar popup's own period, so its tabs never move the Impact window's.
  @Published var miniImpactPeriod = ImpactPeriod.today
  @Published var pressure = "—"
  var openImpact: (() -> Void)?
  var openLog: (() -> Void)?
  var openSettings: (() -> Void)?
  var openWorktrees: (() -> Void)?
  var openHunt: (() -> Void)?
  var openFindings: (() -> Void)?
  var openAdvancedFindings: (() -> Void)?
  var openTeach: (() -> Void)?
  var openWorktreeID: ((String) -> Void)?
  /// Autopilot as the windows see it. The engine replaces this after every sweep and command.
  @Published var autopilot = AutopilotSnapshot() {
    didSet { tellAboutNewQuestions() }
  }
  @Published var settingsPage = SettingsPage.home
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
    // Autopilot does the cleaning. The old cleaner, its cap and its scans stay off; a failure just
    // tries again at the next launch.
    try? Autopilot.retireDiskCleanup()
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
      if id == FindingNotifications.questionID {
        openTeach?()
        return
      }
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
      if state.error == nil {
        do {
          // With Autopilot, BZ tells the owner about its questions instead.
          if state.catalog.preferences.notifications && autopilotRuntime == nil {
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
    sendAutopilot(.restore(receiptID: r.id)) {
      AutopilotLocal.restore(&$0, receipt: r, now: Date())
    }
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
  /// Settings' one choice: how much BZ may do on its own.
  var autopilotLevel: AutopilotLevel {
    let sweep = autopilot.sweep
    if !sweep.enabled { return .off }
    if sweep.lookOnly == true { return .lookOnly }
    return autopilot.actsOnItsOwn ? .actWhenSure : .askFirst
  }
  /// The choice moves at once, and back if the engine can't save it. What holds burns goes first,
  /// so nothing slips through between the steps.
  func setAutopilotLevel(_ level: AutopilotLevel) {
    let before = (autopilot.sweep.enabled, autopilot.sweep.lookOnly, autopilot.actsOnItsOwn)
    let apply: (inout AutopilotSnapshot) -> Void = { snapshot in
      snapshot.sweep.enabled = level != .off
      switch level {
      case .off: break
      case .lookOnly: snapshot.sweep.lookOnly = true
      case .askFirst:
        snapshot.sweep.lookOnly = nil
        snapshot.actsOnItsOwn = false
      case .actWhenSure:
        snapshot.sweep.lookOnly = nil
        snapshot.actsOnItsOwn = true
      }
    }
    let commands: [AutopilotCommand]
    switch level {
    case .off: commands = [.setEnabled(false)]
    case .lookOnly: commands = [.setLookOnly(true), .setEnabled(true)]
    case .askFirst: commands = [.setActsOnItsOwn(false), .setLookOnly(false), .setEnabled(true)]
    case .actWhenSure: commands = [.setActsOnItsOwn(true), .setLookOnly(false), .setEnabled(true)]
    }
    apply(&autopilot)
    sendAutopilot(commands, local: apply) { [weak self] reason in
      guard reason != nil, let self else { return }
      self.autopilot.sweep.enabled = before.0
      self.autopilot.sweep.lookOnly = before.1
      self.autopilot.actsOnItsOwn = before.2
    }
  }
  /// The switch on a lesson in Settings. Off, it burns nothing until it's on again.
  func setLesson(_ group: AutopilotLessonGroup, on: Bool) {
    let ids = group.ruleIDs
    sendAutopilot(.setLesson(ruleIDs: ids, enabled: on)) { snapshot in
      for i in snapshot.lessons.indices where snapshot.lessons[i].id == group.id {
        snapshot.lessons[i].off = on ? nil : true
      }
    }
  }
  func neverTouch(path: String) {
    sendAutopilot(.neverTouch(path: path)) { snapshot in
      snapshot.neverTouch = Array(Set(snapshot.neverTouch).union([path])).sorted()
    }
  }
  func allowTouch(path: String) {
    sendAutopilot(.allowTouch(path: path)) { snapshot in
      snapshot.neverTouch.removeAll { $0 == path }
      snapshot.keptPaths.removeAll { $0 == path }
    }
  }
  private static let toldQuestionsKey = "BZToldQuestions"
  /// One notification for questions nobody was told about yet, never one per question or per look.
  private func tellAboutNewQuestions() {
    guard !demo, state.catalog.preferences.notifications else { return }
    let defaults = UserDefaults.standard
    let told = Set(defaults.stringArray(forKey: Self.toldQuestionsKey) ?? [])
    let open = autopilot.questions.filter(\.isOpen)
    guard let alert = AutopilotText.questionAlert(open, told: told) else { return }
    let keep = Set(open.map(\.id)).union(told)
    defaults.set(Array(keep.sorted().suffix(300)), forKey: Self.toldQuestionsKey)
    Task { try? await FindingNotifications.deliverQuestions(alert) }
  }
  /// Act on its own when sure.
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
  func resetTraining() {
    sendAutopilot(.resetTraining) { AutopilotLocal.reset(&$0) }
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
  lazy var appUpdates = AppUpdateSettingsModel(
    // Settings' header reads this. A demo has no update history, and proofs stay out of real state.
    root: demo
      ? FileManager.default.temporaryDirectory.appendingPathComponent("bz-demo-updates")
      : Store.defaultRoot
  ) { [weak self] plan in
    guard let self else { throw StoreError.message("The app is closing.") }
    let stopped = self.observationStopped
    self.observationStopped = true
    self.timer?.invalidate()
    do {
      try await self.reviewer?.prepareForAppUpdate()
      try await self.autopilotRuntime?.coordinator.prepareForAppUpdate()
      try await self.monitor?.prepareForAppUpdate()
      var request = plan
      request.reopenSettings = NSApp.isActive
      try request.save()
      try await AppUpdateHandoff.launch(request)
      NSApp.terminate(nil)
    } catch {
      await self.monitor?.resumeAfterAppUpdateFailure()
      await self.autopilotRuntime?.coordinator.resumeAfterAppUpdateFailure()
      await self.reviewer?.resumeAfterAppUpdateFailure()
      self.observationStopped = stopped
      if !stopped { self.refresh() }
      throw error
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var item: NSStatusItem!
  var popover: NSPopover!
  var window: NSWindow?
  var worktreeWindow: NSWindow?
  var settingsWindow: NSWindow?
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
      self?.model.settingsPage = .home
      self?.showSettings()
    }
    model.openWorktrees = { [weak self] in self?.showWorktrees() }
    model.openWorktreeID = { [weak self] id in self?.showWorktrees(selectedID: id) }
    model.openFindings = { [weak self] in self?.showFindings() }
    model.openAdvancedFindings = { [weak self] in self?.showAdvancedFindings() }
    model.openTeach = { [weak self] in self?.showTeach() }
    findingNotifications = FindingNotifications { [weak self] id, revision, action in
      self?.model.notificationAction(id: id, revision: revision, action: action)
    }
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
    if CommandLine.arguments.contains("--show-settings") { showSettings() }
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
  func showSettings() {
    popover.performClose(nil)
    if settingsWindow == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 440, height: 660), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      w.title = "BurnZombies — Settings"
      w.isReleasedWhenClosed = false
      w.contentView = NSHostingView(rootView: SettingsWindow(model: model))
      w.center()
      settingsWindow = w
    }
    settingsWindow?.makeKeyAndOrderFront(nil)
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
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--about-proof" {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in
        do {
          try await aboutSettingsProof(output: CommandLine.arguments[2])
          exit(0)
        } catch {
          print("FAIL \(error.localizedDescription)")
          exit(1)
        }
      }
      app.run()
      exit(1)
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--settings-layout-proof" {
      app.setActivationPolicy(.prohibited)
      Task { @MainActor in
        do {
          try settingsLayoutProof(output: CommandLine.arguments[2])
          exit(0)
        } catch {
          print("FAIL \(error.localizedDescription)")
          exit(1)
        }
      }
      app.run()
      exit(1)
    }
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
