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
  // Autopilot's cleanups count like any other: copies as worktrees cleaned, copies and junk
  // folders as disk reclaimed. On a real Mac both read 0 while Autopilot freed hundreds of GB.
  var autopilot = AutopilotImpact()
  autopilot.worktrees = 40
  autopilot.bytes = 900_000_000_000
  autopilot.cleanups = [
    .init(receiptID: UUID(), date: now, worktree: true, bytes: 3_000_000_000),
    .init(receiptID: UUID(), date: today, worktree: false, bytes: 1_000_000_000),
    .init(receiptID: UUID(), date: week, worktree: true, bytes: 5_000_000_000),
    .init(receiptID: UUID(), date: week.addingTimeInterval(-1), worktree: true, bytes: 7_000_000_000),
    .init(receiptID: UUID(), date: now.addingTimeInterval(1), worktree: true, bytes: 11_000_000_000),
  ]
  var manual = Catalog()
  manual.lifetimeWorktreesCleaned = 2
  manual.lifetimeDiskReclaimedBytes = 80_000
  func cleaned(_ period: ImpactPeriod) -> ImpactNumbers {
    ImpactNumbers.make(catalog: manual, autopilot: autopilot, period: period, now: now, calendar: calendar)
  }
  equal(cleaned(.today).worktrees, 1, "Autopilot's copies count as worktrees cleaned today")
  equal(cleaned(.today).disk, 4_000_000_000, "its copies and junk folders count as disk reclaimed today")
  equal(cleaned(.week).worktrees, 2, "7 days")
  equal(cleaned(.week).disk, 9_000_000_000, "7 days")
  equal(cleaned(.all).worktrees, 42, "all time adds Autopilot's tally to earlier cleanups")
  equal(cleaned(.all).disk, 900_000_080_000, "all time")
  equal(cleaned(.all).lifetimeWorktrees, 42)
  // "Last burn" counts them too; a real Mac said "No burns yet today" right after one.
  equal(cleaned(.all).last, now, "Autopilot's latest cleanup is the last burn")
  try autopilotImpactProof()
}

/// Autopilot's cleanups are tallied apart from its receipts, which keep only the latest 500, so
/// the totals never go down when old receipts are trimmed.
func autopilotImpactProof() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("bz-autopilot-impact-" + UUID().uuidString)
  defer { try? fm.removeItem(at: root) }
  let now = Date()
  let day: TimeInterval = 86_400
  func receipt(_ kind: AutopilotKind, _ outcome: String, _ bytes: UInt64, _ date: Date) -> AutopilotReceipt {
    AutopilotReceipt(
      itemID: kind.rawValue + ":" + UUID().uuidString, kind: kind, name: "fixture",
      authority: "rule:fixture", outcome: outcome, detail: "", bytes: bytes, date: date)
  }
  // An install that burned things before the tally existed: each burn counts once.
  let old = receipt(.worktree, "burned", 1_000_000_000, now.addingTimeInterval(-10 * day))
  let copy = receipt(.worktree, "burned", 3_000_000_000, now.addingTimeInterval(-3 * day))
  let folder = receipt(.disk, "burned", 1_000_000_000, now)
  let earlier = [
    old, copy, folder, receipt(.worktree, "refused", 9_000_000_000, now),
    receipt(.worktree, "failed", 9_000_000_000, now), receipt(.process, "burned", 9_000_000_000, now),
  ]
  let directory = root.appendingPathComponent("autopilot", isDirectory: true)
  try fm.createDirectory(at: directory, withIntermediateDirectories: true)
  try JSONEncoder().encode(earlier).write(to: directory.appendingPathComponent("receipts.json"))
  let store = try AutopilotStore(root: root)
  try store.refreshImpact()
  var impact = try store.impact()
  equal(impact.worktrees, 2, "burned copies count as worktrees cleaned")
  equal(
    impact.bytes, 5_000_000_000,
    "burned copies and junk folders count as disk reclaimed; refusals, failures and programs don't")
  try store.refreshImpact()
  equal(try store.impact(), impact, "counting again changes nothing")

  // Trimming old receipts never lowers the totals, and a week of cleanups stays for 7 days.
  let junk = UInt64(AutopilotStore.maximumReceipts) * 1_000_000
  try store.updateReceipts { all in
    for _ in 0..<AutopilotStore.maximumReceipts { all.append(receipt(.disk, "burned", 1_000_000, now)) }
  }
  let kept = try store.receipts()
  checkFalse(kept.contains { $0.id == copy.id }, "the oldest burns were trimmed")
  impact = try store.impact()
  equal(impact.worktrees, 2, "trimming kept the copies")
  equal(impact.bytes, 5_000_000_000 + junk, "trimming kept the bytes")
  check(impact.cleanups.contains { $0.receiptID == copy.id }, "a 3-day-old cleanup stays for 7 days")
  checkFalse(
    impact.cleanups.contains { $0.receiptID == old.id },
    "a 10-day-old cleanup whose receipt is gone is no longer listed")

  // A restore takes its share back.
  let restored = receipt(.worktree, "burned", 2_000_000_000, now)
  try store.append(restored)
  equal(try store.impact().worktrees, 3, "a new burn counts at once")
  try store.updateReceipts { all in
    if let i = all.firstIndex(where: { $0.id == restored.id }) { all[i].outcome = "restored" }
  }
  impact = try store.impact()
  equal(impact.worktrees, 2, "a restored copy is no longer counted")
  equal(impact.bytes, 5_000_000_000 + junk, "nor are its bytes")
}
