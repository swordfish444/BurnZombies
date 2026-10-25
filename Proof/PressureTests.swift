import BurnCore
import CBurn
import Darwin
import Foundation

final class PressureTests: TestSuite {
  func testMixedKernelBurst() throws {
    let native = Native()
    var zombies = [Int32]()
    var live = [Process]()
    defer {
      for process in live {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
      }
      for pid in zombies {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
      }
    }
    for _ in 0..<8 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sleep")
      process.arguments = ["30"]
      try process.run()
      live.append(process)
    }
    for _ in 0..<32 {
      let pid = bz_zombie_fixture()
      guard pid > 0 else { throw StoreError.message("Zombie fixture fork failed") }
      zombies.append(pid)
    }
    let deadline = Date().addingTimeInterval(3)
    var scan = native.scan()
    while Date() < deadline
      && zombies.contains(where: { pid in
        !scan.observations.contains { $0.identity.pid == pid && $0.zombie }
      })
    {
      Thread.sleep(forTimeInterval: 0.05)
      scan = native.scan()
    }
    for pass in 0..<5 {
      scan = native.scan()
      var catalog = Catalog()
      for pid in zombies {
        guard let observation = scan.observations.first(where: { $0.identity.pid == pid }) else {
          failTest("Zombie missing from burst scan \(pass)")
          continue
        }
        check(observation.zombie, "Burst child was not recognized as SZOMB")
        equal(observation.rss, 0)
        notEqual(native.terminate(observation), 0)
        catalog.records[observation.identity.key] = Record(observation)
      }
      for process in live {
        guard case .found(let observation) = native.probe(process.processIdentifier) else {
          failTest("Live control worker disappeared")
          continue
        }
        checkFalse(observation.zombie, "Living idle worker mislabeled zombie")
        catalog.records[observation.identity.key] = Record(observation)
      }
      let findings = DecisionEngine.findings(
        catalog: catalog, leases: [], owners: [:], uid: getuid(), ownPID: getpid(), now: Date())
      equal(
        findings.filter {
          $0.evidence.contains("Kernel zombie state; sending signals cannot reap it.")
        }.count, 32)
      checkFalse(
        findings.contains { $0.disposition == .eligible },
        "Burst created unauthorized cleanup targets")
      check(live.allSatisfy(\.isRunning), "A legitimate worker did not survive")
    }
  }

  func testMixedPolicyPressure() {
    let fixture = DecisionTests()
    var granted = 0
    for index in 0..<4096 {
      var record = fixture.record()
      var lease = fixture.lease(record)
      var owner = OwnerState.gone
      let kind = index % 8
      switch kind {
      case 1: owner = .alive
      case 2: owner = .unknown
      case 3: lease.disarmed = true
      case 4: record.latest.metricsValid = false
      case 5:
        record.latest.writeBytes += 1
        record.latest.monotonic += 1
      case 6: record.latest.identity.seconds += 1
      case 7: record.protection = true
      default: break
      }
      let eligible = fixture.eligible(record, lease, owner)
      equal(eligible, kind == 0, "Wrong decision in mixed simulation \(index)")
      if eligible { granted += 1 }
    }
    equal(granted, 512)
  }

  func testCPUProjection() {
    var record = DecisionTests().record()
    for i in record.samples.indices {
      // A large historical total must not be mistaken for CPU saved.
      record.samples[i].cpuNS = 900_000_000_000 + UInt64(i) * 300_000_000
    }
    record.latest = record.samples.last!
    let projected = ImpactAccounting.cpuSecondsSaved([record])
    check(abs((projected ?? -1) - 18) < 0.0001)
    check(abs((ImpactAccounting.cpuSecondsSaved([record, record]) ?? -1) - 36) < 0.0001)
    record.latest.metricsValid = false
    isNil(ImpactAccounting.cpuSecondsSaved([record]))
    isNil(ImpactAccounting.cpuSecondsSaved([]))
    record = DecisionTests().record()
    equal(ImpactAccounting.cpuSecondsSaved([record]), 0)
    record.samples = [record.latest]
    isNil(ImpactAccounting.cpuSecondsSaved([record]))
  }
}
