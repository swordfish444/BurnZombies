import BurnCore
import Darwin
import Foundation

private final class FixtureAccess: @unchecked Sendable {
  let lock = NSLock()
  private var granted = false
  func set(_ value: Bool) { lock.withLock { granted = value } }
  func get() -> FullDiskAccessStatus { lock.withLock { .init(state: granted ? .granted : .required) } }
}

func fullDiskAccessProof() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-access-proof-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try Store(root: root)
  var calls = 0
  func allowed() -> FullDiskAccessStatus { calls += 1; return fixtureAccess() }
  checkFalse(FullDiskAccess.status(root: root, executableDigest: "build-a", probe: allowed).canScan)
  equal(calls, 0, "Cold setup must not touch protected paths")
  let confirmed = try FullDiskAccess.confirmSetup(root: root, executableDigest: "build-a", probe: allowed)
  check(confirmed.canScan)
  equal(calls, 1)
  check(FullDiskAccess.status(root: root, executableDigest: "build-a", probe: allowed).canScan)
  equal(calls, 2, "Restart revalidates capability, not just the saved Boolean")
  checkFalse(FullDiskAccess.status(root: root, executableDigest: "build-b", probe: allowed).canScan)
  equal(calls, 2, "A new ad-hoc binary requires explicit setup confirmation before probing")
  let revoked = FullDiskAccess.status(root: root, executableDigest: "build-a", probe: { .init() })
  checkFalse(revoked.canScan)
  checkFalse(FullDiskAccess.status(root: root, executableDigest: "build-a", probe: allowed).canScan)
  equal(calls, 2, "Denied access must not repeatedly probe protected folders")
  let unidentified = try FullDiskAccess.confirmSetup(root: root, executableDigest: nil, probe: allowed)
  checkFalse(unidentified.canScan)
  equal(calls, 2, "Unknown executable identity must not probe or allow scanning")
  let unknown = try FullDiskAccess.confirmSetup(root: root, executableDigest: "build-a", probe: { .init(state: .unknown) })
  checkFalse(unknown.canScan)
  checkFalse(FullDiskAccess.status(root: root, executableDigest: "build-a", probe: allowed).canScan)
  equal(calls, 2)
  equal(FullDiskAccess.evaluate(paths: ["mail", "messages"], probe: { _ in .missing }).state, .unknown)
  equal(FullDiskAccess.evaluate(paths: ["mail", "messages"], probe: { $0 == "mail" ? .readable : .denied }).state, .required)
  equal(FullDiskAccess.evaluate(paths: ["mail", "messages"], probe: { $0 == "mail" ? .readable : .unavailable }).state, .unknown)
  equal(FullDiskAccess.evaluate(paths: ["mail", "messages"], probe: { $0 == "mail" ? .readable : .missing }).state, .granted)

  var catalog = Catalog(); catalog.lifetimeVerified = 3; catalog.lifetimeResidentReleased = 987_654
  _ = try store.save(catalog)
  let access = FixtureAccess()
  let monitor = try Monitor(root: root, passiveHome: root.appendingPathComponent("no-passive-reads"),
    discoveryRoots: [root.appendingPathComponent("no-disk-reads").path], accessCheck: { access.get() })
  let cold = await monitor.snapshot()
  equal(cold.catalog.lifetimeVerified, 3, "Missing setup must preserve cold-loaded lifetime totals")
  equal(cold.catalog.lifetimeResidentReleased, 987_654)
  let service = AgentService(monitor: monitor)
  let accessStatus = await service.call(.init("access_status"))
  check(accessStatus.ok)
  checkFalse(accessStatus.fullDiskAccess?.canScan ?? true)
  equal((await monitor.snapshot()).catalog.lastSample, cold.catalog.lastSample, "access_status cannot trigger a scan")
  for operation in ["disk_inspect", "disk_explore", "disk_evidence", "disk_clean", "workspace", "workspace_clean", "owner_preview", "owner_stop", "cache_clean", "inspect", "preview", "burn", "lifecycle"] {
    let reply = await service.call(.init(operation))
    checkFalse(reply.ok, "\(operation) bypassed access prerequisite")
    equal(reply.failureKind, "full_disk_access_required")
  }
  let observed = await monitor.refresh()
  equal(observed.catalog.lifetimeVerified, 3)
  checkFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("disk-discovery.json").path), "Blocked setup must never begin disk discovery")
  checkFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("review-signal").path), "Blocked setup must not publish paid review work")
  access.set(true); try await monitor.requireFullDiskAccess()
  access.set(false)
  do { try await monitor.requireFullDiskAccess(); failTest("Revoked access accepted") } catch {}

  let reviewRoot = root.appendingPathComponent("reviewer")
  let reviewer = try MachineReviewer(root: reviewRoot, accessCheck: { access.get() })
  await reviewer.tick()
  checkFalse(FileManager.default.fileExists(atPath: reviewRoot.appendingPathComponent("review-usage.json").path))
  let config = MachineReviewConfiguration(harness: "codex", executable: "/never/launch", launcher: "/never/launch", server: "/never/launch")
  do {
    try MachineReviewer.execute(config, root: reviewRoot, accessCheck: { access.get() })
    failTest("Direct reviewer bypassed prerequisite")
  } catch { check(error.localizedDescription.contains("Full Disk Access")) }
  let runID = UUID().uuidString
  equal(DiskWalkWorker.run(arguments: [root.path, runID, root.appendingPathComponent("disk-worker-" + runID).path], accessCheck: { access.get() }), 77)
}
