import AppKit
import BurnCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor final class AppModel: ObservableObject {
  @Published var state = ViewState() {
    didSet {
      if didLoadState && state.catalog.lifetimeVerified > oldValue.catalog.lifetimeVerified {
        burnPulse += 1
      }
      didLoadState = true
    }
  }
  private var didLoadState = false
  @Published var burnPulse = 0
  @Published var demoBurnCount = 0
  func previewBurn() {
    guard demo else { return }
    demoBurnCount += 18
    burnPulse += 1
  }
  @Published var selection: Finding?
  @Published var tab = "Overview"
  @Published var preview = false
  @Published var working = false
  @Published var message: String?
  @Published var technical = [String]()
  @Published var impactTab = "Impact"
  @Published var pressure = "—"
  var openImpact: (() -> Void)?
  var openLog: (() -> Void)?
  var openSettings: (() -> Void)?
  var openAudit: (() -> Void)?
  let demo = CommandLine.arguments.contains("--demo")
  private var monitor: Monitor?
  private var timer: Timer?
  var onUpdate: (() -> Void)?
  init() {
    if demo {
      state = Demo.state()
      pressure = "Low"
      return
    }
    do { monitor = try Monitor() } catch {
      state.error = error.localizedDescription
      return
    }
    refresh()
  }
  func refresh() {
    guard !working, let monitor else { return }
    working = true
    Task {
      state = await monitor.refresh()
      pressure = Native().memoryPressure()
      working = false
      if let selected = selection { selection = state.findings.first { $0.id == selected.id } }
      if state.error == nil {
        do {
          if let text = try await monitor.notificationSummary() {
            let content = UNMutableNotificationContent()
            content.title = "A little attention could help"
            content.body = text
            try await UNUserNotificationCenter.current().add(
              UNNotificationRequest(identifier: "grouped-findings", content: content, trigger: nil))
          }
        } catch { message = "Notification delivery unavailable: \(error.localizedDescription)" }
        if state.catalog.preferences.automaticCleanup,
          let eligible = state.findings.first(where: { $0.disposition == .eligible })
        {
          do {
            message = try await monitor.cleanup(eligible, automatic: true)
            state = await monitor.snapshot()
          } catch { message = error.localizedDescription }
        }
      }
      onUpdate?()
      schedule()
    }
  }
  private func schedule() {
    timer?.invalidate()
    let next = Timer(timeInterval: state.interval, repeats: false) {
      [weak self] _ in Task { @MainActor in self?.refresh() }
    }
    next.tolerance = min(10, state.interval / 6)
    // MainActor execution does not select a Foundation run loop. Attach explicitly,
    // and keep observing during AppKit menu tracking and modal interactions.
    RunLoop.main.add(next, forMode: .common)
    timer = next
  }
  func suspend() {
    timer?.invalidate()
    Task { try? await monitor?.checkpoint() }
  }
  func wake() {
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
    var p = state.catalog.preferences
    p.automaticCleanup = enabled
    save(p)
  }
  func setNotifications(_ enabled: Bool) {
    if enabled && !demo {
      Task {
        do {
          let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert
          ])
          var p = state.catalog.preferences
          p.notifications = allowed
          save(p)
          if !allowed {
            message = "Notifications remain off. You can allow them in System Settings."
          }
        } catch { message = error.localizedDescription }
      }
    } else {
      var p = state.catalog.preferences
      p.notifications = enabled
      save(p)
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
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      objectWillChange.send()
    } catch { message = "Login item could not be changed: \(error.localizedDescription)" }
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
  @ObservedObject var model: AppModel
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
        }.buttonStyle(.borderless).help("Refresh observations").accessibilityLabel(
          "Refresh observations")
      }.padding(20)
      Divider()
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
        }.pickerStyle(.segmented).padding([.horizontal, .top], 16)
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
            : model.state.catalog.preferences.automaticCleanup
              ? "Disposable-helper cleanup on" : "Monitoring · cleanup is manual",
          systemImage: "lock.shield"
        ).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Quit") { model.quit() }.buttonStyle(.borderless).font(.caption)
      }.padding(14)
    }.frame(width: 440, height: 660).background(Color(nsColor: .windowBackgroundColor)).tint(ember)
  }
  var overview: some View {
    Group {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          attention == 0
            ? "Room to keep going." : eligible > 0 ? "A few loose ends." : "Worth a closer look."
        ).font(.system(size: 25, weight: .semibold, design: .rounded))
        Text(
          attention == 0
            ? "No sustained issues found in the visible processes. Unknown work stays protected."
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
      if model.state.findings.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Label("Quiet is a good outcome", systemImage: "leaf").font(.headline)
          Text(
            "Keep using your tools. BurnZombies looks for sustained changes and preserves unknown workloads."
          ).font(.callout).foregroundStyle(.secondary)
          Text(
            "For owned helper cleanup, launch disposable jobs through the included burnzombies run command."
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
        }.buttonStyle(.plain).accessibilityLabel("Review \(f.title)")
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
      }.buttonStyle(.borderless).padding(20)
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
              Button("Request graceful stop") { model.clean() }.buttonStyle(.borderedProminent)
                .disabled(model.working)
            }.padding(14).background(ember.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          } else if f.disposition == .eligible {
            Button("Preview cleanup") { model.preview = true }.buttonStyle(.borderedProminent)
          }
          HStack {
            Button("Protect executable") { model.protect() }
            Button("Snooze 24 hours") { model.snooze() }
          }.disabled(f.members.isEmpty)
          DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 10) {
              Button("Inspect descriptors") { model.inspect() }
              ForEach(model.technical, id: \.self) {
                Text($0).font(.caption.monospaced()).textSelection(.enabled)
              }
            }.padding(.top, 8)
          }.font(.callout)
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
        "Memory released uses the resident footprint of verified exits; shared pages can overlap. Impact shows a local command-launch comparison when available. CPU time saved projects the observed pre-stop CPU rate over one hour; it is counted once after verified exit."
      ).font(.caption).foregroundStyle(.secondary)
      Text(
        "Detailed history: 30 days, up to 500 attempts. Lifetime counts retain only verified outcomes."
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  var settings: some View {
    Group {
      Text("Quiet by default.").font(.title2.weight(.semibold))
      Toggle(
        "Automatic disposable-helper cleanup",
        isOn: Binding(
          get: { model.state.catalog.preferences.automaticCleanup }, set: model.setAutomatic))
      Text(
        "Only helpers launched with explicit --allow-cleanup permission qualify. The same preview rules apply. One attempt per registered activity; no force kill, unknown workloads, or file cleanup."
      ).font(.caption).foregroundStyle(.secondary)
      Toggle(
        "Grouped notifications",
        isOn: Binding(
          get: { model.state.catalog.preferences.notifications }, set: model.setNotifications))
      Text(
        "Off by default. A finding notifies once; materially worse impact can notify again after a day. Snoozed and protected activities stay quiet."
      ).font(.caption).foregroundStyle(.secondary)
      Toggle(
        "Start at login",
        isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: model.login)
      ).disabled(model.demo)
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
          Text(URL(fileURLWithPath: p).lastPathComponent).font(.callout)
          Spacer()
          Button("Remove") { model.unprotect(p) }
        }
      }
      Divider()
      Text("Local and bounded").font(.headline)
      Text(
        "No accounts, analytics, cloud, or LLM. No command arguments or environment collected. At most 4,096 process records, eight samples each; private checkpoints every five minutes. Descriptor counts are inspected only when requested."
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
      ).font(.callout)
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var item: NSStatusItem!
  var popover: NSPopover!
  var window: NSWindow?
  var auditWindow: NSWindow?
  var menuPreviewWindow: NSWindow?
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
    model.openAudit = { [weak self] in self?.showAudit() }
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
    popover.contentSize = NSSize(width: 428, height: 795)
    popover.contentViewController = NSHostingController(rootView: MiniImpactView(model: model))
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
    if CommandLine.arguments.contains("--show-window") { showImpact("Impact") }
    if CommandLine.arguments.contains("--show-popover") { toggle() }
    if CommandLine.arguments.contains("--show-mini-window") {
      let panel = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 428, height: 795),
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
      panel.setFrame(NSRect(x: 0, y: 0, width: 428, height: 795), display: false)
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
  @objc func toggle() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = item.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
    }
  }
  @objc func sleeping() { model.suspend() }
  @objc func waking() { model.wake() }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !popover.isShown { toggle() }
    return false
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.run()
}
