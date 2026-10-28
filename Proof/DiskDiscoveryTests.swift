import BurnCore
import CBurn
import Darwin
import Foundation

func diskDiscoveryProof() throws {
  try toolCaptureProof()
  let base = URL(
    fileURLWithPath: WorkspaceSafety.canonical(FileManager.default.temporaryDirectory.path)
  ).appendingPathComponent("bz-discovery-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  let home = base.appendingPathComponent("unfamiliar-storage")
  let outside = base.appendingPathComponent("preserve")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try Data(repeating: 81, count: 1_048_576).write(
    to: outside.appendingPathComponent("only-copy.bin"))
  for i in 0..<3 {
    let folder = home.appendingPathComponent("run-\(i)/producer/derived-output")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: UInt8(i + 1), count: 1_048_576).write(
      to: folder.appendingPathComponent("replaceable.bin"))
  }
  try FileManager.default.createSymbolicLink(
    at: home.appendingPathComponent("external"), withDestinationURL: outside)
  try Data(
    "{\"generatedBy\":\"example compiler\",\"producer_dirty\":true,\"credential\":\"PRIVATE_VALUE_MUST_NOT_LEAK\"}"
      .utf8
  )
  .write(to: home.appendingPathComponent("manifest.json"))
  var measured = try DiskDiscovery.measure(home.path)
  guard let root = measured.first(where: { $0.path == home.path }) else {
    throw StoreError.message("Missing root measurement")
  }
  equal(root.files, 4, "Native traversal must count deep files exactly once and never follow links")
  check(
    root.allocated >= 3_145_728 && root.unshared <= root.allocated,
    "Allocated and unshared accounting must be ordered")
  equal(
    measured.filter { $0.path.hasSuffix("/derived-output") }.count, 3,
    "Unknown folder names are measured without an allowlist")
  checkFalse(measured.contains { $0.path.contains("/external/") })
  throwsError(try DiskDiscovery.measure(home.appendingPathComponent("external").path))
  if let walk = bz_disk_open(home.path, 3) {
    defer { bz_disk_close(walk) }
    var earlier = false
    while bz_disk_step(walk, 1) == 0 {
      for i in 1..<bz_disk_count(walk) {
        var n = bz_disk_node()
        _ = bz_disk_node_at(walk, i, &n)
        earlier = earlier || n.finished != 0
      }
    }
    check(earlier, "Completed subtrees must be available before the whole scan ends")
  } else {
    failTest("Incremental native walker unavailable")
  }
  // Prove APFS clone accounting independently of estimated directory size.
  let original = outside.appendingPathComponent("only-copy.bin")
  let clone = outside.appendingPathComponent("clone.bin")
  equal(clonefile(original.path, clone.path, 0), 0)
  let cloned = try DiskDiscovery.measure(outside.path).first { $0.path == outside.path }!
  check(cloned.allocated >= 2_097_152, "Both clone references must have allocation metadata")
  equal(
    cloned.unshared, 0, "Cloned files must not be advertised as independently reclaimable blocks")
  try FileManager.default.linkItem(at: original, to: outside.appendingPathComponent("hardlink.bin"))
  let linked = try DiskDiscovery.measure(outside.path).first { $0.path == outside.path }!
  check(linked.hardlinks >= 2, "Hardlinks must be identified")
  equal(linked.unshared, 0)

  // A compact 15 GB simulated measurement uses tiny real files; never allocate fake GB.
  for i in measured.indices {
    measured[i].allocated = measured[i].path == home.path ? 15_000_000_000 : 5_000_000_000
    measured[i].unshared = measured[i].allocated
  }
  let store = try Store(root: base.appendingPathComponent("state"))
  var saved = DiskDiscoveryState()
  saved.nodes = measured
  try saved.save(store)
  let discovery = try DiskDiscovery(store: store, roots: [home.path])
  equal(
    discovery.snapshot().pending.map(\.id), [root.id],
    "Small siblings must remain discoverable as a large aggregate")
  let inspected = try discovery.inspect(root.id, allowed: [root.id], visibility: { _ in -1 })
  check(inspected.consumerState.contains("Incomplete"), "Incomplete visibility must be explicit")
  check(
    inspected.producerEvidence.values.joined().contains("example compiler"),
    "Producer metadata must be available for AI reasoning")
  checkFalse(inspected.producerEvidence.values.joined().contains("PRIVATE_VALUE"))
  guard let group = inspected.repeatedFolders.first(where: { $0.path.hasSuffix("derived-output") })
  else {
    throw StoreError.message("Repeated output grouping missing")
  }
  equal(group.allocated, 15_000_000_000)
  equal(group.folders, 3)
  let encoded = try JSONEncoder().encode(inspected)
  check(encoded.count < 12_000, "Bounded model evidence must not include every group member")
  checkFalse(String(decoding: encoded, as: UTF8.self).contains("\"members\""))
  try Data("Keep accepted evidence; rebuild superseded compiler output.\npassword=PRIVATE\n".utf8)
    .write(to: home.appendingPathComponent("retention.md"))
  let retention = try discovery.readEvidence(
    root.id, relativePath: "retention.md", allowed: [root.id])
  check(
    retention.values.joined().contains("Keep accepted evidence"),
    "Dynamic retention evidence must be readable")
  checkFalse(retention.values.joined().contains("PRIVATE"))
  throwsError(
    try discovery.readEvidence(
      root.id, relativePath: "../preserve/only-copy.bin", allowed: [root.id]))
  throwsError(
    try discovery.readEvidence(
      root.id, relativePath: "external/credentials.json", allowed: [root.id]))
  throwsError(
    try discovery.readEvidence(root.id, relativePath: "sessions/history.json", allowed: [root.id]))
  throwsError(try discovery.inspect(root.id, allowed: ["space:unrelated"]))
  throwsError(try discovery.explore("space:invented", allowed: [root.id]))
  _ = try discovery.recommend(
    group.id, disposition: "rebuildable", title: "Trim completed build output",
    summary:
      "The compiler creates these outputs. Source and retained acceptance evidence must remain.",
    nextStep: "Wait for full consumer visibility before approving exact output folders.",
    allowed: [root.id])
  check(
    FileManager.default.fileExists(atPath: original.path),
    "A recommendation must never remove or mutate files")
  equal(try DiskDiscoveryState.load(store).advice[group.id]?.disposition, "rebuildable")
  equal(
    discovery.snapshot().opportunities.count, 1,
    "Grouped advice must not double count parent folders")
  equal(
    discovery.snapshot().pending.count, 0, "Unchanged advice must not cause another model review")
  var tuning = DiskPolicy()
  tuning.mode = "off"
  discovery.tick(policy: tuning)
  check(!discovery.snapshot().pending.isEmpty, "Changed policy must invalidate cached advice")
  _ = try discovery.recommend(
    group.id, disposition: "rebuildable", title: "Trim completed build output",
    summary:
      "The compiler creates these outputs. Source and retained acceptance evidence must remain.",
    nextStep: "Wait for full consumer visibility before approving exact output folders.",
    allowed: [root.id])
  equal(discovery.snapshot().pending.count, 0)
  discovery.tick(policy: tuning)
  equal(
    discovery.snapshot().pending.count, 0, "Unchanged tuning must not repeatedly consume tokens")
  let priorPolicyRevision = discovery.snapshot().nodes.first { $0.id == root.id }!.revision
  tuning.instructions = "Keep accepted captures and all release evidence."
  discovery.tick(policy: tuning)
  check(!discovery.snapshot().pending.isEmpty)
  notEqual(priorPolicyRevision, discovery.snapshot().nodes.first { $0.id == root.id }!.revision)
  var protected = DiskPolicy()
  protected.mode = "off"
  protected.protectedPaths = [home.appendingPathComponent("run-0").path]
  discovery.tick(policy: protected)
  throwsError(try discovery.inspect(group.id, allowed: [root.id]))

  let before = measured[0].revision
  measured[0].allocated += 1
  equal(before, measured[0].revision, "Tiny file churn cannot cause recurring token spend")
  let moleData = try JSONSerialization.data(withJSONObject: [
    "path": home.path, "scan_status": "partial",
    "entries": [
      [
        "path": home.path + "/run-0", "size": 12_000_000_000, "scan_status": "complete",
        "cleanable": true,
      ],
      ["path": outside.path, "size": 99_000_000_000, "scan_status": "complete", "cleanable": true],
      [
        "path": home.path + "/external", "size": 90_000_000_000, "scan_status": "complete",
        "cleanable": true,
      ],
    ],
  ])
  let mole = try MoleEvidence.decode(moleData, root: home.path)
  equal(mole.entries.count, 1, "Mole paths outside scope or through links must be discarded")
  equal(mole.scanStatus, "partial")
  checkFalse(mole.entries[0].cleanupHint, "Partial scans never supply a positive cleanup hint")
  equal(
    try MoleEvidence.decode(moleData, root: home.path, protected: [home.path + "/run-0"]).entries
      .count, 0)
  throwsError(try MoleEvidence.decode(moleData, root: outside.path))
  throwsError(try MoleEvidence.decode(Data(repeating: 32, count: 1_048_577), root: home.path))
  check(inspected.mole == nil, "Fixture discovery must not invoke installed tools")
  var catalog = Catalog()
  catalog.diskDiscovery = [measured[0]]
  let evidence = ReviewEvidence.pending(in: catalog)
  equal(evidence.count, 1)
  equal(evidence[0].recommendationOnly, true)
  equal(ReviewLane.lane(for: evidence[0]), .discovery, "Discovery gets a focused read-only toolset")
}

func toolCaptureProof() throws {
  let output = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-capture-" + UUID().uuidString)
  let fd = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw StoreError.message("Could not create fixture capture") }
  defer {
    close(fd)
    try? FileManager.default.removeItem(at: output)
  }
  func run(_ args: [String], limit: UInt64 = 4096) -> Int32 {
    var argv = args.map { (value: String) in value.withCString { strdup($0) } } + [nil]
    var env = [strdup("PATH=/usr/bin:/bin"), nil]
    defer {
      argv.forEach { free($0) }
      env.forEach { free($0) }
    }
    _ = ftruncate(fd, 0)
    _ = lseek(fd, 0, SEEK_SET)
    return bz_capture_tool(&argv, &env, fd, 500, limit)
  }
  equal(run(["/usr/bin/true"]), 0)
  equal(run(["/usr/bin/false"]), 1)
  let control = Process()
  control.executableURL = URL(fileURLWithPath: "/bin/sleep")
  control.arguments = ["10"]
  try control.run()
  defer {
    control.terminate()
    control.waitUntilExit()
  }
  let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
  let started = ProcessInfo.processInfo.systemUptime
  equal(run([binary, "--mole-hang-fixture"]), 124)
  check(ProcessInfo.processInfo.systemUptime - started < 2)
  let pids = try String(contentsOf: output, encoding: .utf8).split(separator: " ").compactMap {
    Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  equal(pids.count, 2, "Timeout fixture must create both analyzer and helper")
  for pid in pids {
    var process = bz_process()
    var found: Int32 = -1
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
      found = bz_read(pid, &process)
      if found == 0 || (found == 1 && process.status == 5) { break }
      Thread.sleep(forTimeInterval: 0.01)
    } while ProcessInfo.processInfo.systemUptime < deadline
    check(
      found == 0 || (found == 1 && process.status == 5),
      "Owned analyzer/helper must exit after timeout: pid=\(pid), read=\(found), status=\(process.status), group=\(process.pgid)"
    )
  }
  check(control.isRunning, "Unrelated processes must survive analyzer cancellation")
  equal(run([binary, "--mole-output-fixture"]), 125)
  print(
    "PASS bounded tool capture: exit status, timeout, descendant teardown, output cap and unrelated-process protection"
  )
}

/// Explicit opt-in proof against an already installed Mole, using disposable data only.
func moleIntegrationProof() throws {
  let base = URL(
    fileURLWithPath: WorkspaceSafety.canonical(FileManager.default.temporaryDirectory.path)
  )
  .appendingPathComponent("bz-mole-proof-" + UUID().uuidString)
  let folder = base.appendingPathComponent("cache")
  let file = folder.appendingPathComponent("keep.bin")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  let payload = Data(repeating: 42, count: 16384)
  try payload.write(to: file)
  let store = try Store(root: base.appendingPathComponent("state"))
  let started = ProcessInfo.processInfo.systemUptime
  guard let first = MoleEvidence.analyze(folder.path, store: store, protected: []) else {
    throw StoreError.message("Installed Mole did not return compatible bounded JSON.")
  }
  check(ProcessInfo.processInfo.systemUptime - started < 9, "Mole execution must be bounded")
  equal(first.scanStatus, "complete")
  equal(first.entries.map(\.path), [file.path])
  equal(try Data(contentsOf: file), payload, "Mole analysis must preserve source bytes")
  let cache = try FileManager.default.contentsOfDirectory(
    at: store.root, includingPropertiesForKeys: nil
  )
  .filter { $0.lastPathComponent.hasPrefix("mole-analysis-") }
  equal(cache.count, 1)
  let cached = try Data(contentsOf: cache[0])
  // New evidence would appear in a second scan; its absence proves cached reuse.
  try payload.write(to: folder.appendingPathComponent("new.bin"))
  let second = MoleEvidence.analyze(folder.path, store: store, protected: [])
  equal(second?.entries.map(\.path), first.entries.map(\.path))
  equal(try Data(contentsOf: cache[0]), cached, "A cache hit must not execute or rewrite analysis")
  isNil(MoleEvidence.analyze(folder.path, store: store, protected: [file.path]))
  try FileManager.default.createSymbolicLink(
    at: base.appendingPathComponent("link"), withDestinationURL: folder)
  isNil(MoleEvidence.analyze(base.appendingPathComponent("link").path, store: store, protected: []))
  print(
    "PASS installed Mole: real JSON, bounded run, source unchanged, cache reuse, protected and linked branches refused"
  )
}
