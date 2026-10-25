import BurnCore
import Darwin
import Foundation

final class DecisionTests: TestSuite {
  let now = Date(timeIntervalSince1970: 1000)
  func record() -> Record {
    var r = Record(
      Observation(
        identity: ProcessIdentity(pid: 4321, seconds: 1), rss: 1024,
        time: now.addingTimeInterval(-240), monotonic: 0))
    r.samples = (0..<5).map { i in
      Observation(
        identity: r.latest.identity, rss: 1024, time: now.addingTimeInterval(Double(i * 60 - 240)),
        monotonic: Double(i * 60))
    }
    r.latest = r.samples.last!
    r.orphanSince = now.addingTimeInterval(-240)
    return r
  }
  func lease(_ r: Record) -> Lease {
    Lease(
      label: "Fixture", owner: ProcessIdentity(pid: 4320, seconds: 1), members: [Member(r.latest)],
      allowCleanup: true, now: now)
  }
  func eligible(
    _ r: Record, _ l: Lease? = nil, _ owner: OwnerState = .gone,
    _ prefs: Preferences = Preferences()
  ) -> Bool {
    DecisionEngine.eligibility(
      r, lease: l ?? lease(r), owner: owner, preferences: prefs, uid: 501, ownPID: 9999, now: now
    ).0
  }
  func testExplicitAbandonedIdleHelperQualifies() { check(eligible(record())) }
  func testActiveOwnerAlwaysProtected() { checkFalse(eligible(record(), nil, .alive)) }
  func testUnknownOwnerAlwaysProtected() { checkFalse(eligible(record(), nil, .unknown)) }
  func testPermissionRequired() {
    let r = record()
    var l = lease(r)
    l.allowCleanup = false
    checkFalse(eligible(r, l))
  }
  func testSpentPermissionNeverRearms() {
    let r = record()
    var l = lease(r)
    l.disarmed = true
    checkFalse(eligible(r, l))
  }
  func testPIDReuseInvalidatesMembership() {
    var r = record()
    let l = lease(r)
    r.latest.identity.seconds += 1
    checkFalse(eligible(r, l))
  }
  func testExecChangeInvalidatesMembership() {
    var r = record()
    let l = lease(r)
    r.latest.executable = "/different"
    checkFalse(eligible(r, l))
  }
  func testZombieCannotBeKilled() {
    var r = record()
    r.latest.zombie = true
    checkFalse(eligible(r))
  }
  func testActivityInvalidatesEligibility() {
    var r = record()
    r.samples[4].cpuNS = 60_000_000_000
    r.latest = r.samples[4]
    checkFalse(eligible(r))
    r = record()
    r.latest.monotonic += 10
    r.latest.cpuNS += 1_000_000_000
    checkFalse(eligible(r), "Activity after the last retained sample must veto cleanup")
  }
  func testDiskActivityInvalidatesEligibility() {
    var r = record()
    r.samples[4].writeBytes = 1
    r.latest = r.samples[4]
    checkFalse(eligible(r))
    r = record()
    r.latest.monotonic += 10
    r.latest.writeBytes += 1
    checkFalse(eligible(r), "Latest disk activity must veto cleanup")
  }
  func testGraceAndRepeatedObservationsRequired() {
    var r = record()
    r.orphanSince = now.addingTimeInterval(-60)
    checkFalse(eligible(r))
    r = record()
    r.samples = [r.latest]
    checkFalse(eligible(r))
  }
  func testSamplingGapAndClockRollbackFailClosed() {
    var r = record()
    r.samples[3].monotonic = 30
    checkFalse(eligible(r))
    r = record()
    r.latest.time = now.addingTimeInterval(30)
    checkFalse(eligible(r))
  }
  func testStaleAndMissingMetricsProtected() {
    var r = record()
    r.latest.time = now.addingTimeInterval(-200)
    checkFalse(eligible(r))
    r = record()
    r.latest.metricsValid = false
    checkFalse(eligible(r))
  }
  func testProtectionAndSnoozeBlockAutomaticAndManual() {
    var r = record()
    r.protection = true
    checkFalse(eligible(r))
    r = record()
    r.ignoreUntil = now.addingTimeInterval(10)
    checkFalse(eligible(r))
    var p = Preferences()
    p.protectedExecutables.insert(r.latest.executable)
    checkFalse(eligible(record(), nil, .gone, p))
  }
  func testDeterministicProtection() {
    for path in [
      "/Applications/Editor.app/Contents/MacOS/Editor", "/usr/bin/ssh", "/tools/adb",
      "/tools/ffmpeg", "/tools/chromium", "/System/helper", "/tools/camera-upload",
    ] {
      var r = record()
      r.latest.executable = path
      checkFalse(eligible(r), path)
    }
  }
  func testPPIDOneAgeAndMemoryDoNotAuthorize() {
    var r = record()
    r.latest.parent = 1
    r.latest.rss = 30_000_000_000
    var l = lease(r)
    l.allowCleanup = false
    checkFalse(eligible(r, l))
  }
  func testRestartAndWakeResetEligibility() {
    var c = Catalog()
    let r = record()
    c.records[r.id] = r
    c.resetContinuity()
    checkFalse(eligible(c.records[r.id]!))
  }
  func testIndependentDuplicateLookingJobsStaySeparate() {
    var c = Catalog()
    var leases = [Lease]()
    for i in 0..<2 {
      var r = record()
      r.latest.identity.pid += Int32(i)
      c.records[r.id] = r
      var l = lease(r)
      l.label = "Independent \(i)"
      leases.append(l)
    }
    let f = DecisionEngine.findings(
      catalog: c, leases: leases,
      owners: Dictionary(uniqueKeysWithValues: leases.map { ($0.id, .alive) }), uid: 501,
      ownPID: 9999, now: now)
    equal(f.count, 2)
    check(f.allSatisfy { $0.disposition == .protected })
  }
  func testGrowthIsInvestigateOnly() {
    var r = record()
    r.samples = []
    for i in 0..<6 {
      let size = UInt64(100 + i * 80) * 1_048_576
      let time = now.addingTimeInterval(Double(i * 60 - 300))
      r.samples.append(
        Observation(identity: r.latest.identity, rss: size, time: time, monotonic: Double(i * 60)))
    }
    r.latest = r.samples.last!
    var c = Catalog()
    c.records[r.id] = r
    let f = DecisionEngine.findings(
      catalog: c, leases: [], owners: [:], uid: 501, ownPID: 9999, now: now)
    equal(f.first?.disposition, .investigate)
    isNil(f.first?.leaseID)
  }
  func testRestartLoopIsNotKillLoop() {
    var c = Catalog()
    for i in 0..<6 {
      var r = record()
      r.latest.identity.pid += Int32(i)
      r.latest.identity.seconds = 970
      r.latest.parent = 700
      r.firstSeen = now.addingTimeInterval(-30)
      if i < 5 { r.missingSince = now }
      c.records[r.id] = r
    }
    let f = DecisionEngine.findings(
      catalog: c, leases: [], owners: [:], uid: 501, ownPID: 9999, now: now)
    check(f.contains { $0.id.hasPrefix("churn:") })
    checkFalse(f.contains { $0.disposition == .eligible })
  }
}
