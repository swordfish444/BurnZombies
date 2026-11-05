import BurnCore
import CryptoKit
import Darwin
import Foundation

/// A newcomer's first half hour on a fake home of realistic leftovers: the app's real cycle of
/// discovery, inspection and Autopilot, minute by minute on a simulated clock. Programs are
/// limited to the helpers this proof starts; nothing outside `root` is read or changed. With
/// `lookOnly`, the install runs `burnzombies setup --look-only` first, as `install.sh --look-only`
/// does: BZ finds and asks just the same but burns nothing until burning is turned on.
/// Usage: BurnProof --newcomer ROOT [--look-only]
func newcomerProof(root: URL, lookOnly: Bool = false) async throws {
  let fm = FileManager.default
  let home = root.appendingPathComponent("home")
  let state = root.appendingPathComponent("state")
  let remote = root.appendingPathComponent("remote")
  for folder in [home, state, remote] {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
  }
  let day: TimeInterval = 86_400
  func sh(_ command: String, in folder: URL, age: TimeInterval = 0) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = folder
    let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age))
    p.environment = [
      "PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Newcomer", "GIT_AUTHOR_EMAIL": "newcomer@example.com",
      "GIT_COMMITTER_NAME": "Newcomer", "GIT_COMMITTER_EMAIL": "newcomer@example.com",
      "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp,
    ]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw StoreError.message("Fixture failed: \(command)") }
  }
  /// Real allocated bytes, so sizes match what a newcomer's disk holds, cloned from one 100 MB
  /// chunk so the proof writes 100 MB however much it lays out.
  let chunk = root.appendingPathComponent("chunk")
  try sh("dd if=/dev/zero of=\(chunk.path) bs=1m count=100 2>/dev/null", in: root)
  func fill(_ folder: URL, megabytes: Int) throws {
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for part in 0..<(megabytes / 100) {
      try sh(
        "cp -c \(chunk.path) part\(part) 2>/dev/null || cp \(chunk.path) part\(part)", in: folder)
    }
  }
  /// Everything in a copy, its folders included, last changed `age` ago.
  func age(_ folder: URL, _ age: TimeInterval) throws {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMddHHmm.ss"
    try sh(
      "find . -path ./.git -prune -o -exec touch -h -t \(stamp.string(from: Date().addingTimeInterval(-age))) {} +",
      in: folder)
  }

  // An agent-heavy project: three copies merged long ago, two merged this week, one with work
  // only on this Mac from last week and one paused for weeks, each holding rebuildable packages.
  let git = home.appendingPathComponent("git")
  try fm.createDirectory(at: git, withIntermediateDirectories: true)
  try sh("git init -q --bare acme-web.git", in: remote)
  try sh(
    "git clone -q \(remote.path)/acme-web.git acme-web && cd acme-web && git checkout -q -b main && echo app > app.txt && printf 'node_modules/\\n' > .gitignore && git add . && git commit -q -m init && git push -q origin main && git remote set-head origin main",
    in: git, age: 60 * day)
  let main = git.appendingPathComponent("acme-web")
  let copies: [(name: String, age: TimeInterval, megabytes: Int, merged: Bool)] = [
    ("acme-old-1", 40 * day, 300, true), ("acme-old-2", 45 * day, 300, true),
    ("acme-old-3", 50 * day, 300, true), ("acme-recent-1", 2 * day, 600, true),
    ("acme-recent-2", 3 * day, 600, true), ("acme-wip", 10 * day, 200, false),
    ("acme-paused", 20 * day, 400, false),
  ]
  for copy in copies {
    try sh("git worktree add -q -b \(copy.name) ../\(copy.name) main", in: main, age: copy.age)
    let folder = git.appendingPathComponent(copy.name)
    try sh(
      "echo \(copy.name) > \(copy.name).txt && git add . && git commit -q -m \(copy.name)",
      in: folder, age: copy.age)
    if copy.merged {
      try sh(
        "git merge -q --no-edit \(copy.name) && git push -q origin main", in: main, age: copy.age)
    }
    try fill(folder.appendingPathComponent("node_modules/pkg"), megabytes: copy.megabytes)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("node_modules/.package-lock.json"))
    try Data("{}".utf8).write(to: folder.appendingPathComponent("node_modules/pkg/package.json"))
    try age(folder, copy.age)
  }
  // A big Xcode build cache from today.
  try fill(
    home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Acme-abc/Build"),
    megabytes: 1200)

  // An orphaned helper tree from a finished agent run.
  try "sleep 1800 &\nsleep 1800 &\necho $$ > helper.pid\nwait\n".write(
    to: main.appendingPathComponent("helper.sh"), atomically: true, encoding: .utf8)
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: home, root: state, accessCheck: fixtureAccess,
    discoveryWalker: fixtureWalker(), worktreeRecoveryKey: { SymmetricKey(size: .bits256) })
  let starter = Process()
  starter.executableURL = URL(fileURLWithPath: "/bin/sh")
  starter.arguments = ["-c", "/bin/sh helper.sh & sleep 2"]
  starter.currentDirectoryURL = main
  // The helpers must not hold the caller's output open after the proof ends.
  starter.standardOutput = FileHandle.nullDevice
  starter.standardError = FileHandle.nullDevice
  try starter.run()
  usleep(800_000)
  _ = await monitor.refresh()
  starter.waitUntilExit()
  let helper =
    Int32(
      (try String(contentsOf: main.appendingPathComponent("helper.pid"), encoding: .utf8))
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  defer {
    let children = Process()
    children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    children.arguments = ["-KILL", "-P", String(helper)]
    try? children.run()
    children.waitUntilExit()
    kill(helper, SIGKILL)
  }

  if lookOnly {
    let setup = Process()
    setup.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent().appendingPathComponent("burnzombies")
    setup.arguments = ["setup", "--harness", "none", "--look-only", "--root", state.path]
    setup.standardOutput = FileHandle.nullDevice
    try setup.run()
    setup.waitUntilExit()
    guard setup.terminationStatus == 0 else { throw StoreError.message("Look-only setup failed.") }
  }
  var sources = AutopilotSources.live(
    monitor: monitor, root: state, home: home.path,
    recoveryKey: SymmetricKey(data: Data(repeating: 0x71, count: 32)))
  let live = sources.processes
  sources.processes = { threads in await live(threads).filter { $0.pid == helper } }
  let liveBurn = sources.burnProcess
  sources.burnProcess = { item, authority, why in
    guard item.pid == helper else { throw StoreError.message("Outside the sandbox.") }
    return try await liveBurn(item, authority, why)
  }
  let engine = try Autopilot(root: state, sources: sources)
  let coordinator = AutopilotCoordinator(root: state, engine: engine, configuration: { nil })
  let store = try AutopilotStore(root: state)

  // The app's cycle: sample, inventory, Autopilot; every minute on a simulated clock.
  let start = Date()
  var firstFound: Int?
  var firstQuestion: Int?
  var firstBurn: Int?
  var receipts = 0
  var last = AutopilotSnapshot()
  var firstNumber: Int?
  var junkCleared: Int?
  var finishedBurned: Int?
  let finished = Set(copies.filter { $0.merged && $0.age >= 30 * day }.map(\.name))
  let paused = git.appendingPathComponent("acme-paused")
  var previous = ""
  for minute in 0...31 {
    let now = start.addingTimeInterval(Double(minute) * 60)
    _ = await monitor.refresh()
    let inventory = Task { await monitor.worktreeTick() }
    if minute > 0 { await inventory.value }
    let snapshot = await coordinator.tick(now: now)
    if minute == 0 { await inventory.value }
    let view = await monitor.snapshot()
    let numbers = ImpactNumbers.make(
      catalog: view.catalog, autopilot: try store.impact(), period: .today, now: now)
    let kinds = Dictionary(grouping: snapshot.entries, by: { $0.item.kind.rawValue })
      .mapValues(\.count)
    let burned = snapshot.receipts.filter { $0.outcome == "burned" }
    let line =
      "catalog \(kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) · unsure \(snapshot.count(.unsure)) · questions \(snapshot.questions.count) · burned \(burned.count) · panel: disk \(AutopilotPolicy.format(numbers.disk)), worktrees \(numbers.worktrees), zombies \(numbers.count)"
    if line != previous {
      print("t+\(minute)m  \(line)")
      for question in snapshot.questions {
        print(
          "        question: \(AutopilotPolicy.card(question).headline) \(AutopilotPolicy.card(question).frees)"
        )
      }
      previous = line
    }
    if firstFound == nil, !snapshot.entries.isEmpty { firstFound = minute }
    if firstQuestion == nil, !snapshot.questions.isEmpty { firstQuestion = minute }
    receipts = max(receipts, snapshot.receipts.count)
    last = snapshot
    if firstBurn == nil, !burned.isEmpty { firstBurn = minute }
    if finishedBurned == nil,
      finished.isSubset(of: Set(burned.filter { $0.kind == .worktree }.map(\.name)))
    {
      finishedBurned = minute
    }
    let shown = numbers.disk > 0 || numbers.memory > 0 || numbers.count > 0 || numbers.worktrees > 0
    if firstNumber == nil, shown {
      firstNumber = minute
    }
    if junkCleared == nil,
      !fm.fileExists(atPath: paused.appendingPathComponent("node_modules").path)
    {
      junkCleared = minute
    }
    // A real minute leaves background work, like measuring junk folders, plenty of time; a
    // simulated one leaves it a quarter of a second.
    try await Task.sleep(nanoseconds: 250_000_000)
  }
  if lookOnly {
    try await lookOnlyAfterward(
      firstFound: firstFound, firstQuestion: firstQuestion, firstBurn: firstBurn,
      firstNumber: firstNumber, junkCleared: junkCleared, receipts: receipts, last: last,
      engine: engine, store: store, git: git, helper: helper,
      at: start.addingTimeInterval(32 * 60), started: start)
    return
  }
  print(
    "NEWCOMER first question: \(firstQuestion.map { "t+\($0)m" } ?? "none") · first burn: \(firstBurn.map { "t+\($0)m" } ?? "none") · copies merged over a month ago burned: \(finishedBurned.map { "t+\($0)m" } ?? "never") · first non-zero panel number: \(firstNumber.map { "t+\($0)m" } ?? "none") · junk in a paused copy: \(junkCleared.map { "t+\($0)m" } ?? "kept") · sandbox ran \(Int(Date().timeIntervalSince(start))) s"
  )
  // Time to value: within two minutes a newcomer has a question, a burn and a number on the
  // panel; within three the copies merged over a month ago are burned and junk inside a copy paused
  // for weeks goes, while the copy's work stays.
  check((firstQuestion ?? .max) <= 2, "first question within 2 minutes")
  check((firstBurn ?? .max) <= 2, "first burn within 2 minutes")
  check((firstNumber ?? .max) <= 2, "first number on the panel within 2 minutes")
  check((finishedBurned ?? .max) <= 3, "copies merged over a month ago burned within 3 minutes")
  check((junkCleared ?? .max) <= 3, "junk inside a copy paused for weeks cleared within 3 minutes")
  check(
    fm.fileExists(atPath: paused.appendingPathComponent("acme-paused.txt").path),
    "the paused copy's work stays")
  check(
    fm.fileExists(atPath: git.appendingPathComponent("acme-wip/acme-wip.txt").path),
    "work only on this Mac stays")
}
/// The look-only half of the newcomer proof: the first half hour found and asked but burned and
/// wrote nothing; then Start burning (the panel's tap or Settings) burns what waited right away.
private func lookOnlyAfterward(
  firstFound: Int?, firstQuestion: Int?, firstBurn: Int?, firstNumber: Int?, junkCleared: Int?,
  receipts: Int, last: AutopilotSnapshot, engine: Autopilot, store: AutopilotStore, git: URL,
  helper: Int32, at now: Date, started: Date
) async throws {
  let fm = FileManager.default
  let paused = git.appendingPathComponent("acme-paused")
  let copies = [
    "acme-old-1", "acme-old-2", "acme-old-3", "acme-recent-1", "acme-recent-2", "acme-wip",
    "acme-paused",
  ]
  let wouldBurn = last.bytes[AutopilotStatus.burn.rawValue] ?? 0
  print(
    "LOOK-ONLY first find: \(firstFound.map { "t+\($0)m" } ?? "none") · first question: \(firstQuestion.map { "t+\($0)m" } ?? "none") · burns in 31 minutes: \(firstBurn == nil ? 0 : 1) · receipts: \(receipts) · would burn \(last.count(.burn)) things, \(AutopilotPolicy.format(wouldBurn))"
  )
  check((firstFound ?? .max) <= 2, "look-only: finds things within 2 minutes")
  check((firstQuestion ?? .max) <= 2, "look-only: first question within 2 minutes")
  check(firstBurn == nil, "look-only: nothing burned in the first half hour")
  equal(receipts, 0, "look-only: no receipts")
  equal(try store.receipts().count, 0, "look-only: nothing written to the receipts")
  check(firstNumber == nil, "look-only: the panel's totals stay at zero")
  check(junkCleared == nil, "look-only: junk inside the paused copy stays")
  check(
    copies.allSatisfy { fm.fileExists(atPath: git.appendingPathComponent($0).path) },
    "look-only: every copy stays")
  check(kill(helper, 0) == 0, "look-only: the helper keeps running")
  check(last.count(.burn) > 0, "look-only: BZ shows what it would burn")
  let names: Set<String> = ["acme-old-1", "acme-old-2", "acme-old-3"]
  check(
    names.isSubset(
      of: Set(
        last.entries.filter { $0.item.kind == .worktree && $0.status == .burn }.map(\.item.name))),
    "look-only: the copies merged over a month ago are among what BZ would burn")
  // BZ lists folders by their real path: /private/var, not /var.
  let junk = WorkspaceSafety.canonical(paused.appendingPathComponent("node_modules").path)
  check(
    last.entries.contains { $0.item.path == junk && $0.status == .burn },
    "look-only: the paused copy's junk is among what BZ would burn")
  equal(last.sweep.lookOnly, true, "look-only: the snapshot says so")

  // Start burning: what waited burns right away, without waiting for the next look.
  let switched = Date()
  _ = try await engine.apply(.setLookOnly(false), now: now)
  let merged = names.map { git.appendingPathComponent($0).path }
  // A copy's receipt is written just after its folder goes, so wait for the receipts too.
  var burned = [AutopilotReceipt]()
  let deadline = Date().addingTimeInterval(180)
  while Date() < deadline {
    burned = try store.receipts().filter { $0.outcome == "burned" || $0.outcome == "verifying" }
    let copies = Set(burned.filter { $0.kind == .worktree }.map(\.name))
    let junkGone = !fm.fileExists(atPath: junk)
    if names.isSubset(of: copies) && junkGone && !merged.contains(where: fm.fileExists(atPath:)) {
      break
    }
    try await Task.sleep(nanoseconds: 250_000_000)
  }
  print(
    "LOOK-ONLY after Start burning: \(burned.count) burned in \(Int(Date().timeIntervalSince(switched))) s · sandbox ran \(Int(Date().timeIntervalSince(started))) s"
  )
  check(
    names.isSubset(of: Set(burned.filter { $0.kind == .worktree }.map(\.name))),
    "after Start burning: each merged copy burns, with its receipt")
  check(!fm.fileExists(atPath: junk), "after Start burning: junk inside the paused copy goes")
  check(
    !merged.contains(where: fm.fileExists(atPath:)), "after Start burning: the merged copies go")
  check(
    fm.fileExists(atPath: paused.appendingPathComponent("acme-paused.txt").path),
    "the paused copy's work stays")
  check(
    fm.fileExists(atPath: git.appendingPathComponent("acme-wip/acme-wip.txt").path),
    "work only on this Mac stays")
}
