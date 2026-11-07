import BurnCore
import Foundation

/// Words the Burn Log used to be full of. Nothing a row says may use them, old row or new.
private let oldWords = [
  "resident", "upper-bound", "attribut", "verified parent", "reparented", "replacement",
  "escalation", "benefit", "credit", "continuity", "bounded", "graceful", "observation",
  "visibility", "receipt", "regenerable", "reconcile", "fixture", "owner-protocol",
  "autopilot (", "rule:", "pid ", "errno", "worktree",
]
private func plain(_ text: String, _ what: String) {
  let lower = text.lowercased()
  for word in oldWords where lower.contains(word) {
    failTest("\(what) still says \"\(word)\": \(text)")
  }
}

/// Every burn is in the log once, whichever list holds it. What a row says is worked out from how
/// the burn ended, so a row saved in older words reads the same as a new one.
func burnLogProof() throws {
  let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
  func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
  func program(
    _ label: String, _ hours: Double, _ outcome: String = "verified", count: Int = 1,
    detail: String = "Saved words"
  ) -> CleanupEvent {
    var event = CleanupEvent(
      leaseID: UUID(), label: label, date: hoursAgo(hours),
      targets: (0..<count).map {
        Member(Observation(identity: .init(pid: 4321 + Int32($0), seconds: 1)))
      },
      residentBefore: 1_500_000_000, outcome: outcome, detail: detail)
    event.verifiedCount = outcome == "verified" ? count : 0
    return event
  }
  func burn(
    _ name: String, _ kind: AutopilotKind, _ hours: Double, outcome: String = "burned",
    bytes: UInt64 = 2_000_000_000, detail: String = "Saved words", eventID: UUID? = nil
  ) -> AutopilotReceipt {
    AutopilotReceipt(
      itemID: kind.rawValue + ":" + name, kind: kind, name: name, authority: "rule:fixture",
      outcome: outcome, detail: detail, bytes: bytes, date: hoursAgo(hours), eventID: eventID)
  }

  // Programs sit in both lists. Copies and junk folders sit only in Autopilot's receipts. What
  // BZ only tried isn't a burn. A burn stays on file past the log's 30 days, and the log lets it go.
  let java = program("java", 3)
  var catalog = Catalog()
  catalog.events = [java]
  let rows = catalog.burnLog(
    autopilot: [
      burn("java", .process, 3, detail: "Stopped and verified.", eventID: java.id),
      burn("old-copy", .worktree, 1),
      burn("node_modules in app", .disk, 2),
      burn("refused-copy", .worktree, 0.5, outcome: "refused", bytes: 0),
      burn("failed-copy", .worktree, 0.25, outcome: "failed", bytes: 0),
      burn("failed-java", .process, 0.1, outcome: "failed", eventID: UUID()),
      burn("restored-copy", .worktree, 4, outcome: "restored"),
      burn("event-gone", .process, 5, detail: "Stopped and verified.", eventID: UUID()),
      burn("last-month", .worktree, 31 * 24),
    ], now: now)
  equal(
    rows.map(\.title), ["old-copy", "node_modules in app", "java", "restored-copy", "event-gone"],
    "The log lists each burn once, newest first")
  equal(
    rows.map(\.kind), [.copy, .folder, .program, .copy, .program], "Each row knows what it burned")
  equal(
    rows.map(\.result), ["2.0 GB disk", "2.0 GB disk", "1.5 GB memory", "Restored", "2.0 GB memory"],
    "Each row says what it freed, in memory or on disk")
  check(rows.map(\.id).count == Set(rows.map(\.id)).count, "Each row has its own id")
  equal(
    rows.map { $0.finishedAt != nil }, [true, true, true, false, true],
    "A burn that came back isn't a finished burn")
  equal(
    rows.first { $0.title == "java" }?.finishedAt, java.date,
    "A program finishes when it's checked, or when it's asked")
  var checked = java
  checked.verificationDate = hoursAgo(2.9)
  equal(BurnLogRow.helpers(checked).finishedAt, hoursAgo(2.9), "A checked program counts from then")
  equal(BurnLogRow.helpers(program("java", 1, "verifying")).finishedAt, nil, "A check is unfinished")
  var pretend = java
  pretend.fixture = true
  equal(BurnLogRow.helpers(pretend).finishedAt, nil, "A test burn doesn't count")

  // Nothing for a kind that isn't there, and an empty catalog stays empty.
  equal(Catalog().burnLog(autopilot: [], now: now).count, 0, "No burns, no rows")
  equal(
    catalog.burnLog().map(\.title), ["java"], "Without Autopilot the log still lists the catalog")

  // Every way a program's burn can end, in the words it was saved with over the app's life. A
  // verified row may say why the memory number can read high; none talks like a receipt.
  let saved: [(String, String, String)] = [
    (
      "verified", "Stopped. BZ checked",
      "Exact targets exited; no replacement was observed under the same verified parent during the 120-second watch. Reparented or differently owned replacements cannot be attributed. Resident footprint is an upper-bound attribution."
    ),
    (
      "verifying", "checking",
      "Autopilot (rule:abcdef): It's old. Graceful stop requested; verifying exits."
    ),
    ("verifying", "checking", "Agent decision: done. Graceful stop requested; verifying exits."),
    (
      "prepared", "checking",
      "Owner-protocol decision: done. Revalidating exact daemon; no benefit credited."
    ),
    (
      "unverified", "doesn't count",
      "Observation was interrupted by restart, sleep, or a sampling gap. No benefit credited."
    ),
    ("unverified", "doesn't count", "Visibility was lost during verification. No benefit credited."),
    (
      "unverified", "doesn't count",
      "Owner watch lost continuity or exceeded its bounded wait; no escalation or credit."
    ),
    (
      "partial", "doesn't count",
      "A helper remained after the 15-second graceful deadline. No escalation and no benefit credited."
    ),
    ("partial", "doesn't count", "PID 4321: errno 1. No benefit credited."),
    (
      "reappeared", "doesn't count",
      "A new matching helper appeared under the same verified parent after cleanup. Possible recurrence; no benefit credited. Inspect the creator."
    ),
    ("refused", "doesn't count", "No signal dispatched: Fresh process visibility unavailable."),
  ]
  for (outcome, says, old) in saved {
    let row = BurnLogRow.helpers(program("java", 1, outcome, detail: old))
    plain(row.words, "An opened \(outcome) row")
    plain(row.result, "A \(outcome) row's result")
    check(row.words.contains(says), "An opened \(outcome) row says \"\(says)\": \(row.words)")
    let words = row.words.split(whereSeparator: \.isWhitespace).count
    check(words <= 25, "An opened \(outcome) row is short, not \(words) words: \(row.words)")
  }
  check(
    BurnWords.stopped(19).contains("they stayed gone"), "Many programs read as many")
  check(BurnWords.stopped(0).contains("it stayed gone"), "A row without its targets reads as one")
  equal(
    BurnLogRow.helpers(program("node", 1, count: 19)).result, "19 programs · 1.5 GB memory",
    "A burn of many programs counts them")
  equal(
    BurnLogRow.helpers(program("node", 1, count: 19)).words,
    BurnWords.program("verified", count: 19), "and reads as many")
  // An outcome nobody planned for still says what it was saved with.
  equal(BurnLogRow.helpers(program("java", 1, "new", detail: "New words")).words, "New words")
  equal(BurnLogRow.helpers(program("java", 1, "new")).result, "New")

  // A program interrupted while it was being checked is saved in the same words.
  var interrupted = Catalog()
  interrupted.events = [program("java", 1, "verifying", detail: "Pending")]
  interrupted.resetContinuity()
  equal(interrupted.events[0].detail, BurnWords.lostTrack, "Saved in the new words")

  // Autopilot's own words stay, and a sentence nobody would say gets said plainly.
  let copy = BurnLogRow.autopilot(
    burn(
      "old-copy", .worktree, 1,
      detail: "Removed. Everything in it was already saved, so you can restore it."))
  check(copy.words.hasPrefix("Removed. Everything in it was already saved"), copy.words)
  check(copy.words.contains("restore it in Findings"), "It says where: " + copy.words)
  var placed = burn(
    "old-copy", .worktree, 1,
    detail: "Removed. Your unsaved changes are backed up, so you can restore it.")
  placed.restore = AutopilotRestore(
    repository: "/example/.git", path: "/example/old-copy", ref: "refs/x", head: "abc", branch: nil,
    snapshot: false)
  check(BurnLogRow.autopilot(placed).words.hasSuffix("\n/example/old-copy"), "It says which one")
  let folder = BurnLogRow.autopilot(
    burn(
      "build in app", .disk, 1,
      detail: "Cleared build in app. Unique contents are encrypted and restorable."))
  plain(folder.words, "An opened junk folder row")
  checkFalse(folder.words.contains("Unique contents"), "Said plainly: " + folder.words)
  check(folder.words.hasPrefix("Cleared build in app."), folder.words)
  check(folder.words.contains(AutopilotDisk.backedUpWords), "Saved the same way: " + folder.words)
  let stopped = BurnLogRow.autopilot(
    burn("event-gone", .process, 1, detail: "Stopped and verified.", eventID: UUID()))
  equal(stopped.words, BurnWords.stopped(), "A program reads the same from either list")
  // A burn that freed nothing says it burned, not "0 GB".
  equal(
    BurnLogRow.autopilot(burn("empty", .worktree, 1, bytes: 0)).result, "Burned",
    "A burn that freed nothing still burned")

  // The older cleaners' rows read plainly too, and keep what only they know.
  var retired = try require(Demo.state().catalog.workspaceReceipts?.first, "a demo worktree receipt")
  retired.label = "Worktree retired"
  retired.identity.path = "/example/old-worktree"
  retired.outcome = "verified"
  retired.diskReclaimedBytes = 3_000_000_000
  retired.detail = "Retired. Restore through Worktrees → Recovery: 1234"
  equal(BurnLogRow.worktree(retired).title, "old-worktree", "A copy goes by its folder's name")
  equal(BurnLogRow.worktree(retired).kind, .copy)
  equal(BurnLogRow.worktree(retired).result, "3.0 GB disk")
  plain(BurnLogRow.worktree(retired).words, "An opened old worktree row")
  retired.outcome = "unverified"
  retired.detail =
    "Workspace operation interrupted. Preserve the recovery ref; no disk or worktree credit without the completed receipt."
  plain(BurnLogRow.worktree(retired).words, "An interrupted old worktree row")
  check(BurnLogRow.worktree(retired).words.contains("doesn't count"), "It doesn't count")
  equal(BurnLogRow.worktree(retired).result, "Not sure")

  func output(_ outcome: String, _ rationale: String) throws -> DiskReceipt {
    var receipt = try JSONDecoder().decode(
      DiskReceipt.self,
      from: Data(
        #"{"id":"C2C2C2C2-0000-4000-8000-000000000001","candidateID":"fixture","path":"/example/build","date":0,"outcome":"verified","allocatedRemoved":1,"diskReclaimedBytes":1000000000,"rationale":""}"#
          .utf8))
    receipt.outcome = outcome
    receipt.rationale = rationale
    return receipt
  }
  let done = BurnLogRow.output(
    try output("verified", "Nothing uses it. Recovery location if interrupted: /example/pending"))
  equal(done.title, "build", "An old folder goes by its name")
  equal(done.kind, .folder)
  equal(done.result, "1.0 GB disk")
  check(done.words.hasPrefix("Nothing uses it."), "It keeps why: " + done.words)
  check(done.words.hasSuffix("\n/example/build"), "and where: " + done.words)
  checkFalse(done.words.contains("/example/pending"), "A finished burn has nothing to recover")
  let cut = BurnLogRow.output(
    try output(
      "unverified",
      "Nothing uses it. Recovery location if interrupted: /example/pending Interrupted cleanup: inspect or restore its pending location from Impact. No removal credit is known."
    ))
  equal(cut.result, "Not sure")
  check(cut.words.contains("/example/pending"), "It still says where it waits: " + cut.words)
  check(cut.words.contains("/example/build"), "and where it belongs: " + cut.words)
  checkFalse(cut.words.contains("Interrupted cleanup"), "Said plainly: " + cut.words)
  checkFalse(cut.words.contains("credit"), "Said plainly: " + cut.words)
  let back = BurnLogRow.output(
    try output(
      "refused",
      "Exact pending directory restored and its full original contents verified. No cleanup credit. A new decision is required."
    ))
  equal(back.result, "Left alone")
  plain(back.words, "A folder that came back")
  check(back.words.contains("doesn't count"), "It doesn't count: " + back.words)
  let lost = BurnLogRow.output(
    try output(
      "reconciled",
      "Both recorded locations are absent; removal attribution is unknown. Reservation reconciled without cleanup or disk credit."
    ))
  plain(lost.words, "A folder nobody can find")
  plain(lost.result, "A folder nobody can find")
  check(lost.words.contains("doesn't count"), "It doesn't count: " + lost.words)

  // What the windows get: the newest 100 of anything, and every burn on file, newest first.
  var history = (0..<300).map { burn("copy-\($0)", .worktree, Double(1000 - $0)) }
  history += (0..<200).map {
    burn("refused-\($0)", .worktree, Double(600 - $0), outcome: "refused", bytes: 0)
  }
  history.append(burn("restored-copy", .worktree, 1, outcome: "restored"))
  let shown = Autopilot.shownReceipts(history)
  equal(shown.first?.name, "restored-copy", "Newest first")
  equal(shown.filter { $0.outcome == "burned" }.count, 300, "Every burn on file")
  equal(shown.filter { $0.outcome == "refused" }.count, 99, "and the newest of anything else")
  equal(shown.filter { $0.outcome == "restored" }.count, 1, "and what came back")
  equal(shown.count, 400, "Nothing twice")
}

/// The window really gets them: past the newest 100 receipts, from the engine's own snapshot.
func burnLogSnapshotProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-burn-log-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try AutopilotStore(root: root)
  let now = Date()
  func receipt(_ name: String, _ outcome: String, minutes: Double) -> AutopilotReceipt {
    AutopilotReceipt(
      itemID: "worktree:" + name, kind: .worktree, name: name, authority: "rule:fixture",
      outcome: outcome, detail: "Saved words", bytes: 1_000_000,
      date: now.addingTimeInterval(-minutes * 60))
  }
  try store.updateReceipts { all in
    for i in 0..<150 { all.append(receipt("copy-\(i)", "burned", minutes: Double(1000 - i))) }
    for i in 0..<300 { all.append(receipt("waiting-\(i)", "refused", minutes: Double(500 - i))) }
  }
  let engine = try Autopilot(root: root, sources: TellWorld().sources)
  let snapshot = await engine.snapshot(now: now)
  equal(snapshot.receipts.first?.name, "waiting-299", "Newest first, as the windows expect")
  let rows = Catalog().burnLog(autopilot: snapshot.receipts, now: now)
  equal(rows.count, 150, "The Burn Log lists every burn, not only the newest 100 receipts")
  equal(rows.first?.title, "copy-149", "newest first")
  equal(rows.last?.title, "copy-0", "down to the oldest on file")
}

private func require<T>(_ value: T?, _ what: String) throws -> T {
  guard let value else { throw StoreError.message("Missing: " + what) }
  return value
}
