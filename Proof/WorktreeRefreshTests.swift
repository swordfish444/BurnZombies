import BurnCore
import Darwin
import Foundation

func nativeWorktreeRefreshProof() async throws {
  let base = URL(fileURLWithPath: "/private/tmp/bz-refresh-native-" + UUID().uuidString)
  let repository = base.appendingPathComponent("repository")
  let root = base.appendingPathComponent("state")
  let gate = base.appendingPathComponent("hold-worker")
  let placeholder = base.appendingPathComponent("placeholder.json")
  let activeMarker = base.appendingPathComponent("inspecting.json")
  let starts = base.appendingPathComponent("worker-starts")
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
    ("#!/bin/sh\nprintf 'started\\n' >> \(quote(starts.path))\nif [ -e \(quote(gate.path)) ]; then /usr/bin/python3 -c "
      + quote(
        "import json,sys;print(json.dumps({'run':sys.argv[1],'complete':False,'record':json.load(open(sys.argv[2]))}),flush=True)"
      )
      + " \"$2\" " + quote(placeholder.path) + "; fi\n"
      + "if [ -e " + quote(activeMarker.path) + " ]; then /usr/bin/python3 -c "
      + quote(
        "import json,sys;print(json.dumps({'run':sys.argv[1],'complete':False,'inspecting':json.load(open(sys.argv[2]))}),flush=True)"
      )
      + " \"$2\" " + quote(activeMarker.path) + "; fi\n"
      + "while [ -e \(quote(gate.path)) ]; do /bin/sleep 0.02; done\nexec "
      + quote(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
      + " \"$@\"\n").utf8
  ).write(to: wrapper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
  let ledger = try IntentLedger(root: root)
  let service = try WorktreeService(
    root: root, access: fixtureAccess,
    scanRunner: WorktreeScanRunner(executable: wrapper), intent: ledger)
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
    old.observedAt = Date().addingTimeInterval(-125)
    try db.put(old, kind: "record", id: old.id)
    var pending = old
    pending.revision = ""
    pending.gaps = ["Detailed inspection pending."]
    pending.observedAt = Date()
    try JSONEncoder().encode(pending).write(to: placeholder)
    try Data().write(to: gate)
    let blocked = Date()
    do {
      _ = try await service.tick()
      failTest("Held native refresh silently succeeded")
    } catch {
      check(error.localizedDescription.contains("refresh"))
    }
    check(Date().timeIntervalSince(blocked) < 30, "Refresh exceeded its native process deadline")
    check(Date().timeIntervalSince(blocked) >= 24, "Worker fixture did not reach its timeout")
    let afterTimeout = try await service.snapshot().records.first { $0.id == old.id }!
    check(
      afterTimeout.gaps.isEmpty,
      "Registration-only placeholder delayed the retry of an otherwise ready checkout")
    try FileManager.default.removeItem(at: gate)
    _ = try await service.tick()
    let observedAgain = try await service.snapshot().records.first { $0.id == old.id }!.observedAt
    check(
      observedAgain > blocked,
      "Timed-out refresh permanently suppressed observation")
    var slow = try await service.snapshot().records.first { $0.id == old.id }!
    var deferred = try await service.snapshot().records.first { !$0.main && $0.id != old.id }!
    slow.observedAt = Date().addingTimeInterval(-130)
    deferred.observedAt = Date().addingTimeInterval(-125)
    try db.put(slow, kind: "record", id: slow.id)
    try db.put(deferred, kind: "record", id: deferred.id)
    try JSONEncoder().encode(slow.id).write(to: activeMarker)
    try Data().write(to: gate)
    let slowStarted = Date()
    do {
      _ = try await service.tick()
      failTest("Active inspection timeout silently succeeded")
    } catch { check(error.localizedDescription.contains("refresh")) }
    check(
      Date().timeIntervalSince(slowStarted) >= 24,
      "Active inspection fixture did not reach its timeout")
    let timedOut = try await service.snapshot().records.first { $0.id == slow.id }!
    check(timedOut.observedAt >= slowStarted && timedOut.consumer == "unknown")
    check(timedOut.gaps.contains { $0.contains("bounded refresh budget") })
    equal(
      try await service.snapshot().records.first { $0.id == deferred.id }!.observedAt,
      deferred.observedAt, "Deferred checkout was incorrectly stamped as inspected")
    try FileManager.default.removeItem(at: gate)
    try FileManager.default.removeItem(at: activeMarker)
    _ = try await service.tick()
    let afterSlow = try await service.snapshot()
    equal(afterSlow.records.first { $0.id == slow.id }!.observedAt, timedOut.observedAt)
    check(afterSlow.records.first { $0.id == deferred.id }!.observedAt >= slowStarted)
    let slowCalls = try Data(contentsOf: starts)
    _ = try await service.tick()
    equal(try Data(contentsOf: starts), slowCalls, "Slow checkout monopolized the next tick")
    let vanished = Array(rows.prefix(2))
    _ = try WorktreeGit.run(repository.path, ["worktree", "remove", vanished[0].path])
    try FileManager.default.removeItem(atPath: vanished[1].path)
    for var row in vanished {
      row.observedAt = Date().addingTimeInterval(-125)
      try db.put(row, kind: "record", id: row.id)
    }
    let removedAt = Date()
    let removalTick = try await service.tick()
    check(removalTick != nil)
    let afterRemoval = try await service.snapshot()
    for removed in vanished {
      let row = afterRemoval.records.first { $0.id == removed.id }!
      check(row.observedAt >= removedAt && row.consumer == "unknown" && !row.gaps.isEmpty)
      let proposal = try ledger.snapshot().proposals.first {
        $0.resources == ["worktree:" + row.id]
      }!
      checkFalse(proposal.ready)
    }
    let callsBefore = try Data(contentsOf: starts)
    _ = try await service.tick()
    equal(
      try Data(contentsOf: starts), callsBefore,
      "Missing checkout caused a new full consumer scan on every observer tick")
    for (index, removed) in vanished.enumerated() {
      let path = URL(fileURLWithPath: removed.path)
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
      try Data("replacement must survive".utf8).write(to: path.appendingPathComponent("control"))
      if index == 1 {
        try Data("gitdir: \(base.path)/nonexistent-administration\n".utf8)
          .write(to: path.appendingPathComponent(".git"))
      }
      var row = afterRemoval.records.first { $0.id == removed.id }!
      row.observedAt = Date().addingTimeInterval(-901)
      try db.put(row, kind: "record", id: row.id)
    }
    _ = try await service.tick()
    for removed in vanished {
      let path = URL(fileURLWithPath: removed.path)
      equal(
        try Data(contentsOf: path.appendingPathComponent("control")),
        Data("replacement must survive".utf8))
    }
    // A real replacement repository at the exact old path must not stand in for
    // the old repository identity, nor keep the old row eligible every tick.
    _ = try WorktreeGit.run(vanished[0].path, ["init", "--initial-branch=main"])
    var replaced = try await service.snapshot().records.first { $0.id == vanished[0].id }!
    replaced.observedAt = Date().addingTimeInterval(-901)
    try db.put(replaced, kind: "record", id: replaced.id)
    let replacementStarted = Date()
    _ = try await service.tick()
    let replacement = try await service.snapshot().records.first { $0.id == replaced.id }!
    check(replacement.observedAt >= replacementStarted && replacement.consumer == "unknown")
    check(replacement.gaps.contains { $0.contains("recorded repository") })
    let replacementProposal = try ledger.snapshot().proposals.first {
      $0.resources == ["worktree:" + replaced.id]
    }!
    checkFalse(replacementProposal.ready)
    let replacementCalls = try Data(contentsOf: starts)
    _ = try await service.tick()
    equal(
      try Data(contentsOf: starts), replacementCalls, "Replacement repository caused a refresh loop"
    )
    equal(
      try Data(contentsOf: URL(fileURLWithPath: replaced.path + "/control")),
      Data("replacement must survive".utf8))
    var remaining = afterRemoval.records.first { !$0.main && !vanished.map(\.id).contains($0.id) }!
    remaining.observedAt = Date().addingTimeInterval(-125)
    try db.put(remaining, kind: "record", id: remaining.id)
    _ = try await service.tick()
    let rotated = try await service.snapshot().records.first { $0.id == remaining.id }!
    check(rotated.observedAt >= removedAt && rotated.consumer == "none observed")
    // Eight older incomplete rows must not consume every slot ahead of the
    // newer, ready row. Both cohorts must make progress on the same tick.
    for var row in try await service.snapshot().records where !row.main {
      row.observedAt = Date().addingTimeInterval(row.id == remaining.id ? -125 : -3600)
      if row.id != remaining.id {
        row.consumer = "unknown"
        row.gaps = ["Fixture visibility gap"]
      }
      try db.put(row, kind: "record", id: row.id)
    }
    let fairStart = Date()
    _ = try await service.tick()
    let fairRows = try await service.snapshot().records.filter { !$0.main }
    check(
      fairRows.first { $0.id == remaining.id }!.observedAt >= fairStart,
      "Older incomplete rows starved the healthy cohort")
    equal(fairRows.filter { $0.observedAt >= fairStart }.count, 8)
    print(
      "PASS externally removed and manually missing checkouts become bounded row-level unknowns; remaining findings refresh without a permanent global error or repeated worker loop"
    )
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
