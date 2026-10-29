import BurnCore
import CSQLite
import CryptoKit
import Darwin
import Foundation

func worktreeSafetyProof() async throws {
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent("bz-wt-safety-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = URL(fileURLWithPath: WorkspaceSafety.canonical(temporary.path))
  defer { try? fm.removeItem(at: base) }
  let repo = base.appendingPathComponent("repo")
  let root = base.appendingPathComponent("state")
  try fm.createDirectory(at: repo, withIntermediateDirectories: false)
  let oldStore = try Store(root: root)
  func git(_ path: String, _ args: [String]) throws -> String { try WorktreeGit.line(path, args) }
  _ = try git(repo.path, ["init", "--initial-branch=main"])
  _ = try git(repo.path, ["config", "user.name", "Synthetic proof"])
  _ = try git(repo.path, ["config", "user.email", "proof@example.invalid"])
  try Data("fixture".utf8).write(to: repo.appendingPathComponent("source"))
  _ = try git(repo.path, ["add", "."])
  _ = try git(repo.path, ["commit", "-m", "fixture"])
  _ = try git(repo.path, ["update-ref", "refs/remotes/origin/main", "HEAD"])
  let parent = root.appendingPathComponent("workspaces")
  try fm.createDirectory(at: parent, withIntermediateDirectories: false)
  let id = UUID().uuidString
  let path = parent.appendingPathComponent(id).path
  _ = try git(repo.path, ["worktree", "add", "--detach", path])
  let token = UUID().uuidString + UUID().uuidString
  let oldJSON: [String: Any] = [
    "id": id, "tokenHash": WorkEvidence.hash(token),
    "identity": try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(WorkspaceSafety.identity(path, root: root))),
    "label": "Legacy fixture", "purpose": "Synthetic completed work",
    "completionCondition": "All fixture consumers finish.",
    "state": "released", "evidence": "This synthetic task finished with all output preserved.",
    "head": try git(path, ["rev-parse", "HEAD"]), "created": Date().timeIntervalSinceReferenceDate,
    "updated": Date().timeIntervalSinceReferenceDate,
  ]
  let old = try JSONDecoder().decode(
    WorkspaceClaim.self, from: JSONSerialization.data(withJSONObject: oldJSON))
  var catalog = Catalog()
  catalog.workspaces = [old]
  try oldStore.save(catalog)
  let key = SymmetricKey(data: Data(repeating: 81, count: 32))
  let monitor = try Monitor(
    root: root, workspaceVisibility: { _ in 0 }, accessCheck: fixtureAccess,
    worktreeRecoveryKey: { key })
  let cutover = try oldStore.load()
  check(cutover.workspaces?.isEmpty == true, "Live legacy action copies must be cleared at cutover")
  equal(try await monitor.workspaceClaims().count, 1)
  let db = try WorktreeStore(root: root)
  equal(try db.value(String.self, kind: "migration", id: "legacy"), "ready")
  let backupRoot = base.appendingPathComponent("restored-database")
  _ = try Store(root: backupRoot)
  try db.backup(to: backupRoot.appendingPathComponent("worktrees.sqlite"))
  let backup = try WorktreeStore(root: backupRoot)
  equal(
    try backup.values(WorkspaceClaim.self, kind: "legacy").first?.id, id,
    "Database backup did not restore legacy ownership")
  let claims = try db.values(WorktreeClaim.self, kind: "claim")
  equal(claims.first?.tokenHash, old.tokenHash)
  isNil(claims.first?.releasedRevision)
  do {
    _ = try await monitor.previewWorkspace(id)
    failTest("Legacy release lacking content binding was automatically trusted")
  } catch {}
  var release = AgentRequest(
    "workspace",
    rationale: "The migrated fixture task is complete and all consumers have finished.",
    action: "release", workToken: token)
  release.callerPID = getpid()
  _ = try await monitor.recordWorkspace(release)
  _ = try await monitor.previewWorkspace(id)
  let service = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess, recoveryKey: { key })
  let scanned = try await service.scan()
  check(
    scanned.records.contains { $0.id == id },
    "Private legacy root must be scanned without user discovery roots")
  let row = try await service.inspect(id)
  let unknown = try WorktreeService(
    root: root, visibility: { _ in -1 }, access: fixtureAccess, recoveryKey: { key })
  let before = try await unknown.inspect(id)
  _ = try await unknown.request(
    .init(
      "advise", id: id, revision: before.revision,
      evidence: "Synthetic consumer visibility is incomplete; retain this checkout.",
      condition: "Reinspect when native visibility recovers."), caller: "model", management: false)
  equal(try await unknown.snapshot().advice.count, 1)
  let after = try await service.inspect(id)
  equal(
    try await service.snapshot().advice.count, 0,
    "Recovered visibility must invalidate old blocked advice")
  notEqual(before.readinessRevision, after.readinessRevision)
  equal(row.revision, after.revision, "Readiness transitions must not fabricate content changes")
  do {
    _ = try await service.request(
      .init("automatic", id: id, revision: after.revision, enabled: true), caller: "model",
      management: false)
    failTest("Model enabled automatic management")
  } catch {}
  do {
    _ = try await service.request(
      .init("preview", id: id, revision: after.revision), caller: "model", management: false)
    failTest("Automatic repository policy was skipped")
  } catch {}
  // A missing registration is reviewable; nested repositories cannot be archived away.
  let nested = URL(fileURLWithPath: path).appendingPathComponent("nested.git")
  _ = try git(path, ["init", "--bare", nested.path])
  let nestedRow = try await service.inspect(id)
  check(nestedRow.gaps.contains { $0.contains("Nested bare") })
  try fm.removeItem(at: nested)
  equal(WorktreeOwner.githubRepository("git@github.com:example/project.git")?.0, "example")
  check(WorktreeOwner.githubRepository("https://example.invalid/project.git") == nil)
  let head = old.head!
  let metadata: [String: Any] = [
    "data": [
      "repository": [
        "defaultBranchRef": ["name": "main"],
        "object": [
          "oid": head,
          "associatedPullRequests": [
            "nodes": [
              [
                "number": 1, "state": "MERGED", "merged": true, "headRefOid": "different-head",
                "url": "https://github.com/example/project/pull/1",
              ]
            ], "pageInfo": ["hasNextPage": true],
          ],
        ],
      ]
    ]
  ]
  let data = try JSONSerialization.data(withJSONObject: metadata)
  let delivery = try WorktreeOwner.parse(data, id: id, head: head, repository: "example/project")
  checkFalse(delivery.complete)
  checkFalse(delivery.requests[0].headMatches)
  throwsError(
    try WorktreeOwner.parse(data, id: id, head: "wrong-head", repository: "example/project"))
  // Database damage disables only worktree management, preserving process observation.
  for kind in ["corrupt", "symlink", "future"] {
    let unsafeRoot = base.appendingPathComponent(kind)
    _ = try Store(root: unsafeRoot)
    let file = unsafeRoot.appendingPathComponent("worktrees.sqlite")
    if kind == "corrupt" {
      try Data("not a SQLite database".utf8).write(to: file)
    } else if kind == "symlink" {
      try fm.createSymbolicLink(
        at: file, withDestinationURL: root.appendingPathComponent("worktrees.sqlite"))
    } else {
      var database: OpaquePointer?
      equal(sqlite3_open(file.path, &database), SQLITE_OK)
      equal(sqlite3_exec(database, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
      sqlite3_close(database)
    }
    do {
      _ = try WorktreeStore(root: unsafeRoot)
      failTest("Unsafe database accepted: " + kind)
    } catch {}
    let protectedMonitor = try Monitor(root: unsafeRoot, accessCheck: fixtureAccess)
    let snapshot = await protectedMonitor.refresh()
    check(snapshot.worktreeError != nil)
    check(snapshot.processCount > 0, "Worktree damage stopped process observation")
  }
  print(
    "PASS legacy cutover/token continuity, readiness transitions, native-role policy refusal, nested repository protection and corrupt/symlink/future database isolation"
  )
}
