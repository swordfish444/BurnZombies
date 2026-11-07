#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Renders the shipped view after selection changes, without a window or observer.
@MainActor func impactProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let model = AppModel(demo: true)
  let host = NSHostingView(rootView: ImpactWindowView(model: model))
  host.frame = NSRect(x: 0, y: 0, width: 1008, height: 930)
  // AppKit-backed glyph views need a backing surface, but it is never shown.
  let surface = NSWindow(contentRect: host.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
  surface.contentView = host
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }
  /// Delivers local events only; never posts desktop input or shows a window.
  func click(_ point: NSPoint) throws {
    guard let target = host.hitTest(point) else { throw StoreError.message("No hit target") }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: surface.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
        throw StoreError.message("Click event unavailable")
      }
      if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
    }
    settle()
  }
  func clickPeriod(_ option: ImpactPeriod) throws {
    settle()
    let index = ImpactPeriod.allCases.firstIndex(of: option)!
    // Bottom of the actual button: the decorative halo previously extended into this row.
    try click(NSPoint(x: 697 + index * 104, y: host.isFlipped ? 108 : 930 - 108))
    guard model.impactPeriod == option else { throw StoreError.message("Actual period click did not select \(option.rawValue)") }
  }
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for (period, count) in [(ImpactPeriod.week, 368), (.all, 880), (.today, 128)] {
    try clickPeriod(period)
    settle()
    let numbers = ImpactNumbers.make(model, period: model.impactPeriod)
    guard model.impactPeriod == period, numbers.count == count else {
      throw StoreError.message("Filter did not update selection and totals")
    }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw StoreError.message("Impact render unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard !surface.isVisible, !surface.isKeyWindow else {
      throw StoreError.message("Proof surface must stay offscreen")
    }
    // Read the rendered counter, not just the model: transitions can retain an old value.
    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
    guard let counters = bitmap.cgImage?.cropping(to: CGRect(
      x: 40 * scale, y: 400 * scale, width: 928 * scale, height: 85 * scale)) else {
      throw StoreError.message("Rendered counters unavailable")
    }
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    recognition.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: counters, options: [:]).perform([recognition])
    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    guard visible.contains(String(count)) else {
      throw StoreError.message("Rendered counter did not update to \(count): \(visible)")
    }
    guard let heading = bitmap.cgImage?.cropping(to: CGRect(
      x: 80 * scale, y: 120 * scale, width: 540 * scale, height: 230 * scale)) else {
      throw StoreError.message("Rendered headline unavailable")
    }
    try VNImageRequestHandler(cgImage: heading, options: [:]).perform([recognition])
    let headline = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
    guard headline.contains("TAME THE"), headline.contains("HORDE") else {
      throw StoreError.message("Rendered headline incomplete: \(headline)")
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw StoreError.message("Impact PNG unavailable")
    }
    try png.write(to: directory.appendingPathComponent(period.rawValue + ".png"))
    print("PASS native \(period.rawValue) render: \(numbers.count) burns, \(numbers.memory) bytes")
  }
  model.previewBurn()
  settle()
  guard ImpactNumbers.make(model, period: model.impactPeriod).count == 146,
    model.burnPulse == 1 else { throw StoreError.message("Preview burn did not update the selected period once") }
  for period in [ImpactPeriod.week, .today, .all, .week] { try clickPeriod(period) }
  model.impactTab = "Burn Log"; settle()
  model.impactTab = "Impact"; settle()
  guard model.impactPeriod == .week else { throw StoreError.message("Navigation reset the filter") }
  print("PASS real period hit targets in both directions, offscreen rendering, receipt updates and tab navigation")
  // A real cleanup's resource benefit must stay prominent without benchmark samples.
  // Capture all fallback states through the same native layout as the shipped window.
  for name in ["reclaimed", "helpers", "quiet-day", "empty", "disk", "worktrees"] {
    model.state = Demo.state()
    model.state.fullDiskAccess = .init(state: .granted, detail: "Preview access state.")
    for i in model.state.catalog.events.indices {
      model.state.catalog.events[i].responseBeforeMS = nil
      model.state.catalog.events[i].responseAfterMS = nil
      model.state.catalog.events[i].responseBeforeSamples = nil
      model.state.catalog.events[i].responseAfterSamples = nil
      if name == "helpers" { model.state.catalog.events[i].residentBefore = 0 }
    }
    if name == "quiet-day" { model.state.catalog.events = []; model.state.catalog.workspaceReceipts = [] }
    if name == "empty" { model.state.catalog = Catalog() }
    if name == "disk" || name == "worktrees" {
      model.state.catalog.events = []; model.state.catalog.lifetimeVerified = 0
      model.state.catalog.lifetimeResidentReleased = 0
      if name == "worktrees" {
        for i in model.state.catalog.workspaceReceipts!.indices { model.state.catalog.workspaceReceipts?[i].diskReclaimedBytes = 0 }
        model.state.catalog.lifetimeDiskReclaimedBytes = 0
      }
    }
    try clickPeriod(.today)
    // Let numeric transitions settle after fixture changes.
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    settle()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw StoreError.message("Benefit render unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let image = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:]),
      !surface.isVisible, !surface.isKeyWindow else { throw StoreError.message("Offscreen benefit render failed") }
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognition])
    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    let expected = name == "empty" ? "Still warming up" : name == "quiet-day" ? "880 helpers cleared all time" : ["disk", "worktrees"].contains(name) ? "4 worktrees cleaned" : "128 helpers cleared"
    guard visible.contains(expected), !visible.contains("Before"), !visible.contains("No clear boost"),
      visible.contains("View impact details") else { throw StoreError.message("Benefit fallback missing or clipped: \(visible)") }
    if name == "reclaimed" && !visible.contains("Memory reclaimed") {
      throw StoreError.message("Reclaimed memory not shown")
    }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    print("PASS native \(name) benefit render without misleading timing bars")
  }

  // The Burn Log, from a catalog in the order a real one ends up in: what was checked last sits
  // first in its list, and anything that couldn't be checked sits ahead of that.
  let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
  func receipt(_ label: String, daysAgo: Int, _ outcome: String = "verified") -> CleanupEvent {
    var event = CleanupEvent(
      leaseID: UUID(), label: label, date: today.addingTimeInterval(Double(-daysAgo) * 86400),
      targets: [Member(Observation(identity: .init(pid: 4321, seconds: 1)))],
      residentBefore: 3_800_000_000, outcome: outcome, detail: "Invented receipt")
    event.verifiedCount = outcome == "verified" ? 1 : 0
    return event
  }
  let newest = receipt("Newest fixture burn", daysAgo: 0)
  let middle = receipt("Middle fixture burn", daysAgo: 3, "unverified")
  let oldest = receipt("Oldest fixture burn", daysAgo: 9)
  model.state = Demo.state()
  model.state.fullDiskAccess = .init(state: .granted, detail: "Preview access state.")
  model.state.catalog.events = [middle, newest, oldest]
  model.state.catalog.workspaceReceipts = []
  model.state.error = "Invented monitoring problem."
  var openedSettings = 0
  model.openSettings = { openedSettings += 1 }
  model.impactTab = "Burn Log"
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  settle()
  guard let log = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
    throw StoreError.message("Burn Log render unavailable")
  }
  host.cacheDisplay(in: host.bounds, to: log)
  guard let logImage = log.cgImage, let logPNG = log.representation(using: .png, properties: [:]),
    !surface.isVisible, !surface.isKeyWindow
  else { throw StoreError.message("Offscreen Burn Log render failed") }
  try logPNG.write(to: directory.appendingPathComponent("burn-log.png"))
  let reading = VNRecognizeTextRequest()
  reading.recognitionLevel = .accurate
  try VNImageRequestHandler(cgImage: logImage, options: [:]).perform([reading])
  /// In the window's points, top down, whatever OCR read and where.
  let seen: [(text: String, box: NSRect)] = (reading.results ?? []).compactMap { line in
    guard let text = line.topCandidates(1).first?.string else { return nil }
    let box = line.boundingBox
    return (text, NSRect(
      x: box.minX * host.bounds.width, y: (1 - box.maxY) * host.bounds.height,
      width: box.width * host.bounds.width, height: box.height * host.bounds.height))
  }
  func line(_ phrase: String) throws -> NSRect {
    guard let found = seen.first(where: { $0.text.contains(phrase) }) else {
      throw StoreError.message("The Burn Log is missing \"\(phrase)\": \(seen.map(\.text))")
    }
    return found.box
  }
  let rows = [newest, middle, oldest]
  let places = try rows.map { try line($0.label) }
  guard places[0].minY < places[1].minY, places[1].minY < places[2].minY else {
    throw StoreError.message("The Burn Log isn't newest first: \(places.map { Int($0.minY) })")
  }
  // Each row says its own day, on its own line, and the days line up.
  var dayEdges = [Int]()
  for (row, place) in zip(rows, places) {
    let day = ImpactNumbers.day(row.date)
    guard
      let shown = seen.first(where: { $0.text.contains(day) && abs($0.box.midY - place.midY) < 12 })
    else {
      throw StoreError.message("\(row.label) doesn't say \(day): \(seen.map(\.text))")
    }
    dayEdges.append(Int(shown.box.maxX))
  }
  guard (dayEdges.max() ?? 0) - (dayEdges.min() ?? 0) <= 6 else {
    throw StoreError.message("The days don't line up: right edges at \(dayEdges)")
  }
  guard !seen.contains(where: { $0.text.contains("WORTH A LOOK") || $0.text.contains("Open details") })
  else { throw StoreError.message("The Burn Log still points at the old details: \(seen.map(\.text))") }
  // The one way out of the log when monitoring has a problem goes to the window that shows it.
  let open = try line("Open Settings")
  try click(NSPoint(x: open.midX, y: host.isFlipped ? open.midY : host.bounds.height - open.midY))
  guard openedSettings == 1 else {
    throw StoreError.message("Open Settings didn't open Settings")
  }
  model.state.error = nil
  model.impactTab = "Impact"
  print("PASS Burn Log: newest first whatever order the catalog holds, each row with its day, days lined up, Open Settings pressed through its real view")
}
#endif
