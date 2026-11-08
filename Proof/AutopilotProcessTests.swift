import BurnCore
import Darwin
import Foundation

private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Starts `sh script &` from an outer shell that lingers briefly, so the monitor sees the
/// script with a live parent and then reparented to launchd: an observed orphan with two
/// sleeping children.
private func orphanTree(in folder: URL, monitor: Monitor) async throws -> (
  shell: Int32, children: [Int32]
) {
  let marker = folder.appendingPathComponent("pids")
  let script = folder.appendingPathComponent("helper.sh")
  try "sleep 600 &\na=$!\nsleep 600 &\nb=$!\necho \"$$ $a $b\" > pids\nwait\n".write(
    to: script, atomically: true, encoding: .utf8)
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/sh")
  p.arguments = ["-c", "/bin/sh helper.sh & sleep 2"]
  p.currentDirectoryURL = folder
  try p.run()
  var pids = [Int32]()
  for _ in 0..<50 {
    if let text = try? String(contentsOf: marker, encoding: .utf8) {
      pids = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int32($0) }
      if pids.count == 3 { break }
    }
    usleep(100_000)
  }
  guard pids.count == 3 else { throw StoreError.message("orphan fixture did not start") }
  _ = await monitor.refresh()
  p.waitUntilExit()
  usleep(300_000)
  _ = await monitor.refresh()
  return (pids[0], Array(pids.dropFirst()))
}

func autopilotProcessProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-process-" + UUID().uuidString)
  let folder = root.appendingPathComponent("orbit-web")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: root.appendingPathComponent("state"),
    accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  let fixture = try await orphanTree(in: folder, monitor: monitor)
  defer {
    for pid in [fixture.shell] + fixture.children where alive(pid) { kill(pid, SIGKILL) }
  }
  // A program keeping a CPU core busy is worth assessing even when it is small.
  func spinning(_ cpuSeconds: Double) -> AutopilotItem? {
    let pid: Int32 = 999_990
    let first = Observation(
      identity: ProcessIdentity(pid: pid, seconds: 1), executable: "/tmp/bz-spin/node",
      rss: 30 << 20, cpuNS: 1_000_000_000, monotonic: 100)
    var latest = first
    latest.cpuNS += UInt64(cpuSeconds * 60 * 1e9)
    latest.monotonic += 60
    var record = Record(first)
    record.latest = latest
    record.samples = [first, latest]
    let quiet = AutopilotProcessProbe(
      listening: { _ in false }, agent: { _ in nil }, cwd: { _ in nil }, alive: { _ in false })
    return AutopilotProcesses.items(
      [record.id: record], threads: [], protectedPIDs: [], probe: quiet
    ).first
  }
  equal(spinning(0.5)?.facts["cpu"], "busy", "half a core for a minute")
  equal(spinning(0.05)?.facts["cpu"], "calm", "a twentieth of a core")

  let records = await monitor.autopilotRecords()
  let own = AgentSafety.ancestors(of: getpid()) ?? []
  let items = AutopilotProcesses.items(records, threads: [], protectedPIDs: own)
  guard let item = items.first(where: { $0.pid == fixture.shell }) else {
    failTest("orphaned fixture shell is cataloged")
    return
  }
  equal(item.facts["orphaned"], "yes", "observed reparenting means orphaned")
  // When it really started, for its card's "running for": the fixture started a moment ago.
  if let started = item.started {
    let age: TimeInterval = Date().timeIntervalSince(started)
    check(age >= 0 && age < 120, "the program's start is its real start: \(age) s ago")
  } else {
    failTest("a program BZ catalogs carries when it started")
  }
  equal(item.facts["family"], "shell")
  equal(item.facts["thread"], "none")
  equal(item.facts["listening"], "no")
  equal(item.facts["repo"], "none")
  isNil(item.protectedReason)
  check(item.detail.contains("2 helpers"), item.detail)
  checkFalse(
    items.contains(where: { fixture.children.contains($0.pid ?? -1) }),
    "children ride with their orphan root instead of being separate items")

  // A live chat working in the same folder protects the whole tree.
  let live = AgentThread(
    id: "claude:x", agent: "claude",
    cwd: realpath(folder.path, nil).map { resolved in
      defer { free(resolved) }
      return String(cString: resolved)
    } ?? "",
    live: true,
    lastActive: Date())
  let guarded = AutopilotProcesses.items(records, threads: [live], protectedPIDs: own)
    .first { $0.pid == fixture.shell }
  equal(guarded?.facts["thread"], "live")
  equal(guarded?.protectedReason, "A chat is still working in this project.")

  // A helper a working chat still claims is protected.
  let claimed = AutopilotProcesses.items(
    records, threads: [], protectedPIDs: own, claimed: Set(records.values.filter { $0.latest.identity.pid == fixture.children[0] }.map(\.id)))
    .first { $0.pid == fixture.shell }
  equal(claimed?.protectedReason, "A chat said it still needs this.")

  // Rails: macOS, harnesses and real apps are protected; automation browsers are not.
  func rail(_ path: String) -> String? {
    var o = Observation(identity: ProcessIdentity(pid: 4242, seconds: 1), executable: path)
    o.uid = getuid()
    return AutopilotProcesses.rail(
      Record(o), protectedPIDs: [], preferences: Preferences(), home: "/Users/someone")
  }
  check(rail("/System/Library/CoreServices/thing") != nil, "macOS")
  check(rail("/usr/local/bin/claude") != nil, "harness")
  check(rail("/Applications/Notes.app/Contents/MacOS/Notes") != nil, "real app")
  isNil(
    rail(
      "/Users/someone/Library/Caches/ms-playwright/chromium-1/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
    ))
  isNil(rail("/Users/someone/proj/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"))
  isNil(rail("/opt/homebrew/bin/node"))
  equal(AutopilotProcesses.family("/opt/homebrew/bin/node"), "node")
  equal(AutopilotProcesses.family("/usr/bin/python3"), "python")
  equal(
    AutopilotProcesses.family(
      "/Users/x/Library/Caches/ms-playwright/chromium-1/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
    ), "browser")

  // Listening sockets are a fact now, not a refusal.
  let server = socket(AF_INET, SOCK_STREAM, 0)
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  address.sin_port = 0
  _ = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  listen(server, 1)
  equal(Native().listening(getpid()), true, "own listening socket")
  close(server)
  equal(Native().listening(fixture.children[0]), false, "sleep is not listening")
  check(Native().commandLine(fixture.children[0])?.contains("sleep 600") == true, "command line")

  // Burn: the orphan root and both children get a graceful stop.
  let key = item.processKey!
  let event = try await monitor.autopilotBurn(
    key, authority: "starter:test", label: item.name, rationale: "Fixture orphan.")
  var gone = false
  for _ in 0..<50 {
    if !([fixture.shell] + fixture.children).contains(where: alive) {
      gone = true
      break
    }
    usleep(100_000)
  }
  check(gone, "orphan tree exited after SIGTERM")
  _ = await monitor.refresh()
  let outcome = await monitor.autopilotOutcome(event)
  check(["verifying", "verified"].contains(outcome?.outcome ?? ""), "receipt \(String(describing: outcome))")
  do {
    _ = try await monitor.autopilotBurn(
      key, authority: "starter:test", label: item.name, rationale: "Again.")
    failTest("a stopped process cannot be burned twice")
  } catch {}

  // A program a new install finds that has barely used the CPU since it started has been idle
  // since then, so it needn't be watched for hours before Autopilot can judge it.
  let started = Date().addingTimeInterval(-3 * 86_400)
  let quiet = AutopilotProcessProbe(
    listening: { _ in false }, agent: { _ in nil }, cwd: { _ in nil }, alive: { _ in false })
  func found(cpu seconds: Double, busy: Date? = nil) -> AutopilotItem? {
    var o = Observation(
      identity: ProcessIdentity(pid: 99_991, seconds: UInt64(started.timeIntervalSince1970)),
      executable: "/opt/homebrew/bin/node")
    o.uid = getuid()
    o.parent = 1
    o.cpuNS = UInt64(seconds * 1e9)
    var r = Record(o)
    r.lastBusy = busy
    return AutopilotProcesses.items(
      [o.identity.key: r], threads: [], protectedPIDs: [], probe: quiet
    ).first
  }
  equal(found(cpu: 0.4)?.facts["idle"], "1d", "under a second of CPU in three days: idle since it started")
  equal(found(cpu: 120)?.facts["idle"], "active", "real work since it started: watch it first")
  equal(found(cpu: 0.4, busy: Date())?.facts["idle"], "active", "seen busy just now")

  // A program was last used when it was last busy, or when it started if it never was. It has no
  // title of its own: a card row names it as the item is named.
  let sinceStart = found(cpu: 0.4)
  let startSecond = Date(timeIntervalSince1970: Double(UInt64(started.timeIntervalSince1970)))
  equal(sinceStart?.lastUsed, startSecond, "never busy: last used when it started")
  isNil(sinceStart?.title)
  equal(sinceStart?.name, "node", "a program in no project is named by its program")
  let busyAt = Date().addingTimeInterval(-5_400)
  let wasBusy = found(cpu: 120, busy: busyAt)
  equal(wasBusy?.lastUsed, busyAt, "last used when it was last busy, to the moment")
  equal(wasBusy?.facts["idle"], "1h", "the same moment the idle age comes from")
  // With helpers, the tree was last used when its busiest member was.
  func observation(_ pid: Int32, parent: Int32) -> Observation {
    var o = Observation(
      identity: ProcessIdentity(pid: pid, seconds: UInt64(started.timeIntervalSince1970)),
      executable: "/opt/homebrew/bin/node")
    o.uid = getuid()
    o.parent = parent
    o.cpuNS = 120_000_000_000
    return o
  }
  let parentSeen = observation(99_992, parent: 1)
  let helperSeen = observation(99_993, parent: 99_992)
  var parentRecord = Record(parentSeen)
  parentRecord.lastBusy = Date().addingTimeInterval(-86_400)
  var helperRecord = Record(helperSeen)
  let helperBusy = Date().addingTimeInterval(-1_800)
  helperRecord.lastBusy = helperBusy
  let tree = AutopilotProcesses.items(
    [parentSeen.identity.key: parentRecord, helperSeen.identity.key: helperRecord], threads: [],
    protectedPIDs: [], probe: quiet
  ).first
  equal(tree?.lastUsed, helperBusy, "the helper was busy more recently than its parent")
  equal(tree?.facts["idle"], "10m", "which is also what the idle age says")

  // A program in a project is named with it, and a card row says that, beside who started it.
  let project = root.appendingPathComponent("api")
  for folder in [".git", "src"] {
    try FileManager.default.createDirectory(
      at: project.appendingPathComponent(folder), withIntermediateDirectories: true)
  }
  let inProject = AutopilotProcessProbe(
    listening: { _ in false }, agent: { _ in "codex" }, cwd: { _ in project.path + "/src" },
    alive: { _ in false })
  var big = observation(99_994, parent: 1)
  big.rss = 2 << 30
  big.cpuNS = 400_000_000
  let named = AutopilotProcesses.items(
    [big.identity.key: Record(big)], threads: [], protectedPIDs: [], probe: inProject
  ).first
  equal(named?.facts["repo"], "api")
  equal(named?.name, "node in api")
  isNil(named?.title)
  guard let named, let asked = AutopilotPolicy.proposeQuestions([named], memory: AutopilotMemory()).first
  else { return failTest("a question about the program in a project") }
  equal(asked.rows?.map(\.title), ["node in api"], "the row is the program's name")
  equal(asked.rows?.map(\.subtitle), ["started by Codex"])
}
