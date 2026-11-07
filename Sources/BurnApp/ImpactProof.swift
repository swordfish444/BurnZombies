#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Vision fails at random on a very busy Mac (CRImageReaderError), though the picture is fine.
@MainActor private func recognize(_ request: VNRequest, in image: CGImage) throws {
  var tries = 0
  while true {
    do {
      return try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      tries += 1
      guard tries < 10 else { throw error }
      RunLoop.main.run(until: Date().addingTimeInterval(3))
    }
  }
}

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
    try recognize(recognition, in: counters)
    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    guard visible.contains(String(count)) else {
      throw StoreError.message("Rendered counter did not update to \(count): \(visible)")
    }
    guard let heading = bitmap.cgImage?.cropping(to: CGRect(
      x: 80 * scale, y: 120 * scale, width: 540 * scale, height: 230 * scale)) else {
      throw StoreError.message("Rendered headline unavailable")
    }
    try recognize(recognition, in: heading)
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
  var fallbackProblems = [String]()
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
    try recognize(recognition, in: image)
    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    let expected = name == "empty" ? "Still warming up" : name == "quiet-day" ? "880 zombies burned all time" : ["disk", "worktrees"].contains(name) ? "4 worktrees cleaned" : "128 zombies burned"
    guard visible.contains(expected), !visible.contains("Before"), !visible.contains("No clear boost") else {
      fallbackProblems.append("\(name): the card should say \(expected)")
      continue
    }
    if !visible.contains("How BZ counts") {
      fallbackProblems.append("\(name): the card's link should read How BZ counts")
    }
    if name == "reclaimed" && !visible.contains("Memory released") {
      fallbackProblems.append("The card should call it Memory released, as the total above it does")
    }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    print("PASS native \(name) benefit render without misleading timing bars")
  }

  // The Burn Log, from a catalog in the order a real one ends up in: what was checked last sits
  // first in its list, and anything that couldn't be checked sits ahead of that. Autopilot's
  // receipts sit beside it: old copies, junk folders and the programs it also holds as events.
  let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
  func receipt(
    _ label: String, daysAgo: Int, _ outcome: String = "verified",
    detail: String = "Invented receipt"
  ) -> CleanupEvent {
    var event = CleanupEvent(
      leaseID: UUID(), label: label, date: today.addingTimeInterval(Double(-daysAgo) * 86400),
      targets: [Member(Observation(identity: .init(pid: 4321, seconds: 1)))],
      residentBefore: 3_800_000_000, outcome: outcome, detail: detail)
    event.verifiedCount = outcome == "verified" ? 1 : 0
    return event
  }
  func burn(
    _ name: String, _ kind: AutopilotKind, daysAgo: Int, outcome: String = "burned",
    bytes: UInt64, detail: String, eventID: UUID? = nil
  ) -> AutopilotReceipt {
    AutopilotReceipt(
      itemID: kind.rawValue + ":" + name, kind: kind, name: name, authority: "rule:fixture",
      outcome: outcome, detail: detail, bytes: bytes,
      date: today.addingTimeInterval(Double(-daysAgo) * 86400), eventID: eventID)
  }
  // Saved in the words every row on a real Mac has today.
  let newest = receipt(
    "Newest fixture burn", daysAgo: 0,
    detail:
      "Exact targets exited; no replacement was observed under the same verified parent during the 120-second watch. Reparented or differently owned replacements cannot be attributed. Resident footprint is an upper-bound attribution."
  )
  let middle = receipt(
    "Middle fixture burn", daysAgo: 3, "unverified",
    detail: "Observation was interrupted by restart, sleep, or a sampling gap. No benefit credited.")
  let oldest = receipt("Oldest fixture burn", daysAgo: 9)
  let copy = burn(
    "fixture-old-copy", .worktree, daysAgo: 1, bytes: 197_000_000,
    detail: "Removed. Everything in it was already saved, so you can restore it.")
  let folder = burn(
    "node_modules in fixture-app", .disk, daysAgo: 2, bytes: 583_000_000,
    detail: "Cleared node_modules in fixture-app. Your tools will rebuild it when they need it.")
  model.state = Demo.state()
  model.state.fullDiskAccess = .init(state: .granted, detail: "Preview access state.")
  model.state.catalog.events = [middle, newest, oldest]
  model.state.catalog.workspaceReceipts = []
  model.state.error = "Invented monitoring problem."
  model.autopilot.receipts = [
    // Autopilot's own record of the newest program, and a copy it only tried.
    burn(
      newest.label, .process, daysAgo: 0, bytes: newest.residentBefore,
      detail: "Stopped and verified.", eventID: newest.id),
    burn(
      "fixture-refused-copy", .worktree, daysAgo: 0, outcome: "refused", bytes: 0,
      detail: "Something is using that folder right now, so I left it alone."),
    copy, folder,
  ]
  var openedSettings = 0
  model.openSettings = { openedSettings += 1 }
  model.impactTab = "Burn Log"
  RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  settle()
  /// What OCR reads in the window, in the window's points, top down.
  func read(_ view: NSView, saving name: String? = nil) throws -> [(text: String, box: NSRect)] {
    settle()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw StoreError.message("Render unavailable")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.cgImage, !surface.isVisible, !surface.isKeyWindow else {
      throw StoreError.message("Offscreen render failed")
    }
    if let name, let png = bitmap.representation(using: .png, properties: [:]) {
      try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
    let reading = VNRecognizeTextRequest()
    reading.recognitionLevel = .accurate
    reading.usesLanguageCorrection = false
    try recognize(reading, in: image)
    return (reading.results ?? []).compactMap { line in
      guard let text = line.topCandidates(1).first?.string else { return nil }
      let box = line.boundingBox
      return (text, NSRect(
        x: box.minX * view.bounds.width, y: (1 - box.maxY) * view.bounds.height,
        width: box.width * view.bounds.width, height: box.height * view.bounds.height))
    }
  }
  var seen = try read(host, saving: "burn-log")
  func line(_ phrase: String) throws -> NSRect {
    guard let found = seen.first(where: { $0.text.contains(phrase) }) else {
      throw StoreError.message("The Burn Log is missing \"\(phrase)\": \(seen.map(\.text))")
    }
    return found.box
  }
  /// Everything wrong with the log, all at once.
  var problems = fallbackProblems
  func want(_ good: Bool, _ problem: @autoclosure () -> String) {
    if !good { problems.append(problem()) }
  }
  func says(_ phrase: String) -> Bool { seen.contains { $0.text.contains(phrase) } }

  // A control for what happens on its own goes.
  want(!says("Refresh"), "The Burn Log still has a Refresh button")

  // Every burn, once and newest first, whichever list holds it.
  want(
    seen.filter { $0.text.contains(newest.label) }.count == 1,
    "\(newest.label) should show once: \(seen.map(\.text))")
  want(!says("fixture-refused-copy"), "A copy BZ only tried isn't a burn: \(seen.map(\.text))")
  let shownRows: [(name: String, date: Date, result: String)] = [
    (newest.label, newest.date, "3.8 GB memory"), (copy.name, copy.date, "197 MB disk"),
    (folder.name, folder.date, "583 MB disk"), (middle.label, middle.date, "Not sure"),
    (oldest.label, oldest.date, "3.8 GB memory"),
  ]
  var places = [String: NSRect]()
  for row in shownRows {
    if let found = seen.first(where: { $0.text.contains(row.name) }) {
      places[row.name] = found.box
    } else {
      problems.append("The Burn Log doesn't list \(row.name): \(seen.map(\.text))")
    }
  }
  let found = shownRows.compactMap { places[$0.name] }
  want(
    zip(found, found.dropFirst()).allSatisfy { $0.minY < $1.minY },
    "The Burn Log isn't newest first: \(found.map { Int($0.minY) })")
  // Each row says what it freed and its own day, on its own line, and the columns line up.
  var dayEdges = [Int]()
  var dayLines = [CGFloat]()
  for row in shownRows {
    guard let place = places[row.name] else { continue }
    let onLine = seen.filter { abs($0.box.midY - place.midY) < 12 }
    want(
      onLine.contains { $0.text.contains(row.result) },
      "\(row.name) doesn't say \(row.result): \(onLine.map(\.text))")
    let day = ImpactNumbers.day(row.date)
    if let shown = onLine.first(where: { $0.text.contains(day) }) {
      dayEdges.append(Int(shown.box.maxX))
      dayLines.append(shown.box.midY)
    } else {
      problems.append("\(row.name) doesn't say \(day): \(onLine.map(\.text))")
    }
  }
  want(
    (dayEdges.max() ?? 0) - (dayEdges.min() ?? 0) <= 6,
    "The days don't line up: right edges at \(dayEdges)")
  // Names start in one column whichever icon leads the row.
  let nameEdges = found.map { Int($0.minX) }
  want(
    (nameEdges.max() ?? 0) - (nameEdges.min() ?? 0) <= 4,
    "The names don't line up: left edges at \(nameEdges)")
  // Hundreds of rows have to scan: a dozen fit a screen, each the same height whatever it burned.
  let gaps = zip(dayLines, dayLines.dropFirst()).map { $1 - $0 }
  want(gaps.allSatisfy { $0 <= 56 }, "The rows sit too far apart to scan: \(gaps)")
  let marks = BurnLogRow.Kind.allCases.map { NSHostingView(rootView: BurnMark(kind: $0)).fittingSize }
  want(Set(marks.map(\.height)).count == 1, "The rows aren't one height, their marks are: \(marks)")
  // The key names the three kinds beside the list's heading.
  if let heading = seen.first(where: { $0.text.contains("RECENT") })?.box {
    for kind in BurnLogRow.Kind.allCases {
      want(
        seen.contains { $0.text.contains(kind.rawValue) && abs($0.box.midY - heading.midY) < 12 },
        "The key doesn't name \(kind.rawValue): \(seen.map(\.text))")
    }
  } else {
    problems.append("The list has no heading: \(seen.map(\.text))")
  }
  guard !seen.contains(where: { $0.text.contains("WORTH A LOOK") || $0.text.contains("Open details") })
  else { throw StoreError.message("The Burn Log still points at the old details: \(seen.map(\.text))") }

  // An opened row reads plainly, whatever it was saved with.
  let jargon = [
    "Resident", "upper-bound", "attribut", "verified parent", "Reparented", "replacement",
    "benefit", "credited",
  ]
  func center(_ box: NSRect, in view: NSView) -> NSPoint {
    NSPoint(x: box.midX, y: view.isFlipped ? box.midY : view.bounds.height - box.midY)
  }
  if let place = places[newest.label] {
    try click(center(place, in: host))
    seen = try read(host, saving: "burn-log-open")
    want(says("Stopped. BZ checked"), "An opened program row isn't plain: \(seen.map(\.text))")
    for word in jargon {
      want(!says(word), "An opened program row still says \(word): \(seen.map(\.text))")
    }
    try click(center(place, in: host))
    seen = try read(host)
  }
  if let place = places[copy.name] {
    try click(center(place, in: host))
    seen = try read(host, saving: "burn-log-open-copy")
    want(
      says("already saved") && says("Findings"),
      "An opened copy row should say it's saved and where to restore it: \(seen.map(\.text))")
    try click(center(place, in: host))
    seen = try read(host)
  }

  // A busy Mac burns hundreds a week: only the rows on screen get made.
  let everyBurn = model.autopilot.receipts
  model.autopilot.receipts = (0..<2000).map {
    burn("fixture-copy-\($0)", .worktree, daysAgo: 0, bytes: 1_000_000, detail: "Removed.")
  }
  settle()
  let made = appKitViews(NSView.self, in: host).count
  want(made < 400, "A long log made \(made) views for 2,000 rows, not just what's on screen")
  print("Burn Log with 2,000 rows made \(made) views")
  model.autopilot.receipts = everyBurn
  settle()

  // The one way out of the log when monitoring has a problem goes to the window that shows it.
  let open = try line("Open Settings")
  try click(center(open, in: host))
  guard openedSettings == 1 else {
    throw StoreError.message("Open Settings didn't open Settings")
  }
  want(!says("Monitoring"), "The problem should read plainly: \(seen.map(\.text))")

  // Impact's last burn is the log's newest row, even when that's an old copy. Autopilot's cleanup
  // tally dates it, so the name has to come from the log too.
  model.state.error = nil
  var newestCopy = burn(
    "fixture-latest-copy", .worktree, daysAgo: 0, bytes: 123_000_000,
    detail: "Removed. Everything in it was already saved, so you can restore it.")
  newestCopy.date = Date().addingTimeInterval(-1)
  model.autopilot.receipts.insert(newestCopy, at: 0)
  model.impactPeriod = .all
  model.impactTab = "Impact"
  RunLoop.main.run(until: Date().addingTimeInterval(0.7))
  seen = try read(host, saving: "impact-last-burn")
  want(
    says("Last burn") && says(newestCopy.name),
    "Impact's last burn should name the log's newest row: \(seen.map(\.text))")
  want(says("123 MB disk"), "Impact's last burn should say what it freed: \(seen.map(\.text))")
  want(says("Finished burns"), "The caption should read plainly: \(seen.map(\.text))")

  // The sheet: short, plain, one screen, and its buttons work.
  var done = 0
  var logs = 0
  func sheetHost(_ numbers: ImpactNumbers) -> NSHostingView<BurnCountsSheet> {
    let sheet = BurnCountsSheet(
      numbers: numbers, demo: false, done: { done += 1 }, openLog: { logs += 1 }, previewBurn: {})
    let view = NSHostingView(rootView: sheet)
    view.frame = NSRect(x: 0, y: 0, width: BurnCountsSheet.width, height: 10)
    view.frame.size.height = view.fittingSize.height
    return view
  }
  var measured = ImpactNumbers.make(catalog: Catalog(), period: .all)
  measured.cpuSeconds = 7200
  measured.before = 3.2
  measured.after = 2.4
  let sheet = sheetHost(measured)
  let sheetSurface = NSWindow(
    contentRect: sheet.frame, styleMask: .borderless, backing: .buffered, defer: false)
  sheetSurface.isReleasedWhenClosed = false
  sheetSurface.contentView = sheet
  want(sheet.frame.height <= 620, "The sheet is a wall of text: \(Int(sheet.frame.height)) pt tall")
  for fact in BurnCountsSheet.facts {
    let words = fact.words.split(whereSeparator: \.isWhitespace).count
    want(words <= 35, "\(fact.name) takes \(words) words: \(fact.words)")
    for word in jargon + [
      "native", "APFS", "receipt", "samples", "dispersion", "Legacy", "neutral", "attribution",
      "observed", "worktree", "Worktree",
    ] {
      want(!fact.words.contains(word), "\(fact.name) still says \(word): \(fact.words)")
    }
  }
  var sheetSeen = try read(sheet, saving: "how-bz-counts")
  func sheetSays(_ phrase: String) -> Bool { sheetSeen.contains { $0.text.contains(phrase) } }
  want(sheetSays("HOW BZ COUNTS"), "The sheet's title isn't plain: \(sheetSeen.map(\.text))")
  for fact in BurnCountsSheet.facts {
    want(sheetSays(fact.name), "The sheet doesn't show \(fact.name): \(sheetSeen.map(\.text))")
  }
  // A number sits on its own fact's line.
  func onFactLine(_ name: String, _ value: String) -> Bool {
    guard let place = sheetSeen.first(where: { $0.text.contains(name) })?.box else { return false }
    return sheetSeen.contains { $0.text.contains(value) && abs($0.box.midY - place.midY) < 10 }
  }
  want(onFactLine("CPU time saved", "2.0"), "CPU time saved has no number: \(sheetSeen.map(\.text))")
  want(onFactLine("Agent speed", "2.4"), "Agent speed has no numbers: \(sheetSeen.map(\.text))")
  // Its buttons press through the real views SwiftUI made.
  let buttons = appKitViews(NSButton.self, in: sheet)
    .map { (button: $0, box: $0.convert($0.bounds, to: sheet)) }
    .sorted { $0.box.minY < $1.box.minY }
  want(buttons.count == 2, "The sheet should have two buttons, not \(buttons.count)")
  // Done up top beside the title and the way to the log at the bottom, both on the right edge.
  if buttons.count == 2 {
    want(buttons[0].box.maxY < 90, "Done isn't up top: y=\(Int(buttons[0].box.minY))")
    want(
      buttons[1].box.minY > sheet.frame.height - 90,
      "Open Burn Log isn't at the bottom: y=\(Int(buttons[1].box.minY))")
    for (name, box) in zip(["Done", "Open Burn Log"], buttons.map(\.box)) {
      want(abs(box.maxX - (BurnCountsSheet.width - 32)) <= 8, "\(name) ends at x=\(Int(box.maxX))")
    }
  }
  buttons.first?.button.performClick(nil)
  settle()
  want(done == 1 && logs == 0, "Done didn't close the sheet")
  buttons.last?.button.performClick(nil)
  settle()
  want(done == 1 && logs == 1, "Open Burn Log didn't open the log")
  // A number nobody has yet doesn't show as a dash.
  var unknown = ImpactNumbers.make(catalog: Catalog(), period: .all)
  unknown.cpuSeconds = nil
  let empty = sheetHost(unknown)
  sheetSurface.contentView = empty
  sheetSeen = try read(empty, saving: "how-bz-counts-unmeasured")
  want(!sheetSays("Before"), "No timing yet, so no Before: \(sheetSeen.map(\.text))")
  for fact in BurnCountsSheet.facts {
    let number = empty.rootView.value(fact)
    want(number == nil, "\(fact.name) shows \(number ?? "") before there's a number")
  }
  sheetSurface.contentView = nil
  sheetSurface.close()
  if !problems.isEmpty {
    throw StoreError.message("\(problems.count) problems:\n  " + problems.joined(separator: "\n  "))
  }
  model.autopilot.receipts = []
  print("PASS Burn Log: every burn once and newest first whatever list holds it, no Refresh, what each freed and its day lined up, opened rows and How BZ counts in plain words, Open Settings and the sheet's buttons pressed through their real views")
}
#endif
