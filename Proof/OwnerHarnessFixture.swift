import BurnCore
import Darwin
import Foundation

/// Real monitor and MCP service, confined to exact private Gradle fixture owners.
/// Controller data is native owner evidence, never a model verdict or a forged release.
func runOwnerHarnessFixture(root: URL) async throws {
  guard ProcessInfo.processInfo.environment["BURNZOMBIES_HOME"] == nil,
    root.deletingLastPathComponent().lastPathComponent.hasPrefix("bz-owner-harness-") else {
    throw StoreError.message("Owner fixture requires its isolated explicit root")
  }
  let store = try Store(root: root)
  let pids = try JSONDecoder().decode([Int32].self, from: store.read(root.appendingPathComponent("owned-pids.json"), limit: 1024))
  guard pids.count == 2, Set(pids).count == 2 else { throw StoreError.message("Expected two owned fixture daemons") }
  let scan = Native().scan()
  guard !scan.partial else { throw StoreError.message("Incomplete fixture observation") }
  var catalog = Catalog()
  catalog.records = Dictionary(uniqueKeysWithValues: scan.observations.map { ($0.identity.key, Record($0)) })
  var owners = [GradleDaemonEvidence]()
  for pid in pids {
    guard let process = scan.observations.first(where: { $0.identity.pid == pid }),
      let evidence = try GradleDaemon.inspect(process, records: catalog.records, complete: true),
      WorkspaceSafety.contains(WorkspaceSafety.canonical(root.deletingLastPathComponent().path),
        WorkspaceSafety.canonical(evidence.gradleHome)) else { throw StoreError.message("Non-fixture owner refused") }
    owners.append(evidence)
  }
  catalog.ownerDaemons = owners
  try store.save(catalog)
  try store.write(JSONEncoder().encode(owners), to: root.appendingPathComponent("owner-fixture-evidence.json"), limit: 16384)
  let ids = owners.map(\.id)
  try store.write(JSONEncoder().encode(ids), to: root.appendingPathComponent("owner-review-ids.json"), limit: 2048)
  let monitor = try Monitor(root: root, passiveHome: root.appendingPathComponent("empty-passive-home"))
  _ = await monitor.refresh()
  let service = AgentService(monitor: monitor)
  let listener = try AgentListener(root: root) { request in
    guard ["status", "owner_preview", "owner_stop"].contains(request.operation),
      request.operation != "owner_preview" || ids.contains(request.findingID ?? "") else {
      return AgentReply(ok: false, message: "Private owner acceptance fixture permits only its exact owner queue.")
    }
    return await service.call(request)
  }
  let observer = Task {
    while !Task.isCancelled {
      _ = await monitor.refresh()
      try? await Task.sleep(for: .seconds(2))
    }
  }
  print("READY"); fflush(stdout)
  _ = await Task.detached(priority: .utility) { FileHandle.standardInput.readDataToEndOfFile() }.value
  observer.cancel()
  _ = await monitor.refresh()
  let final = await monitor.snapshot()
  try store.save(final.catalog)
  await listener.stop()
}

func runOwnerHarnessReview(root: URL) throws {
  guard root.deletingLastPathComponent().lastPathComponent.hasPrefix("bz-owner-harness-"),
    let configuration = try MachineReviewConfiguration.load(root: root) else {
    throw StoreError.message("Private owner review configuration unavailable")
  }
  let store = try Store(root: root)
  let ids = try JSONDecoder().decode([String].self, from: store.read(root.appendingPathComponent("owner-review-ids.json"), limit: 2048))
  let attempt = UUID()
  try ReviewProgress(attempt: attempt, selected: ids).save(store)
  defer {
    if let log = try? store.read(root.appendingPathComponent("last-review.log"), limit: 1_048_576),
      let usage = ReviewUsage.parse(log, requestedModel: configuration.model) {
      try? store.write(JSONEncoder().encode(usage), to: root.appendingPathComponent("owner-review-usage.json"), limit: 16384)
    }
  }
  try MachineReviewer.execute(configuration, root: root,
    prompt: "Review the supplied ownerProcess queue now. Follow the service instructions; finish without polling.",
    reviewIDs: ids, lane: .ownerProcess, attempt: attempt)
}
