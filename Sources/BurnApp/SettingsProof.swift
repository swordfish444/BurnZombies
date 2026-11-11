#if DEBUG
  import AppKit
  import BurnCore
  import SwiftUI
  import Vision

  /// What Settings saves and says, without starting an observer or showing a window.
  @MainActor func settingsProof(output: String) throws {
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    func fail(_ message: String) -> Error { StoreError.message(message) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bz-settings-ui-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    // The AI rows, with two pretend AIs installed.
    let bins = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bins, withIntermediateDirectories: true)
    for name in ["claude", "codex"] {
      let tool = bins.appendingPathComponent(name)
      try Data("#!/bin/sh\n".utf8).write(to: tool)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }
    setenv("PATH", bins.path, 1)
    setenv("BURNZOMBIES_HARNESS_DIRS", bins.path, 1)
    let aiRoot = root.appendingPathComponent("ai")
    let app = URL(fileURLWithPath: "/Applications/BZ.app")
    let ai = AISettingsModel(root: aiRoot, bundle: app)
    var saves = 0
    ai.saved = { saves += 1 }
    guard ai.choice == "off", ai.choices == ["claude", "codex", "off"], !ai.noAIInstalled else {
      throw fail("A new install should offer what's installed: \(ai.choices), on \(ai.choice)")
    }
    ai.choose("claude")
    guard ai.choice == "claude", ai.brainTag == "smart", saves == 1,
      ai.label(.smartest) == "Smartest · Opus"
    else { throw fail("Choosing Claude saved \(ai.choice), \(ai.brainTag)") }
    ai.setBrain("quick")
    let quick = try MachineReviewConfiguration.load(root: aiRoot)
    guard quick?.model == "haiku", ai.brainTag == "quick", saves == 2 else {
      throw fail("Quick saved \(quick?.model ?? "nothing")")
    }
    ai.choose("off")
    guard ai.choice == "off", try MachineReviewConfiguration.load(root: aiRoot)?.enabled == false
    else { throw fail("Off didn't turn the AI off") }
    ai.choose("claude")
    guard ai.brainTag == "quick" else { throw fail("Back on should remember how smart") }
    ai.setBrain("smart")
    guard try MachineReviewConfiguration.load(root: aiRoot)?.model == nil else {
      throw fail("Smart should ask for nothing extra")
    }
    var custom = try MachineReviewConfiguration.load(root: aiRoot)!
    custom.model = "a-model-from-the-command-line"
    try custom.save(root: aiRoot)
    ai.reload()
    guard ai.brainTag == "custom", ai.customBrain.contains("a-model-from-the-command-line") else {
      throw fail("A model set elsewhere should say so")
    }
    guard
      !FileManager.default.fileExists(atPath: aiRoot.appendingPathComponent("review-request").path)
    else { throw fail("Settings started a review") }
    setenv("BURNZOMBIES_HARNESS_DIRS", "/nonexistent", 1)
    setenv("PATH", "/nonexistent", 1)
    let none = AISettingsModel(root: root.appendingPathComponent("none"), bundle: app)
    guard none.noAIInstalled, none.choices == ["off"] else {
      throw fail("With no AI, Settings should say none was found")
    }
    print(
      "PASS AI rows: installed choices, off and back, how smart, a model set elsewhere, none found")

    // What the AI used, in numbers anyone can read.
    let store = try Store(root: aiRoot)
    var ledger = ReviewLedger()
    let now = Date()
    for hour in [0, 2, 5, 20, 28, 50, 96, 192, 500] {
      _ = ledger.reserve(
        harness: "claude", evidenceCount: 1, now: now.addingTimeInterval(-Double(hour) * 3600))
      ledger.entries[ledger.entries.count - 1].usage = ReviewUsage.parse(
        Data(
          "{\"type\":\"bz.usage\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":\(120_000 + hour * 100),\"cached_input_tokens\":8000,\"output_tokens\":4000}}"
            .utf8))
    }
    try ledger.save(store: store)
    ai.reload()
    let today = ai.report(days: 1).total.estimatedUSD
    let week = ai.report(days: 7).total.estimatedUSD
    let month = ai.report(days: 30).total.estimatedUSD
    guard today > 0, week > today, month > week else {
      throw fail("Today, this week and this month: \(today), \(week), \(month)")
    }
    let usageModel = AppModel(demo: true)
    usageModel.autopilot.sweep.skippedSweeps = 14
    usageModel.settingsPage = .aiUse
    let usagePage = NSHostingView(
      rootView: SettingsSubpage(model: usageModel, ai: ai).frame(width: 440, height: 660)
        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
    usagePage.frame = NSRect(x: 0, y: 0, width: 440, height: 660)
    usagePage.layoutSubtreeIfNeeded()
    guard let usageBitmap = usagePage.bitmapImageRepForCachingDisplay(in: usagePage.bounds) else {
      throw fail("AI use render unavailable")
    }
    usagePage.cacheDisplay(in: usagePage.bounds, to: usageBitmap)
    try usageBitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("ai-use.png"))
    if let usageImage = usageBitmap.cgImage {
      let usageOCR = VNRecognizeTextRequest()
      usageOCR.recognitionLevel = .accurate
      usageOCR.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: usageImage, options: [:]).perform([usageOCR])
      let usageText = (usageOCR.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
      guard usageText.contains("Token efficiency"),
        usageText.contains("Freed by rules"),
        usageText.contains("Noisy sweeps skipped")
      else { throw fail("Token efficiency card missing or clipped: \(usageText)") }
    }
    guard NSApp.windows.allSatisfy({ !$0.isVisible && !$0.isKeyWindow }) else {
      throw fail("AI use proof showed a window")
    }
    guard AISettingsModel.about(0) == "$0", AISettingsModel.about(0.2) == "Under $1",
      AISettingsModel.about(75.01) == "About $75"
    else { throw fail("Money should read plainly") }
    print("PASS AI use: today, this week and this month in plain money")

    // The one choice, both ways. Each level's words stay short.
    let levels = AppModel(demo: true)
    for level in AutopilotLevel.allCases {
      levels.setAutopilotLevel(level)
      guard levels.autopilotLevel == level else {
        throw fail("\(level.label) came back as \(levels.autopilotLevel.label)")
      }
      guard level.sentence.count <= 70, level.label.count <= 13 else {
        throw fail("\(level.label) says too much: \(level.sentence)")
      }
    }
    levels.setAutopilotLevel(.askFirst)
    guard levels.autopilot.sweep.enabled, levels.autopilot.sweep.lookOnly == nil,
      !levels.autopilot.actsOnItsOwn
    else { throw fail("Ask first should burn rules only") }
    levels.setAutopilotLevel(.off)
    levels.setAutopilot(enabled: true)
    guard levels.autopilotLevel == .askFirst else {
      throw fail("The popup's switch should come back to the level you chose")
    }
    print(
      "PASS one Autopilot choice: all four levels both ways, and the popup's switch returns to it")

    // While the AI waits, the words say what's true: rules keep burning.
    var waiting = AutopilotSweepState()
    let back = now.addingTimeInterval(3 * 86_400)
    waiting.retryAfter = back
    waiting.limitResetsAt = back
    let limit = AutopilotText.aiProblem(waiting, harness: "claude", now: now) ?? ""
    let line = AutopilotText.sweepLine(waiting, now: now)
    guard limit.contains("out of Claude usage until"), limit.contains("still burn"),
      line.hasPrefix("Autopilot on · AI back "), !line.contains("paused")
    else { throw fail("Limit reads \"\(limit)\", the line \"\(line)\"") }
    waiting.limitResetsAt = nil
    waiting.lastError = "The AI needs attention (login or usage limit)."
    let login = AutopilotText.aiProblem(waiting, harness: "codex", now: now) ?? ""
    guard login.contains("Codex login"), login.contains("still burn") else {
      throw fail("Login reads \"\(login)\"")
    }
    waiting.lastError = "The AI sweep stopped early (exit 1)."
    let snag = AutopilotText.aiProblem(waiting, harness: "claude", now: now) ?? ""
    guard snag.hasPrefix("AI hit a snag."), snag.contains("still burn") else {
      throw fail("A snag reads \"\(snag)\"")
    }
    guard AutopilotText.aiProblem(AutopilotSweepState(), harness: "claude", now: now) == nil else {
      throw fail("All is well, so nothing should show")
    }
    waiting.enabled = false
    guard AutopilotText.aiProblem(waiting, harness: "claude", now: now) == nil else {
      throw fail("Off means there's no AI to wait for")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let sunday = calendar.date(
      from: DateComponents(year: 2026, month: 11, day: 8, hour: 14))!
    let friday = calendar.date(
      from: DateComponents(year: 2026, month: 11, day: 6, hour: 9))!
    guard AutopilotText.when(sunday, now: friday, calendar: calendar).hasPrefix("Sunday 2") else {
      throw fail("Sunday reads \(AutopilotText.when(sunday, now: friday, calendar: calendar))")
    }
    print(
      "PASS AI waiting: plain reasons, and the status line no longer says paused while rules burn")

    // One notification for new questions, none for ones already told.
    var question = AutopilotQuestion(
      kind: .disk, match: ["folder": ["package-cache"]], question: "Burn 5 tool caches?", why: "",
      examples: [], count: 5, bytes: 14_400_000_000)
    question.id = "q1"
    var second = question
    second.id = "q2"
    guard let one = AutopilotText.questionAlert([question], told: []),
      one.title == "BZ has a question", one.body.contains("14.4 GB")
    else { throw fail("One question should say so and what it frees") }
    guard AutopilotText.questionAlert([question], told: ["q1"]) == nil else {
      throw fail("A question already told shouldn't notify again")
    }
    guard
      AutopilotText.questionAlert([question, second], told: ["q1"])?.title == "BZ has 2 questions"
    else { throw fail("A new question should count them all") }
    guard AutopilotText.questionAlert([], told: []) == nil else {
      throw fail("No questions, no notification")
    }
    let tap = AppModel(demo: true)
    var opened = 0
    tap.openTeach = { opened += 1 }
    tap.notificationAction(id: FindingNotifications.questionID, revision: "", action: "review")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    guard opened == 1 else { throw fail("Tapping the notification should open Teach BZ") }
    print(
      "PASS question notifications: one for what's new, what it frees, and a tap opens Teach BZ")

    // Everything the owner kept reads as one list, and each comes off the way it went on.
    let list = AppModel(demo: true)
    list.autopilot.neverTouch = ["/Users/me/work/client"]
    list.autopilot.keptPaths = ["/Users/me/old-copy"]
    list.state.catalog.preferences.protectedExecutables = ["/usr/local/bin/server"]
    list.autopilot.lessons = [
      AutopilotLessonGroup(
        id: "rule:keep", kind: .process, verdict: .keep, sentence: "Java helpers stay.",
        evidence: "From 1 answer", ruleIDs: []),
      AutopilotLessonGroup(
        id: "b", kind: .disk, verdict: .burn, sentence: "Caches can go.", evidence: "", ruleIDs: []),
    ]
    let rows = list.neverTouchRows
    guard rows.map(\.title) == ["old-copy", "client", "server", "Java helpers stay."] else {
      throw fail("Never touches lists \(rows.map(\.title))")
    }
    rows[0].remove()
    rows[1].remove()
    guard list.autopilot.neverTouch.isEmpty, list.autopilot.keptPaths.isEmpty else {
      throw fail("Removing didn't take it off")
    }
    list.neverTouch(path: "/Users/me/keep")
    guard list.autopilot.neverTouch == ["/Users/me/keep"] else { throw fail("Adding didn't add") }
    print("PASS Never touches: one list from every place, and adding and removing work")

    // Full Disk Access: optional, short, and its buttons all fit.
    let accessModel = AppModel(demo: true)
    for accessState in [FullDiskAccessState.required, .unknown] {
      accessModel.state.fullDiskAccess = .init(state: accessState, detail: "")
      let accessHost = NSHostingView(
        rootView: FullDiskAccessView(model: accessModel).padding(20).frame(width: 440)
          .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
      accessHost.frame = NSRect(x: 0, y: 0, width: 440, height: 340)
      accessHost.layoutSubtreeIfNeeded()
      guard let bitmap = accessHost.bitmapImageRepForCachingDisplay(in: accessHost.bounds) else {
        throw fail("Access render unavailable")
      }
      accessHost.cacheDisplay(in: accessHost.bounds, to: bitmap)
      guard let image = bitmap.cgImage,
        let png = bitmap.representation(using: .png, properties: [:])
      else { throw fail("Access PNG unavailable") }
      let label = accessState == .required ? "required" : "unknown"
      try png.write(
        to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension(
          "access-" + label + ".png"))
      let recognition = VNRecognizeTextRequest()
      recognition.recognitionLevel = .accurate
      recognition.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([recognition])
      let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
      guard visible.contains("Full Disk Access"), visible.contains("Open Settings"),
        visible.contains("Check again"), visible.lowercased().contains("works without")
      else { throw fail("Access setup clipped: \(visible)") }
      guard NSApp.windows.allSatisfy({ !$0.isVisible && !$0.isKeyWindow }) else {
        throw fail("Access setup proof showed a window")
      }
    }
    print("PASS Full Disk Access setup renders short and whole, without opening System Settings")

    // settings.png, for the record.
    let model = AppModel(demo: true)
    let host = NSHostingView(
      rootView: SettingsWindow(model: model, ai: ai).environment(\.colorScheme, .dark))
    host.frame = NSRect(x: 0, y: 0, width: 440, height: 660)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw fail("Settings render unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw fail("Settings PNG unavailable")
    }
    try png.write(to: URL(fileURLWithPath: output))
    print("PASS offscreen Settings render and every save above, with no review started")
  }
#endif
