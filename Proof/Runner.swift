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
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--agent-fixture" {
      do { try await runAgentFixture(root: URL(fileURLWithPath: CommandLine.arguments[2])) }
      catch { print("FAIL: \(error)"); exit(1) }
      return
    }
    let d = DecisionTests()
    let s = StorageNativeTests()
    let pressure = PressureTests()
    let tests: [(String, () throws -> Void)] = [
      ("explicit abandoned ownership", d.testExplicitAbandonedIdleHelperQualifies),
      ("active owner", d.testActiveOwnerAlwaysProtected),
      ("unknown owner", d.testUnknownOwnerAlwaysProtected),
      ("permission required", d.testPermissionRequired),
      ("spent permission", d.testSpentPermissionNeverRearms),
      ("PID reuse", d.testPIDReuseInvalidatesMembership),
      ("exec change", d.testExecChangeInvalidatesMembership),
      ("zombie", d.testZombieCannotBeKilled),
      ("CPU activity", d.testActivityInvalidatesEligibility),
      ("disk activity", d.testDiskActivityInvalidatesEligibility),
      ("grace", d.testGraceAndRepeatedObservationsRequired),
      ("sampling gap", d.testSamplingGapAndClockRollbackFailClosed),
      ("visibility", d.testStaleAndMissingMetricsProtected),
      ("protection and snooze", d.testProtectionAndSnoozeBlockAutomaticAndManual),
      ("hard protection", d.testDeterministicProtection),
      ("weak signals", d.testPPIDOneAgeAndMemoryDoNotAuthorize),
      ("wake and restart", d.testRestartAndWakeResetEligibility),
      ("independent jobs", d.testIndependentDuplicateLookingJobsStaySeparate),
      ("sustained growth", d.testGrowthIsInvestigateOnly),
      ("restart loop", d.testRestartLoopIsNotKillLoop),
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
      ("4096 mixed ownership and activity simulations", pressure.testMixedPolicyPressure),
      ("bounded CPU time projection", pressure.testCPUProjection),
    ]
    for (name, test) in tests {
      let before = failures
      do { try test() } catch { failTest("\(name): \(error)") }
      if failures == before { print("PASS \(name)") }
    }
    let beforeAgent = failures
    do { try await agentBridgeProof() } catch { failTest("Agent bridge: \(error)") }
    if failures == beforeAgent { print("PASS private agent bridge, refusal and socket protection") }
    if CommandLine.arguments.contains("--integration") {
      do { try await integration() } catch { failTest("Integration: \(error)") }
    }
    print("\(tests.count + 1) checks; \(failures) failures")
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
    var candidates = [Finding]()
    while Date().timeIntervalSince(start) < 270 {
      let state = await monitor.refresh()
      candidates = state.findings.filter { $0.disposition == .eligible }
      if candidates.count == workerCount { break }
      try await Task.sleep(nanoseconds: 15_000_000_000)
    }
    guard candidates.count == workerCount else {
      throw StoreError.message("Not all controlled helpers became eligible.")
    }
    print(
      "PASS three independent detached helpers detected after \(Int(Date().timeIntervalSince(start))) seconds"
    )
    for (index, candidate) in candidates.enumerated() {
      if index == 0 {
        let preview = await service.call(AgentRequest("preview", findingID: candidate.id))
        guard let token = preview.previewToken else { throw StoreError.message("Agent preview failed: \(preview.message)") }
        let burn = await service.call(AgentRequest("burn", previewToken: token))
        check(burn.ok && burn.message.contains("Verifying"))
        equal(burn.verifiedHelpers, 0, "pending MCP request earned credit")
        let replay = await service.call(AgentRequest("burn", previewToken: token))
        checkFalse(replay.ok, "agent preview replay accepted")
        continue
      }
      let result = try await monitor.cleanup(candidate)
      check(result.contains("Verifying"))
    }
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
        equal(state.catalog.lifetimeCPUSecondsSaved, cpu)
        check(events.allSatisfy { $0.cpuSecondsSavedEstimate != nil })
        check(
          events.allSatisfy { ($0.responseBeforeMS ?? 0) > 0 && ($0.responseAfterMS ?? 0) > 0 },
          "missing responsiveness probes")
        _ = await monitor.refresh()
        let next = await monitor.snapshot()
        equal(next.catalog.lifetimeVerified, workerCount, "double count")
        equal(next.catalog.lifetimeCPUSecondsSaved, cpu, "double CPU count")
        equal(next.catalog.lifetimeResidentReleased, memory, "double memory count")
        // Verification itself must persist the receipt; an explicit checkpoint here
        // would hide a crash window between displayed credit and saved accounting.
        let saved = try store.load()
        equal(saved.lifetimeVerified, workerCount, "verified count was not immediately durable")
        equal(saved.lifetimeCPUSecondsSaved, cpu)
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
