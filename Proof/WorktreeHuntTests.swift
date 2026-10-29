import BurnCore
import Foundation

func worktreeHuntRefreshProof() async throws {
  let previousFailures = failures
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent(
    "bz-hunt-refresh-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = URL(fileURLWithPath: WorkspaceSafety.canonical(temporary.path))
  defer { try? fm.removeItem(at: base) }
  let repo = base.appendingPathComponent("project")
  let root = base.appendingPathComponent("state")
  try fm.createDirectory(at: repo, withIntermediateDirectories: false)
  _ = try WorktreeGit.run(repo.path, ["init", "--initial-branch=main"])
  try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("source"))
  _ = try WorktreeGit.run(repo.path, ["add", "."])
  _ = try WorktreeGit.run(
    repo.path,
    ["-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m", "fixture"])
  let monitor = try Monitor(root: root, workspaceVisibility: { _ in 0 }, accessCheck: fixtureAccess)
  _ = try await monitor.worktreeRequest(.init("add_root", path: base.path), caller: "fixture")
  _ = try await monitor.worktreeRequest(.init("scan"), caller: "fixture")
  let created = base.appendingPathComponent("created-after-recent-scan")
  _ = try WorktreeGit.run(repo.path, ["worktree", "add", "--detach", created.path])
  await monitor.worktreeTick()
  let before = await monitor.snapshot()
  checkFalse(
    before.worktrees!.records.contains { $0.path == created.path },
    "Ordinary observer tick rescanned a recent inventory")
  _ = try await monitor.prepareHunt(timeout: 5)
  let after = await monitor.snapshot()
  check(
    after.worktrees!.records.contains { $0.path == created.path },
    "Hunt missed a worktree created after the recent scan")
  isNil(after.worktreeError)
  // Age only this fixture's persisted evidence. Refresh must publish it through
  // the same monitor signal the reviewer consumes, without invoking any model.
  let db = try WorktreeStore(root: root)
  var row = after.worktrees!.records.first { $0.path == created.path }!
  row.changedAt = Date().addingTimeInterval(-30 * 86400)
  try db.put(row, kind: "record", id: row.id)
  let ready = try await monitor.prepareHunt(timeout: 5)
  check(
    ready.catalog.worktreeEvidence?.contains { $0.id == "worktree-advice:" + row.id } == true,
    "Hunt did not receive refreshed worktree evidence")
  let signal = try JSONDecoder().decode(
    HarnessHook.Signal.self,
    from: Data(contentsOf: root.appendingPathComponent("review-signal")))
  check(
    signal.reviewEvidence?.contains { $0.id == "worktree-advice:" + row.id } == true,
    "Refreshed evidence was not published to the reviewer")
  _ = try await monitor.prepareHunt(timeout: 0)
  let pending = await monitor.snapshot()
  check(pending.worktreeError != nil, "A preparation deadline looked like ready worktree evidence")
  equal(pending.catalog.worktreeEvidence, [])
  var hunt = HuntSnapshot()
  hunt.includeMonitorReceipts(pending)
  equal(hunt.receiptEvidenceAvailable, false, "Unknown worktree coverage appeared verified")
  await monitor.shutdownWorktrees()
  try await sharedWorktreeHuntRefreshProof(base: base)
  if previousFailures == failures {
    print(
      "PASS Hunt refresh bypasses six-hour cadence, publishes new evidence, shares native scans and bounds readiness without model polling"
    )
  }
}

private func sharedWorktreeHuntRefreshProof(base: URL) async throws {
  let fm = FileManager.default
  let gate = base.appendingPathComponent("scan-gate")
  let starts = base.appendingPathComponent("scan-starts")
  let wrapper = base.appendingPathComponent("delayed-worker")
  func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
  let worker = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
  let script = """
    #!/bin/sh
    printf 'started\\n' >> \(quote(starts.path))
    while [ -e \(quote(gate.path)) ]; do /bin/sleep 0.02; done
    exec \(quote(worker)) "$@"
    """
  try Data(script.utf8).write(to: wrapper)
  try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
  let service = try WorktreeService(
    root: base.appendingPathComponent("shared-state"), access: fixtureAccess,
    scanRunner: WorktreeScanRunner(executable: wrapper))
  func count() -> Int {
    (try? String(contentsOf: starts, encoding: .utf8).split(separator: "\n").count) ?? 0
  }
  func blockedScan(_ expected: Int) async throws -> Task<WorktreeReply, Error> {
    try Data().write(to: gate)
    let task = Task { try await service.scan() }
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while count() < expected && ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard count() == expected else {
      throw StoreError.message("Native fixture worker did not start")
    }
    return task
  }
  do {
    _ = try await service.request(.init("add_root", path: base.path), caller: "fixture")
    let first = try await blockedScan(1)
    let one = Task { try await service.refreshForHunt(timeout: 10) }
    let two = Task { try await service.refreshForHunt(timeout: 10) }
    try await Task.sleep(nanoseconds: 100_000_000)
    try fm.removeItem(at: gate)
    _ = try await first.value
    _ = try await one.value
    _ = try await two.value
    equal(count(), 1, "Overlapping Hunt refreshes started duplicate native scans")

    let second = try await blockedScan(2)
    let start = ProcessInfo.processInfo.systemUptime
    do {
      _ = try await service.refreshForHunt(timeout: 0.08)
      failTest("Hunt accepted evidence while its shared worker was still blocked")
    } catch {
      check(error.localizedDescription.contains("pending"), "Unexpected readiness error: \(error)")
    }
    check(
      ProcessInfo.processInfo.systemUptime - start < 1, "Hunt exceeded its preparation deadline")
    do {
      _ = try await service.tick()
      failTest("Observer republished stale evidence while a Hunt refresh was pending")
    } catch {}
    let cancelled = Task { try await service.refreshForHunt(timeout: 10) }
    try await Task.sleep(nanoseconds: 30_000_000)
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      failTest("Cancelled Hunt waited for the shared scan")
    } catch is CancellationError {} catch { failTest("Unexpected cancellation: \(error)") }
    try fm.removeItem(at: gate)
    _ = try await second.value
    equal(count(), 2, "Timed-out or cancelled Hunt replaced the active scan")
    _ = try await service.tick()
    equal(count(), 2, "Ordinary observer tick ignored its six-hour cadence")

    let third = try await blockedScan(3)
    let stale = Task { try await service.refreshForHunt(timeout: 10) }
    try await Task.sleep(nanoseconds: 30_000_000)
    _ = try await service.request(.init("remove_root", path: base.path), caller: "fixture")
    do {
      _ = try await third.value
      failTest("Changed-root scan was accepted")
    } catch {}
    do {
      _ = try await stale.value
      failTest("Hunt accepted a cancelled, stale-root scan")
    } catch {}
    try fm.removeItem(at: gate)
    _ = try await service.request(.init("add_root", path: base.path), caller: "fixture")
    let fourth = try await blockedScan(4)
    await service.shutdown()
    do {
      _ = try await fourth.value
      failTest("Shutdown did not cancel the owned scan")
    } catch {}
    equal(count(), 4)
  } catch {
    await service.shutdown()
    throw error
  }
}
