import BurnCore
import CryptoKit
import Darwin
import Foundation

private final class SecurityBurns: @unchecked Sendable {
  let lock = NSLock()
  var count = 0
  func record() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

func securityBoundaryProof() async throws {
  let fm = FileManager.default
  let root = URL(fileURLWithPath: WorkspaceSafety.canonical(fm.temporaryDirectory.path))
    .appendingPathComponent("bz-security-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: root) }
  let key = SymmetricKey(data: Data(repeating: 0x6b, count: 32))
  let argv = ProcessCommandSummary.describe(
    [
      "node", "server.js", "--port", "5173", "--api-key=synthetic-credential", "positional-secret",
      "-e", "inline-private-code",
    ], executable: "/usr/local/bin/node")
  check(argv.contains("server.js") && argv.contains("--port 5173"), "useful task identity survives")
  checkFalse(
    argv.contains("synthetic-credential") || argv.contains("positional-secret")
      || argv.contains("inline-private-code"),
    "unknown arguments and inline code never cross the boundary")

  func git(_ path: String, _ args: [String]) throws -> String {
    String(decoding: try WorktreeGit.run(path, args), as: UTF8.self)
  }
  let project = root.appendingPathComponent("project").path
  try fm.createDirectory(atPath: project, withIntermediateDirectories: false)
  _ = try git(project, ["init", "--initial-branch=main"])
  let marker = root.appendingPathComponent("filter-executed").path
  _ = try git(project, ["config", "filter.proof.clean", "touch '" + marker + "'; cat"])
  _ = try git(project, ["config", "filter.proof.smudge", "touch '" + marker + "'; cat"])
  _ = try git(project, ["config", "filter.proof.required", "true"])
  try Data("*.txt filter=proof\n".utf8).write(to: URL(fileURLWithPath: project + "/.gitattributes"))
  try Data("source\n".utf8).write(to: URL(fileURLWithPath: project + "/source.txt"))
  _ = try git(project, ["status", "--porcelain"])
  _ = try git(project, ["add", "."])
  _ = try git(
    project,
    ["-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-qm", "fixture"])
  _ = try git(project, ["checkout-index", "--force", "--all"])
  checkFalse(
    fm.fileExists(atPath: marker), "clean/smudge filters never execute, including required drivers")
  let cleanStatus = try git(project, ["status", "--porcelain"])
  check(cleanStatus.isEmpty, "normal Git evidence is unchanged")
  let included = root.appendingPathComponent("included-config")
  try Data(("[filter \"included\"]\nclean = touch '" + marker + "'; cat\nrequired = true\n").utf8)
    .write(to: included)
  _ = try git(project, ["config", "include.path", included.path])
  try Data("*.txt filter=included\n".utf8).write(
    to: URL(fileURLWithPath: project + "/.gitattributes"))
  _ = try git(project, ["status", "--porcelain"])
  _ = try git(project, ["add", "."])
  checkFalse(fm.fileExists(atPath: marker), "included executable filters cannot bypass the runner")

  try Data(
    "{\"name\":\"useful-project\",\"scripts\":{\"build\":\"tsc\"},\"privateCredential\":\"synthetic-private-value\"}"
      .utf8
  )
  .write(to: URL(fileURLWithPath: project + "/package.json"))
  try Data("PRIVATE=synthetic\n".utf8).write(to: URL(fileURLWithPath: project + "/.env"))
  try fm.createSymbolicLink(atPath: project + "/outside", withDestinationPath: root.path)
  let item = AutopilotItem(
    id: "worktree:proof", kind: .worktree, name: "proof", path: project, facts: [:])
  let evidence = AutopilotEvidence.read(item, relativePath: "package.json")
  check(
    evidence["package.json"]?.contains("useful-project") == true,
    "producer evidence remains available")
  checkFalse(
    evidence["package.json"]?.contains("synthetic-private-value") == true,
    "unrelated JSON fields never cross the boundary")
  for path in [
    ".env", "../package.json", "/etc/passwd", "outside/package.json", "a/../../package.json",
    "package.json\0",
  ] {
    check(
      AutopilotEvidence.read(item, relativePath: path)["error"] != nil, "evidence refuses \(path)")
  }

  for arguments in [
    ["worker", "--credential", "synthetic-private-value.py"],
    ["node", "--credential", "synthetic-private-value.js", "server.js"],
  ] {
    let summary = ProcessCommandSummary.describe(
      arguments, executable: "/usr/local/bin/" + arguments[0])
    checkFalse(
      summary.contains("synthetic-private-value"), "script-shaped credential values stay private")
  }
  let upgrade = root.appendingPathComponent("legacy-state")
  let legacy = try Store(root: upgrade.appendingPathComponent("autopilot"))
  var kept = AutopilotMemory()
  kept.keptItems.insert("never-burn")
  try legacy.write(
    JSONEncoder().encode(kept), to: legacy.root.appendingPathComponent("memory.json"),
    limit: 8 << 20)
  try legacy.write(
    JSONEncoder().encode([AutopilotReceipt]()),
    to: legacy.root.appendingPathComponent("receipts.json"), limit: 8 << 20)
  let upgraded = try AutopilotStore(root: upgrade)
  do {
    _ = try upgraded.sweep()
    failTest("upgrade recreated missing enabled settings")
  } catch {}
  checkFalse(
    fm.fileExists(atPath: upgraded.directory.appendingPathComponent("sweep.json").path),
    "upgrade preserves missing permission state for repair")
  let upgradedMemory = try upgraded.memory()
  check(upgradedMemory.keptItems.contains("never-burn"), "upgrade keeps existing policy")

  // Tracked edits inside generated-looking folders must never be excluded. Clean committed
  // payloads stay in Git instead of consuming duplicate encrypted storage.
  let repo = root.appendingPathComponent("recovery-repo").path
  try fm.createDirectory(atPath: repo, withIntermediateDirectories: false)
  _ = try git(repo, ["init", "--initial-branch=main"])
  try fm.createDirectory(atPath: repo + "/node_modules/pkg", withIntermediateDirectories: true)
  try Data("{}".utf8).write(to: URL(fileURLWithPath: repo + "/node_modules/.package-lock.json"))
  try Data("{}".utf8).write(to: URL(fileURLWithPath: repo + "/node_modules/pkg/package.json"))
  try Data("original".utf8).write(to: URL(fileURLWithPath: repo + "/node_modules/pkg/local.js"))
  var payload = [UInt8](repeating: 0, count: 6 << 20)
  arc4random_buf(&payload, payload.count)
  try Data(payload).write(to: URL(fileURLWithPath: repo + "/saved.bin"))
  try Data("*.js filter=conditional\n".utf8).write(
    to: URL(fileURLWithPath: repo + "/.gitattributes"))
  _ = try git(repo, ["add", "."])
  _ = try git(
    repo,
    [
      "-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-qm",
      "recovery",
    ])
  let copy = root.appendingPathComponent("saved-copy").path
  _ = try git(repo, ["worktree", "add", "--detach", copy])
  try Data("unique tracked edit".utf8).write(
    to: URL(fileURLWithPath: copy + "/node_modules/pkg/local.js"))
  let copyItem = AutopilotItem(
    id: "worktree:security", kind: .worktree, name: "saved-copy", path: copy,
    bytes: 6 << 20, facts: ["saved": "merged", "changes": "small"])
  let retired = AutopilotWorktrees.retire(
    copyItem, authority: "operator", root: root.appendingPathComponent("recovery-state"),
    inUse: { _ in 0 }, recoveryKey: key)
  equal(retired.outcome, "burned", "tracked recovery: " + retired.detail)
  check(
    (retired.restore?.recovery?.allocated ?? .max) < 100_000,
    "unchanged committed data does not consume duplicate archive space")
  try AutopilotWorktrees.restore(retired, recoveryKey: key)
  equal(
    try String(contentsOfFile: copy + "/node_modules/pkg/local.js", encoding: .utf8),
    "unique tracked edit", "tracked cache-shaped edits restore")
  equal(
    try Data(contentsOf: URL(fileURLWithPath: copy + "/saved.bin")), Data(payload),
    "unchanged committed bytes restore exactly")

  // A destination-only include must not execute during a legacy receipt's checkout.
  let legacyPath = root.appendingPathComponent("legacy-restored").path
  let common = (try git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let conditional = root.appendingPathComponent("conditional-config")
  try Data(
    ("[filter \"conditional\"]\nsmudge = touch '" + marker + "'; cat\nclean = touch '" + marker
      + "'; cat\nrequired = true\n").utf8
  ).write(to: conditional)
  _ = try git(
    repo,
    ["config", "includeIf.gitdir:" + common + "/worktrees/legacy-restored/.path", conditional.path])
  let head = try git(repo, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
  let ref = "refs/burnzombies/retired/legacy-security"
  _ = try git(repo, ["update-ref", ref, head])
  let legacyReceipt = AutopilotReceipt(
    itemID: "worktree:legacy", kind: .worktree, name: "legacy", authority: "operator",
    outcome: "burned", detail: "Synthetic legacy receipt",
    restore: AutopilotRestore(
      repository: common, path: legacyPath, ref: ref, head: head, branch: nil, snapshot: false))
  try AutopilotWorktrees.restore(legacyReceipt, recoveryKey: key)
  checkFalse(
    fm.fileExists(atPath: marker), "destination-only filters do not execute during legacy recovery")
  equal(
    try String(contentsOfFile: legacyPath + "/node_modules/pkg/local.js", encoding: .utf8),
    "original", "legacy data still restores")

  let stateRoot = root.appendingPathComponent("state")
  let state = try AutopilotStore(root: stateRoot)
  let burns = SecurityBurns()
  let disk = AutopilotItem(
    id: "disk:policy", kind: .disk, name: "fixture", bytes: 200_000_000,
    facts: ["folder": "build-output", "home": "stale-worktree"])
  let engine = try Autopilot(
    root: stateRoot,
    sources: AutopilotSources(
      disk: { _ in [disk] },
      reclaimDisk: { item, authority in
        burns.record()
        return AutopilotReceipt(
          itemID: item.id, kind: item.kind, name: item.name, authority: authority,
          outcome: "burned", detail: "Synthetic executor only")
      }))
  var memory = AutopilotMemory()
  memory.keptItems.insert(disk.id)
  try state.save(memory: memory)
  _ = await engine.tick(burn: false)
  try Data("invalid settings".utf8).write(to: state.directory.appendingPathComponent("memory.json"))
  do {
    _ = try await engine.apply(.burnNow(itemID: disk.id))
    failTest("corrupt policy allowed an operator burn")
  } catch {}
  equal(burns.value, 0, "corrupt policy blocks every executor")
  try state.save(memory: AutopilotMemory())
  _ = try await engine.apply(.burnNow(itemID: disk.id))
  equal(burns.value, 1, "repair restores legitimate cleanup")
  try fm.removeItem(at: state.directory.appendingPathComponent("memory.json"))
  let reopened = try AutopilotStore(root: stateRoot)
  do {
    _ = try reopened.memory()
    failTest("missing policy silently created fresh permission")
  } catch {}
  checkFalse(
    fm.fileExists(atPath: state.directory.appendingPathComponent("memory.json").path),
    "missing policy stays preserved for repair")
  try state.save(memory: AutopilotMemory())
  try Data("invalid settings".utf8).write(to: state.directory.appendingPathComponent("sweep.json"))
  let sweep = await engine.sweepState()
  check(!sweep.enabled && sweep.lookOnly == true, "unreadable sweep reports a held state")

  let dist = project + "/dist"
  try fm.createDirectory(atPath: dist, withIntermediateDirectories: false)
  let unique = "unique synthetic work survives"
  try Data(unique.utf8).write(to: URL(fileURLWithPath: dist + "/notes.txt"))
  let candidate = AutopilotItem(
    id: "disk:dist", kind: .disk, name: "dist", path: dist,
    bytes: 200_000_000, facts: ["folder": "build-output"])
  let receipt = AutopilotDisk.reclaim(
    candidate, authority: "ai:0.90", home: root.path,
    inUse: { _ in 0 }, root: stateRoot, recoveryKey: key)
  equal(receipt.outcome, "burned", "ambiguous generated names remain cleanable: " + receipt.detail)
  check(receipt.restore?.recovery != nil, "unique contents have encrypted recovery")
  checkFalse(fm.fileExists(atPath: dist), "cleanup still removes its eligible target")
  try AutopilotWorktrees.restore(receipt, recoveryKey: key)
  equal(
    try String(contentsOfFile: dist + "/notes.txt", encoding: .utf8), unique,
    "unique data restores exactly")
  if let archive = receipt.restore?.recovery {
    let manifestURL = URL(fileURLWithPath: archive.directory + "/manifest.enc")
    let original = try Data(contentsOf: manifestURL)
    var damaged = original
    damaged[0] ^= 1
    try damaged.write(to: manifestURL)
    do {
      try PrivateRecovery.restore(
        archive, to: root.appendingPathComponent("tampered").path, key: key)
      failTest("tampered recovery was accepted")
    } catch {}
    try original.write(to: manifestURL)
    for file in try fm.contentsOfDirectory(atPath: archive.directory) where file.hasSuffix(".enc") {
      let bytes = try Data(contentsOf: URL(fileURLWithPath: archive.directory + "/" + file))
      checkFalse(
        bytes.range(of: Data(unique.utf8)) != nil, "archive bytes contain no plaintext source")
    }
  }
}
