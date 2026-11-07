#if DEBUG
  import AppKit
  import BurnCore
  import SwiftUI

  /// The AppKit views SwiftUI really laid out. Accessibility reads empty offscreen, so proofs that
  /// care where something landed look here.
  @MainActor func appKitViews<T>(_ kind: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { appKitViews(kind, in: $0) }
  }

  /// The shipped window offscreen with scratch settings, never a live observer: Settings fits one
  /// screen, every row sits where it should, and the controls do what they say.
  @MainActor func settingsLayoutProof(output: String) throws {
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    BurnTheme.registerFonts()
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bz-settings-layout-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try MachineReviewConfiguration(
      harness: "claude", executable: "/bin/true", launcher: "/bin/true", server: "/bin/true"
    ).save(root: root)
    let ai = AISettingsModel(root: root)
    let model = AppModel(demo: true)
    model.tab = "Settings"
    var checks = 0
    model.appUpdates = AppUpdateSettingsModel(
      root: root, check: { throw StoreError.message("No network in layout proof") },
      install: { _ in checks += 1 })
    let host = NSHostingView(
      rootView: Dashboard(model: model, ai: ai).environment(\.colorScheme, .dark))
    let surface = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 660), styleMask: .borderless,
      backing: .buffered, defer: false)
    surface.isReleasedWhenClosed = false
    surface.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 440, height: 660)
    func settle() {
      for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      }
    }
    func render(_ name: String) throws {
      settle()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw StoreError.message("Settings layout bitmap unavailable")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw StoreError.message("Settings layout PNG unavailable")
      }
      try png.write(to: directory.appendingPathComponent(name + ".png"))
      guard !surface.isVisible, !surface.isKeyWindow else {
        throw StoreError.message("Settings fixture took focus")
      }
    }
    func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: host) }
    func fail(_ message: String) -> Error { StoreError.message(message) }
    func scrollView() -> NSScrollView? { appKitViews(NSScrollView.self, in: host).first }
    /// Taller than its window means someone has to scroll to find a setting.
    func fitsOneScreen(_ name: String) throws {
      settle()
      guard let scroll = scrollView(), let document = scroll.documentView else {
        throw fail("\(name): no content")
      }
      guard document.frame.height <= scroll.contentSize.height + 1 else {
        throw fail(
          "\(name): needs scrolling, \(Int(document.frame.height)) in \(Int(scroll.contentSize.height))")
      }
    }
    func switches() -> [NSRect] {
      appKitViews(NSButton.self, in: host).map(frame).filter {
        abs($0.width - AutopilotSwitch.size.width) < 1
      }
    }

    // One screen, today and with the AI waiting, on any AI choice.
    try render("settings")
    try fitsOneScreen("Settings")
    model.autopilot.sweep.retryAfter = Date().addingTimeInterval(86_400)
    model.autopilot.sweep.limitResetsAt = Date().addingTimeInterval(86_400)
    try render("settings-ai-waiting")
    try fitsOneScreen("Settings with the AI waiting")
    model.autopilot.sweep.retryAfter = nil
    model.autopilot.sweep.limitResetsAt = nil

    // The header holds the version and update link, with nothing else above the tabs.
    let headerBottom: CGFloat = 72
    for tab in ["Settings", "Overview", "History"] {
      model.tab = tab
      try render("tab-" + tab.lowercased())
      guard
        let tabs = appKitViews(NSSegmentedControl.self, in: host).map(frame)
          .min(by: { $0.minY < $1.minY }), let scroll = scrollView().map(frame)
      else { throw fail("\(tab): tabs or content missing") }
      guard
        let version = appKitViews(NSTextField.self, in: host)
          .first(where: { $0.stringValue.hasPrefix("Version ") }).map(frame)
      else { throw fail("\(tab): the version isn't on this tab") }
      guard version.maxY <= headerBottom, version.maxY <= tabs.minY else {
        throw fail(
          "\(tab): the version sits at y=\(Int(version.minY)), below the header or tabs (y=\(Int(tabs.minY)))")
      }
      let buttons = appKitViews(NSButton.self, in: host).map(frame).filter {
        $0.maxY <= headerBottom
      }
      guard buttons.count == 1, buttons[0].width > 60 else {
        throw fail(
          "\(tab): the header should hold only the update link, found widths \(buttons.map { Int($0.width) })")
      }
      guard scroll.minY - tabs.maxY < 12 else {
        throw fail("\(tab): something sits between the tabs and the content")
      }
      // No "View" label pushing the tabs off the page's left edge.
      guard abs(tabs.minX - 20) <= 4, abs(tabs.maxX - 420) <= 4 else {
        throw fail("\(tab): the tabs run \(Int(tabs.minX))...\(Int(tabs.maxX)), not 20...420")
      }
      // Settings gets the whole window: the strip with BZ's status stays on the other tabs.
      let close = tabs.minY - headerBottom < 24
      guard close == (tab == "Settings") else {
        throw fail("\(tab): the tabs start at y=\(Int(tabs.minY))")
      }
    }
    model.tab = "Settings"
    settle()

    // The one choice: each segment says what it does and does it.
    let segments = appKitViews(NSSegmentedControl.self, in: host)
      .first { $0.segmentCount == AutopilotLevel.allCases.count }
    guard let level = segments else { throw fail("The Autopilot choice is missing") }
    let shown = (0..<level.segmentCount).map { level.label(forSegment: $0) ?? "" }
    guard shown == AutopilotLevel.allCases.map(\.label) else {
      throw fail("The Autopilot choice reads \(shown)")
    }
    for (index, wanted) in AutopilotLevel.allCases.enumerated() {
      level.selectedSegment = index
      _ = level.sendAction(level.action, to: level.target)
      settle()
      guard model.autopilotLevel == wanted else {
        throw fail("Pressing \(wanted.label) left it on \(model.autopilotLevel.label)")
      }
      try render("level-" + wanted.rawValue)
      try fitsOneScreen("Settings on " + wanted.label)
    }
    model.setAutopilotLevel(.actWhenSure)
    settle()

    // Switches line up, here and on the page that has dozens of them.
    func linedUp(_ name: String, atLeast count: Int) throws {
      let edges = Set(switches().map { Int($0.maxX.rounded()) })
      guard switches().count >= count, edges.count == 1 else {
        throw fail("\(name): \(switches().count) switches with right edges at \(edges.sorted())")
      }
    }
    try linedUp("Settings", atLeast: 2)

    // A switch in the shipped row does what it says.
    let before = model.state.catalog.preferences.notifications
    guard
      let tell = appKitViews(NSButton.self, in: host).filter({
        abs(frame($0).width - AutopilotSwitch.size.width) < 1 && $0.isEnabled
      }).first
    else { throw fail("The question switch is missing") }
    tell.performClick(nil)
    settle()
    guard model.state.catalog.preferences.notifications != before else {
      throw fail("The question switch didn't change the setting")
    }

    // Each page opens, shows its rows, and comes back.
    for (page, name) in [
      (SettingsPage.burns, "page-burns"), (.never, "page-never"), (.aiUse, "page-ai-use"),
      (.access, "page-access"),
    ] {
      model.settingsPage = page
      try render(name)
      guard appKitViews(NSSegmentedControl.self, in: host).isEmpty else {
        throw fail("\(name): the tabs should give way to the page")
      }
      if page == .burns { try linedUp(name, atLeast: 6) }
      guard
        let back = appKitViews(NSButton.self, in: host).filter({ frame($0).minY >= headerBottom })
          .min(by: { frame($0).minY < frame($1).minY })
      else { throw fail("\(name): no way back") }
      guard frame(back).minY < headerBottom + 24 else {
        throw fail("\(name): the way back isn't at the top")
      }
      back.performClick(nil)
      settle()
      guard model.settingsPage == .home else { throw fail("\(name): back didn't go back") }
    }

    // Nothing on these pages looked at the network or started an update.
    guard checks == 0, model.appUpdates.phase == .idle else {
      throw fail("Settings started an update")
    }
    model.working = true
    try render("header-working")
    model.working = false
    print(
      "PASS Settings fits one screen with and without the AI waiting; four-way Autopilot choice, switches lined up, question switch and pages press through their real views; version and update link above the tabs on every tab, no View label, no status strip on Settings; no network or install"
    )
  }
#endif
