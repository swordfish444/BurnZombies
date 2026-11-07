#if DEBUG
  import AppKit
  import BurnCore
  import SwiftUI

  /// The actual header and controller, with synthetic releases and no observer, network traffic
  /// or visible windows. Like SettingsProof, press the shipped links and render every shipped
  /// state without taking focus from the operator.
  @MainActor func aboutSettingsProof(output: String) async throws {
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scratch = URL(
      fileURLWithPath: WorkspaceSafety.canonical(FileManager.default.temporaryDirectory.path)
    )
    .appendingPathComponent("bz-about-proof-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let release = try AppUpdateRelease.decode(
      JSONSerialization.data(withJSONObject: [
        "tag_name": "v0.16.0", "draft": false, "prerelease": false,
        "html_url": AppUpdateRelease.repository + "/releases/tag/v0.16.0",
        "assets": [
          [
            "name": AppUpdateRelease.assetName, "size": 100,
            "browser_download_url": AppUpdateRelease.repository + "/releases/download/v0.16.0/"
              + AppUpdateRelease.assetName,
          ],
          [
            "name": "SHA256SUMS", "size": 80,
            "browser_download_url": AppUpdateRelease.repository
              + "/releases/download/v0.16.0/SHA256SUMS",
          ],
        ],
      ]))
    var installs = 0
    let app = scratch.appendingPathComponent("BurnZombies.app")
    func fixture(_ url: URL, _ version: String, _ build: String) throws {
      try FileManager.default.createDirectory(
        at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
      try PropertyListSerialization.data(
        fromPropertyList: [
          "CFBundleIdentifier": "io.burnzombies.app",
          "CFBundleExecutable": "BurnZombiesApp", "CFBundleShortVersionString": version,
          "CFBundleVersion": build,
        ], format: .xml, options: 0
      )
      .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    try fixture(app, "0.15.1", "73")
    let workspace = scratch.appendingPathComponent(".BurnZombies-update-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let payload = workspace.appendingPathComponent("unpacked/BurnZombies.app")
    try fixture(payload, "0.16.0", "74")
    let plan = AppUpdatePlan(
      directory: workspace.path, destination: app.path,
      previous: try AppUpdateBundle.read(app), replacement: try AppUpdateBundle.read(payload),
      parent: ProcessIdentity(pid: 1, seconds: 1))
    let model = AppUpdateSettingsModel(
      version: "0.15.1", build: "73", root: scratch,
      check: { release },
      prepare: { _, progress in
        progress(.verifying)
        return plan
      }, install: { _ in installs += 1 })
    let host = NSHostingView(
      rootView: AboutHeader(updates: model, subtitle: "Keep your work running").padding(20)
        .frame(width: 440, height: 320, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
    let surface = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 320), styleMask: .borderless,
      backing: .buffered, defer: false)
    surface.isReleasedWhenClosed = false
    surface.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 440, height: 320)
    func settle(_ view: NSView) {
      for _ in 0..<4 {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      }
    }
    // The header's own size, free of the fixture's frame: its width and how far it pushes the panel.
    let free = NSHostingView(
      rootView: AboutHeader(updates: model, subtitle: "Keep your work running"))
    func fit() -> NSSize {
      settle(free)
      return free.fittingSize
    }
    func press(_ what: String) throws {
      settle(host)
      guard let link = appKitViews(NSButton.self, in: host).first else {
        throw StoreError.message("\(what): no link to press")
      }
      link.performClick(nil)
    }
    var versionTop: CGFloat?
    func render(_ name: String) throws {
      settle(host)
      // Whatever the updater is doing, the version stays where it is.
      guard
        let version = appKitViews(NSTextField.self, in: host)
          .first(where: { $0.stringValue.hasPrefix("Version ") })
          .map({ $0.convert($0.bounds, to: host).minY })
      else { throw StoreError.message("\(name): the version is gone") }
      guard abs(version - (versionTop ?? version)) < 0.5 else {
        throw StoreError.message("\(name): the version moved to y=\(version)")
      }
      versionTop = version
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw StoreError.message("About render unavailable")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw StoreError.message("About PNG unavailable")
      }
      try png.write(to: directory.appendingPathComponent(name + ".png"))
      guard !surface.isVisible, !surface.isKeyWindow else {
        throw StoreError.message("About proof took focus")
      }
    }
    try render("about-idle")
    guard model.phase == .idle, installs == 0 else {
      throw StoreError.message("About performed an automatic update action")
    }
    // The first answer a check gives stays on the version's line: the panel below doesn't jump.
    let quiet = fit()
    guard quiet.width <= 400 else {
      throw StoreError.message("The header needs \(quiet.width) points; the panel has 400")
    }
    model.phase = .checking
    try render("about-checking")
    guard fit().height == quiet.height, fit().width <= 400 else {
      throw StoreError.message("Checking moved the panel or overflowed: \(fit())")
    }
    model.phase = .upToDate
    try render("about-up-to-date")
    guard fit().height == quiet.height, fit().width <= 400 else {
      throw StoreError.message("Up to date moved the panel or overflowed: \(fit())")
    }
    model.phase = .idle
    try press("Check for Updates")
    await model.waitForOperation()
    guard model.phase == .available else {
      throw StoreError.message("Check for Updates did not reach the updater")
    }
    try render("about-available")
    guard fit().height > quiet.height, fit().width <= 400 else {
      throw StoreError.message("An available update has no line of its own or overflowed: \(fit())")
    }
    try press("Update and Restart")
    await model.waitForOperation()
    guard installs == 1, model.phase == .restarting else {
      throw StoreError.message("Update and Restart did not complete the prepared handoff")
    }
    try render("about-restarting")
    model.phase = .downloading
    model.fraction = 0.45
    try render("about-downloading")
    model.phase = .verifying
    try render("about-verifying")
    model.phase = .waiting
    try render("about-finishing-work")
    model.phase = .failed
    model.message =
      "The update couldn't finish. Your previous version was restored. Please try again."
    try render("about-failed")
    try AppUpdateResult(
      state: "failed", version: "0.16.0",
      detail: "The update couldn't finish. Your previous version is in place."
    ).save(root: scratch)
    model.refreshResult()
    model.phase = .idle
    try render("about-failed-update")
    model.phase = .failed
    for width in [360.0, 600.0] {
      let fitted = NSHostingView(
        rootView: AboutHeader(updates: model, subtitle: "Keep your work running").padding(20)
          .frame(width: width, height: 360, alignment: .topLeading)
          .background(Color(nsColor: .windowBackgroundColor)).environment(
            \.colorScheme, .dark))
      surface.contentView = fitted
      surface.setContentSize(NSSize(width: width, height: 360))
      fitted.frame = NSRect(x: 0, y: 0, width: width, height: 360)
      settle(fitted)
      guard let bitmap = fitted.bitmapImageRepForCachingDisplay(in: fitted.bounds) else {
        throw StoreError.message("About width unavailable")
      }
      fitted.cacheDisplay(in: fitted.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw StoreError.message("About width PNG unavailable")
      }
      try png.write(to: directory.appendingPathComponent("about-width-\(Int(width)).png"))

    }
    // Failure, cancellation, no downgrade, and retry are controller behavior, not display fixtures.
    let failed = AppUpdateSettingsModel(
      version: "0.15.1", build: "73", root: scratch,
      check: { throw StoreError.message("Offline fixture") }, install: { _ in installs += 1 })
    failed.check()
    await failed.waitForOperation()
    guard failed.phase == .failed, failed.message?.contains("Offline") == true else {
      throw StoreError.message("Offline update check claimed success")
    }
    let current = AppUpdateSettingsModel(
      version: "0.17.0", build: "90", root: scratch, check: { release },
      install: { _ in installs += 1 })
    current.check()
    await current.waitForOperation()
    current.update()
    guard current.phase == .upToDate, installs == 1 else {
      throw StoreError.message("An update tried to downgrade")
    }
    let cancel = AppUpdateSettingsModel(
      version: "0.15.1", build: "73", root: scratch, check: { release },
      prepare: { _, progress in
        progress(.downloading(0.25))
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return plan
      }, install: { _ in installs += 1 })
    cancel.check()
    await cancel.waitForOperation()
    cancel.update()
    await Task.yield()
    cancel.cancel()
    await Task.yield()
    guard cancel.phase == .available, installs == 1 else {
      throw StoreError.message("Cancelling a download restarted the app")
    }
    // The header stays on screen, so what it says has to stay true. Run in the real view.
    func shown(_ updates: AppUpdateSettingsModel) async throws {
      let view = NSHostingView(rootView: AboutHeader(updates: updates, subtitle: "Keep your work running"))
      surface.contentView = view
      settle(view)
      try await Task.sleep(nanoseconds: 400_000_000)
    }
    let upToDate = AppUpdateSettingsModel(
      version: "0.17.0", build: "90", root: scratch, check: { release },
      answerNanoseconds: 50_000_000, install: { _ in installs += 1 })
    upToDate.check()
    await upToDate.waitForOperation()
    guard upToDate.phase == .upToDate else { throw StoreError.message("Expected up to date") }
    try await shown(upToDate)
    guard upToDate.phase == .idle else {
      throw StoreError.message("\"You're up to date\" stayed on screen after its moment")
    }
    let offline = AppUpdateSettingsModel(
      version: "0.15.1", build: "73", root: scratch,
      check: { throw StoreError.message("Offline fixture") },
      answerNanoseconds: 50_000_000, install: { _ in installs += 1 })
    offline.check()
    await offline.waitForOperation()
    guard offline.phase == .failed else { throw StoreError.message("Expected a failed check") }
    try await shown(offline)
    guard offline.phase == .idle else {
      throw StoreError.message("A failed check stayed on screen after its moment")
    }
    let retry = AppUpdateSettingsModel(
      version: "0.15.1", build: "73", root: scratch, check: { release },
      answerNanoseconds: 50_000_000, install: { _ in installs += 1 })
    retry.check()
    await retry.waitForOperation()
    retry.phase = .failed
    try await shown(retry)
    guard retry.phase == .failed else {
      throw StoreError.message("A failed update that can be retried cleared itself")
    }
    // The window's footer clears itself the same way, so it never says "Hunting now" for hours.
    let footer = AppModel(demo: true)
    footer.messageSeconds = 0.05
    footer.message = "Hunting now."
    let window = NSHostingView(
      rootView: SettingsWindow(model: footer, ai: AISettingsModel(root: scratch)))
    surface.contentView = window
    window.frame = NSRect(x: 0, y: 0, width: 440, height: 660)
    settle(window)
    try await Task.sleep(nanoseconds: 400_000_000)
    guard footer.message == nil else {
      throw StoreError.message("The footer still says \"\(footer.message ?? "")\" after its moment")
    }
    // A saved failure (0.16.0, above) stands only while this copy is still behind that version.
    for (version, stands) in [("0.15.1", true), ("0.16.0", false), ("0.17.0", false)] {
      let saved = AppUpdateSettingsModel(
        version: version, build: "73", root: scratch, check: { release },
        install: { _ in installs += 1 })
      saved.refreshResult()
      guard (saved.failedUpdate != nil) == stands else {
        throw StoreError.message("A saved failure read wrongly on \(version)")
      }
    }
    guard installs == 1 else { throw StoreError.message("A proof step installed an update") }
    print(
      "PASS About header and updater: pressed the shipped links, version never moves across update states, quick answers stay on its line and clear themselves, a retryable failure stays, a saved failure ends once that version arrives, the window's footer clears itself, offline, no downgrade, cancellation, narrow/wide renders; no visible window or observer started"
    )
  }
#endif
