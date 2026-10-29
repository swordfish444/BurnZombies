import BurnCore
import Darwin
import Foundation

// Explicit capability injection belongs only to the isolated proof executable.
func fixtureAccess() -> FullDiskAccessStatus { .init(state: .granted, detail: "Isolated fixture") }
func fixtureWalker() -> DiskWalkRunner {
  DiskWalkRunner(
    executable: URL(fileURLWithPath: CommandLine.arguments[0]),
    argumentPrefix: ["--disk-walk-worker"])
}

// A dependency-free test runner: also works with Apple's Command Line Tools alone.
class TestSuite {}
var failures = 0
func failTest(_ message: String) {
  failures += 1
  print("FAIL: \(message)")
}
func check(_ value: @autoclosure () -> Bool, _ message: String = "expected true") {
  if !value() { failTest(message) }
}
func checkFalse(_ value: @autoclosure () -> Bool, _ message: String = "expected false") {
  if value() { failTest(message) }
}
func equal<T: Equatable>(_ a: T, _ b: T, _ message: String = "values differ") {
  if a != b { failTest(message) }
}
func notEqual<T: Equatable>(_ a: T, _ b: T) { if a == b { failTest("unexpected equality") } }
func isNil<T>(_ value: T?) { if value != nil { failTest("expected nil") } }
func throwsError<T>(_ expression: @autoclosure () throws -> T) {
  do {
    _ = try expression()
    failTest("expected error")
  } catch {}
}

@main struct ProofRunner {
  static func main() async {
    setbuf(stdout, nil)
    if CommandLine.arguments.contains("--worktree-hunt-refresh") {
      do { try await worktreeHuntRefreshProof() } catch {
        failTest("Worktree Hunt refresh: \(error)")
      }
      print("Worktree Hunt refresh checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--worktree-visibility") {
      do { try worktreeVisibilityProof() } catch { failTest("Worktree visibility: \(error)") }
      print("Worktree visibility checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--process-integration") {
      do { try await integration() } catch { failTest("Process integration: \(error)") }
      print("Process integration checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--worktree-native-status") {
      let snapshot = WorktreeConsumerSnapshot()
      print(
        "Native consumer paths: \(snapshot.paths.count); coverage: \(snapshot.gap ?? "complete")")
      return
    }
    if CommandLine.arguments.contains("--worktree-native-descriptors") {
      do { try await worktreeNativeProof(descriptorOnly: true) } catch {
        failTest("Native descriptor coverage: \(error)")
      }
      print("Native descriptor checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--worktree-native") {
      do {
        try worktreeVisibilityProof()
        try await worktreeNativeProof()
      } catch { failTest("Native worktrees: \(error)") }
      print("Native worktree checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--worktree-keychain") {
      do { try worktreeKeychainProof() } catch { failTest("Worktree Keychain: \(error)") }
      print("Worktree Keychain checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--worktree-scale") {
      do { try worktreeScaleProof() } catch { failTest("Worktree scale: \(error)") }
      print("Worktree scale checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.firstIndex(of: "--worktree-scan-worker") == 1 {
      exit(
        WorktreeScanWorker.run(
          arguments: Array(CommandLine.arguments.dropFirst(2)), access: fixtureAccess))
    }
    if CommandLine.arguments.contains("--worktree-lifecycle") {
      do {
        try await worktreeLifecycleProof()
        try await worktreeSafetyProof()
      } catch { failTest("Worktree lifecycle: \(error)") }
      print("Worktree lifecycle checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.firstIndex(of: "--disk-walk-worker") == 1 {
      exit(
        DiskWalkWorker.run(
          arguments: Array(CommandLine.arguments.dropFirst(2)), accessCheck: fixtureAccess))
    }
    if CommandLine.arguments.firstIndex(of: "--disk-walk-fixture") == 1 {
      do { try diskWalkFixture() } catch {
        print("Disk worker fixture: \(error)")
        exit(1)
      }
    }
    if CommandLine.arguments.contains("--full-disk-access") {
      do { try await fullDiskAccessProof() } catch { failTest("Full Disk Access: \(error)") }
      print("Full Disk Access checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--disk-worker") {
      do { try await diskWorkerProof() } catch { failTest("Disk worker: \(error)") }
      print("Disk worker checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--owner-agent-fixture" {
      do {
        try await runOwnerHarnessFixture(root: URL(fileURLWithPath: CommandLine.arguments[2]))
      } catch {
        print("FAIL: \(error)")
        exit(1)
      }
      return
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--review-owner-model" {
      do { try runOwnerHarnessReview(root: URL(fileURLWithPath: CommandLine.arguments[2])) } catch {
        print("FAIL: \(error)")
        exit(1)
      }
      return
    }
    if CommandLine.arguments.contains("--owner-maintenance") {
      do {
        try await ownerMaintenanceProof()
        try await agentBridgeProof()
      } catch { failTest("Owner maintenance: \(error)") }
      print("Owner maintenance checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--gradle-daemon") {
      do { try await gradleDaemonProof() } catch { failTest("Gradle daemon: \(error)") }
      print("Gradle checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--owner-inspect") {
      do { try gradleOwnerInspectionCLI() } catch {
        print("Owner inspection: \(error)")
        exit(1)
      }
      exit(0)
    }
    if CommandLine.arguments.contains("--gradle-fixture") {
      do { try gradleFixtureCLI() } catch {
        let value: [String: Any] = ["ok": false, "error": String(describing: error)]
        if let data = try? JSONSerialization.data(withJSONObject: value) {
          print(String(decoding: data, as: UTF8.self))
        }
        exit(1)
      }
      exit(0)
    }
    if CommandLine.arguments.contains("--managed-cache") {
      do { try managedCacheProof() } catch { failTest("Managed cache: \(error)") }
      print("Managed cache checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--cache-inspect")
      || CommandLine.arguments.contains("--cache-contract")
    {
      do { try managedCacheInspectionCLI() } catch {
        print("Cache inspection: \(error)")
        exit(1)
      }
      exit(0)
    }
    if CommandLine.arguments.contains("--transport") {
      do { try await transportProof() } catch { failTest("Transport: \(error)") }
      print("Transport checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--mole-leaf-fixture") {
      alarm(10)
      signal(SIGTERM, SIG_IGN)
      while true { pause() }
    }
    if CommandLine.arguments.contains("--mole-hang-fixture") {
      alarm(10)
      signal(SIGTERM, SIG_IGN)
      var argv =
        [CommandLine.arguments[0], "--mole-leaf-fixture"].map { (value: String) in
          value.withCString { strdup($0) }
        } + [nil]
      var environment = [strdup("PATH=/usr/bin:/bin"), nil]
      var child: pid_t = -1
      let code = posix_spawn(&child, argv[0]!, nil, nil, &argv, &environment)
      argv.forEach { free($0) }
      environment.forEach { free($0) }
      guard code == 0, child > 0 else { exit(2) }
      print("\(getpid()) \(child)")
      while true { pause() }
    }
    if CommandLine.arguments.contains("--mole-output-fixture") {
      alarm(10)
      try? FileHandle.standardOutput.write(contentsOf: Data(repeating: 65, count: 131072))
      while true { pause() }
    }
    if CommandLine.arguments.contains("--mole-proof") {
      do { try moleIntegrationProof() } catch { failTest("Mole integration: \(error)") }
      print("Mole integration checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--disk-discovery") {
      do { try diskDiscoveryProof() } catch { failTest("Disk discovery: \(error)") }
      print("Disk discovery checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--measure-disk" {
      do {
        let nodes = try DiskDiscovery.measure(CommandLine.arguments[2])
        let data = try JSONEncoder().encode(nodes)
        print(String(decoding: data, as: UTF8.self))
      } catch {
        print("FAIL: \(error)")
        exit(1)
      }
      return
    }
    if CommandLine.arguments.contains("--passive-child") {
      Thread.sleep(forTimeInterval: 120)
      return
    }
    if CommandLine.arguments.contains("--passive-usage") {
      do {
        try usageProof()
        try await passiveProof()
        try await diskProof()
      } catch { failTest("Passive/usage: \(error)") }
      print("Passive/usage checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--review-economy") {
      do { try await machineReviewProof() } catch { failTest("Review economy: \(error)") }
      print("Review economy checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--worktrees") {
      do {
        try await worktreeLifecycleProof()
        try await worktreeSafetyProof()
      } catch { failTest("Worktree lifecycle: \(error)") }
      do { try await workspaceProof() } catch { failTest("Worktree cleanup: \(error)") }
      print("Worktree checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--impact-metrics") {
      do {
        try impactMetricsProof()
        try impactPeriodProof()
      } catch { failTest("Impact metrics: \(error)") }
      print("Impact metrics and period checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if [5, 6].contains(CommandLine.arguments.count) && CommandLine.arguments[1] == "--review-model"
    {
      do {
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let config = try MachineReviewConfiguration.load(root: root) else {
          throw StoreError.message("Missing proof config")
        }
        let prompt =
          CommandLine.arguments[4] == "--production"
          ? MachineReviewer.prompt
          : try String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8)
        let ids =
          CommandLine.arguments.count == 6
          ? try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5])))
          : nil
        try MachineReviewer.execute(
          config, root: root, prompt: prompt, reviewIDs: ids, accessCheck: fixtureAccess)
      } catch {
        print("FAIL: \(error)")
        exit(1)
      }
      return
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--agent-fixture" {
      do { try await runAgentFixture(root: URL(fileURLWithPath: CommandLine.arguments[2])) } catch {
        print("FAIL: \(error)")
        exit(1)
      }
      return
    }
    let d = SafetyTests()
    let s = StorageNativeTests()
    let pressure = PressureTests()
    let tests: [(String, () throws -> Void)] = [
      ("owner-managed BuildKit cleanup plans and receipts", managedCacheProof),
      (
        "whole-machine disk discovery, APFS clones, grouped advice and scope safety",
        diskDiscoveryProof
      ),
      ("cumulative awake CPU savings and stable nonnegative speed impact", impactMetricsProof),
      (
        "impact periods, completion dates, DST, empty history and preview accounting",
        impactPeriodProof
      ),
      (
        "review model/effort migration, persistence, provider arguments and defaults",
        reviewSelectionProof
      ),
      ("agent execution safety boundaries", d.testExecutionBoundaries),
      ("owner-scoped recurrence", d.testRecurrenceScope),
      ("checkpoint", s.testCheckpointRoundTripAndPermissions),
      ("corruption", s.testCorruptionFailsClosed), ("symlink", s.testSymlinkReadRejected),
      ("single instance", s.testOnlyOneMonitorOwnsCatalog),
      ("retention", s.testRetentionCapsRecordsAndEvents),
      ("native process identity", s.testActualProcessIdentityAndGracefulStop),
      ("storage budget", s.testPrivateBudgetEnforced),
      ("verification failure and respawn", s.testVerificationFailureAndRecurrence),
      ("interrupted verification", s.testInterruptedVerificationGetsNoCredit),
      ("real hung process", s.testHungProcessNotForceKilled),
      ("real kernel zombie", s.testRealKernelZombie),
      ("real wrapper cancellation", s.testWrapperCancellation),
      ("32 real zombies with 8 live controls across 5 scans", pressure.testMixedKernelBurst),
      ("4096 mixed mechanical safety simulations", pressure.testMixedSafetyPressure),
      ("bounded CPU time projection", pressure.testCPUProjection),
    ]
    for (name, test) in tests {
      let before = failures
      do { try test() } catch { failTest("\(name): \(error)") }
      if failures == before { print("PASS \(name)") }
    }
    do { try worktreeVisibilityProof() } catch { failTest("Worktree visibility: \(error)") }
    do { try await fullDiskAccessProof() } catch { failTest("Full Disk Access: \(error)") }
    do { try await diskWorkerProof() } catch { failTest("Disk worker: \(error)") }
    do { try await gradleDaemonProof() } catch { failTest("Gradle daemon: \(error)") }
    do {
      try await worktreeLifecycleProof()
      try await worktreeSafetyProof()
    } catch { failTest("Worktree lifecycle: \(error)") }
    do { try await worktreeHuntRefreshProof() } catch {
      failTest("Worktree Hunt refresh: \(error)")
    }
    do { try await workspaceProof() } catch { failTest("Worktree cleanup: \(error)") }
    do {
      try usageProof()
      try await passiveProof()
      try await diskProof()
    } catch { failTest("Passive/usage: \(error)") }
    let beforeLifecycle = failures
    do { try await lifecycleProof() } catch { failTest("Lifecycle evidence: \(error)") }
    if failures == beforeLifecycle {
      print(
        "PASS durable lifecycle evidence, shared consumers, token privacy, identity and release/retain races"
      )
    }
    let beforeAgent = failures
    do { try await ownerMaintenanceProof() } catch { failTest("Owner maintenance: \(error)") }
    do { try await transportProof() } catch { failTest("Transport: \(error)") }
    do { try await agentBridgeProof() } catch { failTest("Agent bridge: \(error)") }
    if failures == beforeAgent { print("PASS private agent bridge, refusal and socket protection") }
    let beforeMachine = failures
    do { try await machineReviewProof() } catch { failTest("Machine review: \(error)") }
    if failures == beforeMachine {
      print(
        "PASS computer-wide review without chat events, coalescing, failure pause and cross-project visibility"
      )
    }
    if CommandLine.arguments.contains("--integration") {
      do { try await integration() } catch { failTest("Integration: \(error)") }
    }
    print("All proof groups completed; \(failures) failures")
    exit(failures == 0 ? 0 : 1)
  }
  static func integration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "BurnZombies-integration-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      .appendingPathComponent("burnzombies")
    let workerCount = 3
    for index in 0..<workerCount {
      let wrapper = Process()
      wrapper.executableURL = cli
      wrapper.arguments = [
        "run", "--label", "Controlled detached fixture \(index)", "--allow-cleanup", "--", cli.path,
        "fixture-tree", "detached",
      ]
      var env = ProcessInfo.processInfo.environment
      env["BURNZOMBIES_HOME"] = root.path
      wrapper.environment = env
      try wrapper.run()
      wrapper.waitUntilExit()
      equal(wrapper.terminationStatus, 0)
    }
    let store = try Store(root: root)
    let leases = try store.leases()
    equal(leases.count, workerCount)
    check(leases.allSatisfy { $0.members.count >= 2 }, "detached descendants were not registered")
    // Clean only exact fixture identities on failure; no process-name matching.
    defer {
      for l in leases {
        for m in l.members {
          if case .found(let o) = Native().probe(m.identity.pid), o.identity == m.identity {
            _ = Native().terminate(o)
          }
        }
      }
    }
    let monitor = try Monitor(
      root: root, accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
    let service = AgentService(monitor: monitor)
    let start = Date()
    for lease in leases {
      let targets = lease.members.compactMap { member -> Observation? in
        if case .found(let o) = Native().probe(member.identity.pid), o.identity == member.identity,
          !o.zombie
        {
          return o
        }
        return nil
      }
      equal(targets.count, 1, "Expected one detached fixture target, found \(targets.count)")
      var request = AgentRequest(
        "preview", processIDs: targets.map { $0.identity.key },
        label: "Controlled detached fixture",
        rationale:
          "The test created these exact helpers; the owning job finished and its recorded descendants are disposable."
      )
      request.callerPID = getpid()
      let preview = await service.call(request)
      guard let token = preview.previewToken else { throw StoreError.message(preview.message) }
      var burnRequest = AgentRequest("burn", previewToken: token)
      burnRequest.callerPID = getpid()
      let burn = await service.call(burnRequest)
      check(burn.ok, burn.message)
      equal(burn.verifiedHelpers, 0)
    }
    print("PASS agent-selected detached helpers stopped without scripted eligibility delay")
    let deadline = Date().addingTimeInterval(150)
    while Date() < deadline {
      try await Task.sleep(nanoseconds: 15_000_000_000)
      let state = await monitor.refresh()
      if state.catalog.events.contains(where: {
        $0.outcome != "verifying" && $0.outcome != "verified"
      }) {
        throw StoreError.message(
          "Verification stopped without credit: "
            + state.catalog.events.map { $0.outcome + ": " + $0.detail }.joined(separator: " "))
      }
      if state.catalog.events.count == workerCount
        && state.catalog.events.allSatisfy({ $0.outcome != "verifying" })
      {
        let events = state.catalog.events
        check(
          events.allSatisfy { $0.outcome == "verified" && $0.verifiedCount == 1 },
          "cleanup was not fully verified")
        equal(state.catalog.lifetimeVerified, workerCount)
        let memory = events.reduce(UInt64(0)) { $0 + $1.residentBefore }
        let cpu = events.compactMap(\.cpuSecondsSavedEstimate).reduce(0, +)
        equal(state.catalog.lifetimeResidentReleased, memory)
        equal(state.catalog.lifetimeCPUSecondsSaved ?? 0, cpu)
        // Fresh first observations do not fabricate a CPU projection.
        check(
          events.allSatisfy { ($0.responseBeforeMS ?? 0) > 0 && ($0.responseAfterMS ?? 0) > 0 },
          "missing responsiveness probes")
        _ = await monitor.refresh()
        let next = await monitor.snapshot()
        equal(next.catalog.lifetimeVerified, workerCount, "double count")
        equal(next.catalog.lifetimeCPUSecondsSaved ?? 0, cpu, "double CPU count")
        equal(next.catalog.lifetimeResidentReleased, memory, "double memory count")
        // Verification itself must persist the receipt; an explicit checkpoint here
        // would hide a crash window between displayed credit and saved accounting.
        let saved = try store.load()
        equal(saved.lifetimeVerified, workerCount, "verified count was not immediately durable")
        equal(saved.lifetimeCPUSecondsSaved ?? 0, cpu)
        equal(saved.lifetimeResidentReleased, memory)
        check(saved.events.allSatisfy { $0.outcome == "verified" && $0.responseAfterMS != nil })
        print(
          "PASS three real cleanups, no respawn, deduplication, CPU projections and persisted accounting (\(Int(Date().timeIntervalSince(start))) seconds)"
        )
        return
      }
    }
    throw StoreError.message("Verification timed out.")
  }
}
