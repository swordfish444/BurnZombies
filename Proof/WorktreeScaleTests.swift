import BurnCore
import Foundation

private final class WorktreeProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var ids = Set<String>()
  private var first: Date?
  func add(_ row: WorktreeRecord) { lock.withLock { ids.insert(row.id); if first == nil { first = Date() } } }
  var snapshot: (Int, Date?) { lock.withLock { (ids.count, first) } }
}

func worktreeScaleProof() throws {
  let fm = FileManager.default, temporary = fm.temporaryDirectory.appendingPathComponent("bz-worktree-scale-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = URL(fileURLWithPath: WorkspaceSafety.canonical(temporary.path))
  defer { try? fm.removeItem(at: base) }
  let setup = Date()
  for i in 0..<100 {
    let repo = base.appendingPathComponent("repo-\(i)")
    try fm.createDirectory(at: repo, withIntermediateDirectories: false)
    _ = try WorktreeGit.run(repo.path, ["init", "--initial-branch=main"])
    try Data("synthetic inventory fixture\n".utf8).write(to: repo.appendingPathComponent("source"))
    _ = try WorktreeGit.run(repo.path, ["add", "."])
    _ = try WorktreeGit.run(repo.path, ["-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m", "fixture"])
    for j in 0..<10 { _ = try WorktreeGit.run(repo.path, ["worktree", "add", "--detach", "--", base.appendingPathComponent("tree-\(i)-\(j)").path]) }
  }
  let root = base.appendingPathComponent("state"); _ = try Store(root: root)
  let progress = WorktreeProgress(), start = Date()
  let runner = WorktreeScanRunner(executable: URL(fileURLWithPath: CommandLine.arguments[0]))
  let result = runner.run(roots: [base.path], root: root, publish: { progress.add($0) })
  let ended = Date(), unique = Dictionary(result.records.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
  equal(unique.count, 1100, "Inventory count \(unique.count); gaps: \(result.gaps.joined(separator: "; "))")
  equal(unique.values.filter { !$0.main }.count, 1000)
  equal(progress.snapshot.0, 1100)
  check(progress.snapshot.1.map { $0 < ended.addingTimeInterval(-1) } ?? false, "No streamed inventory appeared before scan completion")
  checkFalse(result.gaps.contains { $0.contains("interrupted or incomplete") }, result.gaps.joined(separator: "; "))
  let cancellation = Date()
  let cancelled = runner.run(roots: [base.path], root: root, publish: { _ in }, keepGoing: { Date().timeIntervalSince(cancellation) < 0.05 })
  check(cancelled.gaps.contains { $0.contains("interrupted or incomplete") })
  check(Date().timeIntervalSince(cancellation) < 8, "Cancelled worker group did not stop promptly")
  print("Scale observations: 100 repositories, 1,000 worktrees; setup \(String(format: "%.2f", start.timeIntervalSince(setup)))s, scan \(String(format: "%.2f", ended.timeIntervalSince(start)))s; native consumer gaps preserved; cancellation verified")
}
