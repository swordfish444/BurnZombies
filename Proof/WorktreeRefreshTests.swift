import BurnCore
import Darwin
import Foundation

func nativeWorktreeRefreshProof() async throws {
  let base = URL(fileURLWithPath: "/private/tmp/bz-refresh-native-" + UUID().uuidString)
  let repository = base.appendingPathComponent("repository")
  let root = base.appendingPathComponent("state")
  let gate = base.appendingPathComponent("hold-worker")
  let wrapper = base.appendingPathComponent("worker")
  defer { try? FileManager.default.removeItem(at: base) }
  try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repository.path, ["init", "--initial-branch=main"])
  try Data("fixture\n".utf8).write(to: repository.appendingPathComponent("file"))
  _ = try WorktreeGit.run(repository.path, ["add", "."])
  _ = try WorktreeGit.run(
    repository.path,
    [
      "-c", "user.name=Proof", "-c",
      "user.email=proof@example.invalid", "commit", "-m", "fixture",
    ])
  for index in 0..<9 {
    _ = try WorktreeGit.run(
      repository.path,
      [
        "worktree", "add", "--detach",
        base.appendingPathComponent("checkout-\(index)").path,
      ])
  }
  func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  try Data(
    ("#!/bin/sh\nwhile [ -e \(quote(gate.path)) ]; do /bin/sleep 0.02; done\nexec "
      + quote(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
      + " \"$@\"\n").utf8
  ).write(to: wrapper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
  let service = try WorktreeService(
    root: root, access: fixtureAccess,
    scanRunner: WorktreeScanRunner(executable: wrapper))
  do {
    _ = try await service.request(.init("add_root", path: base.path), caller: "fixture")
    _ = try await service.scan()
    let db = try WorktreeStore(root: root)
    var rows = try await service.snapshot().records.filter { !$0.main }
    equal(rows.count, 9)
    for index in rows.indices {
      rows[index].observedAt = Date().addingTimeInterval(-3600 + Double(index))
      try db.put(rows[index], kind: "record", id: rows[index].id)
    }
    let cursor = root.appendingPathComponent("worktree-discovery-cursor.json")
    let beforeCursor = try Data(contentsOf: cursor)
    func cpu() -> Double {
      var own = rusage()
      var children = rusage()
      getrusage(RUSAGE_SELF, &own)
      getrusage(RUSAGE_CHILDREN, &children)
      return [own.ru_utime, own.ru_stime, children.ru_utime, children.ru_stime].reduce(0) {
        $0 + Double($1.tv_sec) + Double($1.tv_usec) / 1_000_000
      }
    }
    let started = Date()
    let cpuBefore = cpu()
    _ = try await service.tick()
    let first = try await service.snapshot().records.filter { !$0.main && $0.observedAt >= started }
    equal(first.count, 8, "Native refresh did not honor its eight-row batch")
    check(
      first.allSatisfy { $0.gaps.isEmpty && $0.consumer == "none observed" },
      "Actual native consumer/inspection coverage is incomplete")
    print(
      "NATIVE_REFRESH_COST eight checkouts: wall=\(Date().timeIntervalSince(started))s, observer+worker CPU=\(cpu() - cpuBefore)s"
    )
    _ = try await service.tick()
    equal(
      try await service.snapshot().records.filter { !$0.main && $0.observedAt >= started }.count, 9,
      "Ninth checkout starved behind recently refreshed rows")
    equal(
      try Data(contentsOf: cursor), beforeCursor,
      "Known-checkout refresh replaced the full discovery frontier")
    guard var old = first.first else { throw StoreError.message("No completed native refresh") }
    old.observedAt = Date().addingTimeInterval(-3600)
    try db.put(old, kind: "record", id: old.id)
    try Data().write(to: gate)
    let blocked = Date()
    do {
      _ = try await service.tick()
      failTest("Held native refresh silently succeeded")
    } catch {
      check(error.localizedDescription.contains("refresh"))
    }
    check(Date().timeIntervalSince(blocked) < 30, "Refresh exceeded its native process deadline")
    try FileManager.default.removeItem(at: gate)
    _ = try await service.tick()
    let observedAgain = try await service.snapshot().records.first { $0.id == old.id }!.observedAt
    check(
      observedAgain > blocked,
      "Timed-out refresh permanently suppressed observation")
    await service.shutdown()
  } catch {
    try? FileManager.default.removeItem(at: gate)
    await service.shutdown()
    throw error
  }
  print(
    "PASS actual native consumer snapshot refresh: eight-row bound, ninth-row rotation, preserved discovery cursor, timed-out worker refusal/reaping and successful later observation"
  )
}
