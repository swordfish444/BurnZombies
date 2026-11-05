import BurnCore
import Foundation

func worktreeDiscoveryFairnessProof() throws {
  let base = URL(fileURLWithPath: "/private/tmp/bz-discovery-fairness-" + UUID().uuidString)
  let fm = FileManager.default
  try fm.createDirectory(at: base, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: base) }
  var repositories: [URL] = []
  for (name, count) in [("a-large", 12), ("z-small", 1)] {
    let repository = base.appendingPathComponent(name)
    repositories.append(repository)
    try fm.createDirectory(at: repository, withIntermediateDirectories: false)
    _ = try WorktreeGit.run(repository.path, ["init", "--initial-branch=main"])
    try Data("synthetic fairness fixture\n".utf8).write(
      to: repository.appendingPathComponent("source"))
    _ = try WorktreeGit.run(repository.path, ["add", "."])
    _ = try WorktreeGit.run(
      repository.path,
      [
        "-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m",
        "fixture",
      ])
    for index in 0..<count {
      _ = try WorktreeGit.run(
        repository.path,
        [
          "worktree", "add", "--detach",
          base.appendingPathComponent(name + "-checkout-\(index)").path,
        ])
    }
  }
  let protected = base.appendingPathComponent(".codex/worktrees/protected")
  try fm.createDirectory(
    at: protected.deletingLastPathComponent(), withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repositories[0].path, ["worktree", "add", "--detach", protected.path])
  let bare = base.appendingPathComponent("bare-anchor")
  _ = try WorktreeGit.run(base.path, ["init", "--bare", bare.path])
  var inspectedPaths: [String] = []
  let result = WorktreeDiscovery.scan(
    roots: [base.path], seconds: 30,
    visibility: {
      inspectedPaths.append($0)
      return 0
    })
  equal(inspectedPaths.count, 14)
  let firstRound = result.records.filter { inspectedPaths.prefix(2).contains($0.path) }
  equal(
    Set(firstRound.map(\.repository)).count, 2,
    "The larger repository monopolized the first detail round")
  let anchors = result.records.filter { $0.main || $0.bare }
  equal(anchors.count, 3)
  for row in anchors {
    check(row.consumer == "unknown" && row.revision.isEmpty && !row.blockers.isEmpty)
    check(row.gaps.contains { $0.contains("not measured automatically") })
    checkFalse(inspectedPaths.contains(row.path))
  }
  // A copy Codex or Claude manages is measured like any other, so Autopilot can judge it, and
  // stays unapprovable in the manual cleanup.
  let owner = result.records.first { $0.path == protected.path }!
  check(owner.ownerManaged && inspectedPaths.contains(owner.path), "owner-managed copy unmeasured")
  check(
    !owner.revision.isEmpty && owner.consumer == "none observed"
      && owner.blockers.contains { $0.contains("owning application") },
    "An owner-managed copy lost either its measurement or its harness protection")
  print(
    "PASS repository-fair first detail round, protected anchors remain unmeasured and unapprovable, owner-managed copies are measured and stay unapprovable"
  )
}

/// Autopilot judges a copy Codex manages from the same facts as any other copy, so the
/// between-scan refresh keeps them current too.
func ownerManagedRefreshProof() async throws {
  let base = URL(fileURLWithPath: "/private/tmp/bz-owner-refresh-" + UUID().uuidString)
  let fm = FileManager.default
  defer { try? fm.removeItem(at: base) }
  let home = base.appendingPathComponent("home")
  let repository = home.appendingPathComponent("git/project")
  let copy = home.appendingPathComponent(".codex/worktrees/a1b2/project")
  try fm.createDirectory(at: repository, withIntermediateDirectories: true)
  try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repository.path, ["init", "--initial-branch=main"])
  try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("source"))
  _ = try WorktreeGit.run(repository.path, ["add", "."])
  _ = try WorktreeGit.run(
    repository.path,
    [
      "-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m",
      "fixture",
    ])
  _ = try WorktreeGit.run(repository.path, ["worktree", "add", "--detach", copy.path])
  let root = base.appendingPathComponent("state")
  let service = try WorktreeService(
    root: root, visibility: { _ in 0 }, access: fixtureAccess, discoveryHome: home)
  _ = try await service.tick()
  var row = try await service.snapshot().records.first { $0.path == copy.path }!
  check(row.ownerManaged && !row.revision.isEmpty, "the full scan left the Codex copy unmeasured")
  equal(row.changes, 0)
  try Data("edit\n".utf8).write(to: copy.appendingPathComponent("notes"))
  row.observedAt = Date().addingTimeInterval(-20 * 60)
  try WorktreeStore(root: root).put(row, kind: "record", id: row.id)
  _ = try await service.tick()
  row = try await service.snapshot().records.first { $0.path == copy.path }!
  equal(row.changes, 1, "the refresh between scans skipped the Codex copy")
  print("PASS owner-managed copies are measured by full scans and refreshed between them")
}

/// A consumer check that can't see every program for a while, like one that catches a program
/// mid-exit on a busy Mac.
private final class BusyMac: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private var failUntil: Int
  init(failing: Int) { failUntil = failing }
  var count: Int { lock.withLock { calls } }
  func fail(next: Int) { lock.withLock { failUntil = calls + next } }
  func state(_ path: String) -> Int32 {
    lock.withLock {
      calls += 1
      return calls <= failUntil ? -1 : 0
    }
  }
}

/// A new install's first consumer check can fail on a busy Mac. The copy is checked again right
/// away instead of 15 minutes later; a check that keeps failing backs off after five tries.
func consumerRetryProof() async throws {
  let before = failures
  let base = URL(fileURLWithPath: "/private/tmp/bz-consumer-retry-" + UUID().uuidString)
  let fm = FileManager.default
  defer { try? fm.removeItem(at: base) }
  let home = base.appendingPathComponent("home")
  let repository = home.appendingPathComponent("git/project")
  let copy = home.appendingPathComponent("git/project-old")
  try fm.createDirectory(at: repository, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repository.path, ["init", "--initial-branch=main"])
  try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("source"))
  _ = try WorktreeGit.run(repository.path, ["add", "."])
  _ = try WorktreeGit.run(
    repository.path,
    [
      "-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m",
      "fixture",
    ])
  _ = try WorktreeGit.run(repository.path, ["worktree", "add", "--detach", copy.path])
  let root = base.appendingPathComponent("state")
  let busy = BusyMac(failing: 1)
  let service = try WorktreeService(
    root: root, visibility: { busy.state($0) }, access: fixtureAccess, discoveryHome: home)
  _ = try await service.tick()
  var row = try await service.snapshot().records.first { $0.path == copy.path }!
  equal(busy.count, 2, "the copy waited after the first scan's consumer check failed")
  check(
    row.consumer == "none observed" && row.gaps.isEmpty,
    "a failed first consumer check left the copy's users unknown")
  busy.fail(next: 1000)
  row.observedAt = Date().addingTimeInterval(-121)
  try WorktreeStore(root: root).put(row, kind: "record", id: row.id)
  var checks: [Int] = []
  for _ in 0..<7 {
    let before = busy.count
    _ = try await service.tick()
    checks.append(busy.count - before)
  }
  equal(checks, [1, 1, 1, 1, 1, 0, 0], "a consumer check that keeps failing did not back off")
  row = try await service.snapshot().records.first { $0.path == copy.path }!
  check(row.consumer == "unknown", "a copy nobody could check was called unused")
  if failures == before {
    print(
      "PASS a failed consumer check is retried at the next tick, and backs off after five failures")
  }
}
