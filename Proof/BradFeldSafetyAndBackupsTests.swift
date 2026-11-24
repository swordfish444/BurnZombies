import BurnCore
import CryptoKit
import Darwin
import Foundation

/// End-to-end proofs covering Brad Feld / Fluffy audit findings and configurable backups:
/// 1. Persistent worktree pool detection (`magic0` + `magic1..11` on `available-N`, reused HEAD
///    reflog), sibling ask-only safety, and lesson non-generalization across pool slots.
/// 2. Complete `git worktree lock` hard rail protecting both the worktree and its `node_modules`.
/// 3. Strict `$TMPDIR/claude-<uid>` scratch matching (immunity for `$TMPDIR/claude-federation/`).
/// 4. Configurable backup retention (default 7d, arbitrary days 1/3/14, live expiration pruning,
///    and disabled backups `0` with honest warnings, no Undo/Act-then-tell, and intact safety rails).
/// 5. AI sweep usage attribution tags/env vars and `allowFailover` default-on + opt-out toggle.
func bradFeldSafetyAndBackupsProof() async throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent(
    "bz-brad-proof-" + UUID().uuidString, isDirectory: true)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  let canonRoot = WorkspaceSafety.canonical(root.path)
  let now = Date()

  func git(_ path: String, _ args: [String]) throws {
    _ = try WorktreeGit.run(path, args, seconds: 20)
  }

  // ---------------------------------------------------------------------------
  // 1. Real Git repo with a magic0..3 worktree slot pool + magic-cursor sibling + locked slot
  // ---------------------------------------------------------------------------
  let codeDir = canonRoot + "/Code"
  let mainRepo = codeDir + "/magic0"
  try fm.createDirectory(atPath: mainRepo, withIntermediateDirectories: true)
  try git(mainRepo, ["init", "-b", "main"])
  try git(mainRepo, ["config", "user.name", "Test"])
  try git(mainRepo, ["config", "user.email", "test@example.com"])
  try Data("hello\n".utf8).write(to: URL(fileURLWithPath: mainRepo + "/README.md"))
  try git(mainRepo, ["add", "README.md"])
  try git(mainRepo, ["commit", "-m", "initial"])

  let slot1 = codeDir + "/magic1"
  let slot2 = codeDir + "/magic2"
  let cursorSlot = codeDir + "/magic-cursor"
  let lockedSlot = codeDir + "/magic-locked"
  let claudeCopy = canonRoot + "/.claude/worktrees/exp-1"
  try fm.createDirectory(
    atPath: canonRoot + "/.claude/worktrees", withIntermediateDirectories: true)

  try git(mainRepo, ["worktree", "add", "-b", "available-1", slot1, "main"])
  try git(mainRepo, ["worktree", "add", "-b", "feat/something", slot2, "main"])
  try git(mainRepo, ["worktree", "add", "-b", "preview", cursorSlot, "main"])
  try git(mainRepo, ["worktree", "add", "-b", "keep-locked", lockedSlot, "main"])
  try git(mainRepo, ["worktree", "lock", "--reason", "pool slot", lockedSlot])
  try git(mainRepo, ["worktree", "add", "-b", "claude-task", claudeCopy, "main"])

  // Simulate multi-branch reuse in `cursorSlot`'s own HEAD reflog.
  for branch in ["feat/a", "feat/b", "feat/c", "preview"] {
    try git(cursorSlot, ["checkout", "-B", branch])
  }

  let commonGit = WorkspaceSafety.canonical(mainRepo + "/.git")
  let oldDate = now.addingTimeInterval(-45 * 86_400)
  func makeRecord(_ id: String, path: String, branch: String, main: Bool = false, locked: Bool = false)
    -> WorktreeRecord
  {
    var r = WorktreeRecord(id: id, path: path, repository: commonGit)
    r.main = main
    r.locked = locked
    r.branch = "refs/heads/" + branch
    r.status = "clean"
    r.changes = 0
    r.consumer = "none observed"
    r.allocated = 2_000_000_000
    r.lastCommitAt = oldDate
    r.lastFileChange = oldDate
    return r
  }

  let records = [
    makeRecord("m0", path: mainRepo, branch: "main", main: true),
    makeRecord("m1", path: slot1, branch: "available-1"),
    makeRecord("m2", path: slot2, branch: "feat/something"),
    makeRecord("mc", path: cursorSlot, branch: "preview"),
    makeRecord("ml", path: lockedSlot, branch: "keep-locked", locked: true),
    makeRecord("cl", path: claudeCopy, branch: "claude-task"),
  ]
  var delivery: [String: AutopilotDelivery] = [:]
  let items = AutopilotWorktrees.items(records, threads: [], delivery: &delivery, now: now)
  let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

  guard let item1 = byID["worktree:m1"], let item2 = byID["worktree:m2"],
    let itemCursor = byID["worktree:mc"], let itemLocked = byID["worktree:ml"],
    let itemClaude = byID["worktree:cl"]
  else {
    return failTest("missing expected worktree items")
  }

  equal(item1.facts["place"], "pool", "magic1 parked on available-1 is pool")
  equal(item1.facts[AutopilotWorktrees.poolRisk], "yes")
  equal(item2.facts["place"], "pool", "magic2 in numbered cluster magic0..2 is pool")
  equal(item2.facts[AutopilotWorktrees.poolRisk], "yes")
  equal(itemCursor.facts["place"], "pool", "magic-cursor with reused HEAD reflog is pool")
  equal(itemCursor.facts[AutopilotWorktrees.poolRisk], "yes")
  equal(itemClaude.facts["place"], "claude", "claude worktree stays claude")
  isNil(itemClaude.facts[AutopilotWorktrees.poolRisk])

  // Neither pool slots nor ordinary sibling copies are auto-burned by starter rules or AI sweeps.
  let siblingOnly = AutopilotItem(
    id: "worktree:sib", kind: .worktree, name: "repo-feat", path: codeDir + "/repo-feat",
    bytes: 2_000_000_000,
    facts: [
      "place": "sibling", "saved": "merged", "changes": "none", "stale": "older",
      "inUse": "no", "thread": "none",
    ])
  var memory = AutopilotMemory()
  equal(AutopilotPolicy.decide(item1, memory: memory).status, .unsure, "pool slot never starter-burns")
  equal(AutopilotPolicy.decide(item2, memory: memory).status, .unsure, "clustered slot never starter-burns")
  equal(AutopilotPolicy.decide(siblingOnly, memory: memory).status, .unsure, "sibling never starter-burns")
  checkFalse(AutopilotPolicy.aiEligible(item1), "pool slot is not AI-eligible")
  checkFalse(AutopilotPolicy.aiEligible(siblingOnly), "sibling copy is not AI-eligible")
  check(itemLocked.protectedReason != nil, "locked slot is mechanically protected")

  // Saying Yes to `.claude/worktrees` creates a lesson that NEVER generalizes onto pool slots!
  let claudeQ = AutopilotPolicy.proposeQuestions([itemClaude], memory: memory, now: now)
  equal(claudeQ.count, 1, "one question for claude worktree")
  let taught = AutopilotPolicy.lessons(
    for: claudeQ[0], verdict: .burn, created: now, earlier: [])
  for rule in taught { AutopilotPolicy.learn(rule, into: &memory.rules) }
  equal(
    AutopilotPolicy.decide(itemClaude, memory: memory).status, .burn,
    "learned lesson burns matching claude worktree")
  equal(
    AutopilotPolicy.decide(item1, memory: memory).status, .unsure,
    "non-pool Yes lesson NEVER generalizes onto pool slot magic1")
  equal(
    AutopilotPolicy.decide(item2, memory: memory).status, .unsure,
    "non-pool Yes lesson NEVER generalizes onto pool slot magic2")

  // ---------------------------------------------------------------------------
  // 2. Complete `git worktree lock` & pool protection for inner `node_modules`
  // ---------------------------------------------------------------------------
  for wt in [lockedSlot, slot1] {
    let nm = wt + "/node_modules"
    try fm.createDirectory(atPath: nm + "/pkg", withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: URL(fileURLWithPath: nm + "/.package-lock.json"))
    try Data("{\"name\":\"pkg\"}".utf8).write(to: URL(fileURLWithPath: nm + "/pkg/package.json"))
    try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: nm)
  }
  let diskItems = AutopilotDisk.items(
    worktrees: records, home: canonRoot, caches: false, mains: true, now: now,
    sizer: { _ in 500_000_000 }, protected: ProtectedLocations(access: fixtureAccess()))
  guard let lockedNM = diskItems.first(where: { $0.path == lockedSlot + "/node_modules" }),
    let poolNM = diskItems.first(where: { $0.path == slot1 + "/node_modules" })
  else {
    return failTest("expected node_modules items inside lockedSlot and slot1")
  }
  check(lockedNM.protectedReason != nil, "node_modules inside locked worktree is protected")
  equal(lockedNM.facts["home"], "repo", "locked worktree never classified as stale-worktree")
  equal(poolNM.facts["home"], "repo", "pool slot never classified as stale-worktree")
  equal(
    AutopilotPolicy.decide(lockedNM, memory: AutopilotMemory()).status, .protected,
    "starter-rebuildable-junk cannot touch locked worktree node_modules")
  equal(
    AutopilotPolicy.decide(poolNM, memory: AutopilotMemory()).status, .unsure,
    "starter-rebuildable-junk cannot strip pool slot node_modules")

  // Even a direct reclaim call with starter or AI authority refuses inside a locked worktree.
  let refusedLockedNM = AutopilotDisk.reclaim(
    lockedNM, authority: "starter:starter-rebuildable-junk", home: canonRoot,
    inUse: { _ in 0 }, protected: ProtectedLocations(access: fixtureAccess()),
    root: root.appendingPathComponent("st-lock"))
  equal(refusedLockedNM.outcome, "refused", "live locked-worktree rail refuses node_modules delete")
  check(fm.fileExists(atPath: lockedSlot + "/node_modules"), "locked node_modules survived")

  // ---------------------------------------------------------------------------
  // 3. Strict `$TMPDIR/claude-<uid>` scratch matching (`claude-federation/` stays immune)
  // ---------------------------------------------------------------------------
  let tempDir = canonRoot + "/tmp"
  let customClaude = tempDir + "/claude-federation"
  let realClaude = tempDir + "/claude-501/proj/tasks/old-task"
  try fm.createDirectory(atPath: customClaude, withIntermediateDirectories: true)
  try fm.createDirectory(atPath: realClaude, withIntermediateDirectories: true)
  try Data("federation".utf8).write(to: URL(fileURLWithPath: customClaude + "/state.json"))
  try Data("log".utf8).write(to: URL(fileURLWithPath: realClaude + "/out.log"))
  let fourDaysAgo = now.addingTimeInterval(-4 * 86_400)
  for p in [
    customClaude + "/state.json", customClaude, realClaude + "/out.log", realClaude,
    tempDir + "/claude-501/proj/tasks", tempDir + "/claude-501/proj", tempDir + "/claude-501",
  ] {
    try fm.setAttributes([.modificationDate: fourDaysAgo], ofItemAtPath: p)
  }
  let scratchFound = AutopilotAgentScratch.items(
    home: canonRoot, temp: tempDir, now: now, minimumBytes: 100, sizer: { _ in 200_000_000 }).items
  checkFalse(
    scratchFound.contains { $0.path == customClaude },
    "$TMPDIR/claude-federation/ must never be discovered as Claude scratch")
  check(
    scratchFound.contains { $0.path == tempDir + "/claude-501" },
    "$TMPDIR/claude-501 is still discovered")
  let bogusItem = AutopilotItem(
    id: "disk:custom-claude", kind: .disk, name: "claude-federation", path: customClaude,
    bytes: 200_000_000, facts: ["folder": "agent-temp", "home": "temp", "stale": "day"])
  let refusedCustom = AutopilotAgentScratch.reclaim(
    bogusItem, authority: "starter:starter-agent-scratch", home: canonRoot, temp: tempDir, now: now,
    inUse: { _ in 0 })
  equal(refusedCustom.outcome, "refused", "reclaim refuses non-UID claude-federation folder")
  check(fm.fileExists(atPath: customClaude + "/state.json"), "claude-federation untouched")

  // ---------------------------------------------------------------------------
  // 4. Configurable backup retention (default 7d, 1d/3d/14d pruning, Off with warning)
  // ---------------------------------------------------------------------------
  let stateDir = URL(fileURLWithPath: canonRoot, isDirectory: true)
    .appendingPathComponent("state-backups", isDirectory: true)
  let store = try AutopilotStore(root: stateDir)
  let initialSweep = try store.sweep()
  equal(
    initialSweep.effectiveBackupRetentionDays, 7,
    "fresh install defaults backup retention to 7 days")
  check(initialSweep.backupsEnabled, "backups enabled by default")

  // Seed two encrypted recovery archives (one 4 days old, one 10 days old) and verify 7d vs 3d pruning.
  let recBase = stateDir.appendingPathComponent("private-recovery", isDirectory: true)
  try fm.createDirectory(at: recBase, withIntermediateDirectories: true)
  let headSHA = try WorktreeGit.line(mainRepo, ["rev-parse", "HEAD"])
  func seedBackup(daysAgo: Double) throws -> (id: String, dir: URL, receipt: AutopilotReceipt) {
    let id = UUID().uuidString
    let dir = recBase.appendingPathComponent(id, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = now.addingTimeInterval(-daysAgo * 86_400)
    let ref = "refs/burnzombies/retired/" + id.lowercased()
    try git(mainRepo, ["update-ref", ref, headSHA])
    var restore = AutopilotRestore(
      repository: commonGit, path: "/tmp/wt-\(id)", ref: ref, head: headSHA, branch: "feat",
      snapshot: true)
    let refJSON: [String: Any] = [
      "directory": dir.path, "id": id, "source": "/tmp/wt-\(id)", "digest": "d", "allocated": 1024,
    ]
    restore.recovery = try JSONDecoder().decode(
      PrivateRecovery.Reference.self, from: JSONSerialization.data(withJSONObject: refJSON))
    try JSONEncoder().encode(restore).write(to: dir.appendingPathComponent("restore.json"))
    try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: dir.path)
    let receipt = AutopilotReceipt(
      itemID: "worktree:\(id)", kind: .worktree, name: "wt", authority: "rule:test",
      outcome: "burned", detail: "Retired.", bytes: 1000, date: stamp, restore: restore)
    return (id, dir, receipt)
  }
  let fourDay = try seedBackup(daysAgo: 4)
  let tenDay = try seedBackup(daysAgo: 10)
  try store.updateReceipts { $0.append(contentsOf: [fourDay.receipt, tenDay.receipt]) }
  try store.refreshImpact(forcePrune: true, now: now)
  check(fm.fileExists(atPath: fourDay.dir.path), "4-day backup kept under 7-day default")
  checkFalse(fm.fileExists(atPath: tenDay.dir.path), "10-day backup pruned under 7-day default")

  // Lower retention to 3 days -> 4-day backup prunes immediately!
  try store.updateSweep { $0.backupRetentionDays = 3 }
  try store.refreshImpact(forcePrune: true, now: now)
  checkFalse(fm.fileExists(atPath: fourDay.dir.path), "4-day backup pruned when retention lowered to 3d")

  // Disabled backups mode (`0`): retire deletes permanently with restore == nil and no safety ref.
  let disposable = codeDir + "/disposable-nobackup"
  try git(mainRepo, ["worktree", "add", "-b", "disp-nobackup", disposable, "main"])
  let dispItem = AutopilotItem(
    id: "worktree:disp-nb", kind: .worktree, name: "disposable-nobackup", path: disposable,
    bytes: 500_000_000,
    facts: [
      "place": "agent", "saved": "merged", "changes": "none", "stale": "older",
      "inUse": "no", "thread": "none",
    ])
  let refsBefore = String(
    decoding: try WorktreeGit.run(mainRepo, ["for-each-ref", "refs/burnzombies/retired"]),
    as: UTF8.self)
  let noBackupReceipt = AutopilotWorktrees.retire(
    dispItem, authority: "operator", root: root.appendingPathComponent("nb-scratch"),
    inUse: { _ in 0 }, protected: ProtectedLocations(access: fixtureAccess()), backupsEnabled: false)
  equal(noBackupReceipt.outcome, "burned", noBackupReceipt.detail)
  isNil(noBackupReceipt.restore)
  check(noBackupReceipt.detail.contains("backups disabled"), noBackupReceipt.detail)
  checkFalse(fm.fileExists(atPath: disposable), "worktree removed cleanly when backups disabled")
  let refsAfter = String(
    decoding: try WorktreeGit.run(mainRepo, ["for-each-ref", "refs/burnzombies/retired"]),
    as: UTF8.self)
  equal(refsAfter, refsBefore, "no retired git ref created when backups disabled")

  // Question cards and consequence text are completely honest when backups are disabled.
  let offCard = AutopilotPolicy.card(claudeQ[0], backupsEnabled: false)
  check(offCard.note.contains("Backups are off"), offCard.note)
  check(offCard.cost?.contains("use at your own risk") == true, offCard.cost ?? "nil")
  check(
    AutopilotPolicy.consequence(itemClaude, backupsEnabled: false).contains("use at your own risk"))

  // ---------------------------------------------------------------------------
  // 5. AI sweep usage attribution markers & failover default-on + opt-out
  // ---------------------------------------------------------------------------
  var cfg = MachineReviewConfiguration(
    harness: "claude", executable: "/usr/bin/true", launcher: "/usr/bin/true",
    server: "/usr/bin/true")
  check(cfg.effectiveAllowFailover, "cross-harness failover defaults to on")
  cfg.allowFailover = false
  checkFalse(cfg.effectiveAllowFailover, "cross-harness failover can be opted out")

  let sweepDir = root.appendingPathComponent("sweep-args", isDirectory: true)
  try fm.createDirectory(at: sweepDir, withIntermediateDirectories: true)
  let claudeArgs = try AutopilotHarness.arguments(cfg, directory: sweepDir, root: stateDir)
  check(claudeArgs.contains("--append-system-prompt"), "Claude sweep passes --append-system-prompt")
  if let idx = claudeArgs.firstIndex(of: "--append-system-prompt"), idx + 1 < claudeArgs.count {
    check(
      claudeArgs[idx + 1].contains("caller=burnzombies")
        && claudeArgs[idx + 1].contains("kind=autopilot-sweep"),
      "attribution tag identifies BurnZombies sweep: \(claudeArgs[idx + 1])")
  }
  if let sIdx = claudeArgs.firstIndex(of: "--settings"), sIdx + 1 < claudeArgs.count {
    let settingsJSON = claudeArgs[sIdx + 1]
    check(settingsJSON.contains("\"BURNZOMBIES_SWEEP\":\"1\""), settingsJSON)
    check(settingsJSON.contains("\"BURNZOMBIES_CALLER\":\"burnzombies\""), settingsJSON)
    check(settingsJSON.contains("\"BURNZOMBIES_RUN_KIND\":\"autopilot-sweep\""), settingsJSON)
  }
  let deepArgs = try AutopilotHarness.arguments(
    cfg, directory: sweepDir, root: stateDir, options: HuntOptions(deep: true, limitUSD: 5))
  if let idx = deepArgs.firstIndex(of: "--append-system-prompt"), idx + 1 < deepArgs.count {
    check(deepArgs[idx + 1].contains("kind=deep-hunt"), deepArgs[idx + 1])
  }

  let codexCfg = MachineReviewConfiguration(
    harness: "codex", executable: "/usr/bin/true", launcher: "/usr/bin/true",
    server: "/usr/bin/true")
  let codexArgs = try AutopilotHarness.arguments(codexCfg, directory: sweepDir, root: stateDir)
  check(
    codexArgs.contains { $0.contains("BURNZOMBIES_SWEEP=\"1\"") },
    "Codex sweep includes BURNZOMBIES_SWEEP attribution env")
  let codexInstructions = try String(
    contentsOf: sweepDir.appendingPathComponent("autopilot-instructions.md"), encoding: .utf8)
  check(
    codexInstructions.hasPrefix("[burnzombies:caller=burnzombies kind=autopilot-sweep"),
    "Codex instructions carry deterministic attribution tag")
}
