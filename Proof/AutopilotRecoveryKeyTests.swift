import BurnCore
import CryptoKit
import Foundation

/// The backup key never stalls Autopilot. A key read that would show macOS's keychain question, or
/// never return at all, refuses the copy within a bound; the burn pass and later ticks go on; the
/// owner allows the key once from the menu, and what waited burns. No real keychain is touched.
func autopilotRecoveryKeyProof() async throws {
  try recoveryKeyGateProof()
  try await recoveryKeyEngineProof()
}

private let rkKey = SymmetricKey(data: Data(repeating: 0x5a, count: 32))
private func rkBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
private struct RKRefused: Error {}

/// A stand-in for the keychain. While macOS's question is up, every read waits, as
/// `SecItemCopyMatching` does; a quiet read that macOS would ask about fails instead. The owner's
/// answer (an interactive read, or `answer()`) lets every waiting read return the key.
private final class RKKeychain: @unchecked Sendable {
  private let condition = NSCondition()
  private var answered = false
  private var quietCalls = 0
  private var interactiveCalls = 0
  /// Quiet reads wait for the owner (`true`) or fail at once like a read macOS would ask about.
  let quietBlocks: Bool
  /// What the owner's interactive read gets: the key, or no (Deny).
  var allows = true
  /// Interactive reads wait for `answer()` instead of answering themselves.
  var interactiveBlocks = false
  init(quietBlocks: Bool) { self.quietBlocks = quietBlocks }
  var quiet: Int { condition.withLock { quietCalls } }
  var interactive: Int { condition.withLock { interactiveCalls } }
  func read(_ interactive: Bool, _ create: Bool) throws -> SymmetricKey {
    condition.lock()
    defer { condition.unlock() }
    if interactive {
      interactiveCalls += 1
      while interactiveBlocks && !answered { condition.wait() }
      guard allows else { throw RKRefused() }
      answered = true
      condition.broadcast()
      return rkKey
    }
    quietCalls += 1
    if answered { return rkKey }
    guard quietBlocks else { throw RKRefused() }
    while !answered { condition.wait() }
    return rkKey
  }
  /// The owner answers macOS's question with Always Allow.
  func answer() {
    condition.withLock {
      answered = true
      condition.broadcast()
    }
  }
}

private func rkWaitUntil(_ seconds: TimeInterval, _ done: () -> Bool) {
  let end = Date().addingTimeInterval(seconds)
  while !done() && Date() < end { usleep(20_000) }
}

private func recoveryKeyGateProof() throws {
  let before = failures
  let bound: TimeInterval = 0.5

  // A read that never answers: the burn moves on after the bound, and a wait starts.
  let stuck = RKKeychain(quietBlocks: true)
  let gate = AutopilotRecoveryKey(bound: bound, read: stuck.read)
  isNil(gate.wait)
  var started = Date()
  do {
    _ = try gate.forBurn()
    failTest("a key read that never answers gave a key")
  } catch let waiting as AutopilotRecoveryKey.Waiting {
    equal(waiting.localizedDescription, AutopilotRecoveryKey.refusal, "the refusal is plain")
  } catch { failTest("a stuck key read threw \(error)") }
  var took = Date().timeIntervalSince(started)
  check(took >= bound * 0.8, "the burn gave the read its bound: \(took)")
  check(took < bound + 2, "the burn didn't wait on the read past its bound: \(took)")
  check(gate.wait != nil, "a late read starts a wait for the owner")
  equal(gate.wait?.asking, false, "nothing asks the owner on its own")

  // While that read is out, the next burn doesn't wait and no second read starts.
  started = Date()
  throwsError(try gate.forBurn())
  took = Date().timeIntervalSince(started)
  check(took < 0.2, "a second burn refuses at once while the first read is out: \(took)")
  equal(stuck.quiet, 1, "only one quiet read is ever outstanding")

  // The owner answers macOS's question: the late read returns the key and the wait ends.
  stuck.answer()
  rkWaitUntil(2) { gate.wait == nil }
  isNil(gate.wait)
  equal(rkBytes(try gate.forBurn()), rkBytes(rkKey), "the next burn reads the key")
  equal(stuck.interactive, 0, "a burn never reads with a question allowed")

  // A read macOS would ask about fails quietly: a wait starts, and the owner's Allow ends it.
  let locked = RKKeychain(quietBlocks: false)
  let asked = AutopilotRecoveryKey(bound: bound, read: locked.read)
  started = Date()
  throwsError(try asked.forBurn())
  check(Date().timeIntervalSince(started) < bound, "a quiet refusal comes back at once")
  check(asked.wait != nil, "a refused quiet read starts a wait")
  equal(locked.interactive, 0, "no question was shown")

  // The owner says no in macOS's dialog: the wait stays and the reason is plain.
  locked.allows = false
  do {
    try asked.allow()
    failTest("Allow said yes when macOS said no")
  } catch {
    equal(
      error.localizedDescription, AutopilotRecoveryKey.notAllowed, "a Deny is said plainly")
  }
  check(asked.wait != nil, "after a Deny old copies still wait")
  equal(asked.wait?.asking, false, "and the question is no longer up")

  // While macOS's question is up, the wait says so; Always Allow ends it.
  locked.allows = true
  locked.interactiveBlocks = true
  let allowing = Thread { try? asked.allow() }
  allowing.start()
  rkWaitUntil(2) { asked.wait?.asking == true }
  equal(asked.wait?.asking, true, "the menu can say macOS is asking now")
  locked.answer()
  rkWaitUntil(2) { asked.wait == nil }
  isNil(asked.wait)
  equal(rkBytes(try asked.forBurn()), rkBytes(rkKey), "after Always Allow, burns read the key")

  // Undo reads with a question allowed too, and its key ends a wait.
  let undo = RKKeychain(quietBlocks: false)
  let restoring = AutopilotRecoveryKey(bound: bound, read: undo.read)
  throwsError(try restoring.forBurn())
  check(restoring.wait != nil, "a wait started")
  equal(rkBytes(try restoring.forOwner(create: false)), rkBytes(rkKey), "Undo reads the key")
  equal(undo.interactive, 1, "Undo may ask")
  isNil(restoring.wait)

  if failures == before { print("PASS backup key: a read that never answers holds nothing up") }
}

private final class RKBurns: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ value: String) { lock.withLock { values.append(value) } }
  var all: [String] { lock.withLock { values } }
}

private func recoveryKeyEngineProof() async throws {
  let before = failures
  let bound: TimeInterval = 0.5
  let root = URL(fileURLWithPath: "/private/tmp/bz-key-" + UUID().uuidString.prefix(8))
  defer { try? FileManager.default.removeItem(at: root) }
  let keychain = RKKeychain(quietBlocks: true)
  let gate = AutopilotRecoveryKey(bound: bound, read: keychain.read)
  let burned = RKBurns()
  // Old copies a starter rule burns without asking.
  let facts = [
    "saved": "merged", "changes": "none", "stale": "month", "inUse": "no", "thread": "none",
    "place": "other",
  ]
  let copies = ["a", "b"].map {
    AutopilotItem(
      id: "worktree:" + $0, kind: .worktree, name: "copy-" + $0, bytes: 3 << 30, facts: facts)
  }
  let sources = AutopilotSources(
    worktrees: { _, _, d in (copies.filter { !burned.all.contains($0.id) }, d) },
    retireWorktree: { item, authority in
      // As retire does: the key right before the backup, never with a question.
      do { _ = try gate.forBurn() } catch {
        return .refused(item, authority: authority, error.localizedDescription)
      }
      burned.add(item.id)
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: authority,
        outcome: "burned", detail: "Removed.", bytes: item.bytes)
    },
    recoveryKeyWait: { gate.wait },
    allowRecoveryKey: { try gate.allow() })
  let engine = try Autopilot(root: root, sources: sources)
  let store = try AutopilotStore(root: root)
  let now = Date()

  // The first look: the key read never answers, yet the tick finishes.
  var started = Date()
  var snapshot = await engine.tick(now: now)
  let took = Date().timeIntervalSince(started)
  check(took < bound + 3, "a key read that never answers doesn't hold the tick: \(took)")
  var receipts = try store.receipts()
  equal(receipts.count, 1, "one copy carries the refusal; the other waits without a receipt")
  equal(receipts.first?.outcome, "refused")
  equal(receipts.first?.detail, AutopilotRecoveryKey.refusal, "the refusal says what to do")
  equal(burned.all, [], "nothing burned without the key")
  check(snapshot.recoveryKey != nil, "the snapshot says old copies wait for the owner")
  equal(keychain.interactive, 0, "BZ never asked on its own")

  // The next tick runs, and writes nothing new while the key waits.
  started = Date()
  snapshot = await engine.tick(now: now.addingTimeInterval(900))
  check(Date().timeIntervalSince(started) < bound + 3, "the next tick isn't stuck behind it")
  let lastTick = try store.sweep().lastTick ?? .distantPast
  check(abs(lastTick.timeIntervalSince(now) - 900) < 1, "the next tick ran: \(lastTick)")
  receipts = try store.receipts()
  equal(receipts.count, 1, "a waiting copy is held, and its refusal stands while the key waits")
  equal(keychain.quiet, 1, "no second read piled up behind the stuck one")
  check(snapshot.recoveryKey != nil, "still waiting for the owner")

  // An agent can't make macOS ask: only the owner's click can.
  var request = AutopilotRequest(tool: "command")
  request.command = .allowRecoveryKey
  let (ok, reply) = await engine.handle(request)
  checkFalse(ok, "the socket can't send Allow: \(reply)")
  equal(keychain.interactive, 0, "no question was shown for the socket")

  // The owner clicks Allow and chooses Always Allow: what waited burns at once.
  snapshot = try await engine.apply(.allowRecoveryKey)
  isNil(snapshot.recoveryKey)
  equal(keychain.interactive, 1, "Allow read the key with the question allowed")
  for _ in 0..<100 where burned.all.count < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
  equal(burned.all.sorted(), ["worktree:a", "worktree:b"], "both copies burn once allowed")
  receipts = try store.receipts()
  equal(receipts.filter { $0.outcome == "burned" }.count, 2, "both burns are recorded")

  if failures == before { print("PASS backup key: ticks go on, and one Allow lets copies burn") }
}
