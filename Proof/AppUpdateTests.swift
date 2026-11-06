import BurnCore
import Darwin
import Foundation

func appUpdateLiveProof(app: URL) async throws {
  let before = try AppUpdateBundle.read(app)
  let release = try await AppUpdateClient.check()
  let plan = try await AppUpdatePreparation.prepare(release, destination: app)
  defer { try? FileManager.default.removeItem(at: plan.workspace) }
  try plan.verifyBeforeQuit()
  equal(
    try AppUpdateBundle.read(app), before, "live preparation never replaces the running fixture")
  equal(plan.replacement.version, release.version.description)
  print(
    "PASS live GitHub update check, bounded HTTPS download, published checksum, archive validation, production certificate and preparation for \(release.version)"
  )
}

func appUpdateProof() async throws {
  let base = URL(
    fileURLWithPath: WorkspaceSafety.canonical(FileManager.default.temporaryDirectory.path)
  )
  .appendingPathComponent("bz-updates-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: base) }
  let newerMinor = try AppVersion("0.16.0") > AppVersion("0.15.99")
  let newerPatch = try AppVersion("0.9.10") > AppVersion("0.9.2")
  check(newerMinor)
  check(newerPatch)
  for invalid in [
    "", "1", "1.2", "-1.2.3", "1.2.3-beta", "v1.2.3", "1.2.3.4", "18446744073709551616.1.1",
  ] {
    throwsError(try AppVersion(invalid))
  }
  let good = updateReleaseJSON()
  let release = try AppUpdateRelease.decode(JSONSerialization.data(withJSONObject: good))
  equal(release.version.description, "0.16.0")
  for edit in 0..<8 {
    var bad = good
    switch edit {
    case 0: bad["draft"] = true
    case 1: bad["prerelease"] = true
    case 2: bad["tag_name"] = "v0.16.0-preview"
    case 3: bad["html_url"] = "https://example.invalid/releases/tag/v0.16.0"
    default:
      var assets = bad["assets"] as! [[String: Any]]
      if edit == 4 { assets[0]["browser_download_url"] = "https://example.invalid/app.tar.gz" }
      if edit == 5 { assets[0]["size"] = 268_435_457 }
      if edit == 6 { assets.append(assets[0]) }
      if edit == 7 { assets[0]["digest"] = "sha256:not-a-digest" }
      bad["assets"] = assets
    }
    throwsError(try AppUpdateRelease.decode(JSONSerialization.data(withJSONObject: bad)))
  }
  let hash = String(repeating: "a", count: 64)
  equal(
    try AppUpdateRelease.checksum(Data((hash + "  " + AppUpdateRelease.assetName + "\n").utf8)),
    hash)
  throwsError(try AppUpdateRelease.checksum(Data((hash + "  wrong.tar.gz\n").utf8)))
  throwsError(
    try AppUpdateRelease.checksum(
      Data(String(repeating: hash + "  " + AppUpdateRelease.assetName + "\n", count: 2).utf8)))
  for invalid in [
    "http://github.com/a", "https://github.com.example.invalid/a",
    "https://user:secret@github.com/a", "https://github.com:444/a", "file:///tmp/update",
  ] {
    checkFalse(
      AppUpdateDownload.allowed(URL(string: invalid)!), "update transport rejects \(invalid)")
  }
  check(AppUpdateDownload.allowed(release.archive))
  let file = base.appendingPathComponent("hash")
  try Data("abc".utf8).write(to: file)
  equal(
    try AppUpdateVerification.hash(file),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

  let app = base.appendingPathComponent("BurnZombies.app")
  try updateFixtureApp(app, version: "0.15.1", build: "72")
  let archive = base.appendingPathComponent("valid.tar.gz")
  try AppUpdateVerification.tool(
    "/usr/bin/tar", ["-czf", archive.path, "-C", base.path, "BurnZombies.app"],
    environment: ["COPYFILE_DISABLE": "1"])
  try AppUpdateVerification.validateArchive(archive)
  throwsError(try AppUpdateVerification.verify(app, version: "0.15.1"))
  for (index, entry) in [
    ("../outside", "0", ""), ("/BurnZombies.app/outside", "0", ""),
    ("BurnZombies.app/../outside", "0", ""), ("Other.app/file", "0", ""),
    ("BurnZombies.app/link", "2", "/tmp/outside"),
    ("BurnZombies.app/link", "1", "BurnZombies.app/other"),
    ("BurnZombies.app/pipe", "6", ""), ("BurnZombies.app/device", "3", ""),
    ("BurnZombies.app/with\nnewline", "0", ""),
  ].enumerated() {
    let raw = base.appendingPathComponent("bad-\(index).tar")
    let packed = base.appendingPathComponent("bad-\(index).tar.gz")
    try updateTar(name: entry.0, type: entry.1, link: entry.2).write(to: raw)
    try AppUpdateVerification.tool("/usr/bin/gzip", ["-c", raw.path]).write(to: packed)
    throwsError(try AppUpdateVerification.validateArchive(packed))
  }
  let info = app.appendingPathComponent("Contents/Info.plist")
  let saved = try Data(contentsOf: info)
  try Data(repeating: 65, count: 65_537).write(to: info)
  throwsError(try AppUpdateBundle.read(app))
  try saved.write(to: info)
  try FileManager.default.removeItem(at: info)
  try FileManager.default.createSymbolicLink(at: info, withDestinationURL: file)
  throwsError(try AppUpdateBundle.read(app))

  for mode in ["success", "launch-failure", "stop-failure", "raced-occupant", "changed-package"] {
    try await updateTransactionProof(base: base.appendingPathComponent(mode), mode: mode)
  }
  var interrupted = AppUpdateResult(state: "installing", version: "0.16.0", detail: "waiting")
  interrupted.worker = ProcessIdentity(pid: Int32.max, seconds: 1, boot: Native().boot)
  let receiptRoot = base.appendingPathComponent("interrupted")
  try interrupted.save(root: receiptRoot)
  equal(
    AppUpdateResult.load(root: receiptRoot)?.state, "failed",
    "interruption never permanently wedges update controls")
  try await updateQuiescenceProof(root: base.appendingPathComponent("quiescence"))
  print(
    "PASS app updates: versions, trusted release URLs, checksums, unsafe archives, signer refusal, atomic install, rollback, raced occupants, interrupted receipts and cleanup quiescence"
  )
}

func updateReleaseJSON(version: String = "0.16.0") -> [String: Any] {
  let base = AppUpdateRelease.repository + "/releases/download/v" + version + "/"
  return [
    "tag_name": "v" + version, "draft": false, "prerelease": false,
    "html_url": AppUpdateRelease.repository + "/releases/tag/v" + version,
    "assets": [
      [
        "name": AppUpdateRelease.assetName,
        "browser_download_url": base + AppUpdateRelease.assetName, "size": 100,
      ],
      ["name": "SHA256SUMS", "browser_download_url": base + "SHA256SUMS", "size": 80],
    ],
  ]
}

private func updateFixtureApp(_ app: URL, version: String, build: String) throws {
  try FileManager.default.createDirectory(
    at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
  let properties = [
    "CFBundleIdentifier": "io.burnzombies.app", "CFBundleExecutable": "BurnZombiesApp",
    "CFBundleShortVersionString": version, "CFBundleVersion": build,
    "LSMinimumSystemVersion": "14.0",
  ]
  try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
    .write(to: app.appendingPathComponent("Contents/Info.plist"))
  try Data(("inert fixture " + version).utf8).write(
    to: app.appendingPathComponent("Contents/MacOS/BurnZombiesApp"))
}

private func updateTar(name: String, type: String, link: String) -> Data {
  var header = [UInt8](repeating: 0, count: 512)
  func field(_ value: String, _ offset: Int, _ length: Int) {
    for (i, byte) in value.utf8.prefix(length).enumerated() { header[offset + i] = byte }
  }
  field(name, 0, 100)
  field("0000755", 100, 7)
  field("0000000", 108, 7)
  field("0000000", 116, 7)
  field("00000000000", 124, 11)
  field("00000000000", 136, 11)
  field("        ", 148, 8)
  field(type, 156, 1)
  field(link, 157, 100)
  field("ustar", 257, 5)
  field("00", 263, 2)
  let checksum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
  field(String(repeating: "0", count: 6 - checksum.count) + checksum + "\0 ", 148, 8)
  return Data(header + [UInt8](repeating: 0, count: 1024))
}

private final class UpdatePathWatcher: @unchecked Sendable {
  private let lock = NSLock()
  private var running = true
  private var missing = 0
  private let group = DispatchGroup()
  init(_ path: String) {
    group.enter()
    DispatchQueue.global().async {
      while self.lock.withLock({ self.running }) {
        var info = stat()
        if lstat(path, &info) != 0, errno == ENOENT { self.lock.withLock { self.missing += 1 } }
        usleep(100)
      }
      self.group.leave()
    }
  }
  func stop() -> Int {
    lock.withLock { running = false }
    group.wait()
    return lock.withLock { missing }
  }
}

private func updateTransactionProof(base: URL, mode: String) async throws {
  let parent = base.appendingPathComponent("Applications With Spaces")
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  let app = parent.appendingPathComponent("BurnZombies.app")
  try updateFixtureApp(app, version: "0.15.1", build: "72")
  let workspace = parent.appendingPathComponent(".BurnZombies-update-" + UUID().uuidString)
  try FileManager.default.createDirectory(
    at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let payload = workspace.appendingPathComponent("unpacked/BurnZombies.app")
  try updateFixtureApp(payload, version: "0.16.0", build: "74")
  let old = try AppUpdateBundle.read(app)
  let new = try AppUpdateBundle.read(payload)
  let plan = AppUpdatePlan(
    directory: workspace.path, destination: app.path, previous: old, replacement: new,
    parent: ProcessIdentity(pid: getpid(), seconds: 1))
  try plan.save()
  let decoded = try AppUpdatePlan.load(plan.file)
  equal(decoded.previous, old)
  equal(decoded.replacement, new)
  let root = base.appendingPathComponent("Private State")
  let store = try Store(root: root)
  let settings = root.appendingPathComponent("owner-settings")
  try store.write(Data("Keep forever and selected model".utf8), to: settings, limit: 1024)
  let calls = Calls()
  let watcher = UpdatePathWatcher(app.path)
  if mode == "changed-package" {
    try updateFixtureApp(payload, version: "0.17.0", build: "99")
  }
  do {
    try await AppUpdateInstallation.install(
      plan, root: root,
      verify: { app, _ in try AppUpdateBundle.read(app) },
      launch: { launched in
        let version = try AppUpdateBundle.read(launched).version
        calls.add("launch:" + version)
        try await Task.sleep(nanoseconds: 50_000_000)
        if version == "0.16.0", mode == "launch-failure" || mode == "stop-failure" {
          throw StoreError.message("Fixture app didn't become healthy")
        }
        if mode == "raced-occupant", version == "0.16.0" {
          try FileManager.default.moveItem(
            at: launched, to: base.appendingPathComponent("displaced.app"))
          try updateFixtureApp(launched, version: "9.0.0", build: "999")
        }
      },
      stop: { _ in
        calls.add("stop")
        if mode == "stop-failure" { throw StoreError.message("Fixture new app is still closing") }
      })
    check(mode == "success", "failure fixture must not succeed: \(mode)")
  } catch { check(mode != "success", "successful update: \(error)") }
  let gaps = watcher.stop()
  // The raced-occupant fixture deliberately moves the app itself; the updater must preserve it.
  if mode != "raced-occupant" { equal(gaps, 0, "the installed app path never disappears") }
  equal(
    try store.read(settings, limit: 1024), Data("Keep forever and selected model".utf8),
    "updates never rewrite owner state")
  let result = AppUpdateResult.load(root: root)
  switch mode {
  case "success":
    equal(try AppUpdateBundle.read(app), new)
    equal(calls.all, ["launch:0.16.0"])
    equal(result?.state, "updated")
    checkFalse(
      FileManager.default.fileExists(atPath: workspace.path),
      "verified success removes the old bundle and staging")
  case "launch-failure":
    equal(try AppUpdateBundle.read(app), old)
    equal(calls.all, ["launch:0.16.0", "stop", "launch:0.15.1"])
    equal(result?.state, "failed")
  case "stop-failure":
    equal(try AppUpdateBundle.read(app), new)
    equal(try AppUpdateBundle.read(plan.backup), old)
    equal(calls.all, ["launch:0.16.0", "stop"], "never replace an observer that is still closing")
  case "raced-occupant":
    equal(try AppUpdateBundle.read(app).version, "9.0.0", "never overwrite a raced new occupant")
    equal(try AppUpdateBundle.read(plan.backup), old)
  default:
    equal(try AppUpdateBundle.read(app), old)
    check(calls.all.isEmpty, "changed package never executes")
  }
}

private func updateQuiescenceProof(root: URL) async throws {
  let calls = Calls()
  let items = (0..<2).map { i in
    AutopilotItem(
      id: "disk:update-\(i)", kind: .disk, name: "fixture junk \(i)", bytes: 1024,
      facts: ["home": "stale-worktree", "folder": "node_modules"])
  }
  let began = DispatchSemaphore(value: 0)
  let finish = DispatchSemaphore(value: 0)
  let engine = try Autopilot(
    root: root,
    sources: AutopilotSources(
      disk: { _ in items.filter { !calls.all.contains($0.id) } },
      reclaimDisk: { item, authority in
        calls.add(item.id)
        if item.id == items[0].id {
          began.signal()
          _ = finish.wait(timeout: .now() + 5)
        }
        return AutopilotReceipt(
          itemID: item.id, kind: .disk, name: item.name, authority: authority,
          outcome: "burned", detail: "Inert fixture", bytes: item.bytes)
      }), minimumBytes: 1)
  let tick = Task { await engine.tick() }
  let started = await Task.detached { began.wait(timeout: .now() + 5) == .success }.value
  check(started, "first authorized cleanup started")
  let coordinator = AutopilotCoordinator(root: root, engine: engine, configuration: { nil })
  let paused = Task { try await coordinator.prepareForAppUpdate() }
  try await Task.sleep(nanoseconds: 80_000_000)
  equal(calls.all.count, 1, "no next cleanup while preparing to update")
  finish.signal()
  _ = await tick.value
  try await paused.value
  equal(calls.all.count, 1, "the active cleanup finishes; the following one waits")
  do {
    _ = try await engine.apply(.setLookOnly(true))
    failTest("new mutations must wait during restart")
  } catch {}
  await coordinator.resumeAfterAppUpdateFailure()
  _ = await engine.tick()
  equal(calls.all.count, 2, "a failed update resumes the unchanged cleanup policy")
}
