import BurnCore
import Darwin
import Foundation

func passiveProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-passive-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home")
  let state = root.appendingPathComponent("state")
  let directory = home.appendingPathComponent(".codex/sessions/2026/10/27")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  // Links beside the session's folder are never followed. On macOS 27 a skip asked for at a link
  // lands on the next folder in the listing, which hid every session in it.
  let month = directory.deletingLastPathComponent()
  for n in 0..<32 {
    try FileManager.default.createSymbolicLink(
      at: month.appendingPathComponent("link\(n)"), withDestinationURL: home)
    if try FileManager.default.contentsOfDirectory(atPath: month.path).first != "27" { break }
  }
  let sessionID = UUID().uuidString.lowercased()
  let now = Date()
  let turn = UUID().uuidString
  let file = directory.appendingPathComponent("rollout-" + sessionID + ".jsonl")
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  func line(_ type: String, _ id: String = turn, _ text: String = "", at time: Date = Date()) throws
    -> Data
  {
    try JSONSerialization.data(withJSONObject: [
      "type": "event_msg", "timestamp": formatter.string(from: time),
      "payload": ["type": type, "turn_id": id, "last_agent_message": text],
    ]) + Data([10])
  }
  // The scenario is an established turn spawning a helper, not a race between
  // millisecond log timestamps and the native microsecond launch timestamp.
  let startEvent = try line("task_started", at: now.addingTimeInterval(-1))
  try startEvent.write(to: file)
  let worker = Process()
  worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  worker.arguments = ["--passive-child"]
  worker.environment = [
    "CODEX_THREAD_ID": sessionID, "CODEX_SESSION_ID": UUID().uuidString,
    "UNRELATED_SECRET": "not-for-persistence",
  ]
  try worker.run()
  defer {
    if worker.isRunning { worker.terminate() }
    worker.waitUntilExit()
  }
  guard case .found(let child) = Native().probe(worker.processIdentifier),
    case .found(var owner) = Native().probe(getpid())
  else { throw StoreError.message("Fixture identity missing") }
  equal(
    Native().codexSessionID(child), sessionID,
    "Only the thread marker UUID crosses the native boundary")
  owner.executable = "/fixture/codex"  // Fixture-only ancestry record; production records come from the native scan.
  let records = [child.identity.key: Record(child), owner.identity.key: Record(owner)]
  let born = Double(child.identity.seconds) + Double(child.identity.micros) / 1_000_000
  try line("task_started", at: Date(timeIntervalSince1970: born + 1)).write(
    to: file, options: .atomic)
  let predating = try PassiveCollector(
    store: Store(root: root.appendingPathComponent("predating-state")), home: home)
  equal(
    try predating.poll(records: records, claims: [], now: now).count, 0,
    "A helper born before the current turn cannot gain passive ownership")
  try startEvent.write(to: file, options: .atomic)
  let collector = try PassiveCollector(store: Store(root: state), home: home)
  var evidence = try collector.poll(records: records, claims: [], now: now)
  guard evidence.count == 1 else {
    let event = try JSONSerialization.jsonObject(with: startEvent) as! [String: Any]
    let started = PassiveSession.date(event["timestamp"])!.timeIntervalSince1970
    throw StoreError.message(
      "Expected passive binding, got \(evidence.count); UUID=\(Native().codexSessionID(child) != nil); parent=\(child.parent == owner.identity.pid); childMinusTurn=\(born - started); \(collector.coverage)"
    )
  }
  checkFalse(evidence[0].eligible, "Active turns are protected")
  let completion =
    "The disposable sleep fixture has finished its job. Its output was saved, no consumer remains, and this exact helper is no longer needed."
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: line("task_complete", turn, completion))
  try handle.close()
  evidence = try collector.poll(records: records, claims: [], now: Date())
  check(
    evidence[0].canReview(),
    "Passive completion should queue a review without working-chat tool calls")
  var catalog = Catalog()
  catalog.records = records
  catalog.passiveEvidence = evidence
  equal(ReviewEvidence.pending(in: catalog).count, 1)
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: state, passiveHome: home,
    accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  let preview = try await monitor.previewTargets([child.identity.key], callerPID: getpid())
  equal(preview.count, 1)
  let append = try FileHandle(forWritingTo: file)
  try append.seekToEnd()
  try append.write(contentsOf: line("task_started", UUID().uuidString))
  try append.close()
  do {
    _ = try await monitor.burnTargets(
      preview, label: "Fixture", rationale: completion, callerPID: getpid())
    failTest("Resumed owner escaped the pre-signal guard")
  } catch {}
  check(worker.isRunning, "Resumed active helper was signalled")
  let bytes = try Data(contentsOf: state.appendingPathComponent("passive-evidence.json"))
  checkFalse(
    String(decoding: bytes, as: UTF8.self).contains("not-for-persistence"),
    "Unrelated environment was persisted")
  var claude = PassiveSession(provider: "claude", id: UUID().uuidString)
  claude.ingest([
    "type": "user", "timestamp": formatter.string(from: now), "uuid": "c1",
    "message": ["content": "private prompt"],
  ])
  claude.ingest([
    "type": "assistant", "timestamp": formatter.string(from: now),
    "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": completion]]],
  ])
  checkFalse(claude.active)
  equal(claude.summary, completion)
  claude.ingest([
    "type": "user", "timestamp": formatter.string(from: now), "uuid": "c2",
    "message": ["content": "new work"],
  ])
  check(claude.active)
  check(claude.completed == nil)
  checkFalse(PassiveSession.excerpt("token=private-key-value").contains("private-key-value"))
  // Truncation, a partial tail and unreadable session evidence must fail closed.
  try Data("{\"type\":".utf8).write(to: file)
  let broken = try collector.poll(records: records, claims: [], now: Date())
  checkFalse(broken[0].eligible)
  try FileManager.default.removeItem(at: file)
  let missing = try collector.poll(records: records, claims: [], now: Date())
  checkFalse(missing[0].eligible)
  // A real-sized log must retain the task-start binding instead of jumping
  // straight to a tail that contains only its completion.
  let filler = Data(
    (String(
      repeating: "{\"type\":\"noop\",\"payload\":\"" + String(repeating: "x", count: 100) + "\"}\n",
      count: 3000)).utf8)
  try (startEvent + filler + line("task_complete", turn, completion)).write(
    to: file, options: .atomic)
  let large = try PassiveCollector(
    store: Store(root: root.appendingPathComponent("large-state")), home: home)
  let largeEvidence = try large.poll(records: records, claims: [], now: now.addingTimeInterval(1))
  equal(largeEvidence.count, 1, "A task start before the former 256 KB tail must bind")
  check(
    largeEvidence.first?.eligible == true, "Completed supported helper was lost in a large session")
  print(
    "PASS passive Codex/Claude completion, exact native UUID, active-turn protection, truncated/missing log refusal and preview-to-burn resume race"
  )
}
