import BurnCore
import CSQLite
import CryptoKit
import Foundation

/// Real Git, archive, encryption and restore with explicitly isolated access
/// and consumer fixtures. Installed native visibility is a separate acceptance.
func approvalIntegrationProof() async throws {
  let fm = FileManager.default
  let base = URL(fileURLWithPath: "/private/tmp/bz-approval-" + UUID().uuidString)
  try fm.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: base) }
  let repo = base.appendingPathComponent("project")
  let tree = base.appendingPathComponent("completed")
  let active = base.appendingPathComponent("active")
  let root = base.appendingPathComponent("state")
  try fm.createDirectory(at: repo, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repo.path, ["init", "--initial-branch=main"])
  try Data("source survives\n".utf8).write(to: repo.appendingPathComponent("source"))
  try Data("build/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
  _ = try WorktreeGit.run(repo.path, ["add", "."])
  _ = try WorktreeGit.run(
    repo.path,
    ["-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m", "fixture"])
  for path in [tree, active] {
    _ = try WorktreeGit.run(repo.path, ["worktree", "add", "--detach", path.path])
  }
  try fm.createDirectory(
    at: tree.appendingPathComponent("build"), withIntermediateDirectories: true)
  let preserved = Data("ignored fixture evidence must survive\n".utf8)
  try preserved.write(to: tree.appendingPathComponent("build/evidence"))
  let mainStatus = try WorktreeGit.run(repo.path, ["status", "--porcelain"])
  let key = SymmetricKey(data: Data(repeating: 61, count: 32))
  let monitor = try Monitor(
    legacyAuthority: false, discoveryHome: nil, root: root,
    workspaceVisibility: { $0 == active.path ? 1 : 0 }, accessCheck: fixtureAccess,
    worktreeRecoveryKey: { key })
  _ = try await monitor.worktreeRequest(.init("add_root", path: base.path), caller: "fixture")
  let scan = try await monitor.worktreeRequest(.init("scan"), caller: "fixture")
  let row = scan.records.first { $0.path == tree.path }!
  checkFalse(row.managed, "Discovery must not silently adopt a worktree")
  var provenance = FixtureProvenance()
  provenance.resources.insert("worktree:" + row.id)
  try provenance.save(root: root)
  let state = await monitor.snapshot()
  let finding = state.inbox.proposals.first { $0.resources == ["worktree:" + row.id] }!
  check(finding.ready, "Unmanaged dirty checkout needs an explicit usable review path")
  check(finding.fixture, "Exact provenance must propagate into proposal")
  checkFalse(
    state.inbox.proposals.first { $0.path == active.path }!.ready,
    "In-use control must not be approvable")
  do {
    _ = try await monitor.executeApprovedFinding(finding.id, revision: finding.revision)
    failTest("Unapproved adoption executed")
  } catch {}
  try await monitor.decideFinding(finding.id, revision: finding.revision, decision: "approve")
  // Fail the ledger's post-adoption presentation after native confirmation was
  // persisted. The error must withdraw that temporary native permission.
  var database: OpaquePointer?
  equal(sqlite3_open(root.appendingPathComponent("intent.sqlite").path, &database), SQLITE_OK)
  defer { sqlite3_close(database) }
  equal(
    sqlite3_exec(
      database,
      "CREATE TRIGGER fail_proposal BEFORE INSERT ON documents WHEN NEW.kind = 'proposal' BEGIN SELECT RAISE(ABORT, 'injected ledger outage'); END",
      nil, nil, nil), SQLITE_OK)
  do {
    _ = try await monitor.executeApprovedFinding(finding.id, revision: finding.revision)
    failTest("Injected ledger outage was ignored")
  } catch {}
  let nativeStore = try WorktreeStore(root: root)
  let failedAdoption = try nativeStore.value(WorktreeRecord.self, kind: "record", id: row.id)!
  check(failedAdoption.managed, "Explicit adoption should survive")
  isNil(failedAdoption.confirmedRevision)
  equal(sqlite3_exec(database, "DROP TRIGGER fail_proposal", nil, nil, nil), SQLITE_OK)
  do {
    _ = try await monitor.worktreeRequest(
      .init("preview_dirty", id: row.id, revision: failedAdoption.revision), caller: "fixture")
    failTest("Failed adoption left a native confirmation")
  } catch {}
  let refreshed = await monitor.snapshot().inbox.proposals.first { $0.id == finding.id }!
  try await monitor.decideFinding(refreshed.id, revision: refreshed.revision, decision: "approve")
  _ = try await monitor.executeApprovedFinding(refreshed.id, revision: refreshed.revision)
  let finished = await monitor.snapshot()
  let operation = finished.worktrees!.operations.first { $0.worktreeID == row.id }!
  equal(operation.phase, "completed")
  checkFalse(fm.fileExists(atPath: tree.path), "Retired checkout still exists")
  let registered = try WorktreeGit.line(repo.path, ["worktree", "list", "--porcelain"])
  checkFalse(registered.contains("worktree " + tree.path), "Retired checkout remains registered")
  check(registered.contains("worktree " + active.path), "Active control registration changed")
  equal(
    try WorktreeGit.run(repo.path, ["status", "--porcelain"]), mainStatus, "Main checkout changed")
  equal(operation.fixture, true)
  equal(finished.inbox.operations.first { $0.id == operation.id }?.outcome, "verified")
  equal(
    finished.catalog.lifetimeWorktreesCleaned ?? 0, 0,
    "Fixture retirement must not inflate real impact")
  equal(finished.catalog.lifetimeDiskReclaimedBytes ?? 0, 0)
  check(fm.fileExists(atPath: active.appendingPathComponent("source").path))
  do {
    _ = try await monitor.executeApprovedFinding(finding.id, revision: finding.revision)
    failTest("Approval replay executed")
  } catch {}
  let restored = base.appendingPathComponent("restored")
  _ = try await monitor.worktreeRequest(
    .init("restore", id: operation.id, path: restored.path), caller: "fixture")
  equal(try Data(contentsOf: restored.appendingPathComponent("build/evidence")), preserved)
  equal(
    try Data(contentsOf: restored.appendingPathComponent("source")), Data("source survives\n".utf8))
  await monitor.shutdownWorktrees()
  print(
    "PASS native inbox approval of unmanaged dirty checkout, active control, exact fixture provenance, verified ledger projection, zero fixture impact, replay refusal and encrypted ignored-file restoration"
  )
}
