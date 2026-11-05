#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Real local hit targets and app-return events, with no system pane, live observer,
/// permission probe, pasteboard write or live preferences involved.
@MainActor func accessBannerProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let suite = "io.burnzombies.access-proof." + UUID().uuidString
  guard let preferences = UserDefaults(suiteName: suite) else { throw StoreError.message("Isolated preferences unavailable") }
  defer { preferences.removePersistentDomain(forName: suite) }
  var opened: [URL] = [], checks = 0, opensSuccessfully = true
  var result = FullDiskAccessStatus(state: .required, detail: "Access is still blocked.")
  // Fixture listing: never a protected folder. Records how many panes were open at the time.
  var listedWithPanesOpen: [Int] = [], guides: [AccessGuide?] = []
  let model = AppModel(demo: true, accessPreferences: preferences, accessOpener: { url in
    opened.append(url); return opensSuccessfully
  }, accessChecker: { checks += 1; return result },
    accessLister: { listedWithPanesOpen.append(opened.count); return .listed },
    accessGuide: { guides.append($0) })
  model.state.fullDiskAccess = result
  let initialHistory = model.state.catalog.lifetimeVerified
  let host = NSHostingView(rootView: MiniImpactView(model: model))
  host.frame = NSRect(origin: .zero, size: MiniImpactView.size)
  let surface = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
  surface.contentView = host
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
  }
  func completeCheck(_ expected: Int) throws {
    let deadline = Date().addingTimeInterval(3)
    while (checks != expected || model.working) && Date() < deadline { settle() }
    guard checks == expected, !model.working else { throw StoreError.message("Return check did not complete exactly once") }
  }
  func click(_ x: CGFloat, _ y: CGFloat) throws {
    settle()
    let point = NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y)
    guard let target = host.hitTest(point) else { throw StoreError.message("Banner hit target unavailable") }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: surface.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
        throw StoreError.message("Banner click unavailable")
      }
      if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
    }
    settle()
  }
  func render(_ name: String) throws -> String {
    settle()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw StoreError.message("Banner render unavailable") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let image = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:]) else { throw StoreError.message("Banner PNG unavailable") }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognition])
    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    try text.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    guard !surface.isVisible, !surface.isKeyWindow else { throw StoreError.message("Proof surfaced a window") }
    return text
  }
  guard model.showsAccessBanner, checks == 0, opened.isEmpty, listedWithPanesOpen.isEmpty, guides.isEmpty else {
    throw StoreError.message("Setup caused an automatic action")
  }
  model.accessSetupDidBecomeActive(); model.accessSetupDidResignActive(); model.accessSetupDidBecomeActive()
  settle()
  guard checks == 0 else { throw StoreError.message("Normal activation must not probe access") }
  _ = try render("required")
  try click(150, 354)
  guard opened.count == 1, opened[0].absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
    !model.accessReady, checks == 0 else { throw StoreError.message("Banner did not open the exact pane, or assumed access") }
  guard listedWithPanesOpen == [0], guides == [.turnOn], model.accessGuide == .turnOn else {
    throw StoreError.message("Allow did not list BurnZombies before opening the pane, or showed no switch guide")
  }
  model.accessSetupDidBecomeActive(); settle()
  guard checks == 0, model.accessGuide == .turnOn else {
    throw StoreError.message("Opening pane without leaving triggered a check or closed the guide")
  }
  model.accessSetupDidResignActive(); model.accessSetupDidBecomeActive()
  try completeCheck(1)
  guard model.accessGuide == nil, guides == [.turnOn, nil] else { throw StoreError.message("Returning left the guide open") }
  model.accessSetupDidResignActive(); model.accessSetupDidBecomeActive(); settle()
  guard checks == 1, !model.accessReady else { throw StoreError.message("Activation loop rechecked or granted denied access") }
  try click(314, 354)
  guard !model.showsAccessBanner, model.accessBannerDismissed,
    preferences.bool(forKey: AppModel.accessBannerDismissedKey), opened.count == 1 else {
    throw StoreError.message("Dismiss hit target did not persist independently of pane link")
  }
  let dismissed = try render("dismissed")
  guard !dismissed.contains("Allow Full Disk Access"), dismissed.contains("limited") else {
    throw StoreError.message("Dismissal hid access status or left the banner visible")
  }
  let reopened = AppModel(demo: true, accessPreferences: preferences, accessOpener: { _ in false })
  reopened.state.fullDiskAccess = result
  guard reopened.accessBannerDismissed, !reopened.showsAccessBanner else { throw StoreError.message("Dismissal did not survive reopening") }
  let isolatedDemo = AppModel(demo: true)
  isolatedDemo.state.fullDiskAccess = result
  guard isolatedDemo.showsAccessBanner else { throw StoreError.message("Demo inherited nonisolated dismissal") }
  // A return during observation waits for that observation instead of retry polling.
  model.working = true; model.openFullDiskAccessSettings()
  model.accessSetupDidResignActive(); model.accessSetupDidBecomeActive(); settle()
  guard checks == 1 else { throw StoreError.message("Busy observer raced access verification") }
  model.working = false; try completeCheck(2)
  opensSuccessfully = false; model.openFullDiskAccessSettings()
  guard model.accessGuide == nil else { throw StoreError.message("Failed pane open showed the guide") }
  model.accessSetupDidResignActive(); model.accessSetupDidBecomeActive(); settle()
  guard checks == 2 else { throw StoreError.message("Failed pane open armed an access probe") }
  result = .init(state: .granted, detail: "Fixture verification succeeded.")
  model.recheckFullDiskAccess(); try completeCheck(3)
  guard model.accessReady, !model.showsAccessBanner, !model.accessBannerDismissed,
    !preferences.bool(forKey: AppModel.accessBannerDismissedKey) else { throw StoreError.message("Verified access did not clear banner/dismissal") }
  _ = try render("verified")
  // Manage access after setup only opens the pane: no listing attempt, no setup guide.
  let listedBeforeManage = listedWithPanesOpen.count, panesBeforeManage = opened.count
  model.openFullDiskAccessSettings()
  guard listedWithPanesOpen.count == listedBeforeManage, opened.count == panesBeforeManage + 1,
    model.accessGuide == nil else { throw StoreError.message("Manage access listed again or showed the setup guide") }
  model.state.fullDiskAccess = .init(state: .required, detail: "Access was revoked.")
  guard model.showsAccessBanner, model.state.catalog.lifetimeVerified == initialHistory else {
    throw StoreError.message("Revocation failed to restore setup or changed cleanup history")
  }
  _ = try render("revoked")
  // macOS may terminate the old process before it returns from System Settings.
  // Recreate the model using only durable preferences, as Quit & Reopen does.
  let restartSuite = suite + ".restart"
  guard let restartPreferences = UserDefaults(suiteName: restartSuite) else { throw StoreError.message("Restart preferences unavailable") }
  defer { restartPreferences.removePersistentDomain(forName: restartSuite) }
  var restartChecks = 0
  var restartResult = FullDiskAccessStatus(state: .granted)
  func launch() -> AppModel {
    let next = AppModel(demo: true, accessPreferences: restartPreferences,
      accessOpener: { _ in true }, accessChecker: { restartChecks += 1; return restartResult })
    next.state.fullDiskAccess = .init()
    return next
  }
  func finishRestart(_ next: AppModel, _ expected: Int) throws {
    let deadline = Date().addingTimeInterval(3)
    while (restartChecks != expected || next.working) && Date() < deadline { settle() }
    guard restartChecks == expected, !next.working else { throw StoreError.message("Quit & Reopen lost the pending access verification") }
  }
  var prior: AppModel? = launch()
  prior!.openFullDiskAccessSettings()
  prior = nil
  let afterQuit = launch()
  try finishRestart(afterQuit, 1)
  guard afterQuit.accessReady, !afterQuit.showsAccessBanner else { throw StoreError.message("Relaunch failed to show verified access") }
  let ordinaryLaunch = launch(); settle()
  guard restartChecks == 1, !ordinaryLaunch.accessReady else { throw StoreError.message("Ordinary launch probed or assumed access") }
  restartResult = .init(state: .required)
  prior = launch(); prior!.openFullDiskAccessSettings()
  prior!.accessSetupDidResignActive(); prior!.accessSetupDidBecomeActive()
  try finishRestart(prior!, 2)
  guard !prior!.accessReady else { throw StoreError.message("Old process assumed permission before restart") }
  prior = nil
  restartResult = .init(state: .granted)
  let afterEarlyDenial = launch(); try finishRestart(afterEarlyDenial, 3)
  guard afterEarlyDenial.accessReady else { throw StoreError.message("Early denial discarded relaunch verification") }
  for unresolved in [FullDiskAccessState.required, .unknown] {
    afterEarlyDenial.openFullDiskAccessSettings()
    restartResult = .init(state: unresolved)
    let expected = restartChecks + 1
    let denied = launch(); try finishRestart(denied, expected)
    guard !denied.accessReady else { throw StoreError.message("Unverified restart granted access") }
    let again = launch(); again.accessSetupDidBecomeActive(); settle()
    guard restartChecks == expected else { throw StoreError.message("Denied relaunch created a retry loop") }
  }
  let failedOpen = AppModel(demo: true, accessPreferences: restartPreferences,
    accessOpener: { _ in false }, accessChecker: { restartChecks += 1; return restartResult })
  failedOpen.openFullDiskAccessSettings()
  let beforeFailedRestart = restartChecks
  _ = launch(); settle()
  guard restartChecks == beforeFailedRestart else { throw StoreError.message("Failed settings launch left a restart probe armed") }
  // Access macOS already allows is verified at once: no pane, no guide.
  var readableChecks = 0, readablePanes = 0, readableGuides = 0
  let readable = AppModel(demo: true, accessOpener: { _ in readablePanes += 1; return true },
    accessChecker: { readableChecks += 1; return .init(state: .granted) },
    accessLister: { .alreadyReadable }, accessGuide: { _ in readableGuides += 1 })
  readable.state.fullDiskAccess = .init()
  readable.openFullDiskAccessSettings()
  let readableDeadline = Date().addingTimeInterval(3)
  while (readableChecks != 1 || readable.working) && Date() < readableDeadline { settle() }
  guard readableChecks == 1, readablePanes == 0, readableGuides == 0, readable.accessReady else {
    throw StoreError.message("Access macOS already allows was not verified directly")
  }
  // Nothing was refused, so BurnZombies isn't listed: the guide asks for a drag instead.
  var dragGuides: [AccessGuide?] = []
  let unlisted = AppModel(demo: true, accessOpener: { _ in true }, accessChecker: { .init() },
    accessLister: { .unavailable }, accessGuide: { dragGuides.append($0) })
  unlisted.state.fullDiskAccess = .init()
  unlisted.openFullDiskAccessSettings()
  unlisted.closeAccessGuide()
  guard dragGuides == [.dragIn, nil], unlisted.accessGuide == nil else {
    throw StoreError.message("Unlisted app did not get the drag guide, or it would not close")
  }
  // The guide itself, rendered offscreen and read back.
  let fixtureApp = Bundle.main.bundleURL.pathExtension == "app"
    ? Bundle.main.bundleURL : URL(fileURLWithPath: "/Applications/BurnZombies.app")
  for (guide, name, expected) in [
    (AccessGuide.turnOn, "guide-turn-on", ["Turn on BurnZombies", "password or Touch ID", "Drag this icon"]),
    (AccessGuide.dragIn, "guide-drag-in", ["Add BurnZombies", "password or Touch ID", "Quit & Reopen"]),
  ] {
    let guideHost = NSHostingView(rootView: AccessGuideView(guide: guide, appURL: fixtureApp, close: {}))
    guideHost.frame = NSRect(origin: .zero, size: guideHost.fittingSize)
    let guideWindow = NSWindow(contentRect: guideHost.frame, styleMask: .borderless, backing: .buffered, defer: false)
    guideWindow.contentView = guideHost
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guideHost.layoutSubtreeIfNeeded(); guideHost.displayIfNeeded()
    guard let bitmap = guideHost.bitmapImageRepForCachingDisplay(in: guideHost.bounds) else {
      throw StoreError.message("Guide render unavailable")
    }
    guideHost.cacheDisplay(in: guideHost.bounds, to: bitmap)
    guard let image = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:]) else {
      throw StoreError.message("Guide PNG unavailable")
    }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognition])
    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    try text.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    guard !guideWindow.isVisible, expected.allSatisfy({ text.contains($0) }) else {
      throw StoreError.message("Guide \(name) surfaced a window or lost its instructions")
    }
  }
  print("PASS native direct-pane/dismiss hits, isolated persistent dismissal, one-shot return check, busy deferral, denied/failed-open refusal, verified completion and revocation; no windows or live permission changes")
  print("PASS Quit & Reopen verification, denied pre-restart return recovery, and denied/unknown restart consumption without loops")
  print("PASS listing before the pane opens, switch and drag guides shown and closed, Manage access without listing, already-allowed access verified without Settings")
}
#endif
