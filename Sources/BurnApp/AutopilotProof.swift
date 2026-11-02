#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// OCR text, normalized so a phrase can be found however Vision wraps or punctuates it.
private struct Reading {
  let raw: String
  let text: String
  let words: Set<String>

  init(_ raw: String) {
    let normalized = Reading.normalize(raw)
    self.raw = raw
    self.text = normalized
    self.words = Set(Reading.tokens(normalized))
  }
  static func normalize(_ value: String) -> String {
    var s = value
    for pair in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("—", "-"), ("–", "-")] {
      s = s.replacingOccurrences(of: pair.0, with: pair.1)
    }
    // OCR often reads a capital I as a lowercase l or a bar: "I" as "l", "If" as "lf".
    s = s.replacingOccurrences(
      of: "(?<![A-Za-z0-9])[l|](?![A-Za-z0-9])", with: "i", options: .regularExpression)
    s = s.replacingOccurrences(
      of: "(?<![A-Za-z0-9])lf(?![A-Za-z0-9])", with: "if", options: .regularExpression)
    // Compare words only, so commas, dashes and question marks never decide the outcome.
    let letters = s.lowercased().unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
    }
    return String(letters).components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }.joined(separator: " ")
  }
  static func tokens(_ text: String) -> [String] {
    text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
  }
  func has(_ phrase: String) -> Bool { text.contains(Reading.normalize(phrase)) }
  /// For long, changing sentences: most of the longer words must be on screen.
  func hasWords(of phrase: String, share: Double = 0.8) -> Bool {
    let wanted = Reading.tokens(Reading.normalize(phrase))
    guard !wanted.isEmpty else { return true }
    return Double(wanted.filter { words.contains($0) }.count) / Double(wanted.count) >= share
  }
}

private func require(_ reading: Reading, _ phrases: [String], in name: String) throws {
  let missing = phrases.filter { !reading.has($0) }
  guard missing.isEmpty else {
    let seen = reading.raw.replacingOccurrences(of: "\n", with: " | ")
    let quoted = missing.map { "\"\($0)\"" }.joined(separator: ", ")
    throw StoreError.message("\(name) is missing \(quoted). OCR saw: \(seen)")
  }
}

/// Lays out an already-built view at a fixed 2x backing scale, writes `<name>.png` and
/// `<name>.txt`, and returns what OCR read. The surface window is never ordered onto the screen.
@MainActor private func capture(
  _ host: NSView, surface: NSWindow, name: String, directory: URL
) throws -> Reading {
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }
  settle()
  settle()
  guard !surface.isVisible, !surface.isKeyWindow else {
    throw StoreError.message("Autopilot proof surface must stay offscreen")
  }
  guard host.bounds.width > 0, host.bounds.height > 0,
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2),
      pixelsHigh: Int(host.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
      bitsPerPixel: 0)
  else { throw StoreError.message("Autopilot \(name) render unavailable") }
  bitmap.size = host.bounds.size
  host.cacheDisplay(in: host.bounds, to: bitmap)
  guard let png = bitmap.representation(using: .png, properties: [:])
  else { throw StoreError.message("Autopilot \(name) image unavailable") }
  try png.write(to: directory.appendingPathComponent(name + ".png"))
  // Read the saved picture itself: the exact pixels a person looks at. Reading the in-memory
  // bitmap instead missed whole lines under heavy machine load.
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["en-US"]
  try VNImageRequestHandler(data: png, options: [:]).perform([request])
  let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
  try text.write(
    to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
  return Reading(text)
}

@MainActor private func render<V: View>(
  _ root: V, size: NSSize, name: String, directory: URL
) throws -> Reading {
  let host = NSHostingView(rootView: root)
  host.sizingOptions = []
  host.frame = NSRect(origin: .zero, size: size)
  let surface = NSWindow(
    contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
  surface.contentView = host
  return try capture(host, surface: surface, name: name, directory: directory)
}

/// Renders the real window, built the way the app builds it, without showing it.
@MainActor private func render(
  window: NSWindow, expected: NSSize, name: String, directory: URL
) throws -> Reading {
  guard let host = window.contentView,
    abs(host.bounds.width - expected.width) < 1, abs(host.bounds.height - expected.height) < 1
  else {
    throw StoreError.message(
      "Autopilot \(name) window is not \(Int(expected.width)) x \(Int(expected.height)): \(window.frame)"
    )
  }
  return try capture(host, surface: window, name: name, directory: directory)
}

/// Renders the Autopilot UI offscreen from the demo snapshot and OCR-checks the words a person
/// has to read. No window is shown or focused, no observer starts, and nothing in the real
/// BurnZombies state folder is read or written.
@MainActor func autopilotProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  // The menu view builds settings models that read a state folder; hand them an empty one.
  let scratch = directory.appendingPathComponent("scratch-state", isDirectory: true)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  var notes = [String]()
  func hint(_ reading: Reading, _ name: String, _ phrases: [String]) {
    let missing = phrases.filter { !reading.has($0) }
    if !missing.isEmpty { notes.append("\(name): OCR did not read \(missing.joined(separator: ", "))") }
  }
  func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw StoreError.message(message) }
  }

  // The demo snapshot has to be the realistic, consistent data the renders depend on.
  let model = AppModel(demo: true)
  let snapshot = model.autopilot
  let questions = snapshot.questions.filter(\.isOpen)
  try check(snapshot.entries.count >= 12, "Demo Autopilot data is too small")
  try check(
    Set(snapshot.entries.map(\.status)) == Set(AutopilotStatus.allCases),
    "Demo Autopilot data must show every status")
  try check(
    Set(snapshot.entries.map(\.item.kind)) == Set(AutopilotKind.allCases),
    "Demo Autopilot data must show every kind")
  try check(
    snapshot.counts.values.reduce(0, +) == snapshot.entries.count,
    "Demo counts do not match the entries")
  for status in AutopilotStatus.allCases {
    var total = UInt64(0)
    for entry in snapshot.entries where entry.status == status { total += entry.item.bytes }
    try check(
      snapshot.bytes[status.rawValue, default: 0] == total,
      "Demo bytes do not match the entries for \(status.rawValue)")
  }
  try check(questions.count == 3, "Demo should have exactly three open questions")
  try check(
    snapshot.rules.filter { $0.source == .`operator` }.count == 2
      && snapshot.rules.filter { $0.source == .starter }.count == 3,
    "Demo should have two learned rules and three starter rules")
  try check(abs(snapshot.trainingProgress - 0.42) < 0.001, "Demo training progress should be 42%")
  try check(
    snapshot.entries.filter { AutopilotDetailCard.canRestore($0) }.count == 1,
    "Exactly one demo entry should offer Restore")
  try check(model.autopilotAvailable, "The demo must show the Autopilot surfaces")
  try check(
    AutopilotText.summary(snapshot).hasPrefix("I found "), "The summary sentence changed shape")
  try check(
    AutopilotText.sweepLine(snapshot.sweep, now: Date()).hasPrefix("Autopilot on · next sweep in"),
    "The menu line should show the next sweep")
  var off = snapshot.sweep
  off.enabled = false
  var paused = snapshot.sweep
  paused.retryAfter = Date().addingTimeInterval(1800)
  try check(
    AutopilotText.sweepLine(off, now: Date()) == "Autopilot off"
      && AutopilotText.sweepLine(paused, now: Date()).hasPrefix("Autopilot paused — retrying at "),
    "The menu line should cover off and paused")
  print("PASS autopilot UI demo data: \(snapshot.entries.count) entries across every status and kind, 3 questions, 2 learned and 3 starter rules")

  // Menu: the Details view with the Autopilot block at the top.
  let menu = try render(
    ZStack {
      AutopilotTheme.window
      Dashboard(
        model: model, reviewerSettings: ReviewSettingsModel(root: scratch, catalog: []),
        huntSettings: HuntSettingsModel(root: scratch))
    }.frame(width: 440, height: 660).environment(\.colorScheme, .dark),
    size: NSSize(width: 440, height: 660), name: "menu", directory: directory)
  try require(menu, ["Autopilot", "quick question"], in: "menu")
  hint(menu, "menu", ["Autopilot on", "Teach BZ", "Advanced findings"])
  print("PASS autopilot UI menu render: Autopilot line and quick-question button")

  // Teach BZ: one big question, then the empty state.
  let teach = try render(
    TeachView(model: model), size: TeachView.size, name: "teach", directory: directory)
  let card = AutopilotPolicy.card(questions[0])
  try require(teach, ["Frees", "Question 1 of 3"], in: "teach")
  try check(teach.hasWords(of: card.headline), "teach is missing the headline. OCR saw: \(teach.raw)")
  try check(teach.hasWords(of: card.yes), "teach is missing the yes button. OCR saw: \(teach.raw)")
  for confusing in ["trained", "on my own", "%"] {
    try check(!teach.raw.contains(confusing), "teach shows \"\(confusing)\". OCR saw: \(teach.raw)")
  }
  hint(teach, "teach", ["Not sure", card.note] + card.facts)
  // Real questions carry up to four facts; every one stays readable on every kind of card.
  for (name, question) in [
    (
      "teach-copies",
      AutopilotQuestion(
        kind: .worktree,
        match: ["saved": ["local"], "changes": ["small"], "stale": ["week"], "place": ["patrol6"]],
        question: "", why: "", examples: [], count: 245, bytes: 101_580_000_000)
    ),
    (
      "teach-programs",
      AutopilotQuestion(
        kind: .process,
        match: ["family": ["java"], "idle": ["1h"], "listening": ["yes"], "agent": ["codex"]],
        question: "", why: "", examples: [], count: 4, bytes: 12_990_000_000)
    ),
    (
      "teach-caches",
      AutopilotQuestion(
        kind: .disk, match: ["folder": ["package-cache"], "home": ["repo"], "stale": ["month"]],
        question: "", why: "", examples: [], count: 5, bytes: 20_290_000_000)
    ),
  ] {
    let busy = AppModel(demo: true)
    busy.autopilot.questions = [question]
    let shown = try render(
      TeachView(model: busy), size: TeachView.size, name: name, directory: directory)
    let busyCard = AutopilotPolicy.card(question)
    for words in [busyCard.headline, busyCard.frees] + busyCard.facts {
      try check(shown.hasWords(of: words), "\(name) lost \"\(words)\". OCR saw: \(shown.raw)")
    }
  }
  let quiet = AppModel(demo: true)
  quiet.autopilot.questions = []
  let teachEmpty = try render(
    TeachView(model: quiet), size: TeachView.size, name: "teach-empty", directory: directory)
  try require(teachEmpty, ["All caught up"], in: "teach-empty")
  try check(!teachEmpty.raw.contains("trained"), "caught-up shows a training percentage")
  let teachDone = try render(
    TeachView(
      model: model,
      confirmation: TeachView.Confirmation(
        text: "Got it! I'll burn these on my own from now on.", symbol: "flame.fill")),
    size: TeachView.size, name: "teach-confirmed", directory: directory)
  hint(teachDone, "teach-confirmed", ["Got it", "burn these on my own"])
  let teachWindow = TeachView.makeWindow(model: model)
  try check(
    !teachWindow.isVisible && abs((teachWindow.contentView?.bounds.width ?? 0) - 640) < 1,
    "Teach BZ window should be 640 wide and unshown")
  print("PASS autopilot UI Teach BZ render: question card, empty state and confirmation")

  // Findings: an entry that needs the operator is selected so the detail card shows.
  guard let focus = snapshot.entries.first(where: { $0.status == .unsure && $0.item.kind == .process }),
    let burnedCopy = snapshot.entries.first(where: { AutopilotDetailCard.canRestore($0) }),
    let pending = snapshot.entries.first(where: { $0.status == .unsure && $0.item.kind == .worktree })
  else { throw StoreError.message("Demo data lost the entries the Findings proof selects") }
  let findings = try render(
    window: AutopilotFindingsView.makeWindow(model: model, selection: focus.id),
    expected: AutopilotFindingsView.size, name: "findings", directory: directory)
  try require(
    findings,
    [
      "I found", "Needs you", "What is it?", "Why I think so", "If I burn it", "Technical details",
    ], in: "findings")
  hint(findings, "findings", ["Leftover programs", focus.label, "Burn now", "Keep forever"])
  let needsYou = try render(
    window: AutopilotFindingsView.makeWindow(model: model, tab: .needsYou, selection: pending.id),
    expected: AutopilotFindingsView.size, name: "findings-needs-you", directory: directory)
  hint(
    needsYou, "findings-needs-you",
    ["Leftover programs", "Old project copies", "Junk folders", "Burn now"])
  let restorable = try render(
    window: AutopilotFindingsView.makeWindow(model: model, tab: .burned, selection: burnedCopy.id),
    expected: AutopilotFindingsView.size, name: "findings-burned", directory: directory)
  hint(restorable, "findings-burned", ["Restore", "What happened", "Burned"])
  let emptyModel = AppModel(demo: true)
  emptyModel.autopilot = AutopilotSnapshot()
  let findingsEmpty = try render(
    window: AutopilotFindingsView.makeWindow(model: emptyModel),
    expected: AutopilotFindingsView.size, name: "findings-empty", directory: directory)
  try require(findingsEmpty, ["Nothing needs you right now"], in: "findings-empty")
  // Thousands of entries must stay quick: only the rows in view are built.
  let template = snapshot.entries
  var big = snapshot
  big.entries = (0..<3000).map { (index: Int) -> AutopilotEntry in
    var entry = template[index % template.count]
    entry.item.id = "synthetic:\(index)"
    entry.item.name += " \(index)"
    entry.label += " \(index)"
    return entry
  }
  AutopilotLocal.recount(&big)
  let crowded = AppModel(demo: true)
  crowded.autopilot = big
  let started = Date()
  let findingsBig = try render(
    window: AutopilotFindingsView.makeWindow(model: crowded, selection: "synthetic:1"),
    expected: AutopilotFindingsView.size, name: "findings-3000", directory: directory)
  let seconds = Date().timeIntervalSince(started)
  try require(findingsBig, ["I found"], in: "findings-3000")
  try check(seconds < 30, "3,000 entries took \(seconds) s to render; the list must stay lazy")
  print("PASS autopilot UI Findings render: detail card, tabs, empty state and \(big.entries.count) entries in \(String(format: "%.1f", seconds)) s")

  // Settings: the section that Settings embeds.
  let settings = try render(
    AutopilotSettingsView(model: model).padding(20).frame(width: 440)
      .frame(maxHeight: .infinity, alignment: .top).background(AutopilotTheme.window)
      .environment(\.colorScheme, .dark),
    size: NSSize(width: 440, height: 780), name: "settings", directory: directory)
  try require(settings, ["What BZ has learned", "Start training over"], in: "settings")
  hint(settings, "settings", ["Sweep every", "Starter rules", "Forget"])
  print("PASS autopilot UI Settings render: learned rules, starter rules and Start training over")

  try autopilotBehavior()
  for note in notes { print("NOTE \(note)") }
  guard NSApp.windows.allSatisfy({ !$0.isVisible && !$0.isKeyWindow }) else {
    throw StoreError.message("Autopilot proof showed a window")
  }
  print("PASS autopilot UI: menu, Teach BZ, Findings, Settings and every command render and behave from the demo snapshot; no window was shown or focused (PNGs in \(directory.path))")
}

/// The AppModel commands, with no engine attached (in-memory) and with a stand-in engine.
@MainActor private func autopilotBehavior() throws {
  func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw StoreError.message(message) }
  }
  func tidy(_ model: AppModel, _ step: String) throws {
    let s = model.autopilot
    try check(
      s.counts.values.reduce(0, +) == s.entries.count, "\(step) left the counts out of step")
    try check(
      abs(s.trainingProgress - min(1, Double(s.answers) / Double(AutopilotPolicy.trainingTarget)))
        < 0.0001, "\(step) left training progress out of step")
  }
  func entry(_ model: AppModel, _ id: String) -> AutopilotEntry? {
    model.autopilot.entries.first { $0.id == id }
  }

  // A yes teaches a burn rule and moves matching things to Will burn.
  let yes = AppModel(demo: true)
  guard let asked = yes.autopilot.questions.first else { throw StoreError.message("No demo question") }
  let answersBefore = yes.autopilot.answers
  let unsureBefore = yes.autopilot.count(.unsure)
  yes.answer(asked, .yes)
  guard let learned = yes.autopilot.rules.first(where: { $0.questionID == asked.id }) else {
    throw StoreError.message("Answering yes did not create a rule")
  }
  try check(learned.verdict == .burn && learned.source == .`operator`, "A yes must teach a burn rule")
  try check(yes.autopilot.questions.filter(\.isOpen).count == 2, "The answered question stayed open")
  try check(yes.autopilot.answers == answersBefore + 1, "The answer was not counted")
  try check(yes.autopilot.count(.unsure) < unsureBefore, "Yes did not move matching things")
  let ruled = yes.autopilot.entries.filter { $0.authority == "rule:" + learned.id }
  try check(!ruled.isEmpty && ruled.allSatisfy { $0.status == .burn }, "Yes did not mean Will burn")
  try tidy(yes, "yes")

  // A no teaches a keep rule; a skip teaches nothing.
  let no = AppModel(demo: true)
  guard let other = no.autopilot.questions.first else { throw StoreError.message("No demo question") }
  no.answer(other, .no)
  guard let kept = no.autopilot.rules.first(where: { $0.questionID == other.id }) else {
    throw StoreError.message("Answering no did not create a rule")
  }
  try check(kept.verdict == .keep, "A no must teach a keep rule")
  try check(
    no.autopilot.entries.filter { $0.authority == "rule:" + kept.id }.allSatisfy { $0.status == .keep },
    "No did not mean Keeping")
  let skip = AppModel(demo: true)
  if let q = skip.autopilot.questions.first {
    let rules = skip.autopilot.rules.count
    skip.answer(q, .skip)
    try check(
      skip.autopilot.rules.count == rules && skip.autopilot.answers == 5
        && skip.autopilot.questions.filter(\.isOpen).count == 2,
      "Skip must hide the question without teaching anything")
  }

  // Burn now, keep forever and restore.
  let acts = AppModel(demo: true)
  guard let waiting = acts.autopilot.entries.first(where: { $0.status == .burn }),
    let unsure = acts.autopilot.entries.first(where: { $0.status == .unsure }),
    let guarded = acts.autopilot.entries.first(where: { $0.status == .protected }),
    let back = acts.autopilot.entries.first(where: { AutopilotDetailCard.canRestore($0) })
  else { throw StoreError.message("Demo data lost an entry the behavior proof needs") }
  acts.burnNow(waiting)
  try check(
    entry(acts, waiting.id)?.status == .burned && entry(acts, waiting.id)?.receipt?.outcome == "burned",
    "Burn now did not burn")
  acts.keepForever(unsure)
  try check(
    entry(acts, unsure.id)?.status == .keep && entry(acts, unsure.id)?.authority == "operator",
    "Keep forever did not keep")
  acts.burnNow(guarded)
  acts.keepForever(guarded)
  try check(entry(acts, guarded.id)?.status == .protected, "A protected thing changed")
  guard let receipt = back.receipt else { throw StoreError.message("Demo restore has no receipt") }
  acts.restore(receipt)
  try check(
    entry(acts, back.id)?.status == .keep && entry(acts, back.id)?.receipt?.outcome == "restored"
      && !AutopilotDetailCard.canRestore(entry(acts, back.id) ?? back),
    "Restore did not put the old copy back")
  try tidy(acts, "burn, keep and restore")

  // Forget a lesson, switch a starter rule off and on, and start over.
  let rules = AppModel(demo: true)
  guard let lesson = rules.autopilot.rules.first(where: { $0.source == .`operator` }) else {
    throw StoreError.message("Demo has no learned rule")
  }
  let affected = rules.autopilot.entries.filter { $0.authority == "rule:" + lesson.id }.map(\.id)
  rules.forgetRule(lesson)
  try check(
    !rules.autopilot.rules.contains { $0.id == lesson.id } && !affected.isEmpty
      && affected.allSatisfy { entry(rules, $0)?.status == .unsure },
    "Forget did not reopen what the lesson decided")
  let starter = "starter-leftover-programs"
  let byStarter = rules.autopilot.entries.filter {
    $0.authority == "starter:" + starter && $0.status == .burn
  }.map(\.id)
  rules.setStarter(starter, enabled: false)
  try check(
    !byStarter.isEmpty && byStarter.allSatisfy { entry(rules, $0)?.status == .unsure }
      && rules.autopilot.rules.first(where: { $0.id == starter })?.enabled == false,
    "Switching a starter rule off did not reopen its things")
  try check(
    rules.autopilot.entries.filter { $0.status == .burned }.count == 2,
    "A starter switch must never undo something already burned")
  rules.setStarter(starter, enabled: true)
  try check(
    byStarter.allSatisfy { entry(rules, $0)?.status == .burn },
    "Switching the starter rule back on did not bring Will burn back")
  rules.answer(rules.autopilot.questions[0], .yes)
  rules.resetTraining()
  try check(
    !rules.autopilot.rules.contains { $0.source == .`operator` } && rules.autopilot.answers == 0
      && rules.autopilot.trainingProgress == 0,
    "Start training over did not forget everything")
  try tidy(rules, "forget, starter and reset")

  // Sweep controls.
  let sweep = AppModel(demo: true)
  sweep.setAutopilot(enabled: false)
  try check(
    AutopilotText.sweepLine(sweep.autopilot.sweep, now: Date()) == "Autopilot off",
    "Autopilot off did not show")
  sweep.setAutopilot(enabled: true)
  sweep.setSweepInterval(minutes: 30)
  sweep.sweepNow()
  try check(
    sweep.autopilot.sweep.intervalMinutes == 30
      && abs(sweep.autopilot.sweep.lastTick?.timeIntervalSinceNow ?? -1000) < 5
      && AutopilotText.sweepLine(sweep.autopilot.sweep, now: Date()).contains("30 min"),
    "Sweep interval or Sweep now did not apply")

  // With an engine attached, every command goes through it and its snapshot wins.
  var sent = [AutopilotCommand]()
  var returned = AutopilotSnapshot()
  returned.answers = 99
  let marker = returned
  let wired = AppModel(demo: true)
  wired.autopilotRunner = { command in
    sent.append(command)
    return marker
  }
  guard let q = wired.autopilot.questions.first, let e = wired.autopilot.entries.first,
    let rcpt = wired.autopilot.entries.first(where: { $0.receipt != nil })?.receipt,
    let rule = wired.autopilot.rules.first
  else { throw StoreError.message("Demo data lost an entry the engine proof needs") }
  wired.answer(q, .no)
  wired.burnNow(e)
  wired.keepForever(e)
  wired.restore(rcpt)
  wired.forgetRule(rule)
  wired.setStarter("starter-finished-copies", enabled: false)
  wired.setAutopilot(enabled: false)
  wired.setSweepInterval(minutes: 60)
  wired.resetTraining()
  wired.sweepNow()
  let expected: [AutopilotCommand] = [
    .answer(questionID: q.id, answer: .no), .burnNow(itemID: e.id), .keep(itemID: e.id),
    .restore(receiptID: rcpt.id), .forgetRule(ruleID: rule.id),
    .setStarter(ruleID: "starter-finished-copies", enabled: false), .setEnabled(false),
    .setInterval(minutes: 60), .resetTraining, .sweepNow,
  ]
  let deadline = Date().addingTimeInterval(3)
  while (sent.count < expected.count || wired.autopilot != marker) && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
  try check(sent == expected, "The engine received the wrong commands: \(sent)")
  try check(wired.autopilot == marker, "The engine's snapshot was not shown")
  let failing = AppModel(demo: true)
  let before = failing.autopilot
  failing.autopilotRunner = { _ in nil }
  failing.setAutopilot(enabled: false)
  let failDeadline = Date().addingTimeInterval(3)
  while failing.message == nil && Date() < failDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
  try check(
    failing.message != nil && failing.autopilot == before,
    "A failed engine command should say so and change nothing")
  print("PASS autopilot UI commands: answer, burn now, keep forever, restore, forget, starter switch, reset, interval, sweep now, and engine hand-off")
}
#endif
