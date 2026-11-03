import BurnCore
import CryptoKit
import Darwin
import Foundation

/// Stricter than macOS privacy protection: each folder itself may be looked at, as on a real
/// Mac, but listing it or touching anything inside kills the process. Where a real Mac would
/// ask the user for access, this fixture fails the proof.
func privacyTripwire(_ folders: [String]) -> String {
  "(version 1)(allow default)"
    + folders.map { folder in
      "(deny file-read* file-write* (require-all (subpath \"\(folder)\")"
        + " (require-not (literal \"\(folder)\"))) (with send-signal SIGKILL))"
        + "(deny file-read-data file-write* (literal \"\(folder)\") (with send-signal SIGKILL))"
    }.joined()
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
  equal(limited.excluded(under: home + "/git"), ["*.photoslibrary"])
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
  // A second Photos library outside the default place.
  let photos = home + "/Pictures/Old.photoslibrary"
  try fixtureJunk(photos + "/originals")
  equal(limited.place(photos + "/originals"), "Photos")
  // A link from an ordinary folder into Documents is never followed, nor one reached by
  // spelling through a missing folder.
  try fm.createSymbolicLink(atPath: home + "/linked", withDestinationPath: documents + "/GitHub")
  isNil(limited.resolve(home + "/linked/notes"))
  isNil(limited.resolve(home + "/gone/../linked/notes"))
  equal(limited.resolve(home + "/git/project"), home + "/git/project")
  equal(
    limited.resolve(home + "/git/absent/file"), WorkspaceSafety.canonical(home + "/git/absent/file"),
    "an ordinary missing path resolves exactly as before")
  equal(limited.pointerPlace(home + "/.codex/worktrees/a1/notes"), "Documents")
  isNil(limited.pointerPlace(home + "/git/project-copy"))
  // Git also reads the objects a repository borrows from another one.
  try fixtureRepository(home + "/git/borrower")
  try (documents + "/GitHub/notes/.git/objects\n").write(
    toFile: home + "/git/borrower/.git/objects/info/alternates", atomically: true, encoding: .utf8)
  equal(limited.pointerPlace(home + "/git/borrower"), "Documents")
  // Autopilot names the project a program works in, but not from inside a protected place.
  equal(AutopilotProcesses.repository(home + "/git/project/src", protected: limited), "project")
  isNil(AutopilotProcesses.repository(documents + "/GitHub/notes", protected: limited))
  // A build manifest linked into Documents.
  try fm.createSymbolicLink(
    atPath: home + "/git/package.json", withDestinationPath: documents + "/GitHub/notes/source")

  // Saved settings and storage evidence that name Documents, as after an earlier run with
  // access: a junk-folder root there, a measured branch and a junk folder there, and a queued
  // walk of it.
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
  var junk = DiskSnapshot()
  junk.date = measured
  junk.policyRevision = policy.revision
  junk.candidates = [
    try JSONDecoder().decode(
      DiskCandidate.self,
      from: JSONSerialization.data(withJSONObject: [
        "id": "disk:earlier", "path": documents + "/GitHub/notes/dist",
        "repository": documents + "/GitHub/notes", "kind": "generated", "bytes": 2_000_000,
        "newest": measured.timeIntervalSinceReferenceDate, "fingerprint": "earlier",
        "complete": true, "guardReason": "Measured with access.", "reviewable": false,
        "userRule": "review", "policyRevision": policy.revision,
      ]))
  ]
  try junk.save(store)

  // An earlier run with Full Disk Access saw every copy, including the ones in Documents.
  let key = SymmetricKey(data: Data(repeating: 41, count: 32))
  func service() throws -> WorktreeService {
    try WorktreeService(
      legacyAuthority: true, root: URL(fileURLWithPath: state), access: { fixtureAccess() },
      recoveryKey: { key },
      scanRunner: WorktreeScanRunner(executable: URL(fileURLWithPath: CommandLine.arguments[0])),
      discoveryHome: URL(fileURLWithPath: home))
  }
  let earlier = try service()
  let seen = try await earlier.request(.init("scan"), caller: "fixture")
  await earlier.shutdown()
  check(
    seen.records.contains { $0.path == documents + "/GitHub/project-copy" && !$0.revision.isEmpty },
    "the run with access did not inspect Documents")

  // The tripwire itself: reading inside Documents is fatal, looking at the folder is not.
  let tripwire = privacyTripwire([documents, photos])
  func tripped(_ path: String) throws -> Bool {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    probe.arguments = ["-p", tripwire, "/usr/bin/stat", path]
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
  // nothing reads inside Documents or the Photos library: the tripwire kills any process that
  // does.
  func runWithoutAccess(_ phase: String) throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    child.arguments = [
      "-p", tripwire, CommandLine.arguments[0], "--protected-locations-child", home, state, phase,
    ]
    child.environment = ["PATH": "/usr/bin:/bin", "HOME": home, "BURNZOMBIES_HOME": state]
    let pipe = Pipe()
    child.standardOutput = pipe
    child.standardError = pipe
    try child.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    print(output, terminator: "")
    guard finished(child, within: 60) else {
      throw StoreError.message("The run without Full Disk Access did not finish: " + phase)
    }
    check(
      child.terminationReason == .exit,
      "the run without Full Disk Access read inside a protected place: " + phase)
    equal(child.terminationStatus, 0, "the run without Full Disk Access failed: " + phase)
  }
  try runWithoutAccess("main")

  // Then with a program running from Documents and working there, as a dev server can be.
  // The tripwire also stops the kernel from describing that program's own folder to a
  // consumer check, which macOS itself does not treat as reading the folder, so this run
  // keeps to the steps that only name programs, weigh Findings, or scan nothing reachable.
  try fm.createDirectory(atPath: documents + "/GitHub/notes/tool", withIntermediateDirectories: true)
  try fm.copyItem(atPath: CommandLine.arguments[0], toPath: documents + "/GitHub/notes/tool/resident")
  let resident = Process()
  resident.executableURL = URL(fileURLWithPath: documents + "/GitHub/notes/tool/resident")
  resident.arguments = ["--passive-child"]
  resident.currentDirectoryURL = URL(fileURLWithPath: documents + "/GitHub/notes")
  try resident.run()
  defer {
    if resident.isRunning { resident.terminate() }
    _ = finished(resident, within: 10)
  }
  Thread.sleep(forTimeInterval: 0.5)
  check(resident.isRunning, "the program in Documents did not start")
  try runWithoutAccess("resident")
  resident.terminate()
  _ = finished(resident, within: 10)

  // With Full Disk Access verified, the same places are covered exactly as before.
  let later = try service()
  let covered = try await later.request(.init("scan"), caller: "fixture")
  let copy = covered.records.first { $0.path == documents + "/GitHub/project-copy" }
  isNil(copy?.protectedPlace)
  check(
    copy.map { !$0.revision.isEmpty && $0.gaps.isEmpty } == true,
    "with access, Documents is inspected: " + (copy?.gaps ?? ["no row"]).joined(separator: " "))
  check(
    covered.records.contains { $0.path == home + "/.codex/worktrees/a1/notes" && $0.protectedPlace == nil },
    "with access, a copy whose project is in Documents is checked")
  checkFalse(
    covered.gaps.joined().contains("Full Disk Access"), covered.gaps.joined(separator: " "))
  await later.shutdown()
}

/// The run without Full Disk Access, inside the tripwire, through production entry points: the
/// observer and its `burnzombies` workers, the storage map, the junk-folder inventory, the
/// agent bridge, Findings, settings and Autopilot. No access record exists, so nothing is
/// granted.
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
  check(gaps.contains(home + "/git/borrower"), "a repository borrowing from Documents was opened")
  guard let copy = scan.records.first(where: { $0.path == home + "/git/project-copy" }) else {
    throw StoreError.message("An ordinary copy was not discovered: " + gaps)
  }
  check(!copy.revision.isEmpty && copy.head != nil, "an ordinary copy is inspected")
  isNil(copy.protectedPlace)
  // Another app's open files can still leave a consumer gap; nothing may blame access.
  checkFalse(
    copy.gaps.contains { $0.contains("Full Disk Access") || $0.contains("Detailed inspection pending") },
    "an ordinary copy was not checked: " + copy.gaps.joined(separator: " | "))
  // A copy in Documents, and one whose project is there, are reported as not checked: never
  // missing, and what the earlier run with access saw is kept.
  for path in [documents + "/GitHub/project-copy", home + "/.codex/worktrees/a1/notes"] {
    guard let skipped = scan.records.first(where: { $0.path == path }) else {
      failTest("a copy was dropped instead of reported: " + path)
      continue
    }
    equal(skipped.protectedPlace, "Documents", path)
    checkFalse(skipped.missing, "a skipped copy is reported missing")
    equal(skipped.state, "Inspection blocked", "a skipped copy looks ready")
    let reason = skipped.gaps.joined(separator: " ")
    check(reason.contains("Documents") && reason.contains("Full Disk Access"), reason)
  }
  let skipped = scan.records.first { $0.path == documents + "/GitHub/project-copy" }!
  // Codex owns its copies, so only the Documents copy was inspected with access.
  check(!skipped.revision.isEmpty, "a skipped copy lost what was seen with access")
  do {
    _ = try await worktrees(.init("inspect", id: skipped.id))
    failTest("a copy in Documents was inspected without Full Disk Access")
  } catch {
    check(error.localizedDescription.contains("Full Disk Access"), error.localizedDescription)
  }
  // The bounded refresh of known copies leaves them alone too.
  await monitor.worktreeTick()

  // The storage map measures the home folder, skips Documents and the Photos library, and says
  // so.
  _ = await monitor.refresh()
  var map = try DiskDiscoveryState.load(store)
  var junk = try DiskSnapshot.load(store)
  let deadline = Date().addingTimeInterval(120)
  while (map.running != nil || !map.queue.isEmpty || junk.limited != true) && Date() < deadline {
    try await Task.sleep(nanoseconds: 200_000_000)
    map = try DiskDiscoveryState.load(store)
    junk = try DiskSnapshot.load(store)
  }
  check(map.queue.isEmpty && map.running == nil, "the storage map did not finish")
  check(
    map.nodes.contains { $0.path == home + "/git" && $0.files > 0 }, "ordinary folders unmeasured")
  let measuredInside = map.nodes.filter {
    (WorkspaceSafety.contains(documents, $0.path) && $0.path != documents + "/GitHub")
      || $0.path.hasSuffix(".photoslibrary")
  }
  check(measuredInside.isEmpty, "a protected place was measured: " + measuredInside.map(\.path).joined(separator: ", "))
  check((map.nodes.first { $0.path == home }?.errors ?? 0) > 0, "a skipped place counted as empty")
  equal(map.unavailable ?? [], [], "a storage walk failed")
  check(map.detail.contains("Documents") && map.detail.contains("Full Disk Access"), map.detail)

  // The junk-folder inventory covers ~/git and skips Documents; the junk folder measured there
  // earlier stays on record but cannot be reviewed.
  check(
    junk.candidates.contains { $0.path == home + "/git/project/dist" },
    "junk outside Documents missed: " + junk.detail)
  for kept in junk.candidates where WorkspaceSafety.contains(documents, kept.path) {
    checkFalse(kept.reviewable || kept.recommendationEligible == true, "junk in Documents is reviewable")
    check(kept.guardReason.contains("Full Disk Access"), kept.guardReason)
  }
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
  if let homeNode = map.nodes.first(where: { $0.path == home }) {
    let reached = await bridge.call(
      .init("disk_evidence", findingID: homeNode.id, workspacePath: "Documents/GitHub/notes/README.md"))
    checkFalse(reached.ok, "evidence was read from Documents")
    check(reached.message.contains("Full Disk Access"), reached.message)
  } else {
    failTest("the home folder was not measured")
  }

  // A program is named from its path's spelling, never by looking at its file.
  let program = Observation(
    identity: .init(pid: 99_999, seconds: 1), executable: documents + "/GitHub/notes/source")
  equal(program.name, "source")
  _ = AutopilotProcesses.family(program.executable)

  // Autopilot judges only copies it can check, names programs without looking at their files,
  // and its note says what it skipped.
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

  // A new junk-folder root in Documents cannot be checked, so it is refused; the one saved
  // with access stays.
  var adding = try DiskPolicy.load(store)
  adding.roots.append(documents + "/Archive")
  do {
    try adding.save(store)
    failTest("a new folder in Documents was saved without being checked")
  } catch {
    check(error.localizedDescription.contains("Full Disk Access"), error.localizedDescription)
  }
  var tuned = try DiskPolicy.load(store)
  tuned.minimumAgeDays = 20
  try tuned.save(store)
  let saved = try DiskPolicy.load(store).roots
  check(saved.contains(documents + "/GitHub"), "a saved root was dropped")

  await monitor.shutdownWorktrees()
}

/// The second run without Full Disk Access, while a program runs from Documents and works
/// there: naming programs, weighing Findings and a scan with no reachable root look at none of
/// its files.
func protectedLocationsResidentChild(home: String, state: String) async throws {
  let documents = home + "/Documents"
  let root = URL(fileURLWithPath: state)
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: URL(fileURLWithPath: home), root: root,
    discoveryRoots: [home])
  // The observer names every program from the kernel's record of it.
  _ = await monitor.refresh()
  let observed = await monitor.snapshot()
  check(
    observed.catalog.records.values.contains { $0.latest.executable.hasPrefix(documents) },
    "the program in Documents was not observed")
  // Findings weigh every stored candidate without looking at the ones in Documents.
  let findings = try await monitor.findingPage(offset: 0)
  check(
    findings.proposals.contains { $0.resources == ["disk:earlier"] && !$0.ready },
    "the junk folder measured in Documents was not weighed: " + (findings.error ?? ""))
  // Autopilot names programs and the projects they work in without opening their folders.
  let sources = AutopilotSources.live(monitor: monitor, root: root, home: home)
  _ = await sources.processes(sources.threads())
  // With only a protected root left, a scan reads no other program's files either.
  func worktrees(_ q: WorktreeRequest) async throws -> WorktreeReply {
    try await monitor.worktreeRequest(q, caller: "fixture")
  }
  _ = try await worktrees(.init("remove_root", path: home + "/git"))
  _ = try await worktrees(.init("remove_root", path: home + "/.codex/worktrees"))
  let only = try await worktrees(.init("scan"))
  checkFalse(
    only.gaps.joined().contains("interrupted"), "the worker stopped early: " + only.gaps.joined())
  _ = try await worktrees(.init("add_root", path: home + "/git"))
  _ = try await worktrees(.init("add_root", path: home + "/.codex/worktrees"))
  await monitor.shutdownWorktrees()
}
