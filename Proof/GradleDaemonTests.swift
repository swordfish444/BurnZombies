import BurnCore
import Darwin
import Foundation

/// Standalone script owns these temporary homes. This entry point refuses user homes.
func gradleFixtureCLI() throws {
  let args = CommandLine.arguments
  guard args.count == 6, let pid = Int32(args[3]) else { throw StoreError.message("Malformed fixture request") }
  func physical(_ path: String) throws -> String {
    guard let value = realpath(path, nil) else { throw StoreError.message("Fixture directory is unavailable") }
    defer { free(value) }; return String(cString: value)
  }
  let action = args[2], home = try physical(args[4]), requestedOutput = URL(fileURLWithPath: args[5])
  let output = URL(fileURLWithPath: try physical(requestedOutput.deletingLastPathComponent().path))
    .appendingPathComponent(requestedOutput.lastPathComponent)
  let prefix = try physical(NSTemporaryDirectory()) + "/bz-gradle-proof-"
  guard home.hasPrefix(prefix), output.path.hasPrefix(prefix) else {
    throw StoreError.message("Fixture paths do not match temporary root: expected \(prefix), home \(home), evidence \(output.path)")
  }
  guard ["inspect", "stop", "wrong-uid", "expired", "denied", "changed", "advanced"].contains(action),
    case .found(let process) = Native().probe(pid) else { throw StoreError.message("Fixture action or native identity unavailable") }
  let scan = Native().scan()
  let records = Dictionary(uniqueKeysWithValues: scan.observations.map { ($0.identity.key, Record($0)) })
  if action == "inspect" {
    guard let evidence = try GradleDaemon.inspect(process, records: records, complete: !scan.partial),
      evidence.gradleHome == home else { throw StoreError.message("Wrong fixture owner") }
    try JSONEncoder().encode(evidence).write(to: output, options: .atomic)
    print("{\"ok\":true,\"state\":\"\(evidence.state)\",\"eligible\":\(evidence.eligible)}")
  } else {
    var evidence = try JSONDecoder().decode(GradleDaemonEvidence.self, from: Data(contentsOf: output))
    guard evidence.gradleHome == home, evidence.member.identity == process.identity else { throw StoreError.message("Changed fixture") }
    if action == "wrong-uid" { evidence.daemonUID = UUID().uuidString }
    if action == "expired" { evidence.checkedAt = Date().addingTimeInterval(-61) }
    if action == "changed" { evidence.evidenceFingerprint = UUID().uuidString }
    if action == "stop" {
      _ = try GradleDaemon.requestGracefulStop(evidence, records: records)
      print("{\"ok\":true,\"requested\":true}")
    } else {
      do {
        _ = try GradleDaemon.requestGracefulStop(evidence, records: records, authorize: {
          if action == "denied" { throw StoreError.message("Fixture policy was revoked") }
        })
      }
      catch {
        guard OwnerStopFailure.receiptOutcome(for: error) == "refused" else {
          throw StoreError.message("A proven pre-dispatch fixture refusal was incorrectly classified as uncertain")
        }
        guard Native().ownerState(process.identity) == .alive else { throw StoreError.message("Refused fixture did not survive") }
        print("{\"ok\":true,\"refused\":true}"); return
      }
      throw StoreError.message("Invalid fixture was not refused")
    }
  }
}

func gradleOwnerInspectionCLI() throws {
  guard let flag = CommandLine.arguments.firstIndex(of: "--owner-inspect") else { return }
  let pids = CommandLine.arguments.dropFirst(flag + 1).compactMap(Int32.init)
  guard !pids.isEmpty, pids.count <= 8 else { throw StoreError.message("Supply 1–8 exact owner PIDs") }
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
  var result = [GradleDaemonEvidence]()
  for pid in pids {
    guard case .found(let process) = Native().probe(pid) else { throw StoreError.message("Exact owner PID is unavailable") }
    if let evidence = try GradleDaemon.inspect(process, records: [:], complete: false) { result.append(evidence) }
  }
  print(String(decoding: try encoder.encode(result), as: UTF8.self))
}

func gradleDaemonProof() async throws {
  guard case .found(let selfProcess) = Native().probe(getpid()) else { throw StoreError.message("Native proof identity unavailable") }
  let unrelated = try GradleDaemon.inspect(selfProcess, records: [:])
  check(unrelated == nil, "Unrelated process is not a Gradle owner")
  var forged = selfProcess; forged.executable = "/unrelated/bin/java"
  do { _ = try GradleDaemon.inspect(forged, records: [:]); failTest("Forged Java identity escaped native validation") } catch {}
  equal(Native().ownerState(selfProcess.identity), .alive, "Inspection refusal must preserve the process")
  try await passiveRetryAndBundledRuntimeProof()
  print("PASS Gradle non-owner/forged-identity refusal; passive negative-lookup retry and bundled runtime evidence")
}

private func passiveRetryAndBundledRuntimeProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-passive-retry-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("state")
  let sessions = home.appendingPathComponent(".codex/sessions/2026/10/28")
  let executable = root.appendingPathComponent("Fixture.app/Contents/MacOS/Python")
  try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
  let sessionID = UUID().uuidString.lowercased(), turn = UUID().uuidString, now = Date()
  let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let event: [String: Any] = ["type": "event_msg", "timestamp": formatter.string(from: now.addingTimeInterval(-1)),
    "payload": ["type": "task_started", "turn_id": turn]]
  try (JSONSerialization.data(withJSONObject: event) + Data([10]))
    .write(to: sessions.appendingPathComponent("rollout-" + sessionID + ".jsonl"))
  let worker = Process(); worker.executableURL = executable; worker.arguments = ["--passive-child"]
  worker.environment = ["CODEX_THREAD_ID": sessionID]
  try worker.run(); defer { if worker.isRunning { worker.terminate() }; worker.waitUntilExit() }
  guard case .found(let child) = Native().probe(worker.processIdentifier),
    case .found(var owner) = Native().probe(getpid()) else { throw StoreError.message("Fixture identity missing") }
  let collector = try PassiveCollector(store: Store(root: state), home: home)
  var records = [child.identity.key: Record(child), owner.identity.key: Record(owner)]
  equal(try collector.poll(records: records, claims: [], now: now).count, 0, "Initially missing owner must not invent a binding")
  owner.executable = "/fixture/codex" // Test-only ancestry record, as in PassiveTests.
  records[owner.identity.key] = Record(owner)
  equal(try collector.poll(records: records, claims: [], now: now.addingTimeInterval(56)).count, 0, "Negative lookup is backed off")
  let evidence = try collector.poll(records: records, claims: [], now: now.addingTimeInterval(301))
  equal(evidence.count, 1, "A previous negative lookup must retry and observe bundled runtime helpers")
  if let binding = evidence.first {
    equal(binding.member.identity, child.identity)
    checkFalse(binding.eligible, "Active bundled runtime must remain protected")
  }
  check(worker.isRunning, "Evidence collection must never terminate a helper")
}
