import BurnCore
import Foundation

func impactPeriodProof() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/Denver")!
  func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
  let now = date("2026-10-26T18:00:00Z")
  func receipt(_ completed: Date, count: Int, outcome: String = "verified") -> CleanupEvent {
    var event = CleanupEvent(leaseID: UUID(), label: "Period fixture", date: completed.addingTimeInterval(-120),
      targets: [], residentBefore: UInt64(count * 100), outcome: outcome, detail: "Fixture")
    event.verificationDate = completed
    event.verifiedCount = count
    event.cpuSecondsSavedEstimate = Double(count * 10)
    event.responseBeforeMS = 200
    event.responseAfterMS = Double(count)
    return event
  }
  let today = calendar.startOfDay(for: now)
  let week = calendar.date(byAdding: .day, value: -6, to: today)!
  var catalog = Catalog()
  // Intentionally out of order: the latest completion need not be the last request.
  catalog.events = [receipt(now, count: 3), receipt(today, count: 2),
    receipt(today.addingTimeInterval(-1), count: 5), receipt(week, count: 7),
    receipt(week.addingTimeInterval(-1), count: 11), receipt(now.addingTimeInterval(1), count: 99),
    receipt(now, count: 101, outcome: "verifying"), receipt(now, count: 103, outcome: "unverified")]
  catalog.lifetimeVerified = 1000
  catalog.lifetimeResidentReleased = 100_000
  catalog.lifetimeCPUSecondsSaved = 10_000
  let day = ImpactNumbers.make(catalog: catalog, period: .today, now: now, calendar: calendar)
  equal(day.count, 5, "Today must use local completion date, excluding future/pending/failed receipts")
  equal(day.memory, 500); equal(day.cpuSeconds, 50)
  equal(day.latestCount, 3); equal(day.after, 3); equal(day.last, now)
  let seven = ImpactNumbers.make(catalog: catalog, period: .week, now: now, calendar: calendar)
  equal(seven.count, 17, "7 days must include today and six preceding calendar dates")
  equal(seven.memory, 1700); equal(seven.cpuSeconds, 170)
  let all = ImpactNumbers.make(catalog: catalog, period: .all, now: now, calendar: calendar)
  equal(all.count, 1000); equal(all.memory, 100_000); equal(all.cpuSeconds, 10_000)
  equal(all.latestCount, 3, "Recent card must follow completion order")
  catalog.events = []
  let retained = ImpactNumbers.make(catalog: catalog, period: .all, now: now, calendar: calendar)
  equal(retained.count, all.count); equal(retained.memory, all.memory); equal(retained.cpuSeconds, all.cpuSeconds)
  for period in ImpactPeriod.allCases {
    let empty = ImpactNumbers.make(catalog: Catalog(), period: period, now: now, calendar: calendar)
    equal(empty.count, 0); equal(empty.memory, 0); equal(empty.cpuSeconds, 0)
    isNil(empty.last); isNil(empty.before); equal(empty.boost, "—")
  }
  // Older receipts did not store verificationDate or CPU projections.
  var legacy = receipt(today, count: 4)
  legacy.date = today; legacy.verificationDate = nil; legacy.cpuSecondsSavedEstimate = nil
  catalog.events = [legacy]
  let migrated = ImpactNumbers.make(catalog: catalog, period: .today, now: now, calendar: calendar)
  equal(migrated.count, 4); isNil(migrated.cpuSeconds)
  // Midnight rollover and the same instant viewed in a different local time zone.
  equal(ImpactNumbers.make(catalog: catalog, period: .today,
    now: calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar).count, 0)
  var tokyo = calendar; tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
  equal(ImpactNumbers.make(catalog: catalog, period: .today, now: now, calendar: tokyo).count, 0)
  for (instant, expectedStart) in [
    ("2026-03-09T18:00:00Z", "2026-03-03T07:00:00Z"),
    ("2026-11-02T19:00:00Z", "2026-10-27T06:00:00Z")
  ] {
    equal(ImpactPeriod.week.start(now: date(instant), calendar: calendar), date(expectedStart),
      "7-day boundary must survive daylight-saving changes")
  }
  var demo = Demo.state(now: now, calendar: calendar).catalog
  let expected = [128, 368, 880]
  for (period, count) in zip(ImpactPeriod.allCases, expected) {
    equal(ImpactNumbers.make(catalog: demo, period: period, now: now, calendar: calendar).count, count,
      "Preview must respect selected period")
  }
  Demo.recordBurn(in: &demo, now: now)
  for (period, count) in zip(ImpactPeriod.allCases, expected) {
    equal(ImpactNumbers.make(catalog: demo, period: period, now: now, calendar: calendar).count, count + 18,
      "A new receipt must update every applicable period once")
  }
}
