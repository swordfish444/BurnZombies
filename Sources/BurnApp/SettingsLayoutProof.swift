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
    var checks = 0
    model.appUpdates = AppUpdateSettingsModel(
      root: root, check: { throw StoreError.message("No network in layout proof") },
      install: { _ in checks += 1 })
    let host = NSHostingView(
      rootView: SettingsWindow(model: model, ai: ai).environment(\.colorScheme, .dark))
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
    // The most it can show at once: the AI waiting and a message in the footer.
    model.message = "Hunting now. I'll burn what's safe and ask if I'm unsure."
    try render("settings-ai-waiting-message")
    try fitsOneScreen("Settings with the AI waiting and a message")
    model.message = nil
    model.autopilot.sweep.retryAfter = nil
    model.autopilot.sweep.limitResetsAt = nil

    // The window is Settings and nothing else: BZ's name, version and update link, then the page.
    let headerBottom: CGFloat = 72
    guard let page = scrollView().map(frame) else { throw fail("The page is missing") }
    guard
      let version = appKitViews(NSTextField.self, in: host)
        .first(where: { $0.stringValue.hasPrefix("Version ") }).map(frame)
    else { throw fail("The version is missing") }
    guard version.maxY <= headerBottom else {
      throw fail("The version sits at y=\(Int(version.minY)), below the header")
    }
    let headerButtons = appKitViews(NSButton.self, in: host).map(frame).filter {
      $0.maxY <= headerBottom
    }
    guard headerButtons.count == 1, headerButtons[0].width > 60 else {
      throw fail(
        "The header should hold only the update link, found widths \(headerButtons.map { Int($0.width) })")
    }
    // No tabs and no status strip: the page starts right under the header.
    guard page.minY - headerBottom < 12 else {
      throw fail("Something sits between the header and the page, which starts at y=\(Int(page.minY))")
    }
    let pickers = appKitViews(NSSegmentedControl.self, in: host)
    guard pickers.count == 1, pickers[0].segmentCount == AutopilotLevel.allCases.count else {
      throw fail(
        "The Autopilot choice should be the only picker, found \(pickers.map { $0.segmentCount }) segments")
    }
    // It runs the page's full width, and it's the first thing on the page.
    let choice = frame(pickers[0])
    guard abs(choice.minX - 20) <= 4, abs(choice.maxX - 420) <= 4 else {
      throw fail("The Autopilot choice runs \(Int(choice.minX))...\(Int(choice.maxX)), not 20...420")
    }
    guard choice.minY - headerBottom < 48 else {
      throw fail("The Autopilot choice starts at y=\(Int(choice.minY)), too far below the header")
    }
    try render("header")

    // The one choice: each segment says what it does and does it.
    let level = pickers[0]
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
        throw fail("\(name): the Autopilot choice should give way to the page")
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
      "PASS Settings fits one screen with and without the AI waiting; four-way Autopilot choice, switches lined up, question switch and pages press through their real views; the window is Settings alone: version and update link on top, no tabs, no status strip, the Autopilot choice first; no network or install"
    )
  }
#endif
