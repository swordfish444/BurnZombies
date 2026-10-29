import BurnCore
import CBurn
import CryptoKit
import Darwin
import Foundation

func workspaceProof() async throws {
  let fm = FileManager.default
  let base = fm.temporaryDirectory.appendingPathComponent("bz-wt-" + UUID().uuidString).resolvingSymlinksInPath()
  try fm.createDirectory(at: base, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: base) }
  let repo = base.appendingPathComponent("repo"), root = base.appendingPathComponent("state")
  try fm.createDirectory(at: repo, withIntermediateDirectories: false)
  func git(_ path: String, _ args: [String]) throws -> String { try WorkspaceSafety.git(path, args) }
  _ = try git(repo.path, ["init", "--initial-branch=main"])
  _ = try git(repo.path, ["config", "user.name", "BurnZombies proof"])
  _ = try git(repo.path, ["config", "user.email", "proof@example.invalid"])
  // A real allocated 8 MiB tracked file gives the accounting test a measurable footprint.
  try Data((0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: repo.appendingPathComponent("payload"))
  try Data("secret.env\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
  _ = try git(repo.path, ["add", "."]); _ = try git(repo.path, ["commit", "-m", "fixture"])
  _ = try git(repo.path, ["update-ref", "refs/remotes/origin/main", "HEAD"])
  // Inject only the consumer-observation boundary for this private, test-owned fixture.
  // Real Git, storage, permissions, preview/actuation and recovery remain exercised.
  // The shipped app/CLI have no override switch and always use the strict native reader.
  let prefix = WorkspaceSafety.canonical(base.path) + "/"
  let monitor = try Monitor(root: root, workspaceVisibility: { path in
    guard path.hasPrefix(prefix) else { return -1 }
    let result = bz_path_in_use(path)
    return result == 1 ? 1 : 0
  }, accessCheck: fixtureAccess, discoveryWalker: fixtureWalker(), worktreeRecoveryKey: { SymmetricKey(data: Data(repeating: 42, count: 32)) }), service = AgentService(monitor: monitor)
  let store = try Store(root: root)
  func call(_ request: AgentRequest) async -> AgentReply {
    var r = request; r.callerPID = getpid(); return await service.call(r)
  }
  func create() async throws -> (WorkspaceClaim, String) {
    let response = await call(.init("workspace", label: "Completed fixture worktree",
      rationale: "This task needs an isolated disposable worktree to run its fixture operation.", action: "create",
      completionCondition: "Fixture checks finish, all output is preserved and no process uses the checkout.", workspacePath: repo.path))
    guard response.ok, let token = response.workToken, let id = response.workspaces.first?.id,
      let claim = try await monitor.workspaceClaims().first(where: { $0.id == id }) else { throw StoreError.message(response.message) }
    let responseJSON = try response.json(); checkFalse(responseJSON.contains("tokenHash"))
    return (claim, token)
  }
  func change(_ token: String, _ action: String) async -> AgentReply {
    await call(.init("workspace", rationale: "Fixture checks completed, outputs were preserved and all workspace consumers have finished.", action: action, workToken: token))
  }
  func preview(_ id: String) async -> AgentReply {
    await call(.init("workspace_preview", rationale: "Owner evidence matches completed fixture work with preserved commits and no remaining consumer.", workspaceID: id))
  }
  _ = try git(repo.path, ["config", "filter.fixture.smudge", "false"])
  do { _ = try await create(); failTest("repository checkout filter accepted") }
  catch { check(error.localizedDescription.contains("filters"), "unexpected filter refusal") }
  _ = try git(repo.path, ["config", "--unset-all", "filter.fixture.smudge"])
  let (claim, token) = try await create(), path = claim.identity.path
  let active = await preview(claim.id); checkFalse(active.ok, "active workspace accepted")
  let missing = await preview(UUID().uuidString); checkFalse(missing.ok, "unknown workspace accepted")
  throwsError(try WorkspaceSafety.identity(repo.path, root: root))
  let bad = await change(String(repeating: "x", count: 72), "release"); checkFalse(bad.ok, "forged owner token accepted")
  let transition1 = await change(token, "release"); check(transition1.ok, transition1.message)
  let status = await call(.init("status")); equal(status.workspaces.count, 1)
  let statusJSON = try status.json()
  checkFalse(statusJSON.contains(token), "read-only status exposed private owner capability")

  // Each destructive refusal operates on a real Git state and leaves the exact checkout intact.
  try Data("unsaved\n".utf8).write(to: URL(fileURLWithPath: path + "/payload"))
  let dirty = await preview(claim.id); checkFalse(dirty.ok, "dirty tracked file accepted")
  _ = try git(path, ["add", "payload"])
  let staged = await preview(claim.id); checkFalse(staged.ok, "staged work accepted")
  _ = try git(path, ["restore", "--staged", "--worktree", "payload"])
  for name in ["unsaved.txt", "secret.env"] {
    try Data("private fixture output".utf8).write(to: URL(fileURLWithPath: path + "/" + name))
    let blocked = await preview(claim.id); checkFalse(blocked.ok, "untracked/ignored file accepted: " + name)
    check(fm.fileExists(atPath: path + "/" + name))
    try fm.removeItem(atPath: path + "/" + name)
  }
  _ = try git(repo.path, ["worktree", "lock", path])
  let locked = await preview(claim.id); checkFalse(locked.ok, "locked checkout accepted")
  _ = try git(repo.path, ["worktree", "unlock", path])
  _ = try git(path, ["update-index", "--assume-unchanged", "payload"])
  let assumed = await preview(claim.id); checkFalse(assumed.ok, "assume-unchanged index accepted")
  _ = try git(path, ["update-index", "--no-assume-unchanged", "payload"])
  try fm.createSymbolicLink(atPath: path + "/link", withDestinationPath: repo.path)
  let link = await preview(claim.id); checkFalse(link.ok, "symlink accepted")
  try fm.removeItem(atPath: path + "/link")
  let held = open(path + "/payload", O_RDONLY)
  check(held >= 0)
  equal(bz_path_in_use(path), 1, "open file consumer not found")
  let heldPreview = await preview(claim.id); checkFalse(heldPreview.ok, "open file consumer allowed removal")
  close(held)
  // Extra commits are protected even after a new release until remote reachability is established.
  _ = try git(path, ["commit", "--allow-empty", "-m", "unpushed fixture work"])
  let changedHead = await preview(claim.id); checkFalse(changedHead.ok, "HEAD changed after release")
  let transition2 = await change(token, "release"); check(transition2.ok, transition2.message)
  let unpushed = await preview(claim.id); checkFalse(unpushed.ok, "unpushed commit accepted")
  _ = try git(path, ["update-ref", "refs/remotes/origin/fixture", "HEAD"])
  if let released = try await monitor.workspaceClaims().first(where: { $0.id == claim.id }) {
    throwsError(try WorkspaceSafety.check(released, root: root, visibility: { _ in -1 }))
    if bz_path_in_use(path) == -1 {
      throwsError(try WorkspaceSafety.check(released, root: root))
      print("PASS production native reader preserves workspace on this Mac's incomplete handle visibility; positive actuation below uses isolated-fixture consumer simulation")
    }
  }
  let ready = await preview(claim.id)
  guard let previewToken = ready.previewToken else { throw StoreError.message("Ready worktree preview: " + ready.message) }
  let transition3 = await change(token, "retain"); check(transition3.ok, transition3.message)
  let retained = await call(.init("workspace_clean", previewToken: previewToken)); checkFalse(retained.ok, "retain after preview did not block deletion")
  check(fm.fileExists(atPath: path))
  let transition4 = await change(token, "release"); check(transition4.ok, transition4.message)
  let second = await preview(claim.id)
  guard let racedToken = second.previewToken else { throw StoreError.message(second.message) }
  try Data("new ignored output".utf8).write(to: URL(fileURLWithPath: path + "/secret.env"))
  let lateFile = await call(.init("workspace_clean", previewToken: racedToken))
  checkFalse(lateFile.ok, "ignored file appearing after preview was deleted")
  check(fm.fileExists(atPath: path + "/secret.env"))
  try fm.removeItem(atPath: path + "/secret.env")
  let renewed = await change(token, "release"); check(renewed.ok, renewed.message)
  let third = await preview(claim.id)
  guard let cleanupToken = third.previewToken else { throw StoreError.message(third.message) }
  // Different authenticated peer cannot spend the owner's preview.
  let foreign = await service.call(.init("workspace_clean", previewToken: cleanupToken)); checkFalse(foreign.ok)
  let cleaned = await call(.init("workspace_clean", previewToken: cleanupToken))
  check(cleaned.ok, cleaned.message); checkFalse(fm.fileExists(atPath: path))
  equal(cleaned.worktreesCleaned, 1); equal(cleaned.verifiedHelpers, 0)
  let repeated = await call(.init("workspace_clean", previewToken: cleanupToken)); checkFalse(repeated.ok, "preview reused")
  let saved = (await monitor.snapshot()).catalog
  guard let receipt = saved.workspaceReceipts?.last else { throw StoreError.message("Missing verified worktree receipt") }
  equal(receipt.outcome, "verified"); check(WorkspaceSafety.removed(receipt))
  equal(saved.lifetimeDiskReclaimedBytes, receipt.diskReclaimedBytes)
  check(receipt.diskReclaimedBytes <= 9 * 1024 * 1024, "disk attribution exceeded deleted allocation")
  // Restore the retained commit to another fixture checkout without requiring the remote.
  let restore = base.appendingPathComponent("restored").path
  _ = try git(repo.path, ["worktree", "add", "--detach", restore, receipt.recoveryRef])
  equal(try Data(contentsOf: URL(fileURLWithPath: restore + "/payload")).count, 8 * 1024 * 1024)
  let numbers = ImpactNumbers.make(catalog: saved, period: .today)
  equal(numbers.worktrees, 1); equal(numbers.disk, receipt.diskReclaimedBytes)
  check(numbers.benefit != .firstBurn && numbers.benefit != .ready)
  var old = saved
  old.workspaceReceipts?[0].verifiedAt = Calendar.current.date(byAdding: .day, value: -3, to: Date())
  equal(ImpactNumbers.make(catalog: old, period: .today).worktrees, 0)
  equal(ImpactNumbers.make(catalog: old, period: .week).worktrees, 1)
  equal(ImpactNumbers.make(catalog: old, period: .all).worktrees, 1)
  old.workspaceReceipts?[0].verifiedAt = Date().addingTimeInterval(86400)
  equal(ImpactNumbers.make(catalog: old, period: .week).worktrees, 0)
  // Interrupted preparation never gets retroactive cleanup credit, even if the path is now absent.
  let interruptedRoot = base.appendingPathComponent("interrupted-state")
  let interruptedStore = try Store(root: interruptedRoot)
  var interrupted = Catalog(), pending = receipt
  pending.outcome = "prepared"; pending.verifiedAt = nil; pending.diskReclaimedBytes = 0
  interrupted.workspaceReceipts = [pending]
  try interruptedStore.save(interrupted)
  let recovered = try Monitor(root: interruptedRoot, accessCheck: fixtureAccess, discoveryWalker: fixtureWalker(), worktreeRecoveryKey: { SymmetricKey(data: Data(repeating: 42, count: 32)) })
  let recoveredState = await recovered.refresh()
  equal(recoveredState.catalog.workspaceReceipts?.first?.outcome, "unverified")
  equal(ImpactNumbers.make(catalog: recoveredState.catalog, period: .all).worktrees, 0)
  let legacy = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(Catalog()))
  equal(ImpactNumbers.make(catalog: legacy, period: .all).worktrees, 0)
  print("PASS real Git fixture lifecycle with simulated complete consumer visibility, refusal controls, retained preview, one-use receipt, commit restoration and period accounting; disk bytes: \(receipt.diskReclaimedBytes)")
}
