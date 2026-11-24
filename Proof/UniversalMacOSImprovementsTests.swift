import BurnCore
import CryptoKit
import Darwin
import Foundation

private func currentResidentBytes() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
  let status = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private func setTreeTimestamp(_ root: URL, to date: Date) throws {
  let seconds = Int(date.timeIntervalSince1970)
  var times = [
    timeval(tv_sec: seconds, tv_usec: 0),
    timeval(tv_sec: seconds, tv_usec: 0),
  ]
  if let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: nil)
  {
    for case let item as URL in enumerator {
      _ = item.path.withCString { lutimes($0, &times) }
    }
  }
  _ = root.path.withCString { lutimes($0, &times) }
}

func universalMacOSImprovementsProof() async throws {
  try recoveryLifecycleAndMemoryProof()
  try processPrecisionAndPythonShimProof()
  try await worktreeVisibilityAndUniversalRootsProof()
  try universalDiskAndAppUpdaterProof()
  try claudeRunCachePruneProof()
}

private func recoveryLifecycleAndMemoryProof() throws {
  let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-universal-recovery-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  let canonTemp = WorkspaceSafety.canonical(temp.path)
  defer { try? FileManager.default.removeItem(atPath: canonTemp) }

  let stateRoot = URL(fileURLWithPath: canonTemp + "/state", isDirectory: true)
  let sourceDir = URL(fileURLWithPath: canonTemp + "/source", isDirectory: true)
  let restoredDir = URL(fileURLWithPath: canonTemp + "/restored", isDirectory: true)
  try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
  let key = SymmetricKey(size: .bits256)

  // 1. Multi-hundred-file capture & restore round-trip with bounded RSS growth.
  let payload = Data((0..<16_384).map { UInt8(($0 * 31) & 0xff) })
  for idx in 0..<300 {
    let subdir = sourceDir.appendingPathComponent("mod-\(idx % 12)", isDirectory: true)
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    var content = payload
    content.append(contentsOf: "file-\(idx)".utf8)
    try content.write(to: subdir.appendingPathComponent("entry-\(idx).dat"))
  }

  let rssBefore = currentResidentBytes()
  let captured = try PrivateRecovery.capture(sourceDir.path, root: stateRoot, key: key)
  try PrivateRecovery.restore(captured, to: restoredDir.path, key: key)
  let rssAfter = currentResidentBytes()
  if rssBefore > 0 && rssAfter > rssBefore {
    let delta = rssAfter - rssBefore
    check(delta < 96 << 20, "capture/restore RSS growth stayed bounded (\(delta) bytes)")
  }
  let restoredSample = try Data(
    contentsOf: restoredDir.appendingPathComponent("mod-5/entry-17.dat"))
  equal(restoredSample.count, payload.count + "file-17".utf8.count, "restored payload matches")

  // 2. PrivateRecovery.prune removes unreferenced >2h archives + retired git ref, keeps referenced & fresh.
  let repoDir = URL(fileURLWithPath: canonTemp + "/repo", isDirectory: true)
  try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repoDir.path, ["init", "-q", "--initial-branch=main"])
  _ = try WorktreeGit.run(repoDir.path, ["config", "user.email", "proof@example.invalid"])
  _ = try WorktreeGit.run(repoDir.path, ["config", "user.name", "Proof"])
  try Data("hello\n".utf8).write(to: repoDir.appendingPathComponent("README.md"))
  _ = try WorktreeGit.run(repoDir.path, ["add", "README.md"])
  _ = try WorktreeGit.run(repoDir.path, ["commit", "-q", "-m", "init"])
  let head = try WorktreeGit.text(repoDir.path, ["rev-parse", "HEAD"])
    .trimmingCharacters(in: .whitespacesAndNewlines)

  let recoveryRoot = stateRoot.appendingPathComponent("private-recovery", isDirectory: true)
  let staleOrphanID = UUID().uuidString
  let freshInFlightID = UUID().uuidString
  let staleOrphanDir = recoveryRoot.appendingPathComponent(staleOrphanID, isDirectory: true)
  let freshInFlightDir = recoveryRoot.appendingPathComponent(freshInFlightID, isDirectory: true)
  try FileManager.default.createDirectory(at: staleOrphanDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: freshInFlightDir, withIntermediateDirectories: true)

  let commonGit = repoDir.appendingPathComponent(".git").path
  let retiredRef = "refs/burnzombies/retired/" + staleOrphanID.lowercased()
  _ = try WorktreeGit.run(repoDir.path, ["update-ref", retiredRef, head])
  let orphanRestore = AutopilotRestore(
    repository: commonGit, path: "/tmp/retired-copy", ref: retiredRef, head: head,
    branch: "feat/old", snapshot: true)
  try JSONEncoder().encode(orphanRestore)
    .write(to: staleOrphanDir.appendingPathComponent("restore.json"))

  let now = Date()
  try setTreeTimestamp(staleOrphanDir, to: now.addingTimeInterval(-3 * 3600))
  try setTreeTimestamp(freshInFlightDir, to: now.addingTimeInterval(-300))

  let pruned = PrivateRecovery.prune(
    root: stateRoot, keepingIDs: [captured.id], graceAge: 2 * 3600, now: now)
  equal(pruned.removed, 1, "exactly the stale unreferenced recovery folder was pruned")
  checkFalse(
    FileManager.default.fileExists(atPath: staleOrphanDir.path),
    "stale unreferenced recovery folder removed")
  check(
    FileManager.default.fileExists(atPath: freshInFlightDir.path),
    "fresh in-flight recovery folder preserved during grace window")
  check(
    FileManager.default.fileExists(
      atPath: recoveryRoot.appendingPathComponent(captured.id).path),
    "referenced recovery folder preserved")
  let remainingRefs = try WorktreeGit.text(
    repoDir.path, ["for-each-ref", "--format=%(refname)", "refs/burnzombies/retired"])
  checkFalse(
    remainingRefs.contains(staleOrphanID.lowercased()), "retired git ref cleaned up on prune")

  // 3. AutopilotStore receipt priority-trim preserves live <30d restorable worktree receipts
  // ahead of >500 non-restorable process/disk receipts.
  let store = try AutopilotStore(root: stateRoot)
  var restorableIDs: [String] = []
  for idx in 0..<8 {
    let recID = UUID().uuidString
    restorableIDs.append(recID)
    var restore = AutopilotRestore(
      repository: commonGit, path: "/tmp/orbit-copy-\(idx)",
      ref: "refs/burnzombies/retired/\(recID)",
      head: head, branch: "feat/item-\(idx)", snapshot: true)
    let refJSON: [String: Any] = [
      "directory": recoveryRoot.path, "id": recID, "source": "/tmp/orbit-copy-\(idx)",
      "digest": "digest-\(idx)", "allocated": 1_024,
    ]
    restore.recovery = try JSONDecoder().decode(
      PrivateRecovery.Reference.self,
      from: JSONSerialization.data(withJSONObject: refJSON))
    try store.append(
      AutopilotReceipt(
        itemID: "worktree:\(idx)", kind: .worktree, name: "orbit-copy-\(idx)",
        authority: "rule:w", outcome: "burned", detail: "Retired copy.", bytes: 50_000_000,
        date: now.addingTimeInterval(-Double(idx + 1) * 18 * 3600), restore: restore))
  }
  try store.updateReceipts { all in
    for idx in 0..<520 {
      all.append(
        AutopilotReceipt(
          itemID: "process:\(idx)", kind: .process, name: "node",
          authority: "starter:p", outcome: "burned", detail: "Stopped helper.",
          bytes: 100_000_000, date: now.addingTimeInterval(-Double(520 - idx) * 60)))
    }
  }
  let trimmed = try store.receipts()
  equal(trimmed.count, AutopilotStore.maximumReceipts, "bounded at maximumReceipts")
  let survivingRecoveryIDs = Set(trimmed.compactMap { $0.restore?.recovery?.id })
  for id in restorableIDs {
    check(
      survivingRecoveryIDs.contains(id),
      "recent restorable worktree receipt survived 520 process stops")
  }

  // 4. Pre-removal refusal in AutopilotDisk.reclaim cleans up captured PrivateRecovery immediately.
  let fakeHome = canonTemp + "/disk-home"
  let diskProject = URL(fileURLWithPath: fakeHome + "/git/orbit-app", isDirectory: true)
  let genericDist = diskProject.appendingPathComponent("dist", isDirectory: true)
  try FileManager.default.createDirectory(at: genericDist, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(diskProject.path, ["init", "-q", "--initial-branch=main"])
  _ = try WorktreeGit.run(diskProject.path, ["config", "user.email", "proof@example.invalid"])
  _ = try WorktreeGit.run(diskProject.path, ["config", "user.name", "Proof"])
  try Data("{}\n".utf8).write(to: diskProject.appendingPathComponent("package.json"))
  try Data("dist/\n".utf8).write(to: diskProject.appendingPathComponent(".gitignore"))
  _ = try WorktreeGit.run(diskProject.path, ["add", "package.json", ".gitignore"])
  _ = try WorktreeGit.run(diskProject.path, ["commit", "-q", "-m", "init"])
  try Data("bundle\n".utf8).write(to: genericDist.appendingPathComponent("bundle.js"))
  try setTreeTimestamp(genericDist, to: now.addingTimeInterval(-20 * 86_400))

  var primaryWT = WorktreeRecord(
    id: "wt-primary", path: diskProject.path,
    repository: diskProject.appendingPathComponent(".git").path)
  primaryWT.main = true
  primaryWT.lastFileChange = now.addingTimeInterval(-20 * 86_400)

  let diskItems = AutopilotDisk.items(
    worktrees: [primaryWT], home: fakeHome, caches: false, now: now,
    sizer: { _ in 120_000_000 })
  guard let distItem = diskItems.first(where: { $0.path == genericDist.path }) else {
    failTest("generic dist folder discovered")
    return
  }
  let beforeDirs = Set(
    (try? FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path)) ?? [])
  // Pass inUse returning 0 on the first check and 1 on the post-capture check so PrivateRecovery.capture
  // runs and then pre-removal refusal triggers `defer` cleanup.
  var inUseCalls = 0
  let refusedReceipt = AutopilotDisk.reclaim(
    distItem, authority: "rule:test", home: fakeHome,
    inUse: { _ in
      inUseCalls += 1
      return inUseCalls == 1 ? 0 : 1
    },
    root: stateRoot, recoveryKey: key)
  equal(refusedReceipt.outcome, "refused", "busy dist refused at post-capture reclaim check")
  let afterDirs = Set(
    (try? FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path)) ?? [])
  equal(afterDirs, beforeDirs, "refused disk reclaim left zero leaked private-recovery folders")
}

private func processPrecisionAndPythonShimProof() throws {
  let fakeHome = "/tmp/bz-fixture-home"

  // 1. Standalone CLI Python framework shims are NOT treated as user GUI .app bundles,
  // whereas Python.framework embedded inside a real user .app remains protected.
  let homebrewPython =
    "/opt/homebrew/Cellar/python@3.13/3.13.2/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
  let cltPython =
    "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
  let uvPython =
    fakeHome
    + "/.local/share/uv/python/cpython-3.12/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
  let embeddedAppPython =
    "/Applications/StudioApp.app/Contents/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"

  check(
    AutopilotProcesses.isCommandLinePythonShim(homebrewPython), "Homebrew Python.app is CLI shim")
  check(AutopilotProcesses.isCommandLinePythonShim(cltPython), "CLT Python3.framework is CLI shim")
  check(
    AutopilotProcesses.isCommandLinePythonShim(uvPython, home: fakeHome),
    "uv Python.framework is CLI shim")
  checkFalse(
    AutopilotProcesses.isCommandLinePythonShim(embeddedAppPython, home: fakeHome),
    "Python.framework inside user .app is NOT treated as standalone CLI shim")

  let cliObs = Observation(
    identity: ProcessIdentity(pid: 81001, seconds: 100), parent: 1, uid: getuid(),
    executable: homebrewPython, rss: 250 << 20, cpuNS: 1_000_000_000, monotonic: 100, pgid: 81001)
  let cliRecord = Record(cliObs)
  isNil(
    AgentSafety.refusal(cliRecord, preferences: Preferences(), protectedPIDs: []))

  let embeddedObs = Observation(
    identity: ProcessIdentity(pid: 81002, seconds: 100), parent: 1, uid: getuid(),
    executable: embeddedAppPython, rss: 250 << 20, cpuNS: 1_000_000_000, monotonic: 100, pgid: 81002
  )
  let embeddedRecord = Record(embeddedObs)
  equal(
    AgentSafety.refusal(embeddedRecord, preferences: Preferences(), protectedPIDs: []),
    "OS service or application main process.")
  equal(
    AutopilotProcesses.rail(
      embeddedRecord, protectedPIDs: [], preferences: Preferences(), home: fakeHome),
    "It's part of an app you use.")

  let quietProbe = AutopilotProcessProbe(
    listening: { _ in false }, agent: { _ in nil }, cwd: { _ in "/tmp/vm-workdir" },
    alive: { _ in false })
  let cliCataloged = AutopilotProcesses.items(
    [cliRecord.id: cliRecord], threads: [], protectedPIDs: [], probe: quietProbe, home: fakeHome
  ).first
  check(cliCataloged != nil, "Homebrew Python CLI is cataloged as a candidate")
  check(cliCataloged?.protectedReason == nil, "Homebrew Python CLI has no protectedReason")
  let embeddedCataloged = AutopilotProcesses.items(
    [embeddedRecord.id: embeddedRecord], threads: [], protectedPIDs: [], probe: quietProbe,
    home: fakeHome)
  check(embeddedCataloged.isEmpty, "Embedded GUI app Python is excluded from leftovers catalog")

  // 2. <defunct> zombie child does NOT poison an orphaned parent's protection rail.
  let parentID = ProcessIdentity(pid: 82000, seconds: 50)
  let firstParent = Observation(
    identity: parentID, parent: 4000, uid: getuid(),
    executable: "/opt/homebrew/bin/qemu-system-aarch64", rss: 500 << 20,
    cpuNS: 2_000_000_000, monotonic: 10, pgid: 82000)
  var reparentedParent = firstParent
  reparentedParent.parent = 1
  reparentedParent.monotonic = 4000
  var parentRecord = Record(firstParent)
  parentRecord.latest = reparentedParent
  parentRecord.orphanSince = Date()
  parentRecord.samples = [firstParent, reparentedParent]

  let defunctChildObs = Observation(
    identity: ProcessIdentity(pid: 82001, seconds: 55), parent: 82000, uid: getuid(),
    executable: "", rss: 0, cpuNS: 0, zombie: true, metricsValid: false, monotonic: 4000,
    pgid: 82000)
  let defunctRecord = Record(defunctChildObs)

  let withDefunct = AutopilotProcesses.items(
    [parentRecord.id: parentRecord, defunctRecord.id: defunctRecord],
    threads: [], protectedPIDs: [], probe: quietProbe, home: fakeHome)
  guard let vmItem = withDefunct.first(where: { $0.pid == 82000 }) else {
    failTest("orphaned VM with defunct child cataloged")
    return
  }
  check(vmItem.protectedReason == nil, "exited <defunct> child must not protect live orphan parent")
  equal(vmItem.facts["orphaned"], "yes")

  // Contrast: a LIVE unreadable child still protects the parent fail-closed.
  var liveUnreadableObs = defunctChildObs
  liveUnreadableObs.zombie = false
  let liveUnreadableRecord = Record(liveUnreadableObs)
  let withLiveUnreadable = AutopilotProcesses.items(
    [parentRecord.id: parentRecord, liveUnreadableRecord.id: liveUnreadableRecord],
    threads: [], protectedPIDs: [], probe: quietProbe, home: fakeHome)
  equal(
    withLiveUnreadable.first(where: { $0.pid == 82000 })?.protectedReason,
    "Part of it is something I must not touch.",
    "live unreadable child still protects parent")

  // 3. Broad cwd ($HOME, /, /tmp, or parent folder above a nested .git repo) does NOT inherit
  // thread == "live" from a coding chat inside a nested repository.
  let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-thread-scope-" + UUID().uuidString, isDirectory: true)
  let homeDir = temp.appendingPathComponent("home", isDirectory: true)
  let gitParent = homeDir.appendingPathComponent("git", isDirectory: true)
  let nestedRepo = gitParent.appendingPathComponent("orbit-service", isDirectory: true)
  let nestedSubdir = nestedRepo.appendingPathComponent("packages/api", isDirectory: true)
  try FileManager.default.createDirectory(
    at: nestedRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: nestedSubdir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temp) }

  let canonHome = WorkspaceSafety.canonical(homeDir.path)
  let canonGitParent = WorkspaceSafety.canonical(gitParent.path)
  let canonRepo = WorkspaceSafety.canonical(nestedRepo.path)
  let canonSubdir = WorkspaceSafety.canonical(nestedSubdir.path)

  let activeChat = AgentThread(
    id: "codex:nested", agent: "codex", cwd: canonRepo, live: true, lastActive: Date())
  equal(
    AgentThreads.processState(for: canonHome, home: canonHome, threads: [activeChat]).thread,
    "none", "process with cwd == $HOME is not protected by nested repo chat")
  equal(
    AgentThreads.processState(for: "/", home: canonHome, threads: [activeChat]).thread,
    "none", "process with cwd == / is not protected by nested repo chat")
  equal(
    AgentThreads.processState(for: canonGitParent, home: canonHome, threads: [activeChat]).thread,
    "none", "process in ~/git above nested .git repo is not protected by nested repo chat")
  equal(
    AgentThreads.processState(for: canonRepo, home: canonHome, threads: [activeChat]).thread,
    "live", "process inside exact repo cwd remains protected")
  equal(
    AgentThreads.processState(for: canonSubdir, home: canonHome, threads: [activeChat]).thread,
    "live", "process inside subdirectory of active repo chat remains protected")

  // 4. Universal developer harnesses & tool families.
  let windsurfObs = Observation(
    identity: ProcessIdentity(pid: 83001, seconds: 100), parent: 1, uid: getuid(),
    executable: "/usr/local/bin/windsurf", rss: 300 << 20, cpuNS: 1_000_000_000, monotonic: 100,
    pgid: 83001)
  let windsurfRec = Record(windsurfObs)
  equal(
    AutopilotProcesses.rail(
      windsurfRec, protectedPIDs: [], preferences: Preferences(), home: fakeHome),
    "It's an agent or a system helper you rely on.")
  check(
    AutopilotProcesses.items(
      [windsurfRec.id: windsurfRec], threads: [], protectedPIDs: [], probe: quietProbe,
      home: fakeHome
    ).isEmpty, "windsurf harness excluded from leftovers catalog")
}

private func worktreeVisibilityAndUniversalRootsProof() async throws {
  let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-wt-universal-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temp) }

  // 1. WorktreeInspection.inspect records consumer ("none observed") even when files() hits a hardlink.
  let repoDir = temp.appendingPathComponent("repo", isDirectory: true)
  let linkedDir = temp.appendingPathComponent("linked-wt", isDirectory: true)
  try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(repoDir.path, ["init", "-q", "--initial-branch=main"])
  _ = try WorktreeGit.run(repoDir.path, ["config", "user.email", "proof@example.invalid"])
  _ = try WorktreeGit.run(repoDir.path, ["config", "user.name", "Proof"])
  try Data("seed\n".utf8).write(to: repoDir.appendingPathComponent("seed.txt"))
  _ = try WorktreeGit.run(repoDir.path, ["add", "seed.txt"])
  _ = try WorktreeGit.run(repoDir.path, ["commit", "-q", "-m", "seed"])
  _ = try WorktreeGit.run(
    repoDir.path, ["worktree", "add", "-q", "-b", "feat/hardlink", linkedDir.path])

  let fileA = linkedDir.appendingPathComponent("store-a.dat")
  let fileB = linkedDir.appendingPathComponent("store-b.dat")
  try Data("pnpm-like-hardlink".utf8).write(to: fileA)
  equal(link(fileA.path, fileB.path), 0, "created hardlink in worktree")

  let commonGit = WorkspaceSafety.canonical(repoDir.appendingPathComponent(".git").path)
  let canonLinked = WorkspaceSafety.canonical(linkedDir.path)
  let initial = WorktreeRecord(
    id: WorkEvidence.hash(commonGit + "|" + canonLinked), path: canonLinked, repository: commonGit)
  let inspected = WorktreeInspection.inspect(initial, visibility: { _ in 0 })
  equal(
    inspected.consumer, "none observed",
    "consumer check completes even when file walk encounters hardlinked node_modules")
  check(
    inspected.gaps.contains(where: { $0.lowercased().contains("hardlink") }),
    "hardlink gap is still recorded accurately")

  // 2. Universal macOS developer & agent worktree root seeding + place classification.
  let home = temp.appendingPathComponent("home", isDirectory: true)
  let state = temp.appendingPathComponent("state", isDirectory: true)
  let seededDirs = [
    ".codex/source-repos", ".codex/automations", ".windsurf/worktrees",
    ".codeium/windsurf/worktrees", "GitHub", "Development", ".custom-harness/workspaces",
  ]
  for rel in seededDirs {
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(rel), withIntermediateDirectories: true)
  }
  // Excluded dot-folders must never be seeded.
  try FileManager.default.createDirectory(
    at: home.appendingPathComponent(".npm/worktrees"), withIntermediateDirectories: true)

  let service = try WorktreeService(
    root: state, visibility: { _ in 0 },
    access: { .init(state: .granted, detail: "Isolated fixture") }, discoveryHome: home)
  let roots = try await service.snapshot().policy.roots
  for rel in seededDirs {
    let expected = WorkspaceSafety.canonical(home.appendingPathComponent(rel).path)
    check(roots.contains(expected), "universal root seeded: \(rel)")
  }
  checkFalse(
    roots.contains(WorkspaceSafety.canonical(home.appendingPathComponent(".npm/worktrees").path)),
    ".npm/worktrees must not be seeded as an agent worktree root")

  var deliveryCache: [String: AutopilotDelivery] = [:]
  var windsurfRec = WorktreeRecord(
    id: "wt-windsurf",
    path: home.appendingPathComponent(".codeium/windsurf/worktrees/orbit/wt-1").path,
    repository: commonGit)
  windsurfRec.consumer = "none observed"
  windsurfRec.lastFileChange = Date().addingTimeInterval(-10 * 86_400)
  windsurfRec.status = "clean"
  windsurfRec.allocated = 200_000_000
  var codexAutoRec = windsurfRec
  codexAutoRec.id = "wt-codex-auto"
  codexAutoRec.path = home.appendingPathComponent(".codex/automations/daily/wt-2").path
  let wtItems = AutopilotWorktrees.items(
    [windsurfRec, codexAutoRec], threads: [], delivery: &deliveryCache)
  equal(wtItems.first(where: { $0.id == "worktree:wt-windsurf" })?.facts["place"], "agent")
  equal(wtItems.first(where: { $0.id == "worktree:wt-codex-auto" })?.facts["place"], "codex")
}

private func universalDiskAndAppUpdaterProof() throws {
  let rawTemp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-universal-disk-" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: rawTemp, withIntermediateDirectories: true)
  let canonTemp = WorkspaceSafety.canonical(rawTemp.path)
  defer { try? FileManager.default.removeItem(atPath: canonTemp) }

  let home = URL(fileURLWithPath: canonTemp + "/home", isDirectory: true)
  let tmpRoot = URL(fileURLWithPath: canonTemp + "/tmp", isDirectory: true)
  let stateRoot = URL(fileURLWithPath: canonTemp + "/state", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

  let now = Date()
  let fiveDaysAgo = now.addingTimeInterval(-10 * 86_400)

  // 1. Staged Squirrel.Mac (.ShipIt) and electron-updater (-updater) caches.
  let shipIt = home.appendingPathComponent(
    "Library/Caches/com.example.Desktop.ShipIt", isDirectory: true)
  let shipItStage = shipIt.appendingPathComponent("update.xyz123", isDirectory: true)
  try FileManager.default.createDirectory(at: shipItStage, withIntermediateDirectories: true)
  try Data("<plist/>".utf8).write(to: shipIt.appendingPathComponent("ShipItState.plist"))
  try Data("bundle".utf8).write(to: shipItStage.appendingPathComponent("Desktop.app.zip"))
  try setTreeTimestamp(shipIt, to: fiveDaysAgo)

  let electronUpdater = home.appendingPathComponent(
    "Library/Caches/orbit-desktop-updater/pending", isDirectory: true)
  try FileManager.default.createDirectory(at: electronUpdater, withIntermediateDirectories: true)
  try Data("{}".utf8).write(to: electronUpdater.appendingPathComponent("update-info.json"))
  try Data("zip".utf8).write(to: electronUpdater.appendingPathComponent("orbit-1.2.0-arm64.zip"))
  try setTreeTimestamp(electronUpdater.deletingLastPathComponent(), to: fiveDaysAgo)

  let discoveredUpdaters = AutopilotAppUpdaters.discoverUpdaters(
    home: home.path, now: now, protected: ProtectedLocations(access: fixtureAccess()),
    shipItRunning: false)
  equal(discoveredUpdaters.targets.count, 2, "ShipIt and electron-updater discovered")
  check(
    AutopilotAppUpdaters.updaterRefusal(
      shipIt.path, home: home.path, now: now, shipItRunning: true) != nil,
    "active ShipIt process refuses .ShipIt deletion")
  isNil(
    AutopilotAppUpdaters.updaterRefusal(
      shipIt.path, home: home.path, now: now, shipItRunning: false))

  // 2. Temp tsx-<uid> with mixed dead-PID (settled) and live-PID (getpid()) entries.
  let tsxDir = tmpRoot.appendingPathComponent("tsx-\(getuid())", isDirectory: true)
  try FileManager.default.createDirectory(at: tsxDir, withIntermediateDirectories: true)
  // PID 2147483640 does not exist on macOS, so kill(pid, 0) fails with ESRCH.
  let deadPIDFile = tsxDir.appendingPathComponent("2147483640-001c4e5596598905253c1379")
  let livePIDFile = tsxDir.appendingPathComponent("\(getpid())-0098b23c4bf9bf3ddcd674df")
  try Data(repeating: 0x77, count: 1_048_576).write(to: deadPIDFile)
  try Data(repeating: 0x66, count: 1_048_576).write(to: livePIDFile)
  try setTreeTimestamp(tsxDir, to: fiveDaysAgo)

  let tempCompile = AutopilotAppUpdaters.tempCompilerItems(
    in: tmpRoot.path, now: now, minimumBytes: 512_000)
  equal(tempCompile.items.count, 1, "tsx temp compile cache discovered")
  if let tsxItem = tempCompile.items.first {
    let burned = AutopilotAppUpdaters.reclaimTempCompiler(
      tsxItem, authority: "rule:u", temp: tmpRoot.path, now: now, inUse: { _ in 0 })
    equal(burned.outcome, "burned", "dead-PID tsx cache reclaimed")
    checkFalse(
      FileManager.default.fileExists(atPath: deadPIDFile.path), "dead-PID tsx file removed")
    check(FileManager.default.fileExists(atPath: livePIDFile.path), "live-PID tsx file preserved")
  }

  // 3. Universal global package caches & deep Gradle build/ + .gradle worktree exclusions.
  let swiftpmCache = home.appendingPathComponent(
    "Library/Caches/org.swift.swiftpm", isDirectory: true)
  try FileManager.default.createDirectory(at: swiftpmCache, withIntermediateDirectories: true)
  try Data("repos".utf8).write(to: swiftpmCache.appendingPathComponent("repositories.bin"))
  try setTreeTimestamp(swiftpmCache, to: fiveDaysAgo)

  let monorepo = URL(fileURLWithPath: home.path + "/git/orbit-monorepo", isDirectory: true)
  let androidRoot = monorepo.appendingPathComponent("apps/mobile/android", isDirectory: true)
  let gradleCleanupDir = androidRoot.appendingPathComponent(
    ".gradle/buildOutputCleanup", isDirectory: true)
  let appModule = androidRoot.appendingPathComponent("app", isDirectory: true)
  let appIntermediates = appModule.appendingPathComponent("build/intermediates", isDirectory: true)
  try FileManager.default.createDirectory(at: gradleCleanupDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: appIntermediates, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(monorepo.path, ["init", "-q", "--initial-branch=main"])
  _ = try WorktreeGit.run(monorepo.path, ["config", "user.email", "proof@example.invalid"])
  _ = try WorktreeGit.run(monorepo.path, ["config", "user.name", "Proof"])
  try Data("rootProject.name = 'mobile'\n".utf8).write(
    to: androidRoot.appendingPathComponent("settings.gradle.kts"))
  try Data("plugins {}\n".utf8).write(to: appModule.appendingPathComponent("build.gradle.kts"))
  try Data("**/.gradle/\n**/build/\n".utf8).write(to: monorepo.appendingPathComponent(".gitignore"))
  _ = try WorktreeGit.run(
    monorepo.path,
    [
      "add", "apps/mobile/android/settings.gradle.kts",
      "apps/mobile/android/app/build.gradle.kts", ".gitignore",
    ])
  _ = try WorktreeGit.run(monorepo.path, ["commit", "-q", "-m", "init"])
  try Data("cache".utf8).write(to: gradleCleanupDir.appendingPathComponent("cache.properties"))
  try Data("apk".utf8).write(to: appIntermediates.appendingPathComponent("classes.dex"))
  try setTreeTimestamp(monorepo, to: fiveDaysAgo)

  let exclusions = AutopilotDisk.recoveryExclusions(monorepo.path, home: home.path)
  check(
    exclusions.contains("apps/mobile/android/app/build"),
    "nested Android Gradle app/build excluded from worktree PrivateRecovery: \(exclusions)")
  check(
    exclusions.contains("apps/mobile/android/.gradle"),
    "nested project-local .gradle excluded from worktree PrivateRecovery: \(exclusions)")

  // Also test standalone checkout discovery & regenerable reclaim at depth <= 3.
  let standaloneAndroid = URL(
    fileURLWithPath: home.path + "/git/mobile-standalone", isDirectory: true)
  let standaloneIntermediates = standaloneAndroid.appendingPathComponent(
    "app/build/intermediates", isDirectory: true)
  let standaloneBuild = standaloneAndroid.appendingPathComponent("app/build", isDirectory: true)
  try FileManager.default.createDirectory(
    at: standaloneIntermediates, withIntermediateDirectories: true)
  _ = try WorktreeGit.run(standaloneAndroid.path, ["init", "-q", "--initial-branch=main"])
  _ = try WorktreeGit.run(
    standaloneAndroid.path, ["config", "user.email", "proof@example.invalid"])
  _ = try WorktreeGit.run(standaloneAndroid.path, ["config", "user.name", "Proof"])
  try Data("plugins {}\n".utf8).write(
    to: standaloneAndroid.appendingPathComponent("app/build.gradle.kts"))
  try Data("**/build/\n".utf8).write(to: standaloneAndroid.appendingPathComponent(".gitignore"))
  _ = try WorktreeGit.run(standaloneAndroid.path, ["add", "app/build.gradle.kts", ".gitignore"])
  _ = try WorktreeGit.run(standaloneAndroid.path, ["commit", "-q", "-m", "init"])
  try Data("dex".utf8).write(to: standaloneIntermediates.appendingPathComponent("classes.dex"))
  try setTreeTimestamp(standaloneAndroid, to: fiveDaysAgo)

  var androidWT = WorktreeRecord(
    id: "wt-android", path: standaloneAndroid.path,
    repository: standaloneAndroid.appendingPathComponent(".git").path)
  androidWT.main = true
  androidWT.lastFileChange = fiveDaysAgo

  let diskItems = AutopilotDisk.items(
    worktrees: [androidWT], home: home.path, caches: true, now: now,
    sizer: { _ in 120_000_000 },
    protected: ProtectedLocations(access: fixtureAccess()))
  check(
    diskItems.contains(where: {
      $0.path == swiftpmCache.path && $0.facts["folder"] == "package-cache"
    }),
    "SwiftPM global cache discovered")
  check(
    diskItems.contains(where: { $0.path == shipIt.path && $0.facts["folder"] == "package-cache" }),
    "ShipIt updater cache surfaced through AutopilotDisk.items")

  if let shipItDiskItem = diskItems.first(where: { $0.path == shipIt.path }) {
    let key = SymmetricKey(size: .bits256)
    let receipt = AutopilotDisk.reclaim(
      shipItDiskItem, authority: "rule:u", home: home.path, inUse: { _ in 0 },
      protected: ProtectedLocations(access: fixtureAccess()), root: stateRoot, recoveryKey: key)
    equal(receipt.outcome, "burned", "ShipIt updater cache reclaimed via AutopilotDisk")
    isNil(receipt.restore)
    checkFalse(FileManager.default.fileExists(atPath: shipIt.path), "ShipIt folder removed")
  } else {
    failTest("ShipIt item surfaced in AutopilotDisk.items")
  }

  if let gradleBuildItem = diskItems.first(where: { $0.path == standaloneBuild.path }) {
    let key = SymmetricKey(size: .bits256)
    let receipt = AutopilotDisk.reclaim(
      gradleBuildItem, authority: "rule:d", home: home.path, inUse: { _ in 0 },
      protected: ProtectedLocations(access: fixtureAccess()), root: stateRoot, recoveryKey: key)
    equal(receipt.outcome, "burned", "Gradle build output burned")
    isNil(receipt.restore)
  } else {
    failTest("Gradle app/build item discovered under standaloneAndroid")
  }
}

private func claudeRunCachePruneProof() throws {
  let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-claude-cache-" + UUID().uuidString, isDirectory: true)
  let home = temp.appendingPathComponent("Users/fixture", isDirectory: true)
  let appSupport = home.appendingPathComponent(
    "Library/Application Support/BurnZombies", isDirectory: true)
  try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temp) }

  let staleUUID = UUID().uuidString
  let activeUUID = UUID().uuidString
  let recentUUID = UUID().uuidString

  let staleRunDir = appSupport.appendingPathComponent(
    "autopilot-run-" + staleUUID, isDirectory: true)
  let activeRunDir = appSupport.appendingPathComponent(
    "autopilot-run-" + activeUUID, isDirectory: true)
  let recentRunDir = appSupport.appendingPathComponent(
    "autopilot-run-" + recentUUID, isDirectory: true)
  try FileManager.default.createDirectory(at: activeRunDir, withIntermediateDirectories: true)

  let staleCache = AutopilotHarness.claudeRunCacheDirectory(for: staleRunDir, home: home.path)
  let activeCache = AutopilotHarness.claudeRunCacheDirectory(for: activeRunDir, home: home.path)
  let recentCache = AutopilotHarness.claudeRunCacheDirectory(for: recentRunDir, home: home.path)
  let userProjectCache = home.appendingPathComponent(
    "Library/Caches/claude-cli-nodejs/-Users-fixture-git-orbit-web", isDirectory: true)

  check(
    staleCache.lastPathComponent.contains("Application-Support-BurnZombies-autopilot-run-"),
    "spaces and slashes encoded identically to Claude CLI: \(staleCache.lastPathComponent)")

  for dir in [staleCache, activeCache, recentCache, userProjectCache] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  let now = Date()
  try setTreeTimestamp(staleCache, to: now.addingTimeInterval(-7_200))
  try setTreeTimestamp(activeCache, to: now.addingTimeInterval(-7_200))
  try setTreeTimestamp(recentCache, to: now.addingTimeInterval(-300))
  try setTreeTimestamp(userProjectCache, to: now.addingTimeInterval(-86_400))

  let removed = AutopilotHarness.pruneClaudeRunCaches(
    home: home.path, root: appSupport, graceAge: 3_600, now: now)
  equal(removed, 1, "pruned only expired orphan autopilot-run cache")
  checkFalse(FileManager.default.fileExists(atPath: staleCache.path), "expired orphan removed")
  check(FileManager.default.fileExists(atPath: activeCache.path), "active sweep cache preserved")
  check(FileManager.default.fileExists(atPath: recentCache.path), "recent sweep cache preserved")
  check(
    FileManager.default.fileExists(atPath: userProjectCache.path),
    "normal user Claude CLI project cache untouched")
}
