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
  let learnedRules = snapshot.rules.filter { $0.source == .`operator` }
  try check(
    !learnedRules.isEmpty && snapshot.rules.filter { $0.source == .starter }.count == 3,
    "Demo should have learned rules and three starter rules")
  // What the owner taught shows as a few plain lessons, each rule in exactly one of them.
  let grouped = snapshot.lessons.flatMap(\.ruleIDs)
  try check(
    (4...6).contains(snapshot.lessons.count) && grouped.count == Set(grouped).count
      && Set(grouped) == Set(learnedRules.map(\.id)),
    "Demo should have four to six lesson groups that hold every learned rule exactly once")
  try check(
    (3...4).contains(snapshot.progress.lines.count)
      && snapshot.progress.lines.allSatisfy { !$0.contains("%") },
    "Demo should have three or four plain progress lines")
  let expectedProgress: Double = min(
    1, Double(snapshot.answers) / Double(AutopilotPolicy.trainingTarget))
  try check(
    abs(snapshot.trainingProgress - expectedProgress) < 0.001 && snapshot.answers > 0,
    "Demo answers and training progress should agree")
  let openTells = snapshot.tellsWaiting
  try check(openTells.count == 1, "Demo should have exactly one open tell")
  guard let demoTell = openTells.first else { throw StoreError.message("Demo has no tell") }
  // A lesson made only from BZ's own call says so, and none says "0 answers".
  let actGroup = snapshot.lessons.first { $0.ruleIDs.contains(demoTell.ruleID) }
  try check(
    actGroup?.evidence.hasPrefix("From my own call · ") == true
      && snapshot.lessons.allSatisfy { !$0.evidence.contains("0 answers") },
    "BZ's own call reads \"From my own call\": \(actGroup?.evidence ?? "no lesson")")
  let burnedByTell = snapshot.entries.filter { $0.authority == "rule:" + demoTell.ruleID }
  var tellBytes: UInt64 = 0
  for entry in burnedByTell { tellBytes += entry.item.bytes }
  let tellBurned: Bool = burnedByTell.allSatisfy { $0.status == .burned }
  let tellRuleExists: Bool = snapshot.rules.contains { $0.id == demoTell.ruleID }
  try check(
    burnedByTell.count == demoTell.count && tellBurned && tellBytes == demoTell.bytes
      && tellRuleExists,
    "The demo tell must count the copies BZ really burned, under a lesson that exists")
  // Whatever the demo says was decided is what the engine's own `decide` decides from these rules,
  // so a thing a lesson covers is never also a question. A thing BZ burned on its own is one its
  // lesson covers.
  var rulesAsDecided = AutopilotMemory()
  rulesAsDecided.rules = learnedRules
  for rule in snapshot.rules where rule.source == .starter && !rule.enabled {
    rulesAsDecided.starterDisabled.insert(rule.id)
  }
  for entry in snapshot.entries where entry.status == .keep && entry.authority == "operator" {
    rulesAsDecided.keptItems.insert(entry.item.id)
  }
  for entry in snapshot.entries where entry.status != .burned {
    let decision = AutopilotPolicy.decide(entry.item, memory: rulesAsDecided)
    let expected: AutopilotStatus = entry.status == .failed ? .burn : entry.status
    let said: String = entry.authority ?? "nothing"
    let engine: String = decision.authority ?? "nothing"
    try check(
      decision.status == expected && decision.authority == entry.authority,
      "Demo entry \"\(entry.label)\" is \(entry.status.rawValue) by \(said); the engine decides \(decision.status.rawValue) by \(engine)"
    )
  }
  if let actedRule = learnedRules.first(where: { $0.id == demoTell.ruleID }) {
    try check(
      burnedByTell.allSatisfy { AutopilotPolicy.matches(actedRule, $0.item) },
      "The lesson BZ acted under must cover everything it burned")
  }
  let firstCard = AutopilotPolicy.card(questions[0])
  let firstNamesThree: Bool = firstCard.rows.count == 3 && firstCard.more > 0
  let firstIsPlain: Bool = firstCard.facts.isEmpty && firstCard.line != nil
  try check(
    firstNamesThree && firstIsPlain,
    "The demo's first question should name three things, say how many more and have no chips")
  try check(
    snapshot.entries.filter { AutopilotDetailCard.canRestore($0) }.count == 1 + demoTell.count,
    "Demo should offer Restore for an old copy and for each copy BZ burned on its own")
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
  var looking = snapshot.sweep
  looking.lookOnly = true
  try check(
    AutopilotText.sweepLine(off, now: Date()) == "Autopilot off"
      && AutopilotText.sweepLine(paused, now: Date()).hasPrefix("Autopilot paused — retrying at ")
      && AutopilotText.sweepLine(looking, now: Date()).hasPrefix("Look-only · next sweep in"),
    "The menu line should cover off, paused and look-only")
  print(
    "PASS autopilot UI demo data: \(snapshot.entries.count) entries across every status and kind, 3 questions, \(snapshot.lessons.count) lessons from \(learnedRules.count) learned rules, 3 starter rules, \(snapshot.progress.lines.count) progress lines and 1 tell"
  )
  for group in snapshot.lessons { print("  lesson: \(group.sentence) [\(group.evidence)]") }
  for line in snapshot.progress.lines { print("  doing: \(line)") }
  let showing = AutopilotPolicy.card(questions[0])
  var shownRows = [String]()
  for row in showing.rows {
    let project: String = row.subtitle ?? "-"
    shownRows.append("\(row.title) / \(project) / \(row.when)")
  }
  let shownLine: String = showing.line ?? "-"
  print(
    "  question: \(showing.headline) | \(showing.frees) | \(shownLine) | rows \(shownRows) | + \(showing.more) more"
  )
  print(
    "  tell: \(AutopilotText.tellHeadline(demoTell)) | \(AutopilotText.tellSize(demoTell)) | \(AutopilotText.tellWhy(demoTell))"
  )

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
  // BZ acts instead of asking, so a tell comes when no question is waiting: the menu prompts for it
  // in the Details view and in the compact popover, in the place the questions prompt takes.
  let tellOnly = AppModel(demo: true)
  tellOnly.autopilot.questions = []
  let tellPrompt = AutopilotText.burnedOnItsOwn(tellOnly.autopilot.tells)
  try check(
    tellPrompt == "BZ burned 3 things on its own",
    "The menu prompt for a tell reads: \(tellPrompt)")
  let menuTell = try render(
    ZStack {
      AutopilotTheme.window
      Dashboard(
        model: tellOnly, reviewerSettings: ReviewSettingsModel(root: scratch, catalog: []),
        huntSettings: HuntSettingsModel(root: scratch))
    }.frame(width: 440, height: 660).environment(\.colorScheme, .dark),
    size: NSSize(width: 440, height: 660), name: "menu-tell", directory: directory)
  try require(menuTell, ["Autopilot", tellPrompt], in: "menu-tell")
  try check(!menuTell.has("quick question"), "A tell-only menu still prompts for questions")
  let miniTell = try render(
    MiniImpactView(model: tellOnly), size: MiniImpactView.size, name: "mini-tell",
    directory: directory)
  try require(miniTell, [tellPrompt], in: "mini-tell")
  try check(!miniTell.has("quick question"), "A tell-only popover still prompts for questions")
  let miniAsking = try render(
    MiniImpactView(model: model), size: MiniImpactView.size, name: "mini", directory: directory)
  try require(miniAsking, ["BZ has 3 quick questions"], in: "mini")
  try check(!miniAsking.has(tellPrompt), "Questions come first in the popover's prompt")
  print("PASS autopilot UI menu prompts: quick questions first, then what BZ burned on its own")

  // Teach BZ: what BZ did on its own first, then one big question at a time.
  // The question card as the owner sees it once no tell waits: the things it is about, with when.
  let asking = AppModel(demo: true)
  asking.autopilot.tells = []
  let teach = try render(
    TeachView(model: asking), size: TeachView.size, name: "teach", directory: directory)
  let card = AutopilotPolicy.card(questions[0])
  try require(teach, ["Frees", "Question 1 of 3", "\(card.more) more"], in: "teach")
  try check(teach.hasWords(of: card.headline), "teach is missing the headline. OCR saw: \(teach.raw)")
  try check(teach.hasWords(of: card.yes), "teach is missing the yes button. OCR saw: \(teach.raw)")
  try check(teach.hasWords(of: card.no), "teach is missing the no button. OCR saw: \(teach.raw)")
  if let line = card.line {
    try check(teach.hasWords(of: line), "teach is missing the safe line. OCR saw: \(teach.raw)")
  }
  for row in card.rows {
    try check(
      teach.hasWords(of: row.title), "teach lost the row \"\(row.title)\". OCR saw: \(teach.raw)")
    var beside: [String] = [row.when]
    if let project = row.subtitle { beside.append(project) }
    hint(teach, "teach", beside)
  }
  for confusing in ["trained", "on my own", "%"] {
    try check(!teach.raw.contains(confusing), "teach shows \"\(confusing)\". OCR saw: \(teach.raw)")
  }
  hint(teach, "teach", ["Not sure", card.note])
  // Real questions come in many shapes; every one stays readable with its rows, and none leaves an
  // empty gap where chips would be. The first has three chips and a long title, the last has none.
  let used: Date = Date().addingTimeInterval(-9 * 86_400)
  func busy(_ kind: AutopilotKind, _ match: [String: [String]], count: Int, bytes: UInt64)
    -> AutopilotQuestion
  {
      AutopilotQuestion(
      kind: kind, match: match, question: "", why: "", examples: [], count: count, bytes: bytes)
  }
  var copies = busy(
    .worktree,
    ["saved": ["local"], "changes": ["small"], "stale": ["week"], "place": ["patrol6"]],
    count: 245, bytes: 101_580_000_000)
  copies.rows = [
    AutopilotQuestionRow(
      title: "rebuild the invoice exporter with the new billing schema and its tests",
      subtitle: "api", bytes: 9_000_000_000, lastUsed: used),
    AutopilotQuestionRow(
      title: "dark mode toggle", subtitle: "web-app", bytes: 8_000_000_000, lastUsed: used),
    AutopilotQuestionRow(title: "web-app-spike", bytes: 7_000_000_000, lastUsed: used),
  ]
  var programs = busy(
    .process,
    ["family": ["java"], "idle": ["1h"], "listening": ["yes"], "agent": ["codex"]], count: 4,
    bytes: 12_990_000_000)
  programs.rows = [
    AutopilotQuestionRow(
      title: "java in api", subtitle: "started by Codex", bytes: 5_000_000_000,
      lastUsed: Date().addingTimeInterval(-3 * 3600)),
    AutopilotQuestionRow(
      title: "java in web-app", subtitle: "started by Codex", bytes: 4_000_000_000,
      lastUsed: Date().addingTimeInterval(-95 * 60)),
    AutopilotQuestionRow(
      title: "java", subtitle: "started by Codex", bytes: 3_000_000_000,
      lastUsed: Date().addingTimeInterval(-70 * 60)),
  ]
  var caches = busy(
    .disk, ["folder": ["package-cache"], "stale": ["month"]], count: 5, bytes: 20_290_000_000)
  caches.rows = [
    AutopilotQuestionRow(title: "tool cache in api", bytes: 9_000_000_000, lastUsed: used),
    AutopilotQuestionRow(title: "tool cache in web-app", bytes: 6_000_000_000, lastUsed: used),
    AutopilotQuestionRow(title: "tool cache in docs", bytes: 4_000_000_000, lastUsed: used),
  ]
  caches.line = nil
  for (name, question) in [
    ("teach-copies", copies), ("teach-programs", programs), ("teach-caches", caches),
  ] {
    let busyModel = AppModel(demo: true)
    busyModel.autopilot.tells = []
    busyModel.autopilot.questions = [question]
    let shown = try render(
      TeachView(model: busyModel), size: TeachView.size, name: name, directory: directory)
    let busyCard = AutopilotPolicy.card(question)
    for words in [busyCard.headline, busyCard.frees, busyCard.yes, busyCard.no] {
      try check(shown.hasWords(of: words), "\(name) lost \"\(words)\". OCR saw: \(shown.raw)")
    }
    // A chip is a few short words, so one misread letter or digit ("Patrol6") is not a lost chip.
    for fact in busyCard.facts {
      try check(
        shown.hasWords(of: fact, share: 0.6),
        "\(name) lost the chip \"\(fact)\". OCR saw: \(shown.raw)")
    }
    for row in busyCard.rows {
      try check(
        shown.hasWords(of: row.title), "\(name) lost \"\(row.title)\". OCR saw: \(shown.raw)")
    }
    hint(shown, name, ["Not sure", busyCard.note, "\(busyCard.more) more"])
    if name == "teach-caches" {
      try check(
        busyCard.facts.isEmpty, "The tool-caches card should have no chips to leave a gap")
    }
  }
  // What BZ did on its own comes first: how much, which things, why, and Good call or Undo.
  let tellView = try render(
    TeachView(model: model), size: TeachView.size, name: "teach-tell", directory: directory)
  try require(
    tellView,
    [
      AutopilotText.tellHeadline(demoTell), AutopilotText.tellSize(demoTell), "Good call", "Undo",
      "You'd have said yes",
    ], in: "teach-tell")
  try check(
    AutopilotText.tellSize(demoTell) == "Freed 2.4 GB",
    "A copies tell says what it freed, not a bare size")
  try check(
    AutopilotText.tellWhy(demoTell) == "You'd have said yes: you said yes to 6 like these.",
    "The reason reads as one sentence after the prefix")
  try check(
    tellView.hasWords(of: AutopilotText.tellWhy(demoTell)),
    "teach-tell is missing the reason. OCR saw: \(tellView.raw)")
  try check(
    !tellView.has("Bringing them back") && !tellView.has("I'd have said no"),
    "An open copies tell offers Undo and says nothing about bringing them back yet")
  let tellRows = AutopilotText.tellRows(demoTell, now: Date(), calendar: .current)
  try check(
    tellRows.count == 3 && AutopilotText.tellMore(demoTell) == 0,
    "The demo tell should name every copy it burned")
  try check(
    tellRows.allSatisfy { $0.when.hasPrefix("used ") },
    "A copy's row says when it was last used, so it isn't read as when it was burned")
  for row in tellRows {
    try check(
      tellView.hasWords(of: row.title),
      "teach-tell lost \"\(row.title)\". OCR saw: \(tellView.raw)")
  }
  hint(tellView, "teach-tell", tellRows.map(\.when))
  try check(
    !tellView.has("Question 1 of 3") && !tellView.hasWords(of: card.headline),
    "A tell comes before the questions and shows no question count. OCR saw: \(tellView.raw)")

  // Rows are worded by the question card's own function: dates read the same way, with "used".
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(identifier: "UTC") ?? .current
  let fixedNow =
    utc.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 39))
    ?? Date()
  let yesterdayFive =
    utc.date(
      from: DateComponents(year: 2026, month: 11, day: 2, hour: 17)) ?? Date()
  let october26 = utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8)) ?? Date()
  var dated = demoTell
  dated.rows = [
    AutopilotQuestionRow(title: "a", bytes: 3, lastUsed: yesterdayFive),
    AutopilotQuestionRow(title: "b", bytes: 2, lastUsed: october26),
    AutopilotQuestionRow(title: "c", bytes: 1),
  ]
  let datedWords: [String] = AutopilotText.tellRows(dated, now: fixedNow, calendar: utc).map(\.when)
  try check(
    datedWords == ["used yesterday 5 pm", "used Oct 26", ""],
    "A copy's row reads \"used yesterday 5 pm\", then \"used Oct 26\", and nothing with no date: \(datedWords)"
  )
  var datedFolders = dated
  datedFolders.kind = .disk
  let datedFolderWords: [String] = AutopilotText.tellRows(
    datedFolders, now: fixedNow, calendar: utc
  ).map(\.when)
  try check(
    datedFolderWords == datedWords, "A folder's row reads the same way: \(datedFolderWords)")

  // Programs and folders can't be brought back. Their card says so before any press, the second
  // button is the owner's real answer, and pressing it never claims to bring anything back.
  let stopped: Date = Date().addingTimeInterval(-25 * 60)
  let programTell = AutopilotTell(
    id: "demo-program-tell", questionID: "process:demo:question", ruleID: "demo-program-rule",
    kind: .process, count: 3, bytes: 1_700_000_000,
    rows: [
      AutopilotQuestionRow(
        title: "node in api", subtitle: "started by Codex", bytes: 900_000_000,
        lastUsed: stopped.addingTimeInterval(-3 * 3600)),
      AutopilotQuestionRow(
        title: "node in web-app", subtitle: "started by Codex", bytes: 500_000_000,
        lastUsed: stopped.addingTimeInterval(-95 * 60)),
    ], why: "You said yes to 4 like these.", date: stopped)
  var folderTell = programTell
  folderTell.id = "demo-folder-tell"
  folderTell.kind = .disk
  folderTell.count = 4
  folderTell.bytes = 1_500_000_000
  folderTell.rows = [
    AutopilotQuestionRow(
      title: "node_modules in api", bytes: 800_000_000,
      lastUsed: Date().addingTimeInterval(-9 * 86_400)),
    AutopilotQuestionRow(
      title: "node_modules in web-app", bytes: 400_000_000,
      lastUsed: Date().addingTimeInterval(-11 * 86_400)),
  ]
  try check(
    AutopilotText.tellSize(programTell) == "1.7 GB of memory"
      && AutopilotText.tellSize(folderTell) == "Freed 1.5 GB",
    "A program tell says how much memory; a folder tell what it freed")
  let copiesLine: String? = AutopilotText.tellCantComeBack(.worktree)
  let programsLine: String? = AutopilotText.tellCantComeBack(.process)
  let foldersLine: String? = AutopilotText.tellCantComeBack(.disk)
  try check(copiesLine == nil, "Copies come back, so their card says nothing of the kind")
  try check(
    programsLine == "Stopped programs can't be restarted by me; I'll ask next time.",
    "Programs say up front that Undo can't bring them back")
  try check(
    foldersLine == "Your tools rebuild deleted folders; I'll ask next time.",
    "Folders say up front that Undo can't bring them back")
  let copyLabel: String = AutopilotText.tellUndoLabel(.worktree)
  let programLabel: String = AutopilotText.tellUndoLabel(.process)
  let folderLabel: String = AutopilotText.tellUndoLabel(.disk)
  try check(
    copyLabel == "Undo" && programLabel == "I'd have said no" && folderLabel == "I'd have said no",
    "The second button is Undo only for copies")
  let copyWorking: String = AutopilotText.tellWorking(.worktree)
  let programWorking: String = AutopilotText.tellWorking(.process)
  let folderWorking: String = AutopilotText.tellWorking(.disk)
  try check(
    copyWorking == "Bringing them back…" && programWorking == "Got it. I'll ask next time."
      && folderWorking == "Got it. I'll ask next time.",
    "Only copies are brought back")
  try check(
    AutopilotText.tellStalled(.worktree) == "Undo didn't finish. Tap Undo to bring them back.",
    "A copies Undo cut short by a quit says to tap Undo")
  for kind in [AutopilotKind.process, .disk] {
    let lines: [String] = [
      AutopilotText.tellWorking(kind), AutopilotText.tellStalled(kind),
      AutopilotText.tellCantComeBack(kind) ?? "", AutopilotText.tellUndoLabel(kind),
    ]
    try check(
      lines.allSatisfy { !$0.lowercased().contains("bring") && !$0.contains("Undo") },
      "Programs and folders never say they bring anything back: \(lines)")
  }
  let programRows: [String] = AutopilotText.tellRows(programTell, now: Date(), calendar: .current)
    .map(\.when)
  try check(
    programRows == ["idle 3 h", "idle 1 h"],
    "A program's row says how long it sat idle when BZ stopped it: \(programRows)")
  for kindTell in [programTell, folderTell] {
    let kindModel = AppModel(demo: true)
    kindModel.autopilot.tells = [kindTell]
    let name = kindTell.kind == .process ? "teach-tell-programs" : "teach-tell-folders"
    let kindView = try render(
      TeachView(model: kindModel), size: TeachView.size, name: name, directory: directory)
    try require(
      kindView,
      [
        AutopilotText.tellHeadline(kindTell), AutopilotText.tellSize(kindTell),
        AutopilotText.tellCantComeBack(kindTell.kind) ?? "", "Good call", "I'd have said no",
        "You'd have said yes",
      ], in: name)
    try check(
      kindView.hasWords(of: AutopilotText.tellWhy(kindTell)),
      "\(name) is missing the reason. OCR saw: \(kindView.raw)")
    try check(
      !kindView.has("Undo") && !kindView.has("Bringing them back"),
      "\(name) offers no Undo and never says it brings anything back. OCR saw: \(kindView.raw)")
    for row in AutopilotText.tellRows(kindTell, now: Date(), calendar: .current) {
      try check(
        kindView.hasWords(of: row.title), "\(name) lost \"\(row.title)\". OCR saw: \(kindView.raw)")
    }
  }

  // Pressing the second button: both buttons go off at once. For copies the card says they are
  // coming back; for programs it says BZ will ask next time.
  var engineDone = false
  let problem = "I can't find that anymore."
  let undoing = AppModel(demo: true)
  undoing.autopilotRunner = { _ in
    while !engineDone { try? await Task.sleep(for: .milliseconds(20)) }
    throw StoreError.message(problem)
  }
  guard let pressed = undoing.autopilot.tells.first else {
    throw StoreError.message("Demo has no tell to undo")
  }
  undoing.tellUndo(pressed)
  try check(undoing.tellActions[pressed.id] == .undo, "Undo should show as under way at once")
  let undoingView = try render(
    TeachView(model: undoing), size: TeachView.size, name: "teach-tell-undoing",
    directory: directory)
  try require(
    undoingView, [AutopilotText.tellHeadline(demoTell), AutopilotText.undoingLine],
    in: "teach-tell-undoing")
  try check(
    !undoingView.has("You'd have said yes"),
    "An undone tell should not argue it was right. OCR saw: \(undoingView.raw)")
  let programsWorking = AppModel(demo: true)
  programsWorking.autopilot.tells = [programTell]
  programsWorking.autopilotRunner = { _ in
    while !engineDone { try? await Task.sleep(for: .milliseconds(20)) }
    throw StoreError.message(problem)
  }
  programsWorking.tellUndo(programTell)
  let workingView = try render(
    TeachView(model: programsWorking), size: TeachView.size, name: "teach-tell-programs-working",
    directory: directory)
  try require(
    workingView,
    [AutopilotText.tellHeadline(programTell), "Got it. I'll ask next time.", "I'd have said no"],
    in: "teach-tell-programs-working")
  try check(
    !workingView.has("Bringing them back") && !workingView.has("Undo")
      && !workingView.has("Stopped programs can't be restarted"),
    "A program tell under way says BZ will ask next time, and nothing about bringing back. OCR saw: \(workingView.raw)"
  )
  // The engine can't do it: the tell comes back with its buttons, and says why on the card.
  engineDone = true
  let comeBack = Date().addingTimeInterval(3)
  while !(undoing.tellActions.isEmpty && programsWorking.tellActions.isEmpty) && Date() < comeBack {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
  try check(
    undoing.tellActions.isEmpty && programsWorking.tellActions.isEmpty,
    "A tell the engine couldn't undo stayed under way")
  try check(
    undoing.tellProblems[pressed.id] == problem && undoing.message == problem,
    "A failed Undo keeps its reason for the Teach window as well as the footer")
  let failedView = try render(
    TeachView(model: undoing), size: TeachView.size, name: "teach-tell-failed",
    directory: directory)
  try require(
    failedView, [AutopilotText.tellHeadline(demoTell), problem, "Good call", "Undo"],
    in: "teach-tell-failed")
  // Cut short by a quit, the engine still lists it as undoing and nothing else will finish it, so
  // Undo stays there to pick it up where it stopped; Good call is off, the engine refuses it.
  let resume = AppModel(demo: true)
  resume.autopilot.tells[0].state = "undoing"
  resume.autopilot.tells[0].note = AutopilotPolicy.newerAnswerStands
  let resumeView = try render(
    TeachView(model: resume), size: TeachView.size, name: "teach-tell-resume",
    directory: directory)
  try require(
    resumeView,
    [
      AutopilotText.tellHeadline(demoTell), AutopilotText.tellStalled(.worktree),
      "Your newer answer stands", "Good call", "Undo",
    ], in: "teach-tell-resume")
  try check(
    !resumeView.has("Bringing them back") && !resumeView.has("You'd have said yes"),
    "A stalled Undo says it didn't finish. OCR saw: \(resumeView.raw)")
  let programsStalled = AppModel(demo: true)
  programsStalled.autopilot.tells = [programTell]
  programsStalled.autopilot.tells[0].state = "undoing"
  let stalledView = try render(
    TeachView(model: programsStalled), size: TeachView.size, name: "teach-tell-programs-stalled",
    directory: scratch)
  try require(
    stalledView, [AutopilotText.tellStalled(.process), "Good call", "I'd have said no"],
    in: "teach-tell-programs-stalled")
  try check(
    !stalledView.has("Undo") && !stalledView.has("bring them back"),
    "A stalled program tell never says it brings anything back. OCR saw: \(stalledView.raw)")

  // An Undo that couldn't bring every copy back stays in view, undone, saying which and why, with
  // one OK.
  let unrestored = AppModel(demo: true)
  let unrestoredNote = "1 copy couldn't come back. The restore point is gone."
  unrestored.autopilot.tells[0].state = "undone"
  unrestored.autopilot.tells[0].note = unrestoredNote
  unrestored.autopilot.tells[0].seen = false
  let unrestoredView = try render(
    TeachView(model: unrestored), size: TeachView.size, name: "teach-tell-unrestored",
    directory: directory)
  try require(
    unrestoredView,
    [AutopilotText.tellHeadline(demoTell), "Undo finished", "1 copy couldn't come back", "OK"],
    in: "teach-tell-unrestored")
  try check(
    unrestoredView.hasWords(of: unrestoredNote),
    "teach-tell-unrestored is missing the reason. OCR saw: \(unrestoredView.raw)")
  try check(
    unrestoredView.text.components(separatedBy: " ").contains("ok")
      && !unrestoredView.has("Good call") && !unrestoredView.has("You'd have said yes"),
    "An undone tell with a note offers OK and nothing else. OCR saw: \(unrestoredView.raw)")
  let unrestoredTell: AutopilotTell = unrestored.autopilot.tells[0]
  unrestored.tellSeen(unrestoredTell)
  try check(
    !unrestored.autopilot.tellsWaiting.contains { $0.id == unrestoredTell.id },
    "OK closes what an Undo left to read")

  // A tell that burned nothing says nothing, and one program or folder reads in the singular. Every
  // surface asks the snapshot for the tells that wait.
  var nothing = demoTell
  nothing.count = 0
  try check(!AutopilotText.shows(nothing), "A tell that burned nothing must not show")
  var closed = demoTell
  closed.state = "good"
  try check(!AutopilotText.shows(closed), "A closed tell must not show")
  var crowd = snapshot
  crowd.tells = [demoTell, nothing, closed]
  try check(crowd.tellsWaiting == [demoTell], "The snapshot lists only the tells that wait")
  var oneProgram = demoTell
  oneProgram.kind = .process
  oneProgram.count = 1
  var someFolders = demoTell
  someFolders.kind = .disk
  let programWords: String = AutopilotText.tellHeadline(oneProgram)
  let folderWords: String = AutopilotText.tellHeadline(someFolders)
  let copyWords: String = AutopilotText.tellHeadline(demoTell)
  try check(
    programWords == "Burned 1 program on my own." && folderWords == "Burned 3 folders on my own."
      && copyWords == "Burned 3 copies on my own.",
    "The tell headline should name its things")
  var guessed = demoTell
  guessed.why = "I think you'll say yes."
  try check(
    AutopilotText.tellWhy(guessed) == "You'd have said yes: I think you'll say yes.",
    "A reason that starts with I keeps its capital")

  // A tell that arrives while a question is on screen waits for the card to end.
  let onScreen = questions[0]
  let behind = questions[1]
  try check(
    TeachView.card(
      confirming: false, pinned: onScreen.id, tells: [demoTell], waiting: [onScreen, behind])
      == .question(onScreen.id), "A question on screen stays when a tell arrives")
  try check(
    TeachView.card(confirming: false, pinned: nil, tells: [demoTell], waiting: [onScreen, behind])
      == .tell(demoTell.id), "With no card on screen, what BZ did on its own comes first")
  try check(
    TeachView.card(confirming: false, pinned: onScreen.id, tells: [demoTell], waiting: [behind])
      == .tell(demoTell.id), "When the question on screen is gone, the tell comes next")
  try check(
    TeachView.card(confirming: true, pinned: onScreen.id, tells: [demoTell], waiting: [onScreen])
      == .confirmation, "A confirmation is a card too")
  try check(
    TeachView.card(confirming: false, pinned: nil, tells: [], waiting: [onScreen, behind])
      == .question(onScreen.id)
      && TeachView.card(confirming: false, pinned: nil, tells: [], waiting: []) == .caughtUp,
    "Questions, then all caught up")
  let latch = AppModel(demo: true)
  latch.autopilot.tells = []
  let latchHost = NSHostingView(rootView: TeachView(model: latch))
  latchHost.sizingOptions = []
  latchHost.frame = NSRect(origin: .zero, size: TeachView.size)
  let latchSurface = NSWindow(
    contentRect: latchHost.frame, styleMask: .borderless, backing: .buffered, defer: false)
  latchSurface.contentView = latchHost
  let latchAsking = try capture(
    latchHost, surface: latchSurface, name: "latch-asking", directory: scratch)
  try check(
    latchAsking.hasWords(of: card.headline),
    "The latch proof starts on a question. OCR saw: \(latchAsking.raw)")
  latch.autopilot.tells = snapshot.tells
  let whileAsking = try capture(
    latchHost, surface: latchSurface, name: "latch-arrived", directory: scratch)
  try check(
    whileAsking.hasWords(of: card.headline)
      && !whileAsking.hasWords(of: AutopilotText.tellHeadline(demoTell)),
    "A tell that arrives must not replace the question on screen. OCR saw: \(whileAsking.raw)")
  latch.answer(onScreen, .skip)
  let atBoundary = try capture(
    latchHost, surface: latchSurface, name: "latch-boundary", directory: scratch)
  try check(
    atBoundary.hasWords(of: AutopilotText.tellHeadline(demoTell)),
    "When the question is answered, the tell comes next. OCR saw: \(atBoundary.raw)")

  let quiet = AppModel(demo: true)
  quiet.autopilot.questions = []
  quiet.autopilot.tells = []
  let teachEmpty = try render(
    TeachView(model: quiet), size: TeachView.size, name: "teach-empty", directory: directory)
  try require(teachEmpty, ["All caught up"], in: "teach-empty")
  try check(!teachEmpty.raw.contains("trained"), "caught-up shows a training percentage")
  // After a Yes: "Got it!", the lesson it taught in one sentence, and what BZ does from now on.
  let answeredModel = AppModel(demo: true)
  answeredModel.autopilot.tells = []
  guard let toAnswer = answeredModel.autopilot.questions.first else {
    throw StoreError.message("Demo has no question to answer")
  }
  answeredModel.answer(toAnswer, .yes)
  guard let taught = AutopilotText.lesson(taughtBy: toAnswer.id, in: answeredModel.autopilot)
  else { throw StoreError.message("The lesson a Yes taught is in no lesson group") }
  let teachDone = try render(
    TeachView(model: answeredModel, confirmation: TeachView.confirmation(for: toAnswer, .yes)),
    size: TeachView.size, name: "teach-confirmed", directory: directory)
  try require(teachDone, ["Got it"], in: "teach-confirmed")
  try check(
    teachDone.hasWords(of: taught.sentence),
    "teach-confirmed is missing the lesson. OCR saw: \(teachDone.raw)")
  try check(
    teachDone.hasWords(of: AutopilotText.handling),
    "teach-confirmed is missing what BZ will do. OCR saw: \(teachDone.raw)")
  hint(teachDone, "teach-confirmed", ["handle these on my own", "What BZ has learned"])
  try check(
    AutopilotText.handling
      == "I'll handle these on my own from now on. To change it, use Forget in What BZ has learned."
      && AutopilotText.learnedHeading == "What BZ has learned",
    "The line under the lesson points at the Settings heading by its own name")
  try check(
    !teachDone.has("What I've learned") && !teachDone.has("copies like these"),
    "The old pointer and the claim about \"copies like these\" are gone. OCR saw: \(teachDone.raw)")
  let skipped = TeachView.confirmation(for: toAnswer, .skip)
  let refused = TeachView.confirmation(for: toAnswer, .no)
  try check(
    skipped.taught == nil && skipped.text == "No problem. I'll ask again tomorrow.",
    "A skip teaches nothing")
  try check(
    refused.taught?.questionID == toAnswer.id && refused.symbol == "hand.raised.fill"
      && refused.text == "Got it!",
    "A No says Got it! and points at its lesson")
  // When a tell comes next, the card says "Next up…"; questions say "Next question coming up…".
  try check(
    AutopilotText.whatsNext(tells: 1, questions: 2) == "Next up…"
      && AutopilotText.whatsNext(tells: 0, questions: 2) == "Next question coming up…"
      && AutopilotText.whatsNext(tells: 0, questions: 0) == "That's everything for now.",
    "The confirmation says what comes next")
  let tellNext = AppModel(demo: true)
  tellNext.autopilot.questions = []
  let nextUp = try render(
    TeachView(model: tellNext, confirmation: TeachView.confirmation(for: toAnswer, .skip)),
    size: TeachView.size, name: "teach-confirmed-tell-next", directory: scratch)
  try require(nextUp, ["Next up"], in: "teach-confirmed-tell-next")
  try check(
    !nextUp.has("Next question coming up"),
    "A tell is next, not a question. OCR saw: \(nextUp.raw)")
  let teachWindow = TeachView.makeWindow(model: model)
  let windowWidth: CGFloat = teachWindow.contentView?.bounds.width ?? 0
  let windowHeight: CGFloat = teachWindow.contentView?.bounds.height ?? 0
  try check(
    !teachWindow.isVisible && abs(windowWidth - 640) < 1
      && abs(windowHeight - TeachView.size.height) < 1,
    "Teach BZ window should be \(Int(TeachView.size.width)) wide and unshown")
  print(
    "PASS autopilot UI Teach BZ render: question card with rows, heavier cards, copy, program and folder tells, working, failed and stalled tells, an Undo that left a copy behind, a tell that waits for the card on screen, lesson confirmation and empty state"
  )

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

  // Settings: the section that Settings embeds. The real window scrolls; the proof lays it out in full.
  func settingsView(_ model: AppModel) -> some View {
    AutopilotSettingsView(model: model).padding(20).frame(width: 440)
      .frame(maxHeight: .infinity, alignment: .top).background(AutopilotTheme.window)
      .environment(\.colorScheme, .dark)
  }
  let settings = try render(
    settingsView(model), size: NSSize(width: 440, height: 1250), name: "settings",
    directory: directory)
  try require(
    settings,
    [
      "What BZ has learned", "How I'm doing", "Act on its own when sure", "Look only",
      "Start training over",
    ],
    in: "settings")
  // Every lesson reads as its own sentence with what it rests on, and every count is a plain line.
  for group in snapshot.lessons {
    try check(
      settings.hasWords(of: group.sentence),
      "settings lost the lesson \"\(group.sentence)\". OCR saw: \(settings.raw)")
    try check(
      settings.hasWords(of: group.evidence),
      "settings lost its evidence \"\(group.evidence)\". OCR saw: \(settings.raw)")
  }
  for line in snapshot.progress.lines {
    try check(
      settings.hasWords(of: line), "settings lost \"\(line)\". OCR saw: \(settings.raw)")
  }
  try check(
    settings.hasWords(of: AutopilotSettingsView.actsCaption),
    "settings lost the toggle caption. OCR saw: \(settings.raw)")
  try check(
    AutopilotSettingsView.actsCaption
      == "When I'm sure, I'll do it and tell you after. Copies can be undone. Off means I always ask first.",
    "The toggle caption says only copies can be undone")
  try check(
    snapshot.lessons.allSatisfy {
      AutopilotText.forgetLabel($0) == "Forget: " + $0.sentence
    }, "Each Forget button is labeled with its lesson")
  hint(settings, "settings", ["Sweep every", "Starter rules", "Forget", "Undo"])
  try check(
    !settings.raw.contains("%") && !settings.raw.contains("trained"),
    "settings shows a percentage or training score. OCR saw: \(settings.raw)")
  // A new install has nothing learned and nothing to count yet, and says so without an empty list.
  let fresh = AppModel(demo: true)
  fresh.autopilot.lessons = []
  fresh.autopilot.progress = AutopilotProgress()
  let settingsFresh = try render(
    settingsView(fresh), size: NSSize(width: 440, height: 640), name: "settings-empty",
    directory: directory)
  try require(
    settingsFresh, ["What BZ has learned", "Nothing yet", "Act on its own when sure"],
    in: "settings-empty")
  try check(
    !settingsFresh.has("How I'm doing"),
    "A new install has no counts, so it shows no How I'm doing. OCR saw: \(settingsFresh.raw)")
  print(
    "PASS autopilot UI Settings render: \(snapshot.lessons.count) lessons with Forget, How I'm doing, Act on its own when sure, starter rules and Start training over"
  )

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
  guard
    let learned = yes.autopilot.rules.first(where: {
      AutopilotPolicy.questionIDs($0).contains(asked.id)
    })
  else {
    throw StoreError.message("Answering yes did not create a rule")
  }
  try check(learned.verdict == .burn && learned.source == .`operator`, "A yes must teach a burn rule")
  // The answer teaches why, not which project: the engine's own lesson, kept to the risks its card
  // showed, and it is in a group that reads as a sentence.
  let engineLesson: AutopilotRule = AutopilotPolicy.lesson(
    for: asked, verdict: .burn, created: Date())
  let widest: [String: [String]] = AutopilotPolicy.lessonMatch(
    asked.kind, asked.match, verdict: .burn)
  try check(
    learned.questionID == asked.id && learned.match == engineLesson.match,
    "A yes must teach the general lesson the engine teaches")
  try check(
    asked.risks != nil && learned.match != widest
      && AutopilotPolicy.subsumes(widest, learned.match),
    "A yes must keep to the risks its card showed")
  guard let heldBy = AutopilotText.lesson(taughtBy: asked.id, in: yes.autopilot) else {
    throw StoreError.message("The lesson a yes taught is in no lesson group")
  }
  try check(
    heldBy.ruleIDs.contains(learned.id) && heldBy.sentence.hasSuffix("."),
    "A new lesson must show as a sentence in its group")
  try check(yes.autopilot.questions.filter(\.isOpen).count == 2, "The answered question stayed open")
  try check(yes.autopilot.answers == answersBefore + 1, "The answer was not counted")
  try check(yes.autopilot.count(.unsure) < unsureBefore, "Yes did not move matching things")
  let ruled = yes.autopilot.entries.filter { $0.authority == "rule:" + learned.id }
  try check(!ruled.isEmpty && ruled.allSatisfy { $0.status == .burn }, "Yes did not mean Will burn")
  try tidy(yes, "yes")

  // An answer names no project or maker, and the lessons it joins take its answers in.
  let general = AppModel(demo: true)
  let tied = AutopilotQuestion(
    kind: .worktree, match: ["repo": ["api"], "place": ["patrol6"], "stale": ["week"]],
    question: "", why: "", examples: [], count: 2, bytes: 2_000_000_000)
  general.autopilot.questions.append(tied)
  func copyLessons(_ model: AppModel) -> Int {
    model.autopilot.rules.filter { $0.source == .`operator` && $0.kind == .worktree }.count
  }
  let copyLessonsBefore = copyLessons(general)
  general.answer(tied, .yes)
  guard let wide = general.autopilot.rules.first(where: { $0.questionID == tied.id }) else {
    throw StoreError.message("Answering a question about one project did not create a rule")
  }
  let ages: [String] = ["week", "month", "older"]
  let namesNothing: Bool = wide.match["repo"] == nil && wide.match["place"] == nil
  try check(
    namesNothing && wide.match["stale"] == ages,
    "A lesson must not name the project or maker an answer was about")
  try check(
    copyLessons(general) < copyLessonsBefore && !(wide.from ?? []).isEmpty,
    "A wider lesson must take in the narrower ones instead of piling up beside them")
  try tidy(general, "an answer about one project")

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
    let counted = skip.autopilot.answers
    let groupsBefore = skip.autopilot.lessons
    skip.answer(q, .skip)
    try check(
      skip.autopilot.rules.count == rules && skip.autopilot.answers == counted
        && skip.autopilot.lessons == groupsBefore
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
  func openToChange(_ model: AppModel, _ rule: AutopilotRule) -> [String] {
    model.autopilot.entries.filter {
      $0.authority == "rule:" + rule.id && [.burn, .keep, .failed].contains($0.status)
    }.map(\.id)
  }
  guard
    let lesson = rules.autopilot.rules.first(where: {
      $0.source == .`operator` && !openToChange(rules, $0).isEmpty
    })
  else {
    throw StoreError.message("Demo has no learned rule that decides anything")
  }
  let affected = openToChange(rules, lesson)
  let burnedBefore = rules.autopilot.entries.filter { $0.status == .burned }.count
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
    rules.autopilot.entries.filter { $0.status == .burned }.count == burnedBefore,
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

  // Forget a whole lesson: every rule in its group goes with the answers they came from, and what
  // they decided is asked about again.
  let groups = AppModel(demo: true)
  guard
    let folders = groups.autopilot.lessons.first(where: {
      $0.kind == .disk && $0.verdict == .burn
    })
  else { throw StoreError.message("Demo has no folder lesson") }
  let folderEntries = groups.autopilot.entries.filter { entry in
    folders.ruleIDs.contains { entry.authority == "rule:" + $0 }
  }.map(\.id)
  groups.forgetLesson(folders)
  let rulesGone: Bool = !groups.autopilot.rules.contains { folders.ruleIDs.contains($0.id) }
  let groupGone: Bool = !groups.autopilot.lessons.contains { $0.id == folders.id }
  let reopened: Bool = folderEntries.allSatisfy { entry(groups, $0)?.status == .unsure }
  try check(
    folders.ruleIDs.count > 1 && !folderEntries.isEmpty && rulesGone && groupGone && reopened,
    "Forgetting a lesson did not forget every rule in its group and reopen what they decided")
  try tidy(groups, "forget a lesson")
  // A tell whose lesson is forgotten closes, without a score.
  let forgot = AppModel(demo: true)
  guard let actedTell = forgot.autopilot.tells.first,
    let actGroup = forgot.autopilot.lessons.first(where: { $0.ruleIDs.contains(actedTell.ruleID) }
    )
  else { throw StoreError.message("Demo has no tell with a lesson") }
  forgot.forgetLesson(actGroup)
  try check(forgot.autopilot.tells.isEmpty, "A forgotten lesson left its tell open")

  // BZ acts on its own: Good call closes the tell and keeps the lesson; Undo closes it, brings back
  // what BZ burned, keeps those copies, and turns the lesson into the keep a No teaches.
  let good = AppModel(demo: true)
  guard let called = good.autopilot.tells.first else {
    throw StoreError.message("Demo has no tell")
  }
  good.tellGood(called)
  try check(
    good.autopilot.tells.isEmpty && good.tellActions.isEmpty
      && good.autopilot.rules.contains { $0.id == called.ruleID },
    "Good call must close the tell and leave its lesson")
  let undo = AppModel(demo: true)
  guard let taken = undo.autopilot.tells.first else {
    throw StoreError.message("Demo has no tell")
  }
  let burnedByAct = undo.autopilot.entries.filter { $0.authority == "rule:" + taken.ruleID }.map(
    \.id)
  undo.tellUndo(taken)
  undo.tellUndo(taken)
  let keepTaught = undo.autopilot.rules.first {
    $0.verdict == .keep && $0.questionID == taken.questionID
  }
  var broughtBack = true
  for id in burnedByAct {
    let thing = entry(undo, id)
    if thing?.status != .keep || thing?.receipt?.outcome != "restored" { broughtBack = false }
  }
  try check(
    undo.autopilot.tells.isEmpty && undo.tellActions.isEmpty && burnedByAct.count == taken.count
      && broughtBack, "Undo must close the tell and bring back what BZ burned")
  let keptAges: [String] = keepTaught?.match["stale"] ?? []
  let keepID: String = keepTaught?.id ?? ""
  let actGone: Bool = !undo.autopilot.rules.contains { $0.id == taken.ruleID }
  let keepShown: Bool = undo.autopilot.lessons.contains {
    $0.verdict == .keep && $0.ruleIDs.contains(keepID)
  }
  let actHidden: Bool = !undo.autopilot.lessons.contains { $0.ruleIDs.contains(taken.ruleID) }
  try check(
    actGone && keptAges.contains("week") && keptAges.contains("today") && keepShown && actHidden,
    "Undo must turn the lesson into a keep, wider toward riskier, and show it as one")
  try tidy(undo, "good call and undo")
  // When a newer answer of the owner's took BZ's lesson in, Undo learns no keep, and the tell stays
  // saying the newer answer stands until OK.
  let newer = AppModel(demo: true)
  guard let absorbed = newer.autopilot.tells.first,
    let actIndex = newer.autopilot.rules.firstIndex(where: { $0.id == absorbed.ruleID })
  else { throw StoreError.message("Demo has no tell with a lesson") }
  var wider: AutopilotRule = newer.autopilot.rules[actIndex]
  wider.id = "demo-owner-wider"
  wider.tellID = nil
  wider.formerIDs = [absorbed.ruleID]
  newer.autopilot.rules[actIndex] = wider
  newer.tellUndo(absorbed)
  let left: AutopilotTell? = newer.autopilot.tellsWaiting.first { $0.id == absorbed.id }
  let keptAnyway: Bool = newer.autopilot.rules.contains { rule in
    rule.verdict == .keep && rule.questionID == absorbed.questionID
  }
  try check(
    left?.waitsForOK == true && left?.note == AutopilotPolicy.newerAnswerStands && !keptAnyway,
    "An Undo under a newer answer must learn no keep and say so until OK")
  if let left { newer.tellSeen(left) }
  try check(newer.autopilot.tellsWaiting.isEmpty, "OK must close it")
  // Whether BZ acts on its own is the owner's setting: on by default, and start over keeps it.
  let own = AppModel(demo: true)
  try check(own.autopilot.actsOnItsOwn, "BZ should act on its own when sure by default")
  own.setActsOnItsOwn(false)
  try check(!own.autopilot.actsOnItsOwn, "Turning acting off did not show")
  own.resetTraining()
  try check(
    !own.autopilot.actsOnItsOwn && own.autopilot.lessons.isEmpty && own.autopilot.tells.isEmpty
      && own.autopilot.progress.lines.isEmpty,
    "Start training over keeps the setting and forgets what was learned and counted")

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
  // Look-only: the menu line and the Findings sentence say nothing burns yet; switching it off
  // in Settings, or Start burning on the panel, brings Autopilot back.
  sweep.setLookOnly(true)
  try check(
    AutopilotText.sweepLine(sweep.autopilot.sweep, now: Date()).hasPrefix("Look-only")
      && AutopilotText.summary(sweep.autopilot).contains("once you start burning")
      && !AutopilotText.summary(sweep.autopilot).contains("on my own"),
    "Look-only did not show in the menu line and Findings")
  sweep.setLookOnly(false)
  try check(
    sweep.autopilot.sweep.lookOnly == nil
      && AutopilotText.sweepLine(sweep.autopilot.sweep, now: Date()).hasPrefix("Autopilot on"),
    "Start burning did not turn look-only off")

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
    let rule = wired.autopilot.rules.first, let firstTell = wired.autopilot.tells.first,
    let group = wired.autopilot.lessons.first
  else { throw StoreError.message("Demo data lost an entry the engine proof needs") }
  var secondTell = firstTell
  secondTell.id = "demo-tell-2"
  wired.autopilot.tells.append(secondTell)
  var thirdTell = firstTell
  thirdTell.id = "demo-tell-3"
  thirdTell.state = "undone"
  thirdTell.note = "1 copy couldn't come back. The restore point is gone."
  thirdTell.seen = false
  wired.autopilot.tells.append(thirdTell)
  wired.answer(q, .no)
  wired.burnNow(e)
  wired.keepForever(e)
  wired.restore(rcpt)
  wired.forgetRule(rule)
  wired.setStarter("starter-finished-copies", enabled: false)
  wired.setAutopilot(enabled: false)
  wired.setLookOnly(false)
  wired.setSweepInterval(minutes: 60)
  wired.resetTraining()
  wired.sweepNow()
  wired.tellGood(firstTell)
  wired.tellUndo(secondTell)
  wired.tellSeen(thirdTell)
  wired.setActsOnItsOwn(false)
  wired.forgetLesson(group)
  let expected: [AutopilotCommand] = [
    .answer(questionID: q.id, answer: .no), .burnNow(itemID: e.id), .keep(itemID: e.id),
    .restore(receiptID: rcpt.id), .forgetRule(ruleID: rule.id),
    .setStarter(ruleID: "starter-finished-copies", enabled: false), .setEnabled(false),
    .setLookOnly(false), .setInterval(minutes: 60), .resetTraining, .sweepNow,
    .tellGood(id: firstTell.id), .tellUndo(id: secondTell.id), .tellSeen(id: thirdTell.id),
    .setActsOnItsOwn(false), .forgetLesson(ruleIDs: group.ruleIDs),
  ]
  let deadline = Date().addingTimeInterval(3)
  while (sent.count < expected.count || wired.autopilot != marker) && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
  try check(sent == expected, "The engine received the wrong commands: \(sent)")
  try check(wired.autopilot == marker, "The engine's snapshot was not shown")
  try check(
    wired.tellActions.isEmpty, "A tell command the engine finished stayed marked as under way")
  let failing = AppModel(demo: true)
  let before = failing.autopilot
  let refusal = "That one is already closed."
  failing.autopilotRunner = { _ in throw StoreError.message(refusal) }
  failing.setAutopilot(enabled: false)
  let failDeadline = Date().addingTimeInterval(3)
  while failing.message == nil && Date() < failDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
  try check(
    failing.message != nil && failing.autopilot == before,
    "A failed engine command should say so and change nothing")
  // An Undo the engine couldn't do shows as under way, then gives the tell its buttons back.
  if let stuck = failing.autopilot.tells.first {
    failing.tellUndo(stuck)
    try check(failing.tellActions[stuck.id] == .undo, "Undo should show as under way at once")
    let undoDeadline = Date().addingTimeInterval(3)
    while !failing.tellActions.isEmpty && Date() < undoDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    try check(
      failing.tellActions.isEmpty && failing.autopilot.tells.first == stuck,
      "An Undo the engine couldn't do should leave the tell as it was")
    try check(
      failing.tellProblems[stuck.id] == refusal && failing.message == refusal,
      "A failed Undo keeps the engine's reason for the tell, as well as for the footer")
    // A new press clears the old reason; a Good call the engine can't do gives its own.
    failing.tellGood(stuck)
    try check(failing.tellProblems[stuck.id] == nil, "A new press should clear the last reason")
    let goodDeadline = Date().addingTimeInterval(3)
    while !failing.tellActions.isEmpty && Date() < goodDeadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    try check(
      failing.tellProblems[stuck.id] == refusal && failing.autopilot.tells.first == stuck,
      "A failed Good call says why and leaves the tell")
  } else {
    throw StoreError.message("Demo has no tell for the failing engine proof")
  }
  print(
    "PASS autopilot UI commands: answer, burn now, keep forever, restore, forget, forget a whole lesson, Good call, Undo, OK on an undone tell, act on its own, starter switch, reset, interval, sweep now, look-only and engine hand-off"
  )
}
#endif
