#if DEBUG
  import AppKit
  import BurnCore
  import SwiftUI

  /// The actual Settings view and controller, with synthetic releases and no observer, network
  /// traffic or visible windows. Like SettingsProof, exercise the shared controller and render
  /// every shipped state without taking focus from the operator.
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
      rootView: AboutSettingsView(updates: model).padding(20)
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
    func render(_ name: String) throws {
      settle(host)
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
    model.check()
    await model.waitForOperation()
    guard model.phase == .available else {
      throw StoreError.message("Check button did not reach the updater")
    }
    try render("about-available")
    model.update()
    await model.waitForOperation()
    guard installs == 1, model.phase == .restarting else {
      throw StoreError.message("Update button did not complete the prepared handoff")
    }
    try render("about-restarting")
    model.phase = .upToDate
    try render("about-up-to-date")
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
    for width in [360.0, 600.0] {
      let fitted = NSHostingView(
        rootView: AboutSettingsView(updates: model).padding(20)
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
    print(
      "PASS About and updater view/controller: version/build, all update states, offline, no downgrade, cancellation, narrow/wide renders; no visible window or observer started"
    )
  }
#endif
