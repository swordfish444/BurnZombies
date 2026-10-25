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
      for r in catalog.records.values where r.latest.zombie {
        check(AgentSafety.refusal(r, preferences: catalog.preferences, protectedPIDs: []) != nil)
      }
      check(live.allSatisfy(\.isRunning), "A legitimate worker did not survive")
    }
  }

  func testMixedSafetyPressure() {
    for index in 0..<4096 {
      var r = SafetyTests().record()
      r.latest.uid = getuid()
      switch index % 8 {
      case 1: r.latest.uid += 1
      case 2: r.latest.zombie = true
      case 3: r.protection = true
      case 4: r.latest.metricsValid = false
      case 5: r.latest.executable = "/System/service"
      case 6: r.latest.identity.pid = 1
      case 7: r.ignoreUntil = Date().addingTimeInterval(600)
      default: break
      }
      equal(AgentSafety.refusal(r, preferences: Preferences(), protectedPIDs: []) == nil,
        index % 8 == 0, "Wrong mechanical boundary at \(index)")
    }
  }

  func testCPUProjection() {
    var record = SafetyTests().record()
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
    record = SafetyTests().record()
    equal(ImpactAccounting.cpuSecondsSaved([record]), 0)
    record.samples = [record.latest]
    isNil(ImpactAccounting.cpuSecondsSaved([record]))
  }
}
