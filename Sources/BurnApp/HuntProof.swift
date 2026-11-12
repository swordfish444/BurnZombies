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
      snapshot.phase = phase
      snapshot.processCount = 842
      snapshot.evidenceReviewed = 6
      snapshot.attempts = 3
      snapshot.detail =
        phase == "paused"
        ? "Harness unavailable. Findings are preserved; no cleanup was attempted."
        : "Reviewing process ownership and completed worktrees. Active work stays protected."
      snapshot.append("info", "Manual hunt started.", date: now.addingTimeInterval(-160))
      snapshot.append(
        "info", "Observed 842 processes. Measuring large storage branches.",
        date: now.addingTimeInterval(-155))
      snapshot.append(
        "scanning", "Inspect completed for 3 helper processes.", date: now.addingTimeInterval(-95))
      snapshot.append(
        "warning", "Active development server preserved: a live consumer still needs it.",
        date: now.addingTimeInterval(-90))
      snapshot.append(
        "detected", "Released worktree passed the safety preview.",
        date: now.addingTimeInterval(-65))
      if phase == "completed" {
        snapshot.burned = 3
        snapshot.worktreesCleaned = 1
        snapshot.memoryReclaimed = 1_600_000_000
        snapshot.diskReclaimed = 18_400_000_000
        snapshot.append(
          "burn", "3 zombie processes eradicated. Exit verified.", date: now.addingTimeInterval(-40)
        )
        snapshot.append(
          "burn", "Worktree cleaned. Removal verified.", date: now.addingTimeInterval(-35))
        snapshot.append(
          "complete", "Hunt finished. Cleanup receipts verified.", date: now.addingTimeInterval(-20)
        )
        snapshot.finishedAt = now.addingTimeInterval(-20)
        snapshot.detail = "Hunt complete. Watching this Mac until the next hunt."
      }
      return snapshot
    }
    /// An Autopilot deep hunt: lanes, spend, the live focus and a question waiting.
    func deepFixture(_ phase: String) -> HuntSnapshot {
      var snapshot = HuntSnapshot(startedAt: now.addingTimeInterval(-300))
      snapshot.lane = "autopilot"
      snapshot.deep = true
      snapshot.phase = phase
      snapshot.limitUSD = 5
      snapshot.spentUSD = 1.2
      snapshot.tokens = 412_000
      snapshot.focus = "tsserver in orbit-web · 640 MB"
      snapshot.burned = 41
      snapshot.memoryReclaimed = 2_100_000_000
      snapshot.diskReclaimed = 16_300_000_000
      snapshot.worktreesCleaned = 6
      var programs = HuntLane(kind: "process")
      programs.seen = 2212
      programs.toJudge = 112
      programs.judged = 34
      programs.burned = 23
      programs.bytes = 2_100_000_000
      var copies = HuntLane(kind: "worktree")
      copies.seen = 143
      copies.toJudge = 61
      copies.judged = 20
      copies.burned = 6
      copies.bytes = 11_700_000_000
      var junk = HuntLane(kind: "disk")
      junk.seen = 120
      junk.toJudge = 41
      junk.judged = 12
      junk.burned = 12
      junk.bytes = 4_600_000_000
      snapshot.lanes = [programs, copies, junk]
      snapshot.append(
        "info", "Deep hunt started, up to $5. It burns as it goes, so stopping keeps every win.",
        date: now.addingTimeInterval(-300))
      snapshot.append(
        "burn", "Burned 12 junk folders your rules already cover. No AI needed, 4.6 GB back.",
        date: now.addingTimeInterval(-290))
      snapshot.append(
        "scanning", "Looking closely at node in orbit-web, 1.2 GB.",
        date: now.addingTimeInterval(-200))
      snapshot.append("detected", "Judged 23: 23 to burn.", date: now.addingTimeInterval(-190))
      snapshot.append(
        "burn", "Burned mcp-server-github. 90 MB of memory back.",
        date: now.addingTimeInterval(-185))
      snapshot.append(
        "thinking", "Old copies next: six are merged and untouched for weeks.",
        date: now.addingTimeInterval(-120))
      snapshot.append(
        "ask", "Needs you: Can I burn Xcode build caches untouched for two weeks?",
        date: now.addingTimeInterval(-60))
      snapshot.detail = "Deep hunt: the AI reads everything and burns as it goes."
      if phase == "stopped" {
        snapshot.stopReason = "stopped"
        snapshot.finishedAt = now.addingTimeInterval(-10)
        snapshot.detail = "Stopped. Everything burned stays burned: 18.4 GB freed for $1.20 of AI."
        snapshot.append("stopped", snapshot.detail, date: now.addingTimeInterval(-10))
      }
      if phase == "completed" {
        snapshot.lanes = snapshot.lanes?.map { lane in
          var done = lane
          done.judged = lane.toJudge
          return done
        }
        snapshot.focus = nil
        snapshot.finishedAt = now.addingTimeInterval(-10)
        snapshot.append(
          "burn",
          "Burned 6 old copies, merged and idle 2+ weeks. Restore points saved. 11.7 GB back.",
          date: now.addingTimeInterval(-40))
        snapshot.detail = "Deep hunt complete: 18.4 GB freed for $1.20 of AI."
        snapshot.append("complete", snapshot.detail, date: now.addingTimeInterval(-10))
      }
      return snapshot
    }
    /// The window at its default size, or at `width` × `height` such as the minimum, 800 × 760.
    func render(
      _ name: String, width: CGFloat = 948, height: CGFloat = 860,
      confirmation: HuntConfirmation? = nil
    ) throws {
      let host = NSHostingView(
        rootView: HuntView(model: model, sceneTime: 7.625, needsYouConfirmation: confirmation))
      host.frame = NSRect(x: 0, y: 0, width: width, height: height)
      let window = NSWindow(
        contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.contentView = host
      RunLoop.main.run(until: Date().addingTimeInterval(0.08))
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      guard
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0), !window.isVisible, !window.isKeyWindow
      else { throw StoreError.message("Offscreen hunt rendering unavailable") }
      bitmap.size = host.bounds.size
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw StoreError.message("Hunt PNG unavailable")
      }
      try png.write(to: directory.appendingPathComponent(name + ".png"))
      guard let image = NSBitmapImageRep(data: png)?.cgImage,
        let header = image.cropping(
          to: CGRect(
            x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height) * 0.2))
      else { throw StoreError.message("Saved Hunt image unavailable") }
      // Read the saved pixels, plus their header at a smaller scope: Vision sometimes omits
      // the plainly visible deep-hunt notice when analyzing the entire tall window.
      var readings: [String] = []
      for region in [image, header] {
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        recognition.minimumTextHeight = 0
        do { try VNImageRequestHandler(cgImage: region, options: [:]).perform([recognition]) } catch
        { throw StoreError.message("Hunt \(name) OCR failed: \(error.localizedDescription)") }
        readings += (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      }
      let recognized = readings.joined(separator: "\n")
      try recognized.write(
        to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
      // Vision may split tracked labels into separate observations on macOS 15.
      // Preserve its raw output, but compare words independently of OCR line breaks.
      let text = recognized.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        .joined(separator: " ")
      func expect(_ words: [String], _ problem: String) throws {
        let missing = words.filter { !text.contains($0) }
        guard missing.isEmpty else {
          throw StoreError.message("Hunt \(name): \(problem). Missing \(missing) in: \(text)")
        }
      }
      // Every state: the window's title and the feed. Vision reads "AI" as "Al", so checks stop short of it.
      try expect(["HUNT ZOMBIES", "Hunt feed"], "header or feed clipped")
      let base = name.replacingOccurrences(of: "-small", with: "")
      switch base {
      case "ready":
        // No hunt yet: the stats row rests with no numbers, so the page keeps its one layout.
        try expect(
          [
            "Hunt Zombies", "Deep hunt", "Up to $5", "A deep hunt uses more A", "Freed so far",
            "Nothing yet", "Programs", "Old copies",
            "Junk and caches", "Not looked at yet", "Ready to clear the dead weight", "Needs you",
          ],
          "the ready header, its deep hunt notice, the stats at rest or the empty feed is missing")
      case "running":
        try expect(
          [
            "Hunting Zombies", "Live", "Freed so far", "Zombies burned", "Worktrees cleaned",
            "Processes seen", "842",
            "Active development server preserved",
          ], "actual hunt evidence not displayed")
      case "completed":
        try expect(
          [
            "Freed this hunt", "20.0 GB", "1.6 GB memory", "18.4 GB disk", "Zombies burned",
            "Worktrees cleaned", "Processes seen",
            "Removal verified",
          ], "verified cleanup stats missing")
      case "paused":
        try expect(
          ["HUNT PAUSED", "Processes seen", "Harness unavailable"],
          "the pause and why it paused are missing")
      case "receipts-unavailable":
        try expect(
          ["Receipts unavailable", "Zombies burned", "Processes seen", "842"],
          "totals without receipts missing")
      case "deep-starting":
        try expect(
          [
            "Freed so far", "Programs", "Old copies", "Junk and caches", "Not looked at yet",
            "Looking over this Mac", "Nothing needs you right now",
          ],
          "a deep hunt's first moments are missing")
      case "deep-running":
        try expect(
          [
            "Deep hunt", "$1.20 of $5", "Stop", "Freed so far", "18.4 GB", "41 zombies burned",
            "Programs", "Old copies", "Junk and caches",
            "34 of 112 judged", "Burned 23", "2,212 running", "tsserver in orbit-web", "Needs you",
            "Xcode build folders", "Frees 31.0 GB",
            "Inside your projects", "Yes, burn them", "No, keep them", "Not sure", "View details",
            "1 of 2",
          ],
          "deep hunt stats, spend, focus or question missing")
      case "deep-stopped":
        try expect(
          [
            "Keep hunting", "Hunt Zombies", "Up to $5", "HUNT PAUSED", "Freed this hunt",
            "for $1.20 of A",
            "Stopped. Everything burned stays burned",
          ], "stopped deep hunt can't keep hunting")
      case "deep-needs-ok":
        // The copy's name, minus the "infra" Vision sometimes reads as "intra".
        try expect(
          [
            "Burn this copy?", "phase4-apply", "Made by Claude", "is sure", "Frees 4.0 GB",
            "Yes, burn it", "No, keep it", "Not sure",
          ],
          "the AI's sure-but-needs-OK card is missing")
      case "deep-completed":
        try expect(
          [
            "Hunt Zombies", "Deep hunt", "HUNT COMPLETE", "Freed this hunt", "for $1.20 of A",
            "112 of 112 judged", "Deep hunt complete",
            "Nothing needs you right now",
          ], "a finished deep hunt or the empty Needs you is missing")
      case "deep-answered":
        try expect(
          ["Burning them now", "BZ handles ones like these"], "the answer's confirmation is missing"
        )
      default:
        throw StoreError.message("Hunt \(name) has no checks")
      }
    }
    try render("ready")
    model.huntSnapshot = fixture("hunting")
    try render("running")
    try render("running-small", width: 800, height: 760)
    model.huntSnapshot = fixture("completed")
    try render("completed")
    model.huntSnapshot = fixture("paused")
    try render("paused")
    model.huntSnapshot?.receiptEvidenceAvailable = false
    try render("receipts-unavailable")
    // A deep hunt's first seconds: nothing counted yet, so the lanes say so without a number.
    model.autopilot.questions = []
    model.autopilot.entries = []
    var starting = HuntSnapshot(startedAt: now.addingTimeInterval(-4))
    starting.lane = "autopilot"
    starting.deep = true
    starting.limitUSD = 5
    starting.spentUSD = 0
    starting.focus = "Looking over this Mac"
    starting.detail = "Deep hunt: the AI reads everything and burns as it goes."
    starting.append(
      "info", "Deep hunt started, up to $5. It burns as it goes, so stopping keeps every win.",
      date: now.addingTimeInterval(-4))
    model.huntSnapshot = starting
    try render("deep-starting")
    var question = AutopilotQuestion(
      kind: .disk, match: ["folder": ["xcode-derived"], "stale": ["week"], "home": ["repo"]],
      question: "Can I burn Xcode build caches untouched for two weeks?", why: "", examples: [],
      count: 14, bytes: 31_000_000_000)
    question.line = "Your tools rebuild them when needed."
    var servers = AutopilotQuestion(
      kind: .process,
      match: ["family": ["node"], "listening": ["yes"], "idle": ["1d"], "thread": ["ended"]],
      question: "Can I burn dev servers from chats that ended?", why: "", examples: [], count: 6,
      bytes: 3_400_000_000)
    servers.line = "They just get asked to quit."
    model.autopilot.questions = [question, servers]
    model.huntSnapshot = deepFixture("hunting")
    try render("deep-running")
    try render("deep-running-small", width: 800, height: 760)
    try render(
      "deep-answered",
      confirmation: HuntConfirmation(
        title: "Burning them now", line: "BZ handles ones like these on its own from now on.",
        symbol: "flame.fill"))
    model.huntSnapshot = deepFixture("stopped")
    try render("deep-stopped")
    try render("deep-stopped-small", width: 800, height: 760)
    // Something the AI is sure about but may not burn itself waits for the owner's OK.
    var copy = AutopilotEntry(
      item: AutopilotItem(
        id: "worktree:infra", kind: .worktree, name: "infra-phase4-apply", bytes: 3_960_000_000,
        facts: ["place": "claude", "saved": "pushed", "inUse": "no"]),
      status: .unsure, authority: nil, label: "Merged infra copy", why: "", consequence: "")
    copy.needsOK = true
    copy.aiWhy = "Its work is merged on GitHub and nobody touched it in weeks."
    model.autopilot.questions = []
    model.autopilot.entries = [copy]
    model.huntSnapshot = deepFixture("hunting")
    try render("deep-needs-ok")
    try render("deep-needs-ok-small", width: 800, height: 760)
    // A deep hunt that finished with nothing left to ask: Needs you rests.
    model.autopilot.entries = []
    model.huntSnapshot = deepFixture("completed")
    try render("deep-completed")

    var calls = 0
    var opens = 0
    let control = AppModel(
      demo: true,
      huntAction: {
        calls += 1
        try? await Task.sleep(for: .milliseconds(500))
      })
    control.machineReviewEnabled = false
    control.openHunt = { opens += 1 }
    let history = control.state.catalog.lifetimeVerified
    let host = NSHostingView(rootView: BurnStatus(model: control, compact: true))
    host.frame = NSRect(x: 0, y: 0, width: 312, height: 32)
    let surface = NSWindow(
      contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    surface.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    // The button follows Autopilot's switch and the status text, whose wording depends on Autopilot.
    let status = BurnStatus(model: control, compact: true).status as NSString
    let width = status.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
    let point = NSPoint(x: AutopilotSwitch.size.width + 9 + width + 9 + 40, y: 16)
    guard let target = host.hitTest(point) else {
      throw StoreError.message("Hunt click target unavailable")
    }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = NSEvent.mouseEvent(
        with: type, location: host.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: surface.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
      if type == .leftMouseDown {
        target.mouseDown(with: event)
      } else {
        target.mouseUp(with: event)
      }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard calls == 1, opens == 1, control.huntRunning else {
      throw StoreError.message("Hunt button did not start exactly once with automatic hunts off")
    }
    control.requestAgentCleanup()
    guard calls == 1, opens == 2 else {
      throw StoreError.message("Active hunt failed to open progress or duplicated dispatch")
    }
    let deadline = Date().addingTimeInterval(2)
    while control.huntRunning && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard !control.huntRunning, control.state.catalog.lifetimeVerified == history,
      !surface.isVisible
    else { throw StoreError.message("Hunt control fabricated results or surfaced a test window") }
    var racedCalls = 0
    var racedOpens = 0
    let raced = AppModel(
      demo: true,
      huntAction: {
        racedCalls += 1
        try? await Task.sleep(for: .milliseconds(100))
      })
    raced.openHunt = { racedOpens += 1 }
    raced.runScheduledHunt()
    guard racedOpens == 0 else { throw StoreError.message("Scheduled hunt opened a window") }
    raced.requestAgentCleanup()
    let raceDeadline = Date().addingTimeInterval(2)
    while (racedCalls < 2 || raced.huntRunning) && Date() < raceDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    guard racedCalls == 2, racedOpens == 1, !raced.huntRunning else {
      throw StoreError.message("An automatic no-op swallowed the manual hunt")
    }
    print(
      "PASS native Hunt Zombies hit, manual with automatic off, active progress opening, duplicate prevention, live feed/counters and ready/running/complete/paused/unknown renders at the default and minimum sizes, deep hunt starting/running/stopped/completed with lanes, spend chip, Stop, Keep hunting, and Needs you question, OK, answered and empty cards; no model calls or visible windows"
    )
  }
#endif
