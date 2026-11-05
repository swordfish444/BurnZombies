import BurnCore
import Foundation

private final class Burns: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ value: String) { lock.withLock { values.append(value) } }
  var all: [String] { lock.withLock { values } }
}

/// Look-only: Autopilot finds, sizes and asks as usual, but nothing burns on its own (a starter
/// rule, a yes answer or the AI) until the owner turns burning on; then what waited burns at once.
/// The owner's own Burn now is the owner acting, so it still burns the one thing picked.
func lookOnlyProof() async throws {
  let before = failures
  let root = URL(fileURLWithPath: "/private/tmp/bz-look-" + UUID().uuidString.prefix(8))
  defer { try? FileManager.default.removeItem(at: root) }
  let burns = Burns()
  let gone = Burns()
  let safe = AutopilotItem(
    id: "process:safe", kind: .process, name: "vitest", bytes: 200 << 20,
    facts: [
      "family": "node", "orphaned": "yes", "thread": "ended", "idle": "1d", "listening": "no",
      "agent": "claude",
    ], processKey: "safe")
  let server = AutopilotItem(
    id: "process:server", kind: .process, name: "vite", bytes: 3 << 30,
    facts: [
      "family": "node", "orphaned": "yes", "thread": "none", "idle": "1d", "listening": "yes",
      "agent": "none",
    ], processKey: "server")
  let copy = AutopilotItem(
    id: "worktree:c", kind: .worktree, name: "atlas-fix", bytes: 2 << 30,
    facts: [
      "place": "patrol6", "saved": "pushed", "changes": "none", "stale": "older", "inUse": "no",
      "thread": "none",
    ])
  let sources = AutopilotSources(
    processes: { _ in [safe, server].filter { !gone.all.contains($0.id) } },
    worktrees: { _, _, d in ([copy].filter { !gone.all.contains($0.id) }, d) },
    burnProcess: { item, authority, _ in
      burns.add(item.id + "@" + authority)
      gone.add(item.id)
      return UUID()
    },
    processOutcome: { _ in ("verified", "") },
    retireWorktree: { item, authority in
      burns.add(item.id + "@" + authority)
      gone.add(item.id)
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: authority,
        outcome: "burned", detail: "", bytes: item.bytes)
    })

  // The installer's step with no app running goes straight to the state folder.
  try Autopilot.setLookOnly(true, root: root)
  let store = try AutopilotStore(root: root)
  equal(try store.sweep().lookOnly, true, "setup turns look-only on")
  let engine = try Autopilot(root: root, sources: sources)
  let now = Date()
  var snapshot = await engine.tick(now: now)
  equal(burns.all, [], "a starter rule's match waits")
  equal(snapshot.count(.burn), 1, "and shows as what BZ would burn")
  check(snapshot.questions.contains { $0.kind == .process }, "BZ still asks")

  // The AI still learns to ask about what it may not burn: look-only isn't a reason to stop asking.
  let unsure = await engine.burn([server.id])
  check(unsure.first?.detail.contains("autopilot_ask") == true, "an unsure item still says to ask")

  // A yes teaches a rule, and its matches wait too.
  guard let question = snapshot.questions.first(where: { $0.kind == .process }) else {
    failTest("look-only asks about the server")
    return
  }
  snapshot = try await engine.apply(.answer(questionID: question.id, answer: .yes), now: now)
  check(snapshot.rules.contains { $0.questionID == question.id }, "the answer is kept as a rule")
  // The answer's burn pass runs in the background; give it time to do nothing.
  try await Task.sleep(nanoseconds: 500_000_000)
  equal(burns.all, [], "a yes answer's matches wait")

  // The AI judges as usual; its burn is held with a reason and leaves nothing behind.
  let authorized = try await engine.decide([
    AutopilotJudgment(
      itemID: copy.id, revision: "", verdict: .burn, confidence: 0.92, label: "Old atlas copy",
      why: "Its work is on GitHub and nobody touched it in months.")
  ])
  equal(authorized, [copy.id], "a confident verdict still authorizes the copy")
  let held = await engine.burn([copy.id])
  equal(held.first?.outcome, "refused")
  check(held.first?.detail.hasPrefix("Look-only") == true, "the AI hears why: \(held)")
  let page = await engine.catalogPage(status: nil, kind: nil, offset: 0, limit: 10)
  equal(page.summary["lookOnly"], "true", "the AI's catalog says look-only")
  snapshot = await engine.tick(now: now.addingTimeInterval(60))
  equal(burns.all, [], "nothing burned while look-only")
  equal(try store.receipts().count, 0, "no receipts")
  equal(try store.sweep().log.count, 0, "and no activity lines")
  equal(snapshot.count(.burn), 3, "the starter match, the answer's match and the AI's pick wait")
  equal(AutopilotSummary(snapshot).lookOnly, true, "the command line's snapshot says look-only")

  // A sweep state it can't read can't turn look-only off.
  let sweepFile = store.directory.appendingPathComponent("sweep.json")
  let saved = try Data(contentsOf: sweepFile)
  try Data("{".utf8).write(to: sweepFile)
  _ = await engine.tick(now: now.addingTimeInterval(120))
  equal(burns.all, [], "an unreadable sweep state holds every burn")
  try saved.write(to: sweepFile)
  _ = try await engine.apply(.setEnabled(false))
  _ = try await engine.apply(.setEnabled(true))
  equal(try store.sweep().lookOnly, true, "switching Autopilot off and on keeps look-only")

  // Burn now is the owner acting: it burns the one thing picked, and nothing else.
  _ = try await engine.apply(.burnNow(itemID: server.id), now: now.addingTimeInterval(180))
  equal(burns.all, [server.id + "@operator"], "Burn now still burns what the owner picked")

  // Start burning (Settings or the panel): what waited burns right away, not at the next look.
  snapshot = try await engine.apply(.setLookOnly(false), now: now.addingTimeInterval(240))
  isNil(snapshot.sweep.lookOnly)
  for _ in 0..<100 where burns.all.count < 3 { try await Task.sleep(nanoseconds: 50_000_000) }
  // The yes answer covers the starter rule's match too, so it burns under the owner's rule.
  equal(burns.all.count, 3, "each burns once: \(burns.all)")
  check(burns.all.contains { $0.hasPrefix(safe.id + "@rule:") }, "the answer's match burns")
  check(burns.all.contains(copy.id + "@ai:0.92"), "the AI's pick burns")
  if failures == before {
    print("PASS look-only: finds, asks and judges, burns nothing until burning starts")
  }
}
