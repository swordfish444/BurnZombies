#if DEBUG
  import AppKit
  import BurnCore
  import SwiftUI

  /// Exercise the shipped Dashboard offscreen with scratch settings, never a live observer.
  @MainActor func settingsLayoutProof(output: String) throws {
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    BurnTheme.registerFonts()
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bz-settings-layout-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = MachineReviewConfiguration(
      harness: "codex", executable: "/bin/true", launcher: "/bin/true", server: "/bin/true")
    try config.save(root: root)
    let review = ReviewSettingsModel(root: root, catalog: [])
    let hunts = HuntSettingsModel(root: root)
    let disk = DiskSettingsModel(root: root)
    let sections = SettingsExpansion()
    let model = AppModel(demo: true)
    model.tab = "Settings"
    var checks = 0
    model.appUpdates = AppUpdateSettingsModel(
      root: root, check: { throw StoreError.message("No network in layout proof") },
      install: { _ in checks += 1 })
    guard sections.expanded.isEmpty, !disk.expanded else {
      throw StoreError.message("Settings must begin collapsed")
    }
    func files() throws -> [String: Data] {
      let contents = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
      return try Dictionary(uniqueKeysWithValues: contents.filter {
        try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      }.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    let baseline = try files()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let preferences = try encoder.encode(model.state.catalog.preferences)
    let host = NSHostingView(rootView: Dashboard(
      model: model, reviewerSettings: review, huntSettings: hunts, diskSettings: disk,
      sections: sections).environment(\.colorScheme, .dark))
    let surface = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 660), styleMask: .borderless,
      backing: .buffered, defer: false)
    surface.isReleasedWhenClosed = false
    surface.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 440, height: 660)
    func settle() {
      for _ in 0..<5 {
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
    func scrollView(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap { scrollView($0) }.first
    }
    try render("collapsed")
    guard let initial = scrollView(host) else {
      throw StoreError.message("Settings scroll view unavailable")
    }
    let top = initial.contentView.bounds.origin
    // Every disclosure uses this binding; draft models outlive their conditional contents.
    review.model = "unsaved-model-draft"
    hunts.intervalHours = 8
    disk.roots = "/unsaved-disk-draft"
    for section in SettingsExpansion.Section.allCases {
      sections.binding(section).wrappedValue = true
      try render(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))
      guard sections.expanded == [section] else {
        throw StoreError.message("Disclosure changed another section")
      }
      sections.binding(section).wrappedValue = false
    }
    disk.expanded = true
    try render("disk")
    disk.expanded = false
    // A long section scrolls independently of the version/update header.
    sections.expanded = [.protection, .general, .autopilot]
    settle()
    guard let scroll = scrollView(host), let document = scroll.documentView else {
      throw StoreError.message("Expanded settings scroll unavailable")
    }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    try render("scrolled-header")
    model.tab = "History"
    settle()
    model.tab = "Settings"
    sections.expanded = []
    try render("returned-to-settings")
    guard let returned = scrollView(host), abs(returned.contentView.bounds.origin.y - top.y) < 1,
      review.model == "unsaved-model-draft", hunts.intervalHours == 8,
      disk.roots == "/unsaved-disk-draft", try files() == baseline,
      try encoder.encode(model.state.catalog.preferences) == preferences, checks == 0,
      model.appUpdates.phase == .idle
    else { throw StoreError.message("Disclosure/tab navigation lost drafts, wrote settings, or moved from the top") }
    print("PASS collapsed defaults, all section renders, pinned header while scrolling, tab scroll reset, retained drafts, unchanged saved settings and cleanup preferences; no network, review or install")
  }
#endif
