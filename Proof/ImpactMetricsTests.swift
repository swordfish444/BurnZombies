import BurnCore
import Foundation

func impactMetricsProof() throws {
  func event(before: Double = 2.22125, after: Double = 2.88971) -> CleanupEvent {
    var e = CleanupEvent(leaseID: UUID(), label: "Metrics fixture", date: Date(),
      targets: [Member(Observation(identity: .init(pid: 4321, seconds: 1)))],
      residentBefore: 1024, outcome: "verified", detail: "Isolated accounting only")
    e.verifiedCount = 1
    e.responseBeforeMS = before; e.responseAfterMS = after
    return e
  }
  var c = Catalog(); c.events = [event()]
  equal(ImpactNumbers.make(catalog: c, period: .all).boost, "—", "Legacy -23% must not be called a boost")
  equal(ImpactNumbers.make(catalog: c, period: .all).speedHeadline, "No clear boost yet.")
  func measured(_ before: Double, _ after: Double) -> CleanupEvent {
    var e = event(before: before, after: after)
    e.responseBeforeSamples = Array(repeating: before, count: 7)
    e.responseAfterSamples = Array(repeating: after, count: 7)
    return e
  }
  isNil(Responsiveness.comparison([measured(2.22125, 2.88971)])?.boostPercent)
  isNil(Responsiveness.comparison([measured(2.89, 2.22)])?.boostPercent)
  equal(Responsiveness.comparison([measured(20, 10)])?.boostPercent, 100)
  isNil(Responsiveness.comparison([measured(10, 20), measured(10, 10), measured(20, 10)])?.boostPercent)
  var noisy = measured(20, 10)
  noisy.responseBeforeSamples = [1, 2, 3, 20, 30, 40, 50]
  isNil(Responsiveness.comparison([noisy]))
  for bad in [Double.nan, Double.infinity, -1, 0] {
    isNil(Responsiveness.comparison([measured(bad, 10)]))
  }
  var e = event(); e.cpuSavingsRate = 0.5; e.cpuObservedSeconds = 0; e.cpuSecondsSavedEstimate = 0
  c = Catalog(); c.events = [e]
  for _ in 0..<120 { ImpactAccounting.accrue(&c, awakeSeconds: 60, wallSeconds: 60, boot: 1) }
  equal(c.events[0].cpuSecondsSavedEstimate, 3600, "Savings must grow beyond the old one-hour projection")
  equal(c.lifetimeCPUSecondsSaved, 3600)
  for (awake, wall) in [(0.0, 3600.0), (60.0, 3600.0), (3600.0, 3600.0), (-60.0, 60.0)] {
    equal(ImpactAccounting.accrue(&c, awakeSeconds: awake, wallSeconds: wall, boot: 1), 0,
      "Sleep, downtime and invalid intervals get no credit")
  }
  var pending = c; pending.events[0].outcome = "verifying"
  equal(ImpactAccounting.accrue(&pending, awakeSeconds: 60, wallSeconds: 60, boot: 1), 0)
  var reboot = c
  equal(ImpactAccounting.accrue(&reboot, awakeSeconds: 60, wallSeconds: 60, boot: 2), 0)
  equal(reboot.events[0].cpuAccrualEnded, true)
  var recurrent = c
  equal(ImpactAccounting.accrue(&recurrent, awakeSeconds: 60, wallSeconds: 60, boot: 1, ended: [e.id]), 0)
  equal(ImpactAccounting.accrue(&recurrent, awakeSeconds: 60, wallSeconds: 60, boot: 1), 0)
  for _ in 0..<2000 { ImpactAccounting.accrue(&c, awakeSeconds: 60, wallSeconds: 60, boot: 1) }
  equal(c.lifetimeCPUSecondsSaved, 43_200, "Counterfactual must stop after 24 observed awake hours")
  equal(c.events[0].cpuObservedSeconds, 86_400)
  // Preserve historical one-hour estimates; count no overlapping first hour.
  var legacy = event(); legacy.cpuSecondsSavedEstimate = 1800
  c = Catalog(); c.events = [legacy]; c.lifetimeCPUSecondsSaved = 1800
  ImpactAccounting.migrate(&c); ImpactAccounting.migrate(&c)
  for _ in 0..<60 { ImpactAccounting.accrue(&c, awakeSeconds: 60, wallSeconds: 60, boot: 1) }
  equal(c.lifetimeCPUSecondsSaved, 1800)
  ImpactAccounting.accrue(&c, awakeSeconds: 60, wallSeconds: 60, boot: 1)
  equal(c.lifetimeCPUSecondsSaved, 1830)
  let restored = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(c))
  equal(restored.events[0].cpuObservedSeconds, 3660)
  equal(restored.lifetimeCPUSecondsSaved, 1830)
  equal(ImpactNumbers.make(catalog: restored, period: .today).cpuSeconds, 1830)
}
