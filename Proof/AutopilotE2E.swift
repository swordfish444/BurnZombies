import BurnCore
import CryptoKit
import Darwin
import Foundation

/// A real AI sweep against sacrificial fixtures only: an isolated home, a fixture-scoped
/// catalog (only processes this proof starts, only repositories it creates), the real MCP
/// server and the operator's installed harness login.
func autopilotEndToEndProof(root: URL, harness: String, executable: String) async throws {
  let root = root.resolvingSymlinksInPath()
  setenv("BURNZOMBIES_HOME", root.path, 1)
  let fixtures = root.appendingPathComponent("fixtures")
  try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
  func sh(_ command: String, in folder: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = folder
    p.environment = [
      "PATH": "/usr/bin:/bin", "HOME": fixtures.path, "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
      "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com",
    ]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw StoreError.message("fixture failed: \(command)") }
  }

  // Repositories: one origin, a main clone and three copies.
  try sh(
    """
    git init -q --bare origin.git && git clone -q origin.git orbit-web && cd orbit-web && \
    git checkout -q -b main && echo app > app.txt && printf 'node_modules/\\n.env\\n' > .gitignore && \
    printf '{"name":"orbit-web","scripts":{"build":"tsc"}}' > package.json && \
    printf 'Orbit is a disposable web-project fixture. Generated dependencies can be reinstalled.\\n' > README.md && \
    git add . && git commit -q -m init && git push -q origin main && \
    git remote set-head origin main && \
    git worktree add -q -b merged-fix ../orbit-merged main && \
    git worktree add -q -b pushed-idea ../orbit-pushed main && \
    git worktree add -q -b local-draft ../orbit-local main && \
    cd ../orbit-pushed && echo idea > idea.txt && git add idea.txt && git commit -q -m idea && \
    git push -q origin pushed-idea && cd ../orbit-local && echo draft > draft.txt && \
    git add draft.txt && git commit -q -m draft && echo wip >> app.txt && \
    mkdir -p ../orbit-merged/node_modules/left-pad && \
    printf '{}' > ../orbit-merged/node_modules/.package-lock.json && \
    printf '{"name":"left-pad"}' > ../orbit-merged/node_modules/left-pad/package.json && \
    dd if=/dev/zero of=../orbit-merged/node_modules/left-pad/blob bs=1m count=120 2>/dev/null
    """, in: fixtures)
  let common = fixtures.appendingPathComponent("orbit-web/.git").path
  let old = Date().addingTimeInterval(-60 * 86400)
  func record(_ name: String, changes: Int) -> WorktreeRecord {
    var r = WorktreeRecord(
      id: AutopilotItem.hash(name), path: fixtures.appendingPathComponent(name).path,
      repository: common)
    r.branch = "refs/heads/" + name
    r.status = "inspected"
    r.changes = changes
    r.consumer = "none observed"
    r.allocated = 150 << 20
    r.lastFileChange = old
    r.lastCommitAt = old
    return r
  }
  let records = [
    record("orbit-merged", changes: 0), record("orbit-pushed", changes: 0),
    record("orbit-local", changes: 1),
  ]

  // An orphaned helper tree in the fixture project.
  let project = fixtures.appendingPathComponent("orbit-web")
  try "sleep 900 &\nsleep 900 &\necho $$ > helper.pid\nwait\n".write(
    to: project.appendingPathComponent("helper.sh"), atomically: true, encoding: .utf8)
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: root.appendingPathComponent("observation"),
    accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  let starter = Process()
  starter.executableURL = URL(fileURLWithPath: "/bin/sh")
  starter.arguments = ["-c", "/bin/sh helper.sh & sleep 2"]
  starter.currentDirectoryURL = project
  try starter.run()
  usleep(800_000)
  _ = await monitor.refresh()
  starter.waitUntilExit()
  usleep(300_000)
  _ = await monitor.refresh()
  let helperPID = Int32(
    (try String(contentsOf: project.appendingPathComponent("helper.pid"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines))!
  defer { kill(helperPID, SIGKILL) }

  let fixtureRoot = fixtures.resolvingSymlinksInPath().path
  let sources = AutopilotSources(
    processes: { threads in
      AutopilotProcesses.items(
        await monitor.autopilotRecords(), threads: threads,
        protectedPIDs: AgentSafety.ancestors(of: getpid()) ?? []
      ).filter { $0.pid == helperPID }
    },
    worktreeRecords: { records },
    worktrees: { records, threads, cache in
      var delivery = cache
      return (
        AutopilotWorktrees.items(records, threads: threads, delivery: &delivery, budget: 10),
        delivery
      )
    },
    disk: { records in
      AutopilotDisk.items(worktrees: records, home: fixtures.path, sizer: { _ in 120 << 20 })
        .filter { ($0.path ?? "").contains(fixtureRoot) || ($0.path ?? "").contains(fixtures.path) }
    },
    burnProcess: { item, authority, why in
      guard item.pid == helperPID, let key = item.processKey else {
        throw StoreError.message("Outside the fixture scope.")
      }
      return try await monitor.autopilotBurn(
        key, authority: authority, label: item.name, rationale: why)
    },
    processOutcome: { await monitor.autopilotOutcome($0) },
    retireWorktree: { item, authority in
      AutopilotWorktrees.retire(
        item, authority: authority, root: root,
        recoveryKey: SymmetricKey(data: Data(repeating: 0x76, count: 32)))
    },
    restoreWorktree: {
      try AutopilotWorktrees.restore(
        $0, recoveryKey: SymmetricKey(data: Data(repeating: 0x76, count: 32)))
    },
    reclaimDisk: { item, authority in
      AutopilotDisk.reclaim(
        item, authority: authority, home: fixtures.path, root: root,
        recoveryKey: SymmetricKey(data: Data(repeating: 0x76, count: 32)))
    },
    inspect: { AutopilotInspector.inspect($0) },
    evidence: { AutopilotEvidence.read($0, relativePath: $1) })
  // Fixture copies hold a few kilobytes; real ones must be worth it.
  let engine = try Autopilot(root: root, sources: sources, minimumBytes: 0)
  let service = AgentService(monitor: monitor, autopilot: engine)
  let listener = try AgentListener { request in await service.call(request) }
  defer { withExtendedLifetime(listener) {} }

  var snapshot = await engine.tick()
  print("E2E native tick:", snapshot.counts, "questions", snapshot.questions.count)
  check(
    !snapshot.receipts.isEmpty || snapshot.count(.unsure) > 0,
    "starter rules acted or left work for the AI")

  let binaries = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  let config = MachineReviewConfiguration(
    harness: harness, executable: executable,
    launcher: binaries.appendingPathComponent("burnzombies").path,
    server: binaries.appendingPathComponent("burnzombies-mcp").path)
  let started = Date()
  let output = try AutopilotHarness.run(config, root: root, timeout: 600)
  print("E2E AI sweep finished in \(Int(Date().timeIntervalSince(started))) s")
  snapshot = await engine.tick()
  let memory = try AutopilotStore(root: root).memory()
  print(
    "E2E judgments:", memory.judgments.values.map { "\($0.label) → \($0.verdict) \($0.confidence)" }
  )
  print("E2E questions:", snapshot.questions.map(\.question))
  print("E2E receipts:", snapshot.receipts.map { "\($0.name): \($0.outcome) by \($0.authority)" })
  print("E2E log:", snapshot.sweep.log.suffix(6).map(\.message))
  check(!memory.judgments.isEmpty, "the AI recorded verdicts")
  check(snapshot.questions.count <= 3, "at most three open questions")
  check(snapshot.questions.allSatisfy { $0.question.hasSuffix("?") }, "questions are questions")
  check(output.contains("\"is_error\":false"), "harness reported success")
  for receipt in snapshot.receipts where receipt.outcome == "burned" {
    if let restore = receipt.restore {
      check(restore.path.hasPrefix(fixtures.path), "only fixture copies retired")
    }
  }
  // Anything the AI retired must restore.
  if let retired = snapshot.receipts.first(where: { $0.restore != nil && $0.outcome == "burned" }) {
    _ = try await engine.apply(.restore(receiptID: retired.id))
    check(
      FileManager.default.fileExists(atPath: retired.restore!.path), "restored old copy is back")
  }
}

/// Read-only preview on this Mac: what Autopilot would burn, keep and ask with no answers
/// yet. Uses a copy of the worktree inventory and never burns anything.
func autopilotPreview(inventory: URL?) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-preview-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var records = [WorktreeRecord]()
  if let inventory {
    try FileManager.default.copyItem(
      at: inventory, to: root.appendingPathComponent("worktrees.sqlite"))
    records =
      (try WorktreeStore(root: root).values(WorktreeRecord.self, kind: "record", limit: 50_000))
  }
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: root.appendingPathComponent("observation"),
    accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  _ = await monitor.refresh()
  let threads = AgentThreads.index()
  var delivery = [String: AutopilotDelivery]()
  var items = AutopilotProcesses.items(
    await monitor.autopilotRecords(), threads: threads,
    protectedPIDs: AgentSafety.ancestors(of: getpid()) ?? [],
    launchAgents: AutopilotSources.launchAgentPIDs())
  // The live pipeline: size unmeasured copies, assess only what is worth it.
  let sizingStarted = Date()
  let sized = AutopilotSizes().fill(records, budget: 600)
  print(
    "Sized \(records.filter { $0.allocated == 0 }.count) unmeasured copies in \(Int(Date().timeIntervalSince(sizingStarted))) s; \(sized.filter { $0.allocated == 0 && !$0.missing }.count) still unmeasured"
  )
  let worth = sized.filter { $0.allocated >= AutopilotPolicy.worthBytes }
  items += AutopilotWorktrees.items(
    AutopilotAges().fill(worth, limit: worth.count, budget: 600), threads: threads,
    delivery: &delivery, budget: 2000
  )
  .filter { $0.path.map { FileManager.default.fileExists(atPath: $0) } ?? true }
  let junkStarted = Date()
  items += AutopilotDisk.items(worktrees: records)
  print("Junk-folder scan took \(Int(Date().timeIntervalSince(junkStarted))) s")
  let small = items.filter { !AutopilotPolicy.worthAssessing($0) }
  items.removeAll { !AutopilotPolicy.worthAssessing($0) }
  print(
    "Skipped as too small: \(small.count) programs and folders, plus \(sized.filter { $0.allocated > 0 && $0.allocated < AutopilotPolicy.worthBytes }.count) old copies"
  )
  let memory = AutopilotMemory()
  var byStatus = [String: [AutopilotItem]]()
  for item in items {
    byStatus[
      "\(item.kind.rawValue)/\(AutopilotPolicy.decide(item, memory: memory).status.rawValue)",
      default: []
    ]
    .append(item)
  }
  print("Threads: \(threads.count) (\(threads.filter(\.live).count) live)")
  let processRecords = await monitor.autopilotRecords()
  let own = AgentSafety.ancestors(of: getpid()) ?? []
  var reasons = [String: Int]()
  var culprits = [String: Int]()
  for item in items where item.kind == .process {
    guard let reason = item.protectedReason else { continue }
    reasons[reason, default: 0] += 1
    if reason.hasPrefix("Part of it"), let pid = item.pid {
      for child in AutopilotProcesses.descendants(of: pid, in: processRecords) {
        if let why = AutopilotProcesses.rail(child, protectedPIDs: own, preferences: Preferences())
        {
          culprits[child.latest.name + ": " + why, default: 0] += 1
          break
        }
      }
    } else if reason == "It's part of an app you use." || reason == "It's part of macOS." {
      let path =
        processRecords.values.first { $0.latest.identity.pid == item.pid }?.latest.executable ?? ""
      culprits[
        "root " + URL(fileURLWithPath: path).deletingLastPathComponent().path.suffix(70), default: 0
      ] += 1
    }
  }
  for (k, v) in reasons.sorted(by: { $0.value > $1.value }) { print("  reason \(v): \(k)") }
  for (k, v) in culprits.sorted(by: { $0.value > $1.value }).prefix(15) {
    print("  culprit \(v): \(k)")
  }
  for key in byStatus.keys.sorted() {
    let group = byStatus[key]!
    print(
      "\(key): \(group.count) using \(AutopilotPolicy.format(group.reduce(0) { $0 + $1.bytes }))")
    for item in group.sorted(by: { $0.bytes > $1.bytes }).prefix(6) {
      print(
        "   - \(item.name): \(item.facts.filter { $0.key != "kind" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))\(item.protectedReason.map { " [\($0)]" } ?? "")"
      )
    }
  }
  let unsure = items.filter { AutopilotPolicy.decide($0, memory: memory).status == .unsure }
  for q in AutopilotPolicy.proposeQuestions(unsure, memory: memory) {
    let card = AutopilotPolicy.card(q)
    print("Q: \(card.headline) \(card.frees) · \(card.facts.joined(separator: " · "))")
  }
}
