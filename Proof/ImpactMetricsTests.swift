import BurnCore
import Foundation

private func require<T>(_ value: T?, _ what: String) throws -> T {
  guard let value else { throw StoreError.message("Missing: " + what) }
  return value
}

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
  c.lifetimeVerified = 1
  equal(ImpactNumbers.make(catalog: c, period: .today).benefit, .memory,
    "Verified cleanup remains a benefit even when the timing got slower")
  c.events[0].responseBeforeMS = nil; c.events[0].responseAfterMS = nil
  equal(ImpactNumbers.make(catalog: c, period: .today).benefit, .memory,
    "No timing samples must not hide reclaimed memory")
  c.events[0].residentBefore = 0
  equal(ImpactNumbers.make(catalog: c, period: .today).benefit, .helpers,
    "Even a zero-memory cleanup shows verified helpers cleared")
  c.events[0].date = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
  equal(ImpactNumbers.make(catalog: c, period: .today).benefit, .ready)
  equal(ImpactNumbers.make(catalog: c, period: .week).benefit, .helpers)
  equal(ImpactNumbers.make(catalog: c, period: .today).lifetimeCount, 1)
  c.events = []
  equal(ImpactNumbers.make(catalog: c, period: .today).benefit, .ready,
    "Durable lifetime totals preserve prior benefit after receipts are pruned")
  equal(ImpactNumbers.make(catalog: c, period: .all).benefit, .helpers)
  equal(ImpactNumbers.make(catalog: Catalog(), period: .today).benefit, .firstBurn)
  var unfinished = Catalog(); var attempt = event(); attempt.outcome = "verifying"
  unfinished.events = [attempt]
  equal(ImpactNumbers.make(catalog: unfinished, period: .today).benefit, .firstBurn,
    "An unverified attempt must not claim a benefit")
  func measured(_ before: Double, _ after: Double) -> CleanupEvent {
    var e = event(before: before, after: after)
    e.responseBeforeSamples = Array(repeating: before, count: 7)
    e.responseAfterSamples = Array(repeating: after, count: 7)
    return e
  }
  isNil(Responsiveness.comparison([measured(2.22125, 2.88971)])?.boostPercent)
  isNil(Responsiveness.comparison([measured(2.89, 2.22)])?.boostPercent)
  equal(Responsiveness.comparison([measured(20, 10)])?.boostPercent, 100)
  c = Catalog(); c.events = [measured(20, 10)]; c.lifetimeVerified = 1
  equal(ImpactNumbers.make(catalog: c, period: .today).benefit, .speed)
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

  // The Burn Log reads newest first, across every kind of burn, in the order a real catalog ends up
  // in: `prune` keeps what wasn't verified first, then what was checked last.
  let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
  func burn(_ hoursIn: Double, _ outcome: String = "verified") -> CleanupEvent {
    var e = event()
    e.date = start.addingTimeInterval(hoursIn * 3600)
    e.outcome = outcome
    e.label = "\(hoursIn)"
    return e
  }
  var log = Catalog()
  log.events = [burn(4, "unverified"), burn(1, "unverified"), burn(8), burn(6), burn(2)]
  var worktree = try require(Demo.state().catalog.workspaceReceipts?.first, "a demo worktree receipt")
  worktree.date = start.addingTimeInterval(7 * 3600)
  log.workspaceReceipts = [worktree]
  var output = try JSONDecoder().decode(
    DiskReceipt.self,
    from: Data(
      #"{"id":"C2C2C2C2-0000-4000-8000-000000000001","candidateID":"fixture","path":"/fixture","date":0,"outcome":"verified","allocatedRemoved":1,"diskReclaimedBytes":1,"rationale":""}"#
        .utf8))
  output.date = start.addingTimeInterval(3 * 3600)
  log.diskReceipts = [output]
  equal(
    log.burnLog.map { $0.date.timeIntervalSince(start) / 3600 }, [8, 7, 6, 4, 3, 2, 1],
    "The Burn Log reads newest first across every kind of burn")
  check(
    log.burnLog.map(\.id).count == Set(log.burnLog.map(\.id)).count, "Each row has its own id")
  equal(Catalog().burnLog.count, 0, "An empty catalog has an empty log")
}
