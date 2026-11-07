#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Exercises compact states in memory. No observer, cleanup, visible window or app activation.
@MainActor func miniProof(output: String, catalog: Catalog? = nil) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let cases = catalog == nil ? ["empty", "populated", "paused", "quiet-day", "pruned", "unmeasured", "zero-memory", "legacy-negative", "slower", "noisy", "disk", "worktrees", "access-required", "access-unknown", "access-required-history", "newcomer"] : ["receipt-replay"]
  for name in cases {
    let model = AppModel(demo: true)
    if let catalog { model.state.catalog = catalog }
    if name == "empty" || name == "paused" || name == "access-required" || name == "access-unknown" || name == "newcomer" { model.state.catalog = Catalog() }
    // Nothing found yet, unlike the demo's leftovers.
    if name == "empty" { model.autopilot = AutopilotSnapshot() }
    if name == "newcomer" {
      model.state.fullDiskAccess = .init(state: .required,
        detail: "Enable Full Disk Access in System Settings, then check again.")
    }
    if name.hasPrefix("access-") {
      model.state.fullDiskAccess = .init(state: name == "access-unknown" ? .unknown : .required,
        detail: "Enable Full Disk Access in System Settings, then check again.")
    }

    // Autopilot never pauses for good: a failed AI sweep shows its retry instead.
    if name == "paused" {
      model.machineReview.phase = "paused"
      model.autopilot.sweep.retryAfter = Date().addingTimeInterval(1800)
    }
    if name == "quiet-day" {
      let today = Calendar.current.startOfDay(for: Date())
      model.state.catalog.events.removeAll { ($0.verificationDate ?? $0.date) >= today }
      model.state.catalog.workspaceReceipts?.removeAll { ($0.verifiedAt ?? $0.date) >= today }
    }
    if name == "pruned" { model.state.catalog.events = []; model.state.catalog.workspaceReceipts = [] }
    if name == "unmeasured" || name == "zero-memory" {
      for index in model.state.catalog.events.indices {
        model.state.catalog.events[index].responseBeforeMS = nil
        model.state.catalog.events[index].responseAfterMS = nil
        model.state.catalog.events[index].responseBeforeSamples = nil
        model.state.catalog.events[index].responseAfterSamples = nil
        if name == "zero-memory" { model.state.catalog.events[index].residentBefore = 0 }
      }
    }
    if ["legacy-negative", "slower", "noisy"].contains(name) {
      for i in model.state.catalog.events.indices {
        model.state.catalog.events[i].responseBeforeMS = 2.22125
        model.state.catalog.events[i].responseAfterMS = 2.88971
        model.state.catalog.events[i].responseBeforeSamples = name == "legacy-negative" ? nil :
          (name == "noisy" ? [1, 2, 3, 20, 30, 40, 50] : Array(repeating: 2.22125, count: 7))
        model.state.catalog.events[i].responseAfterSamples = name == "legacy-negative" ? nil : Array(repeating: 2.88971, count: 7)
      }
    }
    if name == "disk" || name == "worktrees" {
      model.state.catalog.events = []; model.state.catalog.lifetimeVerified = 0
      model.state.catalog.lifetimeResidentReleased = 0
      if name == "worktrees" {
        for i in model.state.catalog.workspaceReceipts!.indices { model.state.catalog.workspaceReceipts?[i].diskReclaimedBytes = 0 }
        model.state.catalog.lifetimeDiskReclaimedBytes = 0
      }
    }
    let view = MiniImpactView(model: model)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: MiniImpactView.size)
    // Supply a native backing scale without ever ordering a window onto the screen.
    let surface = NSWindow(contentRect: host.frame, styleMask: .borderless,
      backing: .buffered, defer: false)
    surface.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard !surface.isVisible, !surface.isKeyWindow else {
      throw StoreError.message("Proof surface must stay offscreen")
    }
    // CI can have a 1x virtual display. Render the same native view at a fixed
    // 2x backing resolution so OCR is not dependent on the attached monitor.
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw StoreError.message("Compact render unavailable")
    }
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage,
      let png = bitmap.representation(using: .png, properties: [:]) else {
      throw StoreError.message("Compact PNG unavailable")
    }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([recognition])
    let visibleLines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let visible = visibleLines.joined(separator: "\n")
    try visible.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    // Match the visible footer labels as whole words: OCR may read a link's mark as a character
    // beside it. "View impact" is help text on the speed card, not rendered footer text.
    let footerVisible = ["Impact", "Findings", "Burn Log"].allSatisfy { label in
      visibleLines.contains { (" " + $0 + " ").contains(" " + label + " ") }
    }
    guard footerVisible,
      visible.contains("Memory pressure"), visible.contains("Disk reclaimed"), visible.contains("Worktrees cleaned") else {
      throw StoreError.message("Compact labels or footer clipped: \(visible)")
    }
    if name.hasPrefix("access-") {
      // Autopilot keeps cleaning leftover programs without Full Disk Access, so the status
      // says so while the access card stays in view.
      guard visible.contains("Autopilot on"), visible.contains("Open System Settings"),
        visible.contains("Allow Full Disk Access"), !visible.contains("Agent-led cleanup"),
        !visible.contains("Still warming up") else {
        throw StoreError.message("Access prerequisite missing or presented as active cleanup: \(visible)")
      }
      if name == "access-required-history" {
        guard view.numbers.count == 128, visible.contains("Last burn") else {
          throw StoreError.message("Requiring access erased verified history")
        }
      } else if !visible.contains("Ready for your first burn") && !visible.contains("of leftovers") {
        // Autopilot is genuinely ready: leftover programs need no special access.
        throw StoreError.message("New install hid that Autopilot is ready")
      }
    } else if name == "newcomer" {
      // Before the first burn a newcomer sees what BZ found and what answering frees, in plain
      // words: the access banner already says what's skipped.
      let found = ImpactNumbers.bytes(view.found)
      let asked = ImpactNumbers.bytes(model.autopilot.questions.reduce(0) { $0 + $1.bytes })
      guard visible.contains("Found \(found) of leftovers"), visible.contains(asked),
        visible.contains("Autopilot on"), !visible.contains("limited")
      else { throw StoreError.message("Newcomer panel hides what BZ found: \(visible)") }
    } else if name == "receipt-replay" {
      guard !view.numbers.boost.contains("-"), visible.contains(String(view.numbers.count)) else {
        throw StoreError.message("Receipt replay failed: \(visible)")
      }
      print("Receipt replay: \(view.numbers.count) burns, \(ImpactNumbers.cpuTime(view.numbers.cpuSeconds)), speed \(view.numbers.boost)")
    } else if name == "populated" {
      guard visible.contains("24%"), !visible.contains("Still warming up") else {
        throw StoreError.message("Measured boost not displayed")
      }
    } else if ["legacy-negative", "slower", "noisy", "unmeasured"].contains(name) {
      guard visible.contains("AGENT BOOST"), visible.contains("Memory reclaimed"),
        visible.contains("128 helpers cleared"), !visible.contains("23%"), view.numbers.boost == "—" else {
        throw StoreError.message("Verified resource benefit missing: \(visible)")
      }
    } else if name == "disk" || name == "worktrees" {
      guard visible.contains(name == "disk" ? "Disk reclaimed" : "Worktrees cleaned"),
        !visible.contains("Still warming up"), view.numbers.count == 0, view.numbers.worktrees == 4 else {
        throw StoreError.message("Worktree-only verified benefit missing: \(visible)")
      }
    } else if name == "zero-memory" {
      guard visible.contains("Helpers cleared"), visible.contains("Dead weight. Gone.") else {
        throw StoreError.message("Zero-memory cleanup benefit missing: \(visible)")
      }
    } else if name == "quiet-day" || name == "pruned" {
      guard visible.contains("Ready for the next burn"), visible.contains("880 helpers cleared all time") else {
        throw StoreError.message("Lifetime benefit missing on a quiet day: \(visible)")
      }
    } else {
      guard visible.contains("Still warming up"), visible.contains("Your first cleanup starts here") else {
        throw StoreError.message("Missing compact warmup state: \(visible)")
      }
    }
    if view.numbers.lifetimeCount > 0 {
      guard !visible.contains("Still warming up"), !visible.contains("No clear boost") else {
        throw StoreError.message("Verified cleanup presented as no benefit: \(visible)")
      }
    }
    if name == "access-required" || name == "access-unknown" || name == "newcomer" {
      guard view.numbers.count == 0 else { throw StoreError.message("Access state changed totals") }
    } else if name == "empty" || name == "paused" {
      guard view.numbers.count == 0,
        visible.contains("Ready for your first burn") || visible.contains("of leftovers") else {
        throw StoreError.message("First-burn empty state not displayed")
      }
    } else if name != "pruned" {
      guard visible.contains("Last burn"), !visible.contains("Ready for your first burn") else {
        throw StoreError.message("Existing cleanup history presented as first use")
      }
    }
    if name == "paused" && !visible.contains("waiting") {
      throw StoreError.message("Autopilot retry hidden by compact status: " + visible)
    }
    if name == "populated" && !visible.contains("quick question") {
      throw StoreError.message("Open questions hidden from the menu: " + visible)
    }
    guard host.frame.size == MiniImpactView.size else { throw StoreError.message("Popover size changed") }
    print("PASS offscreen compact \(name): 360 × 550, readable labels and footer")
  }
  if catalog == nil {
    try miniPeriodsProof(directory: directory)
    try miniLookOnlyProof(directory: directory)
    try miniAutopilotSwitchProof(directory: directory)
  }
}

/// Autopilot's switch sits where the status dot was. It starts on; one click turns Autopilot off
/// and the row says so, another turns it back on. The popup keeps its size and its footer.
@MainActor func miniAutopilotSwitchProof(directory: URL) throws {
  let model = AppModel(demo: true)
  let view = MiniImpactView(model: model)
  let host = NSHostingView(rootView: view)
  host.frame = NSRect(origin: .zero, size: MiniImpactView.size)
  let surface = NSWindow(contentRect: host.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
  surface.contentView = host
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }
  func render(_ name: String) throws -> [String] {
    settle()
    guard !surface.isVisible, !surface.isKeyWindow else {
      throw StoreError.message("Proof surface must stay offscreen")
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw StoreError.message("Compact render unavailable")
    }
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage,
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw StoreError.message("Compact PNG unavailable") }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([recognition])
    let lines = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    try lines.joined(separator: "\n").write(
      to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    return lines
  }
  func footer(_ lines: [String]) -> Bool {
    ["Impact", "Findings", "Burn Log"].allSatisfy { label in
      lines.contains { (" " + $0 + " ").contains(" " + label + " ") }
    }
  }
  // The switch is the first thing on the status row: 30 pt in, 76 pt down.
  func click() throws {
    settle()
    let y: CGFloat = 76
    let point = NSPoint(x: 30 + AutopilotSwitch.size.width / 2,
      y: host.isFlipped ? y : MiniImpactView.size.height - y)
    guard let target = host.hitTest(point) else { throw StoreError.message("No Autopilot switch hit target") }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: surface.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
        throw StoreError.message("Autopilot switch click unavailable")
      }
      if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
    }
    settle()
  }
  // A fresh install's Autopilot is on, and the popup shows it on.
  guard AutopilotSweepState().enabled, AutopilotSweepState().lookOnly == nil,
    model.autopilot.sweep.enabled else {
    throw StoreError.message("Autopilot doesn't start on")
  }
  let on = try render("autopilot-on").joined(separator: "\n")
  guard on.contains("Autopilot on"), !on.contains("Autopilot off") else {
    throw StoreError.message("The popup doesn't say Autopilot is on: \(on)")
  }
  try click()
  guard !model.autopilot.sweep.enabled else {
    throw StoreError.message("One click on the switch did not turn Autopilot off")
  }
  let offLines = try render("autopilot-off")
  let off = offLines.joined(separator: "\n")
  guard off.contains("Autopilot off"), !off.contains("Autopilot on"), off.contains("Hunt Zombies"),
    footer(offLines)
  else { throw StoreError.message("Autopilot off isn't plain on the popup: \(off)") }
  try click()
  guard model.autopilot.sweep.enabled else {
    throw StoreError.message("A second click did not turn Autopilot back on")
  }
  let back = try render("autopilot-back-on").joined(separator: "\n")
  guard back.contains("Autopilot on"), !back.contains("Autopilot off") else {
    throw StoreError.message("Turning Autopilot back on left the popup saying off: \(back)")
  }
  guard host.frame.size == MiniImpactView.size else { throw StoreError.message("Popover size changed") }

  // A busy engine answers late: the switch moves at once, and the engine's answer keeps it there.
  let busy = AppModel(demo: true)
  var saved = busy.autopilot
  saved.sweep.enabled = false
  let reply = saved
  busy.autopilotRunner = { _ in
    try await Task.sleep(for: .milliseconds(300))
    return reply
  }
  busy.setAutopilot(enabled: false)
  guard !busy.autopilot.sweep.enabled else {
    throw StoreError.message("The switch waited for a busy engine")
  }
  RunLoop.main.run(until: Date().addingTimeInterval(0.6))
  guard !busy.autopilot.sweep.enabled, busy.message == nil else {
    throw StoreError.message("The engine's answer moved the switch back")
  }
  // An engine that can't save it: the switch moves back, and the footer says why.
  let stuck = AppModel(demo: true)
  let why = "Saved permissions could not be read."
  stuck.autopilotRunner = { _ in throw StoreError.message(why) }
  stuck.setAutopilot(enabled: false)
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  guard stuck.autopilot.sweep.enabled, stuck.message == why else {
    throw StoreError.message("A change the engine couldn't save stayed on the switch")
  }
  print("PASS offscreen compact Autopilot switch: starts on, one click turns it off and the row says so, another turns it back on; it moves at once for a busy engine and moves back when the engine can't save it")
}

/// A look-only first run: the panel says nothing burns, shows what BZ would burn, and one tap on
/// Start burning turns burning on. The card takes the access banner's place until then.
@MainActor func miniLookOnlyProof(directory: URL) throws {
  let model = AppModel(demo: true)
  model.state.catalog = Catalog()
  model.state.fullDiskAccess = .init(state: .required,
    detail: "Enable Full Disk Access in System Settings, then check again.")
  model.autopilot.sweep.lookOnly = true
  let view = MiniImpactView(model: model)
  let host = NSHostingView(rootView: view)
  host.frame = NSRect(origin: .zero, size: MiniImpactView.size)
  let surface = NSWindow(contentRect: host.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
  surface.contentView = host
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }
  func render(_ name: String) throws -> String {
    settle()
    guard !surface.isVisible, !surface.isKeyWindow else {
      throw StoreError.message("Proof surface must stay offscreen")
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw StoreError.message("Compact render unavailable")
    }
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage,
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw StoreError.message("Compact PNG unavailable") }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([recognition])
    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
    try text.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    return text
  }
  let wouldBurn = ImpactNumbers.bytes(view.wouldBurn)
  let looking = try render("look-only")
  guard view.wouldBurn > 0, ["Look-only", "nothing burns", "LOOK-ONLY", "Start burning", wouldBurn,
    "See what in Findings"].allSatisfy(looking.contains),
    !looking.contains("Autopilot on"), !looking.contains("Allow Full Disk Access")
  else { throw StoreError.message("Look-only isn't obvious on the panel: \(looking)") }
  // The tap: Start burning sits at the right of the card, in the access banner's slot.
  let point = NSPoint(x: 261, y: host.isFlipped ? 372 : MiniImpactView.size.height - 372)
  settle()
  guard let target = host.hitTest(point) else { throw StoreError.message("No Start burning hit target") }
  for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    guard let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: surface.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
      throw StoreError.message("Start burning click unavailable")
    }
    if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
  }
  settle()
  guard model.autopilot.sweep.lookOnly == nil else {
    throw StoreError.message("One tap on Start burning did not turn burning on")
  }
  let burning = try render("look-only-started")
  guard burning.contains("Autopilot on"), burning.contains("Allow Full Disk Access"),
    !burning.contains("LOOK-ONLY"), !burning.contains("Start burning")
  else { throw StoreError.message("Start burning left the panel in look-only: \(burning)") }
  guard host.frame.size == MiniImpactView.size else { throw StoreError.message("Popover size changed") }
  print("PASS offscreen compact look-only: says nothing burns, shows \(wouldBurn) it would burn, one tap starts burning")
}

/// The popup's tabs switch its four totals, Autopilot's cleanups included, and nothing else: the
/// boost card stays on today and the Impact window keeps its own period.
@MainActor func miniPeriodsProof(directory: URL) throws {
  let model = AppModel(demo: true)
  var autopilot = AutopilotImpact()
  autopilot.worktrees = 30
  autopilot.bytes = 600_000_000_000
  autopilot.cleanups = [.init(receiptID: UUID(), date: Date(), worktree: true, bytes: 5_000_000_000)]
  model.state.autopilotImpact = autopilot
  let view = MiniImpactView(model: model)
  let host = NSHostingView(rootView: view)
  host.frame = NSRect(origin: .zero, size: MiniImpactView.size)
  let surface = NSWindow(contentRect: host.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
  surface.contentView = host
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }
  func click(_ option: ImpactPeriod) throws {
    settle()
    let index = ImpactPeriod.allCases.firstIndex(of: option)!
    // The tab row sits where the TODAY label was: 162 pt from the top, after the 30 pt margin.
    let x = 30 + CGFloat(index) * MiniImpactView.tabWidth + 12
    let point = NSPoint(x: x, y: host.isFlipped ? 162 : MiniImpactView.size.height - 162)
    guard let target = host.hitTest(point) else { throw StoreError.message("No tab hit target") }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: surface.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
        throw StoreError.message("Tab event unavailable")
      }
      if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
    }
    settle()
    guard model.miniImpactPeriod == option else {
      throw StoreError.message("Clicking \(option.rawValue) did not select it")
    }
  }
  func render(_ name: String) throws -> String {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
      pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw StoreError.message("Compact render unavailable")
    }
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage,
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw StoreError.message("Compact PNG unavailable") }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([recognition])
    return (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
  let card = view.numbers
  for option in [ImpactPeriod.all, .week, .today] {
    try click(option)
    let expected = ImpactNumbers.make(model, period: option)
    let earlier = ImpactNumbers.make(catalog: model.state.catalog, period: option)
    let mineWorktrees: Int = option == .all ? 30 : 1
    let mineBytes: UInt64 = option == .all ? 600_000_000_000 : 5_000_000_000
    guard view.totals.count == expected.count, view.totals.memory == expected.memory,
      view.totals.worktrees == earlier.worktrees + mineWorktrees,
      view.totals.disk == earlier.disk + mineBytes
    else { throw StoreError.message("The \(option.rawValue) tab shows the wrong totals") }
    guard view.numbers.count == card.count, view.numbers.memory == card.memory,
      model.impactPeriod == .today
    else { throw StoreError.message("The \(option.rawValue) tab changed more than the totals") }
    let visible = try render("periods-" + option.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))
    guard ["TODAY", "7 DAYS", "ALL TIME", "Disk reclaimed", "Worktrees cleaned",
      String(view.totals.worktrees)].allSatisfy(visible.contains)
    else { throw StoreError.message("The \(option.rawValue) tab isn't readable: \(visible)") }
  }
  print("PASS offscreen compact periods: tabs switch the four totals and nothing else")
}
#endif
