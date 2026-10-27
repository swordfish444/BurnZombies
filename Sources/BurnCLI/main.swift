import BurnCore
import AppKit
import CBurn
import Darwin
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
func json<T: Encodable>(_ value: T) throws {
  let e = JSONEncoder()
  e.outputFormatting = [.prettyPrinted, .sortedKeys]
  print(String(decoding: try e.encode(value), as: UTF8.self))
}
let args = Array(CommandLine.arguments.dropFirst())
do {
  switch args.first ?? "help" {
  case "start-observer":
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app" else { fail("Start observer from the installed app bundle.") }
    let previous = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
    for running in previous {
      guard running.terminate() else { fail("Could not close the previous BurnZombies observer. Quit it and reopen BurnZombies to finish upgrading.") }
    }
    for _ in 0..<50 {
      if previous.allSatisfy({ $0.isTerminated }) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard previous.allSatisfy({ $0.isTerminated }) else { fail("Previous observer is still closing. No force stop or reopen event was sent.") }
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false; configuration.hides = true
    let _: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
      NSWorkspace.shared.openApplication(at: app, configuration: configuration) { application, error in
        if let application { continuation.resume(returning: application) }
        else { continuation.resume(throwing: error ?? StoreError.message("Could not start the background observer.")) }
      }
    }
  case "review-worker":
    guard args.count >= 3, args[1] == "--", args[2].hasPrefix("/") else { fail("Internal worker requires an absolute harness executable.") }
    let words = args.dropFirst(2).map { strdup($0) }
    defer { words.forEach { free($0) } }
    var pointers = words + [nil]
    exit(bz_review_worker(&pointers, 180))
  case "lifecycle", "workspace":
    guard args.count == 1, let data = try FileHandle.standardInput.read(upToCount: 16385) else {
      fail("Pass one lifecycle JSON object on stdin.")
    }
    let raw = try AgentConnection.call(args[0] == "workspace" ? WorkspaceInput.request(data) : LifecycleInput.request(data))
    print(raw, terminator: "")
    if let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], result["ok"] as? Bool != true { exit(1) }
  case "evidence":
    guard args.count >= 2, args.count <= 17,
      args.dropFirst().allSatisfy({ Int32($0).map { $0 > 0 } ?? false }) else { fail("Use evidence PID [PID ...], up to 16 exact helper PIDs.") }
    print(try AgentConnection.call(AgentRequest("inspect", pids: args.dropFirst().compactMap(Int32.init))), terminator: "")
  case "install-skill":
    try LifecycleSkillInstall.run(Array(args.dropFirst()))
  case "setup":
    try MachineSetup.run(Array(args.dropFirst()))
  case "review-once":
    let reviewer = try MachineReviewer()
    try await reviewer.resume()
    try HarnessHook.requestCleanup()
    await reviewer.tick()
    try json(await reviewer.snapshot())
  case "help", "--help", "-h":
    print(
      """
      BurnZombies 0.7.1
      evidence PID [PID ...]   Read exact helper identities; no process is stopped.
      workspace   Read one create/release/retain JSON object; manage disposable worktree ownership.
      lifecycle   Read one register/release/retain JSON object from stdin; never stops processes.
      install-skill [--home PATH] [--skill-file PATH]   Install portable lifecycle instructions only.
      setup [--harness auto|codex|claude|cursor|copilot|gemini|none] [--model ID|default] [--thinking LEVEL|default]
        Enable computer-wide background reviews. No chat hooks or live config edits.
      install [--harness auto|all|codex|claude|cursor|copilot|gemini] [--mcp-only]
        Connect installed harnesses. MCP-only mode preserves hooks and permissions.
      hook --client NAME --event EVENT
        Native lifecycle adapter. Emits context only; never stops processes.
      run --label NAME [--allow-cleanup] -- /absolute/command [arguments]
        Track this NEW command and observed descendants. Opt in only for disposable,
        noninteractive helpers. Standard streams pass through. Arguments are not saved.
      scan     Aggregate visibility and scanner timing; no private process list.
      status   Aggregate saved catalog totals; does not start a monitor.
      measure PID SECONDS   Aggregate CPU, footprint, wakeups, and writes (10–3600s).
      fixture-tree orphan|detached|hung
        Sacrificial 48 MiB helper, hard lifetime 20 minutes. Tests only.
      BURNZOMBIES_HOME overrides the private state directory for isolated tests.
      """)
  case "install":
    try HarnessInstall.run(Array(args.dropFirst()))
  case "hook":
    // Invalid/missing context must never disrupt the user's work.
    do {
      guard let ci = args.firstIndex(of: "--client"), ci + 1 < args.count,
        let ei = args.firstIndex(of: "--event"), ei + 1 < args.count,
        let data = try FileHandle.standardInput.read(upToCount: 1_048_576),
        let input = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { print("{}"); exit(0) }
      let output = try HarnessHook.response(client: args[ci + 1], event: args[ei + 1], input: input)
      let encoded = try JSONSerialization.data(withJSONObject: output, options: .sortedKeys)
      print(String(decoding: encoded, as: UTF8.self))
    } catch { print("{}") }
  case "scan":
    let start = ProcessInfo.processInfo.systemUptime
    let s = Native().scan()
    try json([
      "visibleOwnUserProcesses": Double(s.observations.count), "hiddenProcesses": Double(s.hidden),
      "partial": s.partial ? 1 : 0,
      "durationMS": (ProcessInfo.processInfo.systemUptime - start) * 1000,
    ])
  case "measure":
    guard args.count == 3, let pid = Int32(args[1]), let duration = Double(args[2]), duration >= 10,
      duration <= 3600,
      case .found(let initial) = Native().probe(pid)
    else { fail("Use measure PID SECONDS (10–3600), for a visible running process.") }
    var first = [UInt64](repeating: 0, count: 6)
    guard bz_usage(pid, &first) == 0 else { fail("Resource counters unavailable.") }
    let start = Double(bz_continuous_ns()) / 1e9
    var peak = first[1]
    var last = first
    var count = 1
    while Double(bz_continuous_ns()) / 1e9 - start < duration {
      pause(min(10, duration - (Double(bz_continuous_ns()) / 1e9 - start)))
      guard case .found(let current) = Native().probe(pid), current.identity == initial.identity,
        bz_usage(pid, &last) == 0
      else { fail("Target exited or identity/visibility changed; measurement incomplete.") }
      peak = max(peak, last[1])
      count += 1
    }
    let elapsed = Double(bz_continuous_ns()) / 1e9 - start
    try json([
      "elapsedSeconds": elapsed, "samples": Double(count),
      "cpuPercentOneCore": Double(last[0] - first[0]) / 1e9 / elapsed * 100,
      "physicalFootprintStartMiB": Double(first[1]) / 1_048_576,
      "physicalFootprintEndMiB": Double(last[1]) / 1_048_576,
      "physicalFootprintPeakMiB": Double(peak) / 1_048_576,
      "interruptWakeupsPerSecond": Double(last[2] - first[2]) / elapsed,
      "packageIdleWakeupsPerSecond": Double(last[3] - first[3]) / elapsed,
      "diskWrittenBytes": Double(last[4] - first[4]),
      "logicalWrittenBytes": Double(last[5] - first[5]),
    ])
  case "status":
    let c = try Store().load()
    try json([
      "catalogRecords": c.records.count, "recentActions": c.events.count,
      "lifetimeVerifiedHelpers": c.lifetimeVerified, "lifetimeVerifiedActions": c.lifetimeActions,
    ])
  case "fixture-tree":
    guard args.count == 2, ["orphan", "detached", "hung"].contains(args[1]) else {
      fail("Choose orphan, detached, or hung.")
    }
    exit(bz_fixture(args[1]))
  case "run":
    guard let delimiter = args.firstIndex(of: "--"), delimiter + 1 < args.count,
      let li = args.firstIndex(of: "--label"), li + 1 < delimiter
    else { fail("Use run --label NAME [--allow-cleanup] -- /absolute/command [arguments].") }
    let command = args[delimiter + 1]
    guard command.hasPrefix("/") else {
      fail("Use an absolute executable path. No implicit shell evaluation.")
    }
    let store = try Store()
    let native = Native()
    // Serialize admission; concurrent wrappers cannot exceed the registration budget.
    var admission: InstanceLock? = try InstanceLock(
      url: store.root.appendingPathComponent("admission.lock"))
    try store.pruneLeases(now: Date(), native: native)
    guard try store.leases().count < 256 else {
      fail("The 256-session budget is full. No command launched.")
    }
    guard case .found(let owner) = native.probe(getpid()) else {
      fail("Cannot establish wrapper identity.")
    }
    var lease = Lease(
      label: args[li + 1], owner: owner.identity, members: [],
      allowCleanup: args[..<delimiter].contains("--allow-cleanup"))
    try store.saveLease(lease)
    withExtendedLifetime(admission) {}
    admission = nil
    bz_watch_signals()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: command)
    child.arguments = Array(args.dropFirst(delimiter + 2))
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    try child.run()
    var cancellation: Date?
    var known = Set<ProcessIdentity>()
    if case .found(let root) = native.probe(child.processIdentifier) {
      lease.members.append(Member(root))
      known.insert(root.identity)
      try store.saveLease(lease)
    }
    while child.isRunning {
      let scan = native.scan()
      var changed = true
      var added = false
      while changed {
        changed = false
        let liveKnown = Set(
          scan.observations.filter { known.contains($0.identity) }.map { $0.identity.pid })
        for o in scan.observations where liveKnown.contains(o.parent) && !known.contains(o.identity)
        {
          guard lease.members.count < 512 else {
            lease.allowCleanup = false
            continue
          }
          known.insert(o.identity)
          lease.members.append(Member(o))
          changed = true
          added = true
        }
      }
      if scan.partial {
        lease.allowCleanup = false
        added = true
      }
      if added { try store.saveLease(lease) }
      if bz_interrupted() != 0 && cancellation == nil {
        cancellation = Date()
        for member in lease.members {
          if case .found(let o) = native.probe(member.identity.pid), o.identity == member.identity {
            _ = native.terminate(o)
          }
        }
      }
      if let cancel = cancellation, Date().timeIntervalSince(cancel) > 15 { break }
      pause(1)
    }
    lease.ended = Date()
    try store.saveLease(lease)
    if child.isRunning {
      fail("Graceful cancellation timed out. No force kill. Review the activity in BurnZombies.")
    }
    child.waitUntilExit()
    exit(child.terminationStatus)
  default: fail("Unknown command. Run burnzombies --help.")
  }
} catch { fail(error.localizedDescription) }
