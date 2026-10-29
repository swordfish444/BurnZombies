import BurnCore
import CryptoKit
import Darwin
import Foundation

func worktreeLifecycleProof() async throws {
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent("bz-lifecycle-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = URL(fileURLWithPath: WorkspaceSafety.canonical(temporary.path))
  defer { try? fm.removeItem(at: base) }
  let repo = base.appendingPathComponent("project")
  let clean = base.appendingPathComponent("clean")
  let dirty = base.appendingPathComponent("dirty")
  try fm.createDirectory(at: repo, withIntermediateDirectories: false)
  func git(_ path: String, _ args: [String]) throws -> String { try WorktreeGit.line(path, args) }
  _ = try git(repo.path, ["init", "--initial-branch=main"])
  _ = try git(repo.path, ["config", "user.name", "Synthetic proof"])
  _ = try git(repo.path, ["config", "user.email", "proof@example.invalid"])
  try Data("initial\n".utf8).write(to: repo.appendingPathComponent("source"))
  try Data(".env\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
  _ = try git(repo.path, ["add", "."])
  _ = try git(repo.path, ["commit", "-m", "fixture"])
  _ = try git(repo.path, ["worktree", "add", "--detach", clean.path])
  _ = try git(repo.path, ["worktree", "add", "--detach", dirty.path])
  let root = base.appendingPathComponent("state")
  let key = SymmetricKey(data: Data(repeating: 37, count: 32))
  let service = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: { fixtureAccess() }, recoveryKey: { key })
  func call(_ q: WorktreeRequest) async throws -> WorktreeReply {
    try await service.request(q, caller: "fixture")
  }
  _ = try await call(.init("add_root", path: base.path))
  let scan = try await call(.init("scan"))
  equal(scan.records.count, 3)
  let cleanRow = scan.records.first { $0.path == clean.path }!
  let again = try await call(.init("scan"))
  equal(
    again.records.first { $0.id == cleanRow.id }?.revision, cleanRow.revision,
    "stable evidence churned")
  equal(scan.records.first { $0.path == repo.path }?.state, "Inspection blocked")
  equal(cleanRow.state, "Needs review")
  check(cleanRow.blockers.isEmpty, cleanRow.blockers.joined())
  check(cleanRow.gaps.isEmpty, cleanRow.gaps.joined())
  do {
    _ = try await call(.init("preview", id: cleanRow.id, revision: cleanRow.revision))
    failTest("unmanaged preview accepted")
  } catch {}
  _ = try await call(.init("adopt", id: cleanRow.id, revision: cleanRow.revision))
  let first = try await call(
    .init(
      "claim", id: cleanRow.id, revision: cleanRow.revision,
      evidence: "Fixture owner uses this checkout for a bounded task.",
      condition: "The fixture task and consumers complete."))
  let second = try await call(
    .init(
      "claim", id: cleanRow.id, revision: cleanRow.revision,
      evidence: "A second fixture consumer retains this checkout.",
      condition: "The second fixture consumer finishes."))
  _ = try await call(
    .init(
      "release", token: first.token,
      evidence: "The first fixture task finished and saved all output."))
  do {
    _ = try await call(.init("preview", id: cleanRow.id, revision: cleanRow.revision))
    failTest("second active owner ignored")
  } catch {}
  _ = try await call(
    .init(
      "release", token: second.token,
      evidence: "The second fixture task finished and saved all output."))
  let p = try await call(.init("preview", id: cleanRow.id, revision: cleanRow.revision))
  _ = try await call(
    .init(
      "retain", token: first.token,
      evidence: "The first fixture owner resumed work before retirement."))
  do {
    _ = try await call(.init("retire", token: p.token))
    failTest("retained preview executed")
  } catch {}
  _ = try await call(
    .init(
      "release", token: first.token,
      evidence: "The resumed fixture work finished with all output saved."))
  let preview = try await call(.init("preview", id: cleanRow.id, revision: cleanRow.revision))
  do {
    _ = try await service.request(.init("retire", token: preview.token), caller: "other")
    failTest("foreign caller accepted")
  } catch {}
  let preview2 = try await call(.init("preview", id: cleanRow.id, revision: cleanRow.revision))
  let retired = try await call(.init("retire", token: preview2.token))
  equal(retired.operations.first?.phase, "completed")
  checkFalse(fm.fileExists(atPath: clean.path))
  do {
    _ = try await call(.init("retire", token: preview2.token))
    failTest("replayed removal accepted")
  } catch {}
  print(
    "PASS clean retirement with independent encrypted recovery, multiple owners and preview revocation"
  )
  try Data("staged\n".utf8).write(to: dirty.appendingPathComponent("source"))
  _ = try git(dirty.path, ["add", "source"])
  try Data("unstaged\n".utf8).write(to: dirty.appendingPathComponent("source"))
  try Data([0, 255, 1, 23]).write(to: dirty.appendingPathComponent("new binary"))
  try Data("synthetic-private-data".utf8).write(to: dirty.appendingPathComponent(".env"))
  let updated = try await call(.init("scan"))
  let d = updated.records.first { $0.path == dirty.path }!
  check(d.changes > 0)
  equal(d.ignored, 1)
  let localDiff = try await call(.init("diff", id: d.id, revision: d.revision))
  check(localDiff.detail.contains("staged") && localDiff.detail.contains("unstaged"))
  checkFalse(
    localDiff.detail.contains("synthetic-private-data"),
    "Local diff traversed ignored-file contents")
  do {
    _ = try await service.request(
      .init("diff", id: d.id, revision: d.revision), caller: "model", management: false)
    failTest("Local content exposed through model endpoint")
  } catch {}
  _ = try await call(.init("adopt", id: d.id, revision: d.revision))
  _ = try await call(
    .init(
      "confirm", id: d.id, revision: d.revision,
      evidence: "This synthetic task is complete and its snapshot may replace the checkout."))
  do {
    _ = try await call(.init("preview", id: d.id, revision: d.revision))
    failTest("dirty checkout entered clean retirement")
  } catch {}
  let rescued = try await call(.init("rescue", id: d.id, revision: d.revision))
  equal(rescued.operations.first?.phase, "rescued")
  check(fm.fileExists(atPath: dirty.path))
  // Restart a journal after preservation but before removal. Never replay it.
  let journal = try WorktreeStore(root: root)
  var interrupted = rescued.operations.first!
  interrupted.phase = "removing"
  try journal.put(interrupted, kind: "operation", id: interrupted.id)
  let restarted = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess, recoveryKey: { key })
  equal(
    try await restarted.snapshot().operations.first { $0.id == interrupted.id }?.phase, "uncertain")
  do {
    _ = try await call(.init("preview_dirty", id: d.id, revision: d.revision))
    failTest("uncertain operation replayed")
  } catch {}
  let reconciled = try await restarted.request(
    .init("reconcile", id: interrupted.id, evidence: "RECONCILE RECOVERY"), caller: "fixture")
  equal(reconciled.operations.first?.phase, "failed")
  equal(reconciled.operations.first?.diskCredit, 0)
  check(fm.fileExists(atPath: dirty.path))
  let missingKey = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess,
    recoveryKey: { throw StoreError.message("Synthetic missing Keychain key") })
  do {
    _ = try await missingKey.request(
      .init("rescue", id: d.id, revision: d.revision), caller: "fixture")
    failTest("missing key was ignored")
  } catch {}
  check(fm.fileExists(atPath: dirty.path))
  let dirtyPreview = try await call(.init("preview_dirty", id: d.id, revision: d.revision))
  let dirtyRetired = try await call(.init("retire_dirty", token: dirtyPreview.token))
  equal(dirtyRetired.operations.first?.phase, "completed")
  checkFalse(fm.fileExists(atPath: dirty.path))
  // Quarantine is a reversible Git move, with no disk credit and explicit grace.
  let quarantineSource = base.appendingPathComponent("quarantine-source")
  _ = try git(repo.path, ["worktree", "add", "--detach", quarantineSource.path])
  try Data("quarantine-local".utf8).write(to: quarantineSource.appendingPathComponent(".env"))
  let quarantineScan = try await call(.init("scan"))
  let qr = quarantineScan.records.first { $0.path == quarantineSource.path }!
  _ = try await call(.init("adopt", id: qr.id, revision: qr.revision))
  _ = try await call(
    .init(
      "confirm", id: qr.id, revision: qr.revision,
      evidence: "The synthetic quarantine task is complete and may be archived."))
  let qp = try await call(.init("preview_dirty", id: qr.id, revision: qr.revision))
  let quarantined = try await call(.init("quarantine", token: qp.token)).operations.first!
  equal(quarantined.phase, "quarantined")
  equal(quarantined.diskCredit, 0)
  checkFalse(fm.fileExists(atPath: quarantineSource.path))
  check(fm.fileExists(atPath: quarantined.quarantinePath!))
  do {
    _ = try await call(
      .init(
        "finish_quarantine", id: quarantined.id, revision: quarantined.archiveDigest,
        evidence: "RETIRE QUARANTINE"))
    failTest("quarantine grace bypassed")
  } catch {}
  var quarantineMetadata = stat()
  check(lstat(quarantined.quarantinePath!, &quarantineMetadata) == 0)
  let lateQuarantineFile = URL(fileURLWithPath: quarantined.quarantinePath!).appendingPathComponent(
    "late-output")
  try Data("New work added after quarantine".utf8).write(to: lateQuarantineFile)
  do {
    _ = try await call(
      .init(
        "finish_quarantine", id: quarantined.id, revision: quarantined.archiveDigest,
        evidence: "RETIRE QUARANTINE NOW"))
    failTest("new quarantine files were removed without recovery")
  } catch {}
  check(fm.fileExists(atPath: lateQuarantineFile.path))
  try fm.removeItem(at: lateQuarantineFile)
  var quarantineTimes = [quarantineMetadata.st_atimespec, quarantineMetadata.st_mtimespec]
  check(
    utimensat(AT_FDCWD, quarantined.quarantinePath!, &quarantineTimes, AT_SYMLINK_NOFOLLOW) == 0)
  let finished = try await call(
    .init(
      "finish_quarantine", id: quarantined.id, revision: quarantined.archiveDigest,
      evidence: "RETIRE QUARANTINE NOW"))
  equal(finished.operations.first?.phase, "completed")
  checkFalse(fm.fileExists(atPath: quarantined.quarantinePath!))
  // Batch execution preserves a target that changes after its reviewed plan.
  var batchRows: [WorktreeRecord] = []
  for name in ["batch-one", "batch-two"] {
    let path = base.appendingPathComponent(name)
    _ = try git(repo.path, ["worktree", "add", "--detach", path.path])
    let row = try await call(.init("scan")).records.first { $0.path == path.path }!
    _ = try await call(.init("adopt", id: row.id, revision: row.revision))
    _ = try await call(
      .init(
        "confirm", id: row.id, revision: row.revision,
        evidence: "This synthetic batch task is complete and no consumer needs it."))
    batchRows.append(row)
  }
  let bp = try await call(
    .init(
      "batch_preview", ids: batchRows.map(\.id),
      revisions: Dictionary(uniqueKeysWithValues: batchRows.map { ($0.id, $0.revision) })))
  equal(bp.batch.filter(\.ready).count, 2)
  try Data("late output".utf8).write(
    to: URL(fileURLWithPath: batchRows[1].path).appendingPathComponent("late-output"))
  let br = try await call(.init("batch_retire", token: bp.token))
  equal(br.batch.filter(\.ready).count, 1)
  check(fm.fileExists(atPath: batchRows[1].path))
  checkFalse(fm.fileExists(atPath: batchRows[0].path))
  var absentOperation = br.operations.first {
    $0.worktreeID == batchRows[0].id && $0.phase == "completed"
  }!
  absentOperation.phase = "verifying"
  try journal.put(absentOperation, kind: "operation", id: absentOperation.id)
  let absentRestart = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess, recoveryKey: { key })
  let absentReconciliation = try await absentRestart.request(
    .init("reconcile", id: absentOperation.id, evidence: "RECONCILE RECOVERY"), caller: "fixture")
  equal(absentReconciliation.operations.first?.phase, "reconciled-absent")
  equal(absentReconciliation.operations.first?.diskCredit, 0)
  // Authenticated ciphertext corruption must fail before a restoration is accepted.
  let encryptedPath = URL(fileURLWithPath: dirtyRetired.operations.first!.recoveryPath)
    .appendingPathComponent("manifest.enc")
  let originalCiphertext = try Data(contentsOf: encryptedPath)
  var damaged = originalCiphertext
  damaged[damaged.startIndex] ^= 1
  try damaged.write(to: encryptedPath)
  do {
    _ = try await call(
      .init(
        "restore", id: dirtyRetired.operations.first!.id,
        path: base.appendingPathComponent("corrupt-restore").path))
    failTest("corrupt archive restored")
  } catch {}
  try originalCiphertext.write(to: encryptedPath)
  let strictNative = WorktreeInspection.inspect(batchRows[1])
  if !strictNative.gaps.isEmpty {
    check(strictNative.state != "Ready to retire", "native unknown visibility authorized removal")
  }
  print(
    "PASS quarantine grace and exact final removal, changed-item batch refusal, corrupted recovery refusal and native unknown preservation"
  )
  // A branch switch at the same commit invalidates both preview and release.
  let binding = base.appendingPathComponent("branch-binding")
  _ = try git(repo.path, ["worktree", "add", "--detach", binding.path])
  let boundRow = try await call(.init("scan")).records.first { $0.path == binding.path }!
  _ = try await call(.init("adopt", id: boundRow.id, revision: boundRow.revision))
  let boundOwner = try await call(
    .init(
      "claim", id: boundRow.id, revision: boundRow.revision,
      evidence: "This fixture owns the detached checkout while its test runs.",
      condition: "The branch binding fixture finishes."))
  _ = try await call(
    .init(
      "release", token: boundOwner.token,
      evidence: "The detached checkout task finished and no consumer remains."))
  let boundPreview = try await call(.init("preview", id: boundRow.id, revision: boundRow.revision))
  _ = try git(binding.path, ["switch", "-c", "new-task-same-commit"])
  do {
    _ = try await call(.init("retire", token: boundPreview.token))
    failTest("same-commit branch switch did not revoke preview")
  } catch {}
  let newBinding = try await call(.init("inspect", id: boundRow.id)).records.first!
  do {
    _ = try await call(.init("preview", id: boundRow.id, revision: newBinding.revision))
    failTest("old owner release authorized a different branch")
  } catch {}
  check(fm.fileExists(atPath: binding.path))
  // Reusing a retired path creates a new unmanaged identity, preserving history.
  _ = try git(repo.path, ["worktree", "add", "--detach", clean.path])
  let reused = try await call(.init("scan")).records.first { $0.path == clean.path && !$0.retired }!
  notEqual(reused.id, cleanRow.id)
  checkFalse(reused.managed)
  isNil(reused.confirmedRevision)
  // Moved registrations can be repaired only for the exact recorded directory.
  let moving = base.appendingPathComponent("moving")
  let moved = base.appendingPathComponent("moved")
  _ = try git(repo.path, ["worktree", "add", "--detach", moving.path])
  let beforeMove = try await call(.init("scan")).records.first { $0.path == moving.path }!
  try fm.moveItem(at: moving, to: moved)
  let missing = try await call(.init("scan")).records.first { $0.id == beforeMove.id }!
  check(missing.missing)
  _ = try await call(.init("repair", id: missing.id, revision: missing.revision, path: moved.path))
  let repairedRegistrations = try WorktreeGit.text(repo.path, ["worktree", "list", "--porcelain"])
  check(repairedRegistrations.contains(moved.path))
  print(
    "PASS branch/release binding, retired-path identity reuse, and exact moved-worktree registration repair"
  )
  // Destroy only the sacrificial original repository. Restoration must not depend on it.
  try fm.removeItem(at: repo)
  let restored = base.appendingPathComponent("restored-dirty")
  _ = try await call(.init("restore", id: dirtyRetired.operations.first!.id, path: restored.path))
  equal(try Data(contentsOf: restored.appendingPathComponent("source")), Data("unstaged\n".utf8))
  equal(try git(restored.path, ["show", ":source"]), "staged")
  equal(
    try Data(contentsOf: restored.appendingPathComponent(".env")),
    Data("synthetic-private-data".utf8))
  equal(try Data(contentsOf: restored.appendingPathComponent("new binary")), Data([0, 255, 1, 23]))
  let restoredClean = base.appendingPathComponent("restored-clean")
  _ = try await call(.init("restore", id: retired.operations.first!.id, path: restoredClean.path))
  equal(
    try Data(contentsOf: restoredClean.appendingPathComponent("source")), Data("initial\n".utf8))
  do {
    _ = try await call(.init("restore", id: retired.operations.first!.id, path: restoredClean.path))
    failTest("restore overwrote existing destination")
  } catch {}
  do {
    _ = try await service.request(
      .init("adopt", id: d.id, revision: d.revision), caller: "review", management: false)
    failTest("reviewer adopted a checkout")
  } catch {}
  let database = try WorktreeStore(root: root)
  let backup = base.appendingPathComponent("backup.sqlite")
  try database.backup(to: backup)
  check(fm.fileExists(atPath: backup.path))
  do {
    try database.transaction {
      try database.put("should rollback", kind: "rollback", id: "test")
      throw StoreError.message("fixture")
    }
  } catch {}
  let rolledBack = try database.values(String.self, kind: "rollback")
  check(rolledBack.isEmpty)
  print(
    "PASS dirty staged/unstaged, binary, ignored-file rescue and independent restoration after original repository loss; database rollback/backup"
  )
}
