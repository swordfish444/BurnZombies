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
  equal(inspectedPaths.count, 13)
  let firstRound = result.records.filter { inspectedPaths.prefix(2).contains($0.path) }
  equal(
    Set(firstRound.map(\.repository)).count, 2,
    "The larger repository monopolized the first detail round")
  let anchors = result.records.filter { $0.main || $0.bare || $0.ownerManaged }
  equal(anchors.count, 4)
  for row in anchors {
    check(row.consumer == "unknown" && row.revision.isEmpty && !row.blockers.isEmpty)
    check(row.gaps.contains { $0.contains("not measured automatically") })
    checkFalse(inspectedPaths.contains(row.path))
  }
  let owner = anchors.first { $0.path == protected.path }!
  let explicit = WorktreeInspection.inspect(owner, visibility: { _ in 0 })
  check(
    !explicit.revision.isEmpty && explicit.blockers.contains { $0.contains("owning application") },
    "Explicit inspection lost either current detail or harness protection")
  print(
    "PASS repository-fair first detail round, protected anchors remain unmeasured and unapprovable, explicit inspection retains protection"
  )
}
