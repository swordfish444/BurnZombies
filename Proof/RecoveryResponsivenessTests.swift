import BurnCore
import CryptoKit
import Darwin
import Foundation

private final class PendingRecoveryKey: @unchecked Sendable {
  private let condition = NSCondition()
  private var entered = false
  private var released = false
  private var reads = 0
  func load() -> SymmetricKey {
    condition.lock()
    entered = true
    reads += 1
    condition.broadcast()
    while !released { condition.wait() }
    condition.unlock()
    return SymmetricKey(data: Data(repeating: 59, count: 32))
  }
  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
  func reset() {
    condition.lock()
    entered = false
    released = false
    condition.unlock()
  }
  var pending: Bool {
    condition.lock()
    defer { condition.unlock() }
    return entered && !released
  }
  var count: Int {
    condition.lock()
    defer { condition.unlock() }
    return reads
  }
}

func recoveryResponsivenessProof() async throws {
  let previous = failures
  let fm = FileManager.default
  let temporary = URL(fileURLWithPath: "/tmp/bz-pk-" + UUID().uuidString.prefix(8))
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = URL(fileURLWithPath: WorkspaceSafety.canonical(temporary.path))
  defer { try? fm.removeItem(at: base) }
  let root = base.appendingPathComponent("state")
  let repo = base.appendingPathComponent("project")
  let tree = base.appendingPathComponent("completed")
  try fm.createDirectory(at: repo, withIntermediateDirectories: false)
  _ = try WorktreeGit.run(repo.path, ["init", "--initial-branch=main"])
  try Data("preserve while approval is pending\n".utf8).write(
    to: repo.appendingPathComponent("source"))
  _ = try WorktreeGit.run(repo.path, ["add", "."])
  _ = try WorktreeGit.run(
    repo.path,
    ["-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m", "fixture"])
  _ = try WorktreeGit.run(repo.path, ["worktree", "add", "--detach", tree.path])
  let key = PendingRecoveryKey()
  let monitor = try Monitor(
    root: root, workspaceVisibility: { _ in 0 }, accessCheck: fixtureAccess,
    worktreeRecoveryKey: { key.load() })
  let service = AgentService(monitor: monitor)
  let listener = try AgentListener(root: root) { await service.call($0) }
  _ = try await monitor.worktreeRequest(.init("add_root", path: base.path), caller: "fixture")
  let scan = try await monitor.worktreeRequest(.init("scan"), caller: "fixture")
  let row = scan.records.first { $0.path == tree.path }!
  _ = try await monitor.worktreeRequest(
    .init("adopt", id: row.id, revision: row.revision), caller: "fixture")
  _ = try await monitor.worktreeRequest(
    .init(
      "confirm", id: row.id, revision: row.revision,
      evidence: "This synthetic fixture task is complete and has no remaining consumer."),
    caller: "fixture")
  let preview = try await monitor.worktreeRequest(
    .init("preview", id: row.id, revision: row.revision), caller: "fixture")
  // The fallback prevents the deliberately broken pre-fix implementation from
  // hanging the runner, including with a single cooperative executor thread.
  let fallback = DispatchWorkItem { key.release() }
  DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: fallback)
  defer {
    fallback.cancel()
    key.release()
  }
  let retirement = Task {
    try await monitor.worktreeRequest(.init("retire", token: preview.token), caller: "fixture")
  }
  let waitDeadline = ProcessInfo.processInfo.systemUptime + 1
  while !key.pending && ProcessInfo.processInfo.systemUptime < waitDeadline {
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  let began = ProcessInfo.processInfo.systemUptime
  async let access = AgentConnection.callAsync(.init("access_status"), root: root)
  async let accessCheck = AgentConnection.callAsync(.init("access_check"), root: root)
  async let status = AgentConnection.callAsync(.init("status"), root: root)
  let responses = try await [access, accessCheck, status]
  check(
    ProcessInfo.processInfo.systemUptime - began < 0.75,
    "Pending recovery approval blocked unrelated IPC replies")
  for text in responses {
    let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    check(value["ok"] as? Bool == true, "Unrelated status request failed during recovery approval")
  }
  check(key.pending, "Approval completed before the responsiveness checks finished")
  let state = await monitor.snapshot()
  equal(state.worktrees?.operations.first?.phase, "preserving")
  equal(state.catalog.lifetimeWorktreesCleaned ?? 0, 0)
  check(
    fm.fileExists(atPath: tree.appendingPathComponent("source").path),
    "Pending approval removed source")
  do {
    _ = try await monitor.worktreeRequest(.init("check_key"), caller: "other")
    failTest("A second recovery prompt was allowed while retirement awaited approval")
  } catch {}
  equal(key.count, 1, "Pending approval was retried")
  _ = await monitor.refresh()
  check(key.pending, "Observer refresh waited for key approval")
  fallback.cancel()
  key.release()
  let finished = try await retirement.value
  equal(finished.operations.first?.phase, "completed")

  let kept = base.appendingPathComponent("kept-during-prompt")
  _ = try WorktreeGit.run(repo.path, ["worktree", "add", "--detach", kept.path])
  let refreshed = try await monitor.worktreeRequest(.init("scan"), caller: "fixture")
  let keptRow = refreshed.records.first { $0.path == kept.path }!
  _ = try await monitor.worktreeRequest(
    .init("adopt", id: keptRow.id, revision: keptRow.revision), caller: "fixture")
  _ = try await monitor.worktreeRequest(
    .init(
      "confirm", id: keptRow.id, revision: keptRow.revision,
      evidence: "This fixture is complete unless the operator explicitly keeps it during approval."),
    caller: "fixture")
  let secondPreview = try await monitor.worktreeRequest(
    .init("preview", id: keptRow.id, revision: keptRow.revision), caller: "fixture")
  key.reset()
  let secondFallback = DispatchWorkItem { key.release() }
  DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: secondFallback)
  defer {
    secondFallback.cancel()
    key.release()
  }
  let keptRetirement = Task {
    try await monitor.worktreeRequest(
      .init("retire", token: secondPreview.token), caller: "fixture")
  }
  let secondDeadline = ProcessInfo.processInfo.systemUptime + 1
  while !key.pending && ProcessInfo.processInfo.systemUptime < secondDeadline {
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  _ = try await monitor.worktreeRequest(
    .init("keep", id: keptRow.id, revision: keptRow.revision), caller: "fixture")
  check(key.pending, "Keep was blocked by the recovery prompt")
  secondFallback.cancel()
  key.release()
  do {
    _ = try await keptRetirement.value
    failTest("Keep during approval did not prevent retirement")
  } catch {}
  check(
    fm.fileExists(atPath: kept.appendingPathComponent("source").path),
    "Keep during approval lost source")
  let final = await monitor.snapshot()
  let failed = final.worktrees?.operations.first { $0.worktreeID == keptRow.id }
  equal(failed?.phase, "failed")
  equal(failed?.diskCredit, 0)
  equal(final.catalog.lifetimeWorktreesCleaned, 1, "Failed approval race received cleanup credit")
  await listener.stop()
  await monitor.shutdownWorktrees()
  if previous == failures {
    print(
      "PASS pending recovery approval keeps IPC/access/observation responsive, prevents duplicate prompts and preserves source/zero credit when kept during approval"
    )
  }
}
