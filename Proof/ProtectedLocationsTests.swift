import BurnCore
import CryptoKit
import Darwin
import Foundation

/// Stricter than macOS privacy protection: the folder itself may be looked at, as on a real
/// Mac, but listing it or touching anything inside kills the process. Where a real Mac would
/// ask the user for access, this fixture fails the proof.
func privacyTripwire(_ folder: String) -> String {
  "(version 1)(allow default)"
    + "(deny file-read* file-write* (require-all (subpath \"\(folder)\")"
    + " (require-not (literal \"\(folder)\"))) (with send-signal SIGKILL))"
    + "(deny file-read-data file-write* (literal \"\(folder)\") (with send-signal SIGKILL))"
}

private func fixtureGit(_ path: String, _ args: [String]) throws {
  _ = try WorktreeGit.run(path, args)
}

private func fixtureRepository(_ path: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  try fixtureGit(path, ["init", "--initial-branch=main"])
  try Data("fixture\n".utf8).write(to: URL(fileURLWithPath: path + "/source"))
  try fixtureGit(path, ["add", "."])
  try fixtureGit(
    path,
    ["-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m", "fixture"])
}

/// Foundation's waitUntilExit can stay blocked in an async proof after its child exits.
private func finished(_ process: Process, within seconds: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
  return !process.isRunning
}

private func fixtureJunk(_ folder: String) throws {
  try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
  var bytes = [UInt8](repeating: 0, count: 2_000_000)
  arc4random_buf(&bytes, bytes.count)
  try Data(bytes).write(to: URL(fileURLWithPath: folder + "/bundle.bin"))
}

func protectedLocationsProof() async throws {
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent("bz-protected-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = WorkspaceSafety.canonical(temporary.path)
  defer { try? fm.removeItem(atPath: base) }
  let home = base + "/home"
  let documents = home + "/Documents"

  // Which places are protected is decided from the path alone.
  let limited = ProtectedLocations(access: .init(), homes: [home])
  let full = ProtectedLocations(access: fixtureAccess(), homes: [home])
  equal(limited.place(documents + "/GitHub/notes"), "Documents")
  equal(limited.place(home + "/documents/notes"), "Documents", "volumes ignore letter case")
  equal(limited.place(documents), "Documents")
  equal(limited.place(home + "/Desktop/notes"), "Desktop")
  equal(limited.place(home + "/Downloads"), "Downloads")
  equal(limited.place(home + "/Library/Mobile Documents/com~apple~CloudDocs/x"), "iCloud Drive")
  equal(limited.place(home + "/Library/Mail/V10"), "Mail")
  equal(limited.place(home + "/Library/Messages"), "Messages")
  equal(limited.place(home + "/Pictures/Photos Library.photoslibrary/originals"), "Photos")
  equal(limited.place("/Volumes/Backup/project"), "external and network drives")
  isNil(limited.place(home + "/DocumentsArchive/notes"))
  isNil(limited.place(home + "/git/project"))
  isNil(limited.place(home + "/Library/Caches/pip"))
  isNil(full.place(documents + "/GitHub/notes"))
  check(limited.excluded(under: home).contains(documents))
  check(limited.excluded(under: home + "/Library").contains(home + "/Library/Mail"))
  equal(limited.excluded(under: home + "/git"), [])
  equal(full.excluded(under: home), [])

  // ~/git/project has one copy beside it and one in Documents. ~/Documents/GitHub/notes is
  // kept in Documents, as GitHub Desktop does, and has a Codex copy outside it.
  try fixtureRepository(home + "/git/project")
  try fixtureGit(
    home + "/git/project", ["worktree", "add", "--detach", home + "/git/project-copy"])
  try fm.createDirectory(atPath: documents + "/GitHub", withIntermediateDirectories: true)
  try fixtureGit(
    home + "/git/project", ["worktree", "add", "--detach", documents + "/GitHub/project-copy"])
  try fixtureRepository(documents + "/GitHub/notes")
  try fm.createDirectory(atPath: home + "/.codex/worktrees/a1", withIntermediateDirectories: true)
  try fixtureGit(
    documents + "/GitHub/notes",
    ["worktree", "add", "--detach", home + "/.codex/worktrees/a1/notes"])
  try fixtureJunk(home + "/git/project/dist")
  try fixtureJunk(documents + "/GitHub/notes/dist")
  // A link from an ordinary folder into Documents is never followed.
  try fm.createSymbolicLink(atPath: home + "/linked", withDestinationPath: documents + "/GitHub")
  isNil(limited.resolve(home + "/linked/notes"))
  equal(limited.resolve(home + "/git/project"), home + "/git/project")
  equal(limited.pointerPlace(home + "/.codex/worktrees/a1/notes"), "Documents")
  isNil(limited.pointerPlace(home + "/git/project-copy"))

  // Saved settings and storage evidence that name Documents, as after an earlier run with
  // access: a junk-folder root there, a measured branch there and a queued walk of it.
  let state = base + "/state"
  let store = try Store(root: URL(fileURLWithPath: state))
  var policy = DiskPolicy(home: URL(fileURLWithPath: home))
  policy.roots = [home + "/git", documents + "/GitHub"]
  policy.minimumCandidateMB = 1
  policy.targetFreeGB = 1000
  try policy.save(store)
  var map = DiskDiscoveryState()
  let measured = Date()
  map.nodes = [home + "/git/big", documents + "/GitHub"].map {
    DiskSpaceNode(
      path: $0, scanRoot: $0, allocated: 500_000_000_000, unshared: 500_000_000_000, files: 10,
      complete: true, measured: measured)
  }
  map.queue = [home, documents + "/GitHub"]
  map.lastCycle = measured
  map.policyRevision = policy.revision
  try map.save(store)

  // The tripwire itself: reading inside Documents is fatal, looking at the folder is not.
  func tripped(_ path: String) throws -> Bool {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    probe.arguments = ["-p", privacyTripwire(documents), "/usr/bin/stat", path]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    try probe.run()
    guard finished(probe, within: 30) else { throw StoreError.message("Tripwire probe hung.") }
    return probe.terminationReason == .uncaughtSignal
  }
  let readInside = try tripped(documents + "/GitHub/notes/source")
  let lookedAt = try tripped(documents)
  check(readInside, "the tripwire does not stop a read inside")
  checkFalse(lookedAt, "the tripwire stops what macOS allows")

  // Without Full Disk Access the production observer and workers cover everything else, and
  // nothing reads inside Documents: the tripwire kills any process that does.
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
  child.arguments = [
    "-p", privacyTripwire(documents), CommandLine.arguments[0], "--protected-locations-child",
    home, state,
  ]
  child.environment = ["PATH": "/usr/bin:/bin", "HOME": home, "BURNZOMBIES_HOME": state]
  let pipe = Pipe()
  child.standardOutput = pipe
  child.standardError = pipe
  try child.run()
  let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  print(output, terminator: "")
  guard finished(child, within: 60) else {
    throw StoreError.message("The run without Full Disk Access did not finish.")
  }
  check(
    child.terminationReason == .exit,
    "the run without Full Disk Access read inside Documents and the tripwire stopped it")
  equal(child.terminationStatus, 0, "the run without Full Disk Access failed")

  // With Full Disk Access verified, the same places are covered exactly as before.
  let key = SymmetricKey(data: Data(repeating: 41, count: 32))
  let service = try WorktreeService(
    legacyAuthority: true, root: URL(fileURLWithPath: state), access: { fixtureAccess() },
    recoveryKey: { key },
    scanRunner: WorktreeScanRunner(executable: URL(fileURLWithPath: CommandLine.arguments[0])),
    discoveryHome: URL(fileURLWithPath: home))
  let covered = try await service.request(.init("scan"), caller: "fixture")
  let copy = covered.records.first { $0.path == documents + "/GitHub/project-copy" }
  isNil(copy?.protectedPlace)
  check(
    copy.map { !$0.revision.isEmpty && $0.gaps.isEmpty } == true,
    "with access, Documents is inspected: " + (copy?.gaps ?? ["no row"]).joined(separator: " "))
  check(
    covered.records.contains { $0.path == home + "/.codex/worktrees/a1/notes" },
    "with access, a copy whose project is in Documents is listed")
  checkFalse(
    covered.gaps.joined().contains("Full Disk Access"), covered.gaps.joined(separator: " "))
  await service.shutdown()
}

/// The run without Full Disk Access, inside the tripwire, through production entry points: the
/// observer and its `burnzombies` workers, the storage map, the junk-folder inventory, the
/// agent bridge and Autopilot. No access record exists, so nothing is granted.
func protectedLocationsChild(home: String, state: String) async throws {
  let documents = home + "/Documents"
  let root = URL(fileURLWithPath: state)
  let store = try Store(root: root)
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: URL(fileURLWithPath: home), root: root,
    discoveryRoots: [home])
  let access = await monitor.accessStatus()
  checkFalse(access.canScan, "the fixture must start without access")
  func worktrees(_ q: WorktreeRequest) async throws -> WorktreeReply {
    try await monitor.worktreeRequest(q, caller: "fixture")
  }
  // A folder in Documents can be added without being touched; scans skip it until access is on.
  _ = try await worktrees(.init("add_root", path: documents + "/GitHub"))
  let scan = try await worktrees(.init("scan"))
  let gaps = scan.gaps.joined(separator: " ")
  checkFalse(gaps.contains("interrupted"), "the worker stopped early: " + gaps)
  check(gaps.contains("Documents") && gaps.contains("Full Disk Access"), "unexplained skip: " + gaps)
  guard let copy = scan.records.first(where: { $0.path == home + "/git/project-copy" }) else {
    throw StoreError.message("An ordinary copy was not discovered: " + gaps)
  }
  check(!copy.revision.isEmpty && copy.head != nil, "an ordinary copy is inspected")
  isNil(copy.protectedPlace)
  // Another app's open files can still leave a consumer gap; nothing may blame access.
  checkFalse(
    copy.gaps.contains { $0.contains("Full Disk Access") || $0.contains("Detailed inspection pending") },
    "an ordinary copy was not checked: " + copy.gaps.joined(separator: " | "))
  guard let skipped = scan.records.first(where: { $0.path == documents + "/GitHub/project-copy" })
  else { throw StoreError.message("A registered copy in Documents was dropped, not reported.") }
  equal(skipped.protectedPlace, "Documents")
  checkFalse(skipped.missing, "a skipped copy is reported missing")
  check(skipped.revision.isEmpty, "a copy in Documents was inspected")
  let reason = (skipped.gaps + skipped.blockers).joined(separator: " ")
  check(reason.contains("Documents") && reason.contains("Full Disk Access"), reason)
  checkFalse(
    scan.records.contains { $0.path == home + "/.codex/worktrees/a1/notes" },
    "a copy whose project is in Documents was opened")
  do {
    _ = try await worktrees(.init("inspect", id: skipped.id))
    failTest("a copy in Documents was inspected without Full Disk Access")
  } catch {
    check(error.localizedDescription.contains("Full Disk Access"), error.localizedDescription)
  }
  // The bounded refresh of known copies leaves it alone too.
  await monitor.worktreeTick()

  // The storage map measures the home folder, skips Documents and says so.
  _ = await monitor.refresh()
  var map = try DiskDiscoveryState.load(store)
  var junk = try DiskSnapshot.load(store)
  let deadline = Date().addingTimeInterval(120)
  while (map.running != nil || !map.queue.isEmpty || junk.date == .distantPast)
    && Date() < deadline
  {
    try await Task.sleep(nanoseconds: 200_000_000)
    map = try DiskDiscoveryState.load(store)
    junk = try DiskSnapshot.load(store)
  }
  check(map.queue.isEmpty && map.running == nil, "the storage map did not finish")
  check(
    map.nodes.contains { $0.path == home + "/git" && $0.files > 0 }, "ordinary folders unmeasured")
  let measuredInside = map.nodes.filter {
    WorkspaceSafety.contains(documents, $0.path) && $0.path != documents + "/GitHub"
  }
  check(measuredInside.isEmpty, "Documents was measured: " + measuredInside.map(\.path).joined(separator: ", "))
  check((map.nodes.first { $0.path == home }?.errors ?? 0) > 0, "a skipped place counted as empty")
  equal(map.unavailable ?? [], [], "a storage walk failed")
  check(map.detail.contains("Documents") && map.detail.contains("Full Disk Access"), map.detail)

  // The junk-folder inventory covers ~/git and skips Documents.
  check(
    junk.candidates.contains { $0.path == home + "/git/project/dist" },
    "junk outside Documents missed: " + junk.detail)
  checkFalse(junk.candidates.contains { WorkspaceSafety.contains(documents, $0.path) })
  check(junk.detail.contains("Documents") && junk.detail.contains("Full Disk Access"), junk.detail)

  // The agent bridge offers storage evidence outside Documents and refuses the rest.
  _ = await monitor.refresh()
  let bridge = AgentService(monitor: monitor)
  let status = await bridge.call(.init("status"))
  let offered = Set(status.diskDiscovery.map(\.path))
  check(offered.contains(home + "/git/big"), "storage outside Documents is withheld")
  checkFalse(offered.contains(documents + "/GitHub"), "storage in Documents was offered")
  if let hidden = map.nodes.first(where: { $0.path == documents + "/GitHub" }) {
    let refused = await bridge.call(.init("disk_inspect", findingID: hidden.id))
    checkFalse(refused.ok)
    check(refused.message.contains("Full Disk Access"), refused.message)
  } else {
    failTest("the saved Documents branch disappeared")
  }
  if let visible = map.nodes.first(where: { $0.path == home + "/git" }) {
    let inspected = await bridge.call(.init("disk_inspect", findingID: visible.id))
    check(inspected.ok, inspected.message)
  }

  // Autopilot judges only copies it can check, and its note says what it skipped.
  let sources = AutopilotSources.live(monitor: monitor, root: root, home: home)
  let records = await sources.worktreeRecords()
  check(records.contains { $0.path == home + "/git/project-copy" }, "Autopilot lost a copy")
  checkFalse(records.contains { WorkspaceSafety.contains(documents, $0.path) })
  _ = sources.worktrees(records, [], [:])
  _ = AutopilotDisk.items(worktrees: await monitor.autopilotWorktreeRecords(), home: home)
  let note = sources.coverageNotes().joined(separator: " ")
  check(note.contains("Documents") && note.contains("Full Disk Access"), note)
  let item = AutopilotItem(
    id: "worktree:" + skipped.id, kind: .worktree, name: "project-copy", path: skipped.path,
    bytes: 1, facts: [:])
  check(sources.inspect(item)["state"]?.contains("Full Disk Access") == true, "Autopilot looked")
  equal(sources.retireWorktree(item, "fixture").outcome, "refused")
  let folder = AutopilotItem(
    id: "disk:fixture", kind: .disk, name: "dist", path: documents + "/GitHub/notes/dist",
    bytes: 1, facts: [:])
  equal(sources.reclaimDisk(folder, "fixture").outcome, "refused")
  await monitor.shutdownWorktrees()
}
