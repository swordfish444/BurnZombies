import BurnCore
import Darwin
import Foundation

func nativeWorktreeRefreshProof() async throws {
  let initialFailures = failures
  try await nativeWorktreeRediscoveryProof()
  try worktreeDiscoveryFairnessProof()
  try await ownerManagedRefreshProof()
  let base = URL(fileURLWithPath: "/private/tmp/bz-refresh-native-" + UUID().uuidString)
  let repository = base.appendingPathComponent("repository")
  let root = base.appendingPathComponent("state")
  let gate = base.appendingPathComponent("hold-worker")
  let placeholder = base.appendingPathComponent("placeholder.json")
  let activeMarker = base.appendingPathComponent("inspecting.json")
  let lateMarker = base.appendingPathComponent("late-marker")
  let deferral = base.appendingPathComponent("defer-worker")
  let single = base.appendingPathComponent("single-row-worker")
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
    ("#!/bin/sh\nprintf 'started\\n' >> \(quote(starts.path))\n"
      + "if [ -e " + quote(single.path) + " ]; then exec /usr/bin/python3 -c "
      + quote(
        "import json,os,sys;from pathlib import Path;p=Path(os.environ['BURNZOMBIES_HOME'])/('worktree-refresh-'+sys.argv[3]+'.json');row=json.loads(p.read_text())[0];p.write_text(json.dumps([row]));os.execv(sys.argv[1],[sys.argv[1]]+sys.argv[2:5]+[row['path']])"
      )
      + " " + quote(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
      + " \"$@\"; fi\n"
      + "if [ -e " + quote(deferral.path) + " ]; then /usr/bin/python3 -c "
      + quote(
        "import json,sys;print(json.dumps({'run':sys.argv[1],'complete':True,'deferred':True}),flush=True)"
      )
      + " \"$2\"; exit 0; fi\n"
      + "if [ -e " + quote(lateMarker.path) + " ]; then /bin/sleep 23.5; fi\n"
      + "if [ -e \(quote(gate.path)) ]; then /usr/bin/python3 -c "
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
    print("NATIVE_REFRESH_TIMEOUT placeholder elapsed=\(Date().timeIntervalSince(blocked))s")
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
    print("NATIVE_REFRESH_TIMEOUT active elapsed=\(Date().timeIntervalSince(slowStarted))s")
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
    var late = afterSlow.records.first { $0.id == deferred.id }!
    late.observedAt = Date().addingTimeInterval(-125)
    try db.put(late, kind: "record", id: late.id)
    try JSONEncoder().encode(late.id).write(to: activeMarker)
    try Data().write(to: lateMarker)
    try Data().write(to: gate)
    let lateStarted = Date()
    do {
      _ = try await service.tick()
      failTest("Late-start interrupted worker silently succeeded")
    } catch { check(error.localizedDescription.contains("refresh")) }
    print("NATIVE_REFRESH_TIMEOUT late elapsed=\(Date().timeIntervalSince(lateStarted))s")
    check(Date().timeIntervalSince(lateStarted) >= 24)
    let afterLate = try await service.snapshot().records.first { $0.id == late.id }!
    equal(afterLate.observedAt, late.observedAt, "Late-start row received a false slow-row stamp")
    check(afterLate.gaps.isEmpty)
    for file in [gate, lateMarker, activeMarker] { try FileManager.default.removeItem(at: file) }
    try Data().write(to: deferral)
    let deferredEvidence = try await service.tick()
    check(deferredEvidence != nil, "Normal batch deferral suppressed review evidence")
    equal(
      try await service.snapshot().records.first { $0.id == late.id }!.observedAt, late.observedAt)
    try FileManager.default.removeItem(at: deferral)
    _ = try await service.tick()
    let retriedLate = try await service.snapshot().records.first { $0.id == late.id }!
    check(retriedLate.observedAt > lateStarted)
    var concurrent = retriedLate
    concurrent.observedAt = Date().addingTimeInterval(-125)
    try db.put(concurrent, kind: "record", id: concurrent.id)
    try JSONEncoder().encode(concurrent.id).write(to: activeMarker)
    try Data().write(to: gate)
    let concurrentID = concurrent.id
    let manual = Task {
      try await Task.sleep(for: .seconds(2))
      return try await service.inspect(concurrentID)
    }
    let concurrentStarted = Date()
    do {
      _ = try await service.tick()
      failTest("Concurrent inspection timeout silently succeeded")
    } catch { check(error.localizedDescription.contains("refresh")) }
    let manualResult = try await manual.value
    let preserved = try await service.snapshot().records.first { $0.id == concurrentID }!
    print(
      "NATIVE_REFRESH_TIMEOUT concurrent elapsed=\(Date().timeIntervalSince(concurrentStarted))s")
    check(Date().timeIntervalSince(concurrentStarted) >= 24)
    check(
      manualResult.gaps.isEmpty && preserved.gaps.isEmpty,
      "Concurrent inspection gaps: manual=\(manualResult.gaps), stored=\(preserved.gaps)")
    equal(
      preserved.observedAt, manualResult.observedAt, "Timeout overwrote a newer complete inspection"
    )
    for file in [gate, activeMarker] { try FileManager.default.removeItem(at: file) }
    let vanished = Array(rows.prefix(2))
    _ = try WorktreeGit.run(repository.path, ["worktree", "remove", vanished[0].path])
    try FileManager.default.removeItem(atPath: vanished[1].path)
    for var row in vanished {
      row.observedAt = Date().addingTimeInterval(-125)
      try db.put(row, kind: "record", id: row.id)
    }
    let removedAt = Date()
    let removalTick = try await service.tick()
    check(removalTick != nil, "Missing-row tick returned no evidence")
    let afterRemoval = try await service.snapshot()
    for removed in vanished {
      let row = afterRemoval.records.first { $0.id == removed.id }!
      check(
        row.observedAt >= removedAt && row.consumer == "unknown" && !row.gaps.isEmpty,
        "Missing-row observation was not refreshed to unknown: \(row.id), \(row.consumer), \(row.gaps)"
      )
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
    check(
      replacement.observedAt >= replacementStarted && replacement.consumer == "unknown",
      "Replacement-row observation was not refreshed: \(replacement.consumer), \(replacement.gaps)")
    check(
      replacement.gaps.contains { $0.contains("recorded repository") },
      "Replacement identity was not diagnosed: \(replacement.gaps)")
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
    check(
      rotated.observedAt >= removedAt && rotated.consumer == "none observed",
      "Healthy-row rotation did not produce complete evidence: \(rotated.consumer), \(rotated.gaps)"
    )
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
    var newlyFound = fairRows.first { $0.id == remaining.id }!
    newlyFound.revision = ""
    newlyFound.consumer = "unknown"
    newlyFound.gaps = ["Detailed inspection pending."]
    newlyFound.observedAt = Date()
    try db.put(newlyFound, kind: "record", id: newlyFound.id)
    var failed = fairRows.first { $0.id == vanished[0].id }!
    failed.consumer = "unknown"
    failed.gaps = ["Real failed-inspection control"]
    failed.observedAt = Date().addingTimeInterval(-60)
    try db.put(failed, kind: "record", id: failed.id)
    _ = try await service.tick()
    let firstInspection = try await service.snapshot()
    let newlyInspected = firstInspection.records.first { $0.id == newlyFound.id }!
    check(
      !newlyInspected.revision.isEmpty && newlyInspected.gaps.isEmpty,
      "A newly discovered checkout waited behind the failed-inspection backoff")
    equal(
      firstInspection.records.first { $0.id == failed.id }!.observedAt, failed.observedAt,
      "A real inspection failure lost its backoff")
    let ordinary = firstInspection.records.filter {
      !$0.main && !vanished.map(\.id).contains($0.id)
    }
    let readyIDs = Set(ordinary.prefix(3).map(\.id))
    let pendingIDs = Set(ordinary.dropFirst(3).prefix(3).map(\.id))
    let blockedIDs = Set(firstInspection.records.filter { !$0.main }.map(\.id))
      .subtracting(readyIDs).subtracting(pendingIDs)
    for var row in firstInspection.records where !row.main {
      row.blockers = []
      if readyIDs.contains(row.id) {
        row.consumer = "none observed"
        row.gaps = []
        row.observedAt = Date().addingTimeInterval(-125)
      } else if pendingIDs.contains(row.id) {
        row.consumer = "unknown"
        row.revision = ""
        row.gaps = ["Detailed inspection pending."]
        row.observedAt = Date()
      } else {
        row.consumer = "unknown"
        row.gaps = ["Older incomplete fixture"]
        row.observedAt = Date().addingTimeInterval(-901)
      }
      try db.put(row, kind: "record", id: row.id)
    }
    try Data().write(to: single)
    let cohortStart = Date()
    for _ in 0..<3 { _ = try await service.tick() }
    try FileManager.default.removeItem(at: single)
    let progressed = try await service.snapshot().records.filter {
      !$0.main && $0.observedAt >= cohortStart
    }
    equal(progressed.count, 3, "One-row workers fabricated observations for deferred rows")
    for cohort in [readyIDs, pendingIDs, blockedIDs] {
      check(
        progressed.contains { cohort.contains($0.id) }, "One-row batches starved a refresh cohort")
    }
    print(
      "PASS newly discovered rows bypass failure backoff; three one-row native batches advance all cohorts without refreshing deferred rows"
    )
    // Unequal repository backlogs must rotate across batches, including when
    // budget deferral allows only one actual observation per native worker.
    for var row in try await service.snapshot().records {
      row.observedAt = Date()
      row.revision = "previously-inspected-control"
      row.gaps = ["Recent control"]
      try db.put(row, kind: "record", id: row.id)
    }
    var repositoryRows: [WorktreeRecord] = []
    for (name, count) in [("a", 3), ("b", 3), ("c", 3), ("d", 3), ("z", 1)] {
      let repo = base.appendingPathComponent("fair-" + name)
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
      _ = try WorktreeGit.run(repo.path, ["init", "--initial-branch=main"])
      try Data("fixture\n".utf8).write(to: repo.appendingPathComponent("source"))
      _ = try WorktreeGit.run(repo.path, ["add", "."])
      _ = try WorktreeGit.run(
        repo.path,
        [
          "-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m",
          "fixture",
        ])
      for index in 0..<count {
        _ = try WorktreeGit.run(
          repo.path,
          [
            "worktree", "add", "--detach",
            base.appendingPathComponent("fair-\(name)-\(index)").path,
          ])
      }
      let raw = try WorktreeGit.run(repo.path, ["worktree", "list", "--porcelain", "-z"])
      let common = WorkspaceSafety.canonical(
        try WorktreeGit.line(
          repo.path,
          ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
      repositoryRows += try WorktreeDiscovery.parse(raw, repository: common).filter { !$0.main }
    }
    func resetPendingRepositories() throws {
      for var row in repositoryRows {
        row.revision = ""
        row.gaps = ["Detailed inspection pending."]
        row.observedAt = Date()
        try db.put(row, kind: "record", id: row.id)
      }
      try db.put("", kind: "scan", id: "pending-repository")
    }
    try resetPendingRepositories()
    try Data().write(to: single)
    let repositoryIDs = Set(repositoryRows.map(\.id))
    let repositoryStart = Date()
    var served = Set<String>()
    for _ in 0..<5 {
      _ = try await service.tick()
      let actual = try await service.snapshot().records.filter {
        repositoryIDs.contains($0.id) && !$0.revision.isEmpty && $0.observedAt >= repositoryStart
      }
      equal(actual.count, served.count + 1, "Deferred rows received fabricated observations")
      let next = actual.filter { !served.contains($0.repository) }
      equal(next.count, 1, "A pending repository repeated before every repository got a turn")
      if let row = next.first {
        served.insert(row.repository)
        equal(
          try db.value(String.self, kind: "scan", id: "pending-repository"), row.repository,
          "Pending cursor did not follow the actual completed observation")
      }
    }
    equal(served.count, 5, "The small repository starved behind larger pending backlogs")
    try FileManager.default.removeItem(at: single)
    try resetPendingRepositories()
    let batchStart = Date()
    _ = try await service.tick()
    let fullBatch = try await service.snapshot().records.filter {
      repositoryIDs.contains($0.id) && !$0.revision.isEmpty && $0.observedAt >= batchStart
    }
    equal(fullBatch.count, 8)
    equal(
      Set(fullBatch.map(\.repository)).count, 5,
      "Repositories beyond the four reserved slots starved in the spare-slot fill")
    print(
      "PASS five unequal repository backlogs rotate across one-row native batches and all appear in an eight-row batch; cursor follows completed observations only"
    )
    print(
      "PASS externally removed and manually missing checkouts become bounded row-level unknowns; remaining findings refresh without a permanent global error or repeated worker loop"
    )
    await service.shutdown()
  } catch {
    try? FileManager.default.removeItem(at: gate)
    await service.shutdown()
    throw error
  }
  if failures == initialFailures {
    print(
      "PASS actual native consumer snapshot refresh: eight-row bound, ninth-row rotation, preserved discovery cursor, timed-out worker refusal/reaping and successful later observation"
    )
  } else {
    print("FAIL native refresh checks: \(failures - initialFailures) failures")
  }
}
