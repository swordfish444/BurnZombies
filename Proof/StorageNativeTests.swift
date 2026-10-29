import BurnCore
import CBurn
import Darwin
import Foundation

final class StorageNativeTests: TestSuite {
  func testWrapperCancellation() throws {
    let root = temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let wrapper = Process()
    wrapper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      .deletingLastPathComponent().appendingPathComponent("burnzombies")
    wrapper.arguments = ["run", "--label", "Cancellation fixture", "--", "/bin/sleep", "30"]
    var env = ProcessInfo.processInfo.environment
    env["BURNZOMBIES_HOME"] = root.path
    wrapper.environment = env
    try wrapper.run()
    let store = try Store(root: root)
    var members = [Member]()
    defer {
      for m in members {
        if case .found(let o) = Native().probe(m.identity.pid), o.identity == m.identity {
          _ = Native().terminate(o)
        }
      }
      if wrapper.isRunning { wrapper.terminate() }
      wrapper.waitUntilExit()
    }
    let registeredDeadline = Date().addingTimeInterval(5)
    while Date() < registeredDeadline {
      members = try store.leases().flatMap(\.members)
      if !members.isEmpty { break }
      Thread.sleep(forTimeInterval: 0.1)
    }
    check(!members.isEmpty, "Wrapper did not record its child")
    wrapper.terminate()
    let exitDeadline = Date().addingTimeInterval(5)
    while wrapper.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.1) }
    checkFalse(wrapper.isRunning, "Wrapper failed to finish graceful cancellation")
    for member in members { equal(Native().ownerState(member.identity), .gone) }
    let leases = try store.leases()
    check(leases.allSatisfy { $0.ended != nil && !$0.allowCleanup })
  }
  func testRealKernelZombie() {
    let pid = bz_zombie_fixture()
    guard pid > 0 else { return failTest("Could not create the zombie fixture") }
    defer {
      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }
    Thread.sleep(forTimeInterval: 0.1)
    guard case .found(let o) = Native().probe(pid) else {
      return failTest("Kernel zombie omitted by native adapter")
    }
    check(o.zombie, "Exited unreaped child must be labeled as a kernel zombie")
    equal(o.rss, 0)
    equal(o.parent, getpid())
    check(
      Native().scan().observations.contains { $0.identity == o.identity && $0.zombie },
      "Zombie absent from the full catalog scan")
    notEqual(Native().terminate(o), 0)
  }
  func temp() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "BurnZombies-test-" + UUID().uuidString)
  }
  func testCheckpointRoundTripAndPermissions() throws {
    let root = temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try Store(root: root)
    var c = Catalog()
    c.lifetimeVerified = 7
    c.preferences.automaticCleanup = true
    try s.save(c)
    let read = try s.load()
    equal(read.lifetimeVerified, 7)
    check(read.preferences.automaticCleanup)
    let attrs = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("catalog.bzcat").path)
    equal((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
  func testCorruptionFailsClosed() throws {
    let root = temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try Store(root: root)
    try Data("broken".utf8).write(to: root.appendingPathComponent("catalog.bzcat"))
    throwsError(try s.load())
  }
  func testSymlinkReadRejected() throws {
    let root = temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try Store(root: root)
    let target = root.appendingPathComponent("target")
    try Data("x".utf8).write(to: target)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    throwsError(try s.read(link, limit: 20))
  }
  func testOnlyOneMonitorOwnsCatalog() throws {
    let root = temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try Monitor(root: root, accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
    throwsError(try Monitor(root: root, accessCheck: fixtureAccess, discoveryWalker: fixtureWalker()))
    withExtendedLifetime(a) {}
  }
  func testRetentionCapsRecordsAndEvents() {
    var c = Catalog()
    let now = Date()
    for i in 0..<5000 {
      let o = Observation(identity: ProcessIdentity(pid: Int32(i + 10), seconds: 1))
      c.records[o.identity.key] = Record(o)
    }
    for _ in 0..<600 {
      c.events.append(
        CleanupEvent(
          leaseID: UUID(), label: "test", date: now, targets: [], residentBefore: 0,
          outcome: "partial", detail: "fixture"))
    }
    c.lifetimeVerified = 900
    c.prune(now: now)
    equal(c.records.count, 4096)
    equal(c.events.count, 500)
    equal(c.lifetimeVerified, 900)
  }
  func testActualProcessIdentityAndGracefulStop() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    defer {
      if p.isRunning { p.terminate() }
      p.waitUntilExit()
    }
    let native = Native()
    guard case .found(let o) = native.probe(p.processIdentifier) else {
      return failTest("fixture not visible")
    }
    var wrong = o
    wrong.identity.seconds += 1
    notEqual(native.terminate(wrong), 0)
    equal(native.ownerState(o.identity), .alive)
    equal(native.terminate(o), 0)
    p.waitUntilExit()
    equal(native.ownerState(o.identity), .gone)
  }
  func testPrivateBudgetEnforced() throws {
    let root = temp()
    defer { try? FileManager.default.removeItem(at: root) }
    let s = try Store(root: root)
    throwsError(
      try s.write(
        Data(repeating: 0, count: 20), to: root.appendingPathComponent("large"), limit: 10))
  }
  func testVerificationFailureAndRecurrence() {
    equal(
      Verification.outcome(elapsed: 16, targets: [.unknown], recurrence: false, partialScan: false),
      "unverified")
    equal(
      Verification.outcome(elapsed: 14, targets: [.gone], recurrence: false, partialScan: false),
      "verifying")
    equal(
      Verification.outcome(
        elapsed: 16, targets: [.gone, .alive], recurrence: false, partialScan: false), "partial")
    equal(
      Verification.outcome(elapsed: 180, targets: [.gone], recurrence: true, partialScan: false),
      "reappeared")
    equal(
      Verification.outcome(
        elapsed: 181, targets: [.unknown], recurrence: false, partialScan: false), "unverified")
    equal(
      Verification.outcome(elapsed: 120, targets: [.gone], recurrence: false, partialScan: true),
      "unverified")
    equal(
      Verification.outcome(elapsed: 120, targets: [.gone], recurrence: false, partialScan: false),
      "verified")
  }
  func testInterruptedVerificationGetsNoCredit() {
    var c = Catalog()
    c.events = [
      CleanupEvent(
        leaseID: UUID(), label: "test", date: Date(), targets: [], residentBefore: 100,
        outcome: "verifying", detail: "pending")
    ]
    c.resetContinuity()
    equal(c.events[0].outcome, "unverified")
    equal(c.lifetimeVerified, 0)
  }
  func testHungProcessNotForceKilled() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
    try process.run()
    Thread.sleep(forTimeInterval: 0.1)
    guard case .found(let observed) = Native().probe(process.processIdentifier) else {
      return failTest("fixture invisible")
    }
    defer {
      if case .found(let current) = Native().probe(process.processIdentifier),
        current.identity == observed.identity
      {
        kill(process.processIdentifier, SIGKILL)
      }
      process.waitUntilExit()
    }
    equal(Native().terminate(observed), 0)
    Thread.sleep(forTimeInterval: 0.1)
    equal(Native().ownerState(observed.identity), .alive)
    equal(
      Verification.outcome(elapsed: 16, targets: [.alive], recurrence: false, partialScan: false),
      "partial")
  }
}
