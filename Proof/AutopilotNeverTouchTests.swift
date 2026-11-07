import BurnCore
import CryptoKit
import Foundation

private func require<T>(_ value: T?, _ what: String) throws -> T {
  guard let value else { throw StoreError.message("Missing: " + what) }
  return value
}

/// Never touches, lesson switches, the old cleaner's retirement and what Settings' AI rows save.
func autopilotNeverTouchProof() async throws {
  let base = URL(fileURLWithPath: "/private/tmp/bz-never-" + UUID().uuidString.prefix(8))
  defer { try? FileManager.default.removeItem(at: base) }
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

  // The list covers what's inside a folder, what holds one, and nothing that only looks similar.
  var memory = AutopilotMemory()
  func item(_ kind: AutopilotKind, _ path: String) -> AutopilotItem {
    AutopilotItem(
      id: "\(kind.rawValue):" + path, kind: kind, name: path, path: path, bytes: 1 << 30,
      facts: ["family": "node", "orphaned": "yes", "thread": "ended", "idle": "1d",
        "listening": "no", "agent": "claude"])
  }
  let program = item(.process, "/work/keep/bin/node")
  equal(AutopilotPolicy.decide(program, memory: memory).status, .burn, "a starter rule burns it")
  memory.neverTouch = ["/work/keep"]
  equal(AutopilotPolicy.decide(program, memory: memory).status, .keep, "inside a listed folder")
  equal(
    AutopilotPolicy.decide(item(.process, "/work/keep"), memory: memory).status, .keep,
    "the listed path itself")
  equal(
    AutopilotPolicy.decide(item(.worktree, "/work"), memory: memory).status, .keep,
    "a copy that holds a listed folder")
  check(
    !AutopilotPolicy.neverTouched(item(.process, "/work/keeper/bin/node"), memory: memory),
    "a neighbor with a similar name isn't covered")

  // No rule, AI verdict or Burn now gets past it: the real burn path, on a real folder.
  let root = base.appendingPathComponent("state")
  let home = WorkspaceSafety.canonical(base.path) + "/home"
  let target = home + "/.npm/_cacache"
  try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
  try Data("fixture".utf8).write(to: URL(fileURLWithPath: target + "/entry"))
  try FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(-10 * 86_400)], ofItemAtPath: target)
  let cache = try require(
    AutopilotDisk.items(
      worktrees: [], home: home, mains: false, sizer: { _ in 5_000_000_000 }
    ).first { $0.path == target }, "Autopilot sees the folder")
  let engine = try Autopilot(
    root: root,
    sources: AutopilotSources(
      disk: { _ in [cache] },
      reclaimDisk: { item, authority in
        AutopilotDisk.reclaim(
          item, authority: authority, home: home, inUse: { _ in 0 }, root: root,
          recoveryKey: SymmetricKey(size: .bits256))
      }))
  _ = await engine.tick()
  let yes = AutopilotRule(
    id: "tool-caches", kind: .disk, match: ["folder": ["package-cache"]], verdict: .burn,
    source: .operator, title: "Tool caches", created: Date())
  try AutopilotStore(root: root).updateMemory { $0.rules = [yes] }
  _ = try await engine.apply(.neverTouch(path: target))
  _ = await engine.tick()
  check(FileManager.default.fileExists(atPath: target), "a rule's burn leaves it alone")
  var refused = ""
  do { _ = try await engine.apply(.burnNow(itemID: cache.id)) } catch {
    refused = error.localizedDescription
  }
  check(refused.contains("never to touch"), "Burn now is refused: \(refused)")
  check(FileManager.default.fileExists(atPath: target), "Burn now leaves it alone")
  let burnt = await engine.burn([cache.id])
  equal(burnt.first?.outcome, "refused", "the AI is refused")
  check(FileManager.default.fileExists(atPath: target), "the AI leaves it alone")
  equal(await engine.snapshot().neverTouch, [target], "Settings can show the list")
  _ = try await engine.apply(.resetTraining)
  equal(await engine.snapshot().neverTouch, [target], "starting training over keeps the list")
  // Off the list, the same rule burns it, so the check above really was the list.
  try AutopilotStore(root: root).updateMemory { $0.rules = [yes] }
  _ = try await engine.apply(.allowTouch(path: target))
  _ = await engine.tick()
  check(!FileManager.default.fileExists(atPath: target), "off the list, its rule burns it")

  // Keep forever shows on the same list and comes off the same way.
  _ = try await engine.apply(.keep(itemID: cache.id))
  equal(await engine.snapshot().keptPaths, [target], "Keep forever appears by its path")
  _ = try await engine.apply(.allowTouch(path: target))
  equal(await engine.snapshot().keptPaths, [], "taken back")
  isNil(try AutopilotStore(root: root).memory().keptItems.first { $0.contains(cache.id) })

  // A lesson switched off burns nothing, teaches nothing, and comes back on.
  let copy = AutopilotItem(
    id: "worktree:c", kind: .worktree, name: "c", path: "/work/c", bytes: 1 << 30,
    facts: ["place": "codex", "saved": "merged", "changes": "none", "stale": "older"])
  let lesson = AutopilotRule(
    id: "old-copies", kind: .worktree, match: ["stale": ["older"]], verdict: .burn,
    source: .operator, title: "Old copies", created: Date())
  var switching = AutopilotMemory()
  switching.rules = [lesson]
  equal(AutopilotPolicy.decide(copy, memory: switching).status, .burn, "a lesson on burns")
  isNil(AutopilotPolicy.lessonGroups(switching).first?.off)
  switching.rules[0].enabled = false
  equal(AutopilotPolicy.decide(copy, memory: switching).status, .unsure, "a lesson off doesn't")
  equal(AutopilotPolicy.lessonGroups(switching).first?.off, true, "Settings shows it off")
  check(AutopilotPolicy.catalogLessons(switching).isEmpty, "the AI doesn't read it as a lesson")
  // With every other reason to act on its own in place, the switch alone stops it.
  var earned = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["older"]], question: "Burn old copies?", why: "",
    examples: [], count: 1, bytes: 1 << 30)
  earned.answer = AutopilotAnswer.yes
  earned.answered = Date()
  var asked = earned
  asked.id = "q2"
  asked.answer = nil
  asked.answered = nil
  switching.questions = [earned, asked]
  let topic = AutopilotPolicy.subject(.worktree, ["stale": ["older"]])
  switching.scores = (0..<12).map { index in
    AutopilotScore(
      questionID: "s\(index)", subject: topic, guess: AutopilotAnswer.yes,
      answer: AutopilotAnswer.yes, right: true, date: Date())
  }
  check(AutopilotPolicy.guess(asked, memory: switching)?.sure == false, "a switched-off lesson: asks")
  switching.rules[0].enabled = true
  check(AutopilotPolicy.guess(asked, memory: switching)?.sure == true, "switched on: can act again")
  let switchRoot = base.appendingPathComponent("switch")
  let switchEngine = try Autopilot(root: switchRoot, sources: AutopilotSources())
  try AutopilotStore(root: switchRoot).updateMemory { $0.rules = [lesson] }
  let off = try await switchEngine.apply(.setLesson(ruleIDs: ["old-copies"], enabled: false))
  equal(off.lessons.first?.off, true, "the command switches it off")
  let on = try await switchEngine.apply(.setLesson(ruleIDs: ["old-copies"], enabled: true))
  isNil(on.lessons.first?.off)

  // The old cleaner goes off, and what was protected there moves over and stays moved.
  let oldRoot = base.appendingPathComponent("old")
  let oldStore = try Store(root: oldRoot)
  var old = DiskPolicy(home: base.appendingPathComponent("home"))
  old.mode = "automatic"
  old.maximumGBPerDay = 1
  old.protectedPaths = ["/work/always"]
  old.rules = [
    DiskRule(path: "/work/keep", disposition: "keep"),
    DiskRule(path: "/work/approved", disposition: "regenerable"),
  ]
  try old.save(oldStore)
  try Autopilot.retireDiskCleanup(root: oldRoot)
  let retired = try DiskPolicy.load(oldStore)
  equal(retired.mode, "off", "the old cleaner is off")
  check(retired.protectedPaths.isEmpty && retired.rules.isEmpty, "nothing is left to hold it")
  equal(retired.roots, old.roots, "worktree discovery keeps its folders")
  equal(
    try AutopilotStore(root: oldRoot).memory().neverTouch, ["/work/always", "/work/keep"],
    "protections move; an approval doesn't")
  try AutopilotStore(root: oldRoot).updateMemory { $0.neverTouch = [] }
  try Autopilot.retireDiskCleanup(root: oldRoot)
  equal(try AutopilotStore(root: oldRoot).memory().neverTouch, [], "one move: a removal stands")
  let newRoot = base.appendingPathComponent("new")
  try Autopilot.retireDiskCleanup(root: newRoot)
  equal(try DiskPolicy.load(Store(root: newRoot)).mode, "off", "a new install starts with it off")

  // A refused run says when its limit comes back; anything else doesn't count.
  let now = Date(timeIntervalSince1970: 1_794_100_000)
  let refusal = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1794171600,"rateLimitType":"seven_day"}}"#
  let warning = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1794171600}}"#
  equal(
    AutopilotSweeper.limitReset(in: Data(("noise\n" + refusal + "\n").utf8), now: now),
    Date(timeIntervalSince1970: 1_794_171_600), "the seven-day limit")
  isNil(AutopilotSweeper.limitReset(in: Data(warning.utf8), now: now))
  isNil(AutopilotSweeper.limitReset(in: Data(refusal.utf8), now: now.addingTimeInterval(86_400)))

  // Settings' AI rows save what they say.
  let aiRoot = base.appendingPathComponent("ai")
  let bins = base.appendingPathComponent("bin")
  try FileManager.default.createDirectory(at: bins, withIntermediateDirectories: true)
  for name in ["claude", "codex"] {
    let tool = bins.appendingPathComponent(name)
    try Data("#!/bin/sh\n".utf8).write(to: tool)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
  }
  let path = ProcessInfo.processInfo.environment["PATH"]
  let dirs = ProcessInfo.processInfo.environment["BURNZOMBIES_HARNESS_DIRS"]
  setenv("PATH", bins.path, 1)
  setenv("BURNZOMBIES_HARNESS_DIRS", bins.path, 1)
  defer {
    if let path { setenv("PATH", path, 1) }
    if let dirs { setenv("BURNZOMBIES_HARNESS_DIRS", dirs, 1) } else {
      unsetenv("BURNZOMBIES_HARNESS_DIRS")
    }
  }
  let app = URL(fileURLWithPath: "/Applications/BZ.app")
  try MachineReviewConfiguration.choose(nil, root: aiRoot, bundle: app)
  isNil(try MachineReviewConfiguration.load(root: aiRoot))
  try MachineReviewConfiguration.choose("claude", root: aiRoot, bundle: app)
  var chosen = try require(try MachineReviewConfiguration.load(root: aiRoot), "saved")
  check(chosen.enabled, "choosing an AI turns it on")
  equal(chosen.server, "/Applications/BZ.app/Contents/MacOS/burnzombies-mcp", "the app's own tool")
  equal(chosen.brain, AIBrain.smart, "BZ's default is Smart")
  chosen.set(.smartest)
  equal(chosen.model, "opus", "Smartest on Claude")
  equal(chosen.brain, AIBrain.smartest, "and reads back")
  try chosen.save(root: aiRoot)
  try MachineReviewConfiguration.choose(nil, root: aiRoot, bundle: app)
  var offAI = try require(try MachineReviewConfiguration.load(root: aiRoot), "still saved")
  check(!offAI.enabled, "Off turns AI off")
  equal(offAI.model, "opus", "and keeps the choice for later")
  try MachineReviewConfiguration.choose("claude", root: aiRoot, bundle: app)
  offAI = try require(try MachineReviewConfiguration.load(root: aiRoot), "back on")
  check(offAI.enabled && offAI.model == "opus", "back on, as it was")
  try MachineReviewConfiguration.choose("codex", root: aiRoot, bundle: app)
  var codex = try require(try MachineReviewConfiguration.load(root: aiRoot), "codex")
  equal(codex.brain, AIBrain.smart, "a new AI starts at Smart")
  codex.set(.quick)
  isNil(codex.model)
  equal(codex.reasoningEffort, "low", "Quick on Codex")
  codex.model = "some-model"
  isNil(codex.brain)
}
