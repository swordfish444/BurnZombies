import BurnCore
import Foundation
import Darwin

func passiveProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-passive-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
  let directory = home.appendingPathComponent(".codex/sessions/2026/10/27")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let sessionID = UUID().uuidString.lowercased(), now = Date(), turn = UUID().uuidString
  let file = directory.appendingPathComponent("rollout-" + sessionID + ".jsonl")
  let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  func line(_ type: String, _ id: String = turn, _ text: String = "") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: Date()),
      "payload": ["type": type, "turn_id": id, "last_agent_message": text]]) + Data([10])
  }
  try line("task_started").write(to: file)
  let worker = Process(); worker.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); worker.arguments = ["--passive-child"]
  worker.environment = ["CODEX_THREAD_ID": sessionID, "CODEX_SESSION_ID": UUID().uuidString, "UNRELATED_SECRET": "not-for-persistence"]
  try worker.run(); defer { if worker.isRunning { worker.terminate() }; worker.waitUntilExit() }
  guard case .found(let child) = Native().probe(worker.processIdentifier), case .found(var owner) = Native().probe(getpid()) else { throw StoreError.message("Fixture identity missing") }
  equal(Native().codexSessionID(child), sessionID, "Only the thread marker UUID crosses the native boundary")
  owner.executable = "/fixture/codex" // Fixture-only ancestry record; production records come from the native scan.
  let records = [child.identity.key: Record(child), owner.identity.key: Record(owner)]
  let collector = try PassiveCollector(store: Store(root: state), home: home)
  var evidence = try collector.poll(records: records, claims: [], now: now)
  guard evidence.count == 1 else { throw StoreError.message("Expected passive binding, got \(evidence.count); UUID=\(Native().codexSessionID(child) != nil); parent=\(child.parent == owner.identity.pid)") }
  checkFalse(evidence[0].eligible, "Active turns are protected")
  let completion = "The disposable sleep fixture has finished its job. Its output was saved, no consumer remains, and this exact helper is no longer needed."
  let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: line("task_complete", turn, completion)); try handle.close()
  evidence = try collector.poll(records: records, claims: [], now: Date())
  check(evidence[0].canReview(), "Passive completion should queue a review without working-chat tool calls")
  var catalog = Catalog(); catalog.records = records; catalog.passiveEvidence = evidence
  equal(ReviewEvidence.pending(in: catalog).count, 1)
  let monitor = try Monitor(root: state, passiveHome: home)
  let preview = try await monitor.previewTargets([child.identity.key], callerPID: getpid())
  equal(preview.count, 1)
  let append = try FileHandle(forWritingTo: file); try append.seekToEnd(); try append.write(contentsOf: line("task_started", UUID().uuidString)); try append.close()
  do { _ = try await monitor.burnTargets(preview, label: "Fixture", rationale: completion, callerPID: getpid()); failTest("Resumed owner escaped the pre-signal guard") } catch {}
  check(worker.isRunning, "Resumed active helper was signalled")
  let bytes = try Data(contentsOf: state.appendingPathComponent("passive-evidence.json"))
  checkFalse(String(decoding: bytes, as: UTF8.self).contains("not-for-persistence"), "Unrelated environment was persisted")
  var claude = PassiveSession(provider: "claude", id: UUID().uuidString)
  claude.ingest(["type": "user", "timestamp": formatter.string(from: now), "uuid": "c1", "message": ["content": "private prompt"]])
  claude.ingest(["type": "assistant", "timestamp": formatter.string(from: now), "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": completion]]]])
  checkFalse(claude.active); equal(claude.summary, completion)
  claude.ingest(["type": "user", "timestamp": formatter.string(from: now), "uuid": "c2", "message": ["content": "new work"]])
  check(claude.active); check(claude.completed == nil)
  checkFalse(PassiveSession.excerpt("token=private-key-value").contains("private-key-value"))
  // Truncation, a partial tail and unreadable session evidence must fail closed.
  try Data("{\"type\":".utf8).write(to: file)
  let broken = try collector.poll(records: records, claims: [], now: Date())
  checkFalse(broken[0].eligible)
  try FileManager.default.removeItem(at: file)
  let missing = try collector.poll(records: records, claims: [], now: Date())
  checkFalse(missing[0].eligible)
  print("PASS passive Codex/Claude completion, exact native UUID, active-turn protection, truncated/missing log refusal and preview-to-burn resume race")
}
