import BurnCore
import Darwin
import Foundation

func agentBridgeProof() async throws {
  let root = URL(fileURLWithPath: "/tmp/bz-" + UUID().uuidString.prefix(8))
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = try Monitor(root: root)
  let service = AgentService(monitor: monitor)
  let listener = try AgentListener(root: root) { await service.call($0) }
  let status = try await Task.detached { try AgentConnection.call(AgentRequest("status"), root: root) }.value
  let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
  let reply = try decoder.decode(AgentReply.self, from: Data(status.utf8))
  check(reply.ok && reply.observedProcesses > 0, "agent did not reach the live monitor")
  equal(reply.verifiedHelpers, 0)
  check(reply.findings.allSatisfy { $0.id.isEmpty || UUID(uuidString: $0.id) != nil }, "private group path leaked")
  let refused = await service.call(AgentRequest("preview", findingID: UUID().uuidString))
  checkFalse(refused.ok, "unknown work received cleanup permission")
  let forged = await service.call(AgentRequest("burn", previewToken: UUID().uuidString))
  checkFalse(forged.ok, "forged preview token accepted")
  let unknown = await service.call(AgentRequest("delete"))
  checkFalse(unknown.ok)
  throwsError(try AgentListener(root: root) { _ in AgentReply(message: "wrong owner") })
  var metadata = stat()
  equal(lstat(AgentListener.socketPath(root), &metadata), 0)
  equal(metadata.st_mode & 0o777, 0o600)
  check(AgentConnection.isAvailable(root: root), "second listener broke the first")
  await listener.stop()
  checkFalse(AgentConnection.isAvailable(root: root))
  let target = root.appendingPathComponent("preserved")
  try Data("keep".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(atPath: AgentListener.socketPath(root), withDestinationPath: target.path)
  throwsError(try AgentListener(root: root) { _ in AgentReply(message: "unsafe") })
  equal(try String(contentsOf: target, encoding: .utf8), "keep")
}

func runAgentFixture(root: URL) async throws {
  let monitor = try Monitor(root: root)
  let service = AgentService(monitor: monitor)
  let listener = try AgentListener(root: root) { await service.call($0) }
  print("READY"); fflush(stdout)
  _ = FileHandle.standardInput.readDataToEndOfFile()
  await listener.stop()
}
