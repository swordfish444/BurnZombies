#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

@MainActor func huntProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let model = AppModel(demo: true)
  let now = Date()
  func fixture(_ phase: String) -> HuntSnapshot {
    var snapshot = HuntSnapshot(startedAt: now.addingTimeInterval(-160))
    snapshot.phase = phase; snapshot.processCount = 842; snapshot.evidenceReviewed = 6; snapshot.attempts = 3
    snapshot.detail = phase == "paused" ? "Harness unavailable. Findings are preserved; no cleanup was attempted." : "Reviewing process ownership and completed worktrees. Active work stays protected."
    snapshot.append("info", "Manual hunt started.", date: now.addingTimeInterval(-160))
    snapshot.append("info", "Observed 842 processes. Measuring large storage branches.", date: now.addingTimeInterval(-155))
    snapshot.append("scanning", "Inspect completed for 3 helper processes.", date: now.addingTimeInterval(-95))
    snapshot.append("warning", "Active development server preserved: a live consumer still needs it.", date: now.addingTimeInterval(-90))
    snapshot.append("detected", "Released worktree passed the safety preview.", date: now.addingTimeInterval(-65))
    if phase == "completed" {
      snapshot.burned = 3; snapshot.worktreesCleaned = 1; snapshot.memoryReclaimed = 1_600_000_000; snapshot.diskReclaimed = 18_400_000_000
      snapshot.append("burn", "3 zombie processes eradicated. Exit verified.", date: now.addingTimeInterval(-40))
      snapshot.append("burn", "Worktree cleaned. Removal verified.", date: now.addingTimeInterval(-35))
      snapshot.append("complete", "Hunt finished. Cleanup receipts verified.", date: now.addingTimeInterval(-20))
      snapshot.finishedAt = now.addingTimeInterval(-20)
      snapshot.detail = "Hunt complete. Watching this Mac until the next hunt."
    }
    return snapshot
  }
  /// An Autopilot deep hunt: lanes, spend, the live focus and a question waiting.
  func deepFixture(_ phase: String) -> HuntSnapshot {
    var snapshot = HuntSnapshot(startedAt: now.addingTimeInterval(-300))
    snapshot.lane = "autopilot"; snapshot.deep = true; snapshot.phase = phase
    snapshot.limitUSD = 5; snapshot.spentUSD = 1.2; snapshot.tokens = 412_000
    snapshot.focus = "tsserver in orbit-web · 640 MB"
    snapshot.burned = 41; snapshot.memoryReclaimed = 2_100_000_000; snapshot.diskReclaimed = 16_300_000_000
    snapshot.worktreesCleaned = 6
    var programs = HuntLane(kind: "process"); programs.seen = 2212; programs.toJudge = 112; programs.judged = 34
    programs.burned = 23; programs.bytes = 2_100_000_000
    var copies = HuntLane(kind: "worktree"); copies.seen = 143; copies.toJudge = 61; copies.judged = 20
    copies.burned = 6; copies.bytes = 11_700_000_000
    var junk = HuntLane(kind: "disk"); junk.seen = 120; junk.toJudge = 41; junk.judged = 12
    junk.burned = 12; junk.bytes = 4_600_000_000
    snapshot.lanes = [programs, copies, junk]
    snapshot.append("info", "Deep hunt started, up to $5. It burns as it goes, so stopping keeps every win.", date: now.addingTimeInterval(-300))
    snapshot.append("burn", "Burned 12 junk folders your rules already cover. No AI needed, 4.6 GB back.", date: now.addingTimeInterval(-290))
    snapshot.append("scanning", "Looking closely at node in orbit-web, 1.2 GB.", date: now.addingTimeInterval(-200))
    snapshot.append("detected", "Judged 23: 23 to burn.", date: now.addingTimeInterval(-190))
    snapshot.append("burn", "Burned mcp-server-github. 90 MB of memory back.", date: now.addingTimeInterval(-185))
    snapshot.append("thinking", "Old copies next: six are merged and untouched for weeks.", date: now.addingTimeInterval(-120))
    snapshot.append("ask", "Needs you: Can I burn Xcode build caches untouched for two weeks?", date: now.addingTimeInterval(-60))
    snapshot.detail = "Deep hunt: the AI reads everything and burns as it goes."
    if phase == "stopped" {
      snapshot.stopReason = "stopped"; snapshot.finishedAt = now.addingTimeInterval(-10)
      snapshot.detail = "Stopped. Everything burned stays burned: 18.4 GB freed for $1.20 of AI."
      snapshot.append("stopped", snapshot.detail, date: now.addingTimeInterval(-10))
    }
    return snapshot
  }
  func render(_ name: String, width: CGFloat = 948) throws {
    let host = NSHostingView(rootView: HuntView(model: model, sceneTime: 7.625))
    host.frame = NSRect(x: 0, y: 0, width: width, height: 860)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: 1720,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0), !window.isVisible, !window.isKeyWindow else { throw StoreError.message("Offscreen hunt rendering unavailable") }
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let cg = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:]) else { throw StoreError.message("Hunt PNG unavailable") }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([recognition]) }
    catch { throw StoreError.message("Hunt \(name) OCR failed: \(error.localizedDescription)") }
    let recognized = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    try recognized.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    // Vision may split tracked labels into separate observations on macOS 15.
    // Preserve its raw output, but compare words independently of OCR line breaks.
    let text = recognized.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    // Older hunts show their totals; Autopilot hunts their lanes.
    let labels = name.hasPrefix("deep") ? ["Programs", "Old copies", "Junk and caches"] : ["Processes seen", "Worktrees cleaned"]
    guard text.contains("HUNT ZOMBIES"), text.contains("HUNT FEED"), labels.allSatisfy(text.contains) else { throw StoreError.message("Hunt interface clipped: \(text)") }
    if name == "deep-running" {
      guard text.contains("$1.20 of $5"), text.contains("Stop"), text.uppercased().contains("NEEDS YOU"), text.contains("Yes, burn them"),
        text.contains("18.4 GB"), text.contains("tsserver in orbit-web") else { throw StoreError.message("Deep hunt stats, spend, focus or question missing: \(text)") }
    }
    if name == "deep-stopped" {
      guard text.contains("Keep hunting"), text.contains("for $1.20 of A") /* Vision reads "AI" as "Al" */, text.contains("Up to $5") else { throw StoreError.message("Stopped deep hunt can't keep hunting: \(text)") }
    }
    if name == "running" { guard text.contains("842"), text.contains("Active development server preserved") else { throw StoreError.message("Actual hunt evidence not displayed") } }
    if name == "completed" { guard text.contains("18.4 GB"), text.contains("Removal verified") else { throw StoreError.message("Verified cleanup stats missing") } }
  }
  try render("ready")
  model.huntSnapshot = fixture("hunting"); try render("running"); try render("running-small", width: 800)
  model.huntSnapshot = fixture("completed"); try render("completed")
  model.huntSnapshot = fixture("paused"); try render("paused")
  model.huntSnapshot?.receiptEvidenceAvailable = false; try render("receipts-unavailable")
  var question = AutopilotQuestion(kind: .disk, match: ["family": ["xcode"], "stale": ["week"]], question: "Can I burn Xcode build caches untouched for two weeks?",
    why: "", examples: [], count: 14, bytes: 31_000_000_000)
  question.line = "Your tools rebuild them when needed."
  model.autopilot.questions = [question]
  model.huntSnapshot = deepFixture("hunting"); try render("deep-running"); try render("deep-running-small", width: 800)
  model.huntSnapshot = deepFixture("stopped"); try render("deep-stopped")

  var calls = 0, opens = 0
  let control = AppModel(demo: true, huntAction: {
    calls += 1
    try? await Task.sleep(for: .milliseconds(500))
  })
  control.machineReviewEnabled = false
  control.openHunt = { opens += 1 }
  let history = control.state.catalog.lifetimeVerified
  let host = NSHostingView(rootView: BurnStatus(model: control, compact: true))
  host.frame = NSRect(x: 0, y: 0, width: 312, height: 32)
  let surface = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
  surface.contentView = host
  RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
  // The button follows the status text, whose wording depends on Autopilot.
  let status = BurnStatus(model: control, compact: true).status as NSString
  let width = status.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
  let point = NSPoint(x: 12 + 9 + width + 9 + 40, y: 16)
  guard let target = host.hitTest(point) else { throw StoreError.message("Hunt click target unavailable") }
  for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: surface.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
  }
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  guard calls == 1, opens == 1, control.huntRunning else { throw StoreError.message("Hunt button did not start exactly once with automatic hunts off") }
  control.requestAgentCleanup()
  guard calls == 1, opens == 2 else { throw StoreError.message("Active hunt failed to open progress or duplicated dispatch") }
  let deadline = Date().addingTimeInterval(2)
  while control.huntRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  guard !control.huntRunning, control.state.catalog.lifetimeVerified == history, !surface.isVisible else { throw StoreError.message("Hunt control fabricated results or surfaced a test window") }
  var racedCalls = 0, racedOpens = 0
  let raced = AppModel(demo: true, huntAction: {
    racedCalls += 1
    try? await Task.sleep(for: .milliseconds(100))
  })
  raced.openHunt = { racedOpens += 1 }
  raced.runScheduledHunt()
  guard racedOpens == 0 else { throw StoreError.message("Scheduled hunt opened a window") }
  raced.requestAgentCleanup()
  let raceDeadline = Date().addingTimeInterval(2)
  while (racedCalls < 2 || raced.huntRunning) && Date() < raceDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  guard racedCalls == 2, racedOpens == 1, !raced.huntRunning else { throw StoreError.message("An automatic no-op swallowed the manual hunt") }
  print("PASS native Hunt Zombies hit, manual with automatic off, active progress opening, duplicate prevention, live feed/counters and ready/running/complete/paused/unknown renders, deep hunt lanes, spend chip, Stop, Needs you and Keep hunting; no model calls or visible windows")
}
#endif
