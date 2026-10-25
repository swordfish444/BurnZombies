import BurnCore
import Darwin
import Foundation

final class SafetyTests: TestSuite {
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
  func testExecutionBoundaries() {
    var r = record()
    r.latest.uid = getuid()
    let prefs = Preferences()
    isNil(AgentSafety.refusal(r, preferences: prefs, protectedPIDs: []))
    r.latest.cpuNS = 9_000_000_000
    isNil(AgentSafety.refusal(r, preferences: prefs, protectedPIDs: []))
    check(AgentSafety.refusal(r, preferences: prefs, protectedPIDs: [r.latest.identity.pid]) != nil)
    r.protection = true
    check(AgentSafety.refusal(r, preferences: prefs, protectedPIDs: []) != nil)
    r.protection = false
    r.latest.zombie = true
    check(AgentSafety.refusal(r, preferences: prefs, protectedPIDs: []) != nil)
    r.latest.zombie = false
    r.latest.metricsValid = false
    check(AgentSafety.refusal(r, preferences: prefs, protectedPIDs: []) != nil)
  }
  func testRecurrenceScope() {
    let parent = Member(Observation(identity: .init(pid: 900, seconds: 1)))
    let target = Observation(identity: .init(pid: 901, seconds: 50), parent: 900, executable: "/test/node")
    var event = CleanupEvent(leaseID: UUID(), label: "test", date: Date(timeIntervalSince1970: 100.5),
      targets: [Member(target)], residentBefore: 1024, outcome: "verifying", detail: "test")
    event.recurrenceScopes = [.init(executable: target.executable, parent: parent)]
    var other = Observation(identity: .init(pid: 902, seconds: 100, micros: 400000), parent: 900, executable: target.executable)
    checkFalse(Verification.recurrence(event: event, observations: [other], parentAlive: { _ in true }), "preexisting active sibling counted as a respawn")
    other.identity = .init(pid: 902, seconds: 101)
    check(Verification.recurrence(event: event, observations: [other], parentAlive: { _ in true }))
    checkFalse(Verification.recurrence(event: event, observations: [other], parentAlive: { _ in false }), "reused parent identity accepted")
    other.parent = 950
    checkFalse(Verification.recurrence(event: event, observations: [other], parentAlive: { _ in true }), "unrelated job counted as a respawn")
  }

}
