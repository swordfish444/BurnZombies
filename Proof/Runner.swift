import BurnCore
import Darwin
import Foundation

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
    if CommandLine.arguments.contains("--passive-child") { Thread.sleep(forTimeInterval: 120); return }
    if CommandLine.arguments.contains("--passive-usage") {
      do { try usageProof(); try await passiveProof(); try await diskProof() } catch { failTest("Passive/usage: \(error)") }
      print("Passive/usage checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--review-economy") {
      do { try await machineReviewProof() } catch { failTest("Review economy: \(error)") }
      print("Review economy checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--worktrees") {
      do { try await workspaceProof() } catch { failTest("Worktree cleanup: \(error)") }
      print("Worktree checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.contains("--impact-metrics") {
      do { try impactMetricsProof(); try impactPeriodProof() } catch { failTest("Impact metrics: \(error)") }
      print("Impact metrics and period checks: \(failures) failures")
      exit(failures == 0 ? 0 : 1)
    }
    if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--review-model" {
      do {
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let config = try MachineReviewConfiguration.load(root: root) else { throw StoreError.message("Missing proof config") }
        let prompt = CommandLine.arguments[4] == "--production" ? MachineReviewer.prompt
          : try String(contentsOfFile: CommandLine.arguments[4], encoding: .utf8)
        try MachineReviewer.execute(config, root: root, prompt: prompt)
      } catch { print("FAIL: \(error)"); exit(1) }
      return
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--agent-fixture" {
      do { try await runAgentFixture(root: URL(fileURLWithPath: CommandLine.arguments[2])) }
      catch { print("FAIL: \(error)"); exit(1) }
      return
    }
    let d = SafetyTests()
    let s = StorageNativeTests()
    let pressure = PressureTests()
    let tests: [(String, () throws -> Void)] = [
      ("cumulative awake CPU savings and stable nonnegative speed impact", impactMetricsProof),
      ("impact periods, completion dates, DST, empty history and preview accounting", impactPeriodProof),
      ("review model/effort migration, persistence, provider arguments and defaults", reviewSelectionProof),
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
    do { try await workspaceProof() } catch { failTest("Worktree cleanup: \(error)") }
    do { try usageProof(); try await passiveProof(); try await diskProof() } catch { failTest("Passive/usage: \(error)") }
    let beforeLifecycle = failures
    do { try await lifecycleProof() } catch { failTest("Lifecycle evidence: \(error)") }
    if failures == beforeLifecycle { print("PASS durable lifecycle evidence, shared consumers, token privacy, identity and release/retain races") }
    let beforeAgent = failures
    do { try await agentBridgeProof() } catch { failTest("Agent bridge: \(error)") }
    if failures == beforeAgent { print("PASS private agent bridge, refusal and socket protection") }
    let beforeMachine = failures
    do { try await machineReviewProof() } catch { failTest("Machine review: \(error)") }
    if failures == beforeMachine { print("PASS computer-wide review without chat events, coalescing, failure pause and cross-project visibility") }
    if CommandLine.arguments.contains("--integration") {
      do { try await integration() } catch { failTest("Integration: \(error)") }
    }
    print("\(tests.count + 4) checks; \(failures) failures")
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
    let monitor = try Monitor(root: root)
    let service = AgentService(monitor: monitor)
    let start = Date()
    for lease in leases {
      let targets = lease.members.compactMap { member -> Observation? in
        if case .found(let o) = Native().probe(member.identity.pid), o.identity == member.identity, !o.zombie { return o }
        return nil
      }
      equal(targets.count, 1)
      var request = AgentRequest("preview", processIDs: targets.map { $0.identity.key },
        label: "Controlled detached fixture", rationale: "The test created these exact helpers; the owning job finished and its recorded descendants are disposable.")
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
