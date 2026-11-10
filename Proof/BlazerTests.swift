import BurnCore
import Darwin
import Foundation

func blazerProof() throws {
  let fm = FileManager.default
  let workspace = fm.temporaryDirectory.appendingPathComponent("bz-blazer-" + UUID().uuidString)
  let home = workspace.appendingPathComponent("home")
  let state = workspace.appendingPathComponent("state")
  let tempRoot = workspace.appendingPathComponent("tmp")
  try fm.createDirectory(at: home, withIntermediateDirectories: true)
  try fm.createDirectory(at: state, withIntermediateDirectories: true)
  try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: workspace) }

  let now = Date(timeIntervalSince1970: 1_800_000_000)

  // 1. BlazerOverdrive velocity + low-disk activation
  let t0 = now.addingTimeInterval(-1_800)
  let initial = BlazerOverdrive.sample(
    root: state, volumePath: home.path, now: t0,
    statVolume: { _ in (free: 80_000_000_000, total: 500_000_000_000) })
  equal(initial.overdriveActive, false, "80 GB free with no history is nominal")

  let burningFast = BlazerOverdrive.sample(
    root: state, volumePath: home.path, now: now,
    statVolume: { _ in (free: 74_000_000_000, total: 500_000_000_000) })
  check(
    burningFast.exhaustBytesPerHour >= 11_000_000_000,
    "6 GB lost in 30m computes ~12 GB/hr exhaust velocity")
  equal(burningFast.overdriveActive, true, ">= 5 GB/hr exhaust engages Overdrive")

  let lowDisk = BlazerOverdrive.readOnlyTelemetry(
    root: state, volumePath: home.path, now: now,
    statVolume: { _ in (free: 18_000_000_000, total: 500_000_000_000) })
  equal(lowDisk.overdriveActive, true, "< 50 GB free engages Overdrive")

  var sweep = AutopilotSweepState()
  sweep.firstTick = now.addingTimeInterval(-7_200)
  sweep.lastTick = now.addingTimeInterval(-130)
  sweep.intervalMinutes = 15
  equal(AutopilotSweeper.nativeDue(sweep, now: now, overdrive: false), false, "15m nominal waits")
  equal(AutopilotSweeper.nativeDue(sweep, now: now, overdrive: true), true, "2m Overdrive fires")

  // 2. BlazerAnatomy content-signature discovery & safe reclamation
  let disguisedDD = tempRoot.appendingPathComponent("ios-dd-hidden")
  try fm.createDirectory(
    at: disguisedDD.appendingPathComponent("Build/Intermediates.noindex"),
    withIntermediateDirectories: true)
  try Data("<plist/>".utf8).write(to: disguisedDD.appendingPathComponent("info.plist"))

  let sdkBase = home.appendingPathComponent(".patrol6/android-sdk-local/group")
  for index in 1...4 {
    let tree = sdkBase.appendingPathComponent("sdk-\(index)")
    try fm.createDirectory(at: tree.appendingPathComponent("platforms"), withIntermediateDirectories: true)
    try fm.createDirectory(at: tree.appendingPathComponent("build-tools"), withIntermediateDirectories: true)
    let stamp = now.addingTimeInterval(Double(-index * 86_400))
    try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: tree.path)
  }

  let simUUID = UUID().uuidString
  let simDir = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(simUUID)")
  let simData = simDir.appendingPathComponent("data")
  try fm.createDirectory(at: simData, withIntermediateDirectories: true)
  let plistData = try PropertyListSerialization.data(
    fromPropertyList: ["name": "Ephemeral QA iPhone", "state": 1], format: .xml, options: 0)
  try plistData.write(to: simDir.appendingPathComponent("device.plist"))
  try fm.setAttributes(
    [.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: simData.path)
  try fm.setAttributes(
    [.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: disguisedDD.path)

  let found = BlazerAnatomy.scan(
    home: home.path, root: state, threads: [], tempRoots: [tempRoot.path], overdrive: true,
    minimumBytes: 100_000_000, now: now, sizer: { _ in 500_000_000 },
    protected: .limited(homes: [home.path]))
  let kinds = Set(found.compactMap { $0.facts["anatomical"] })
  check(kinds.contains("disguised-derived-data"), "found disguised DerivedData in temp")
  check(kinds.contains("android-sdk-tree"), "found 4th Android SDK tree while protecting newest 3")
  check(kinds.contains("simulator-data"), "found shut-down Simulator data")
  equal(
    found.filter { $0.facts["anatomical"] == "android-sdk-tree" }.count, 1,
    "exact 3 newest Android SDK trees are kept safe")

  if let ddItem = found.first(where: { $0.facts["anatomical"] == "disguised-derived-data" }) {
    let decision = AutopilotPolicy.decide(ddItem, memory: AutopilotMemory(), now: now)
    equal(decision.status, .burn, "Overdrive starter rule burns disguised DerivedData")
    equal(decision.authority, "starter:starter-blazer-overdrive")
    let receipt = BlazerAnatomy.reclaim(
      ddItem, authority: "starter:starter-blazer-overdrive", home: home.path,
      tempRoots: [tempRoot.path], inUse: { _ in 0 }, protected: .limited(homes: [home.path]),
      root: state)
    equal(receipt.outcome, "burned", "disguised DerivedData reclaimed cleanly")
    checkFalse(fm.fileExists(atPath: disguisedDD.path), "disguised DerivedData removed")
  } else {
    failTest("missing disguised-derived-data item")
  }

  // 3. AgentThrashScanner (Loop Zombie + Focus Thief) & Antigravity thread indexing
  let agyDir = home.appendingPathComponent(
    ".gemini/antigravity/brain/session-123/.system_generated/logs")
  try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
  let loopTranscript = (1...5).map { i in
    "{\"step_index\":\(i),\"status\":\"ERROR\",\"content\":\"Command Working Directory: \(home.path)\\nindex.lock already exists\"}"
  }.joined(separator: "\n")
  try Data(loopTranscript.utf8).write(to: agyDir.appendingPathComponent("transcript.jsonl"))

  let threads = AgentThreads.index(home: home.path, now: Date())
  check(
    threads.contains(where: { $0.id == "antigravity:session-123" && $0.agent == "antigravity" }),
    "Antigravity transcript indexed in AgentThreads")

  let thrash = AgentThrashScanner.scan(
    home: home.path, now: Date(), threads: threads,
    processSamples: [
      .init(
        pid: 42424, name: "Google Chrome for Testing",
        commandLine: "playwright open --headed https://localhost:3000")
    ])
  check(thrash.contains(where: { $0.kind == .loopZombie }), "detected Loop Zombie from tail")
  check(thrash.contains(where: { $0.kind == .focusThief }), "detected --headed Focus Thief")

  // 4. AgentBaton (<execution_baton> + Negative Memory) & Multi-Brain Failover
  let baton = try AgentBaton.compile(target: "session-123", home: home.path, now: Date())
  check(baton.markdown.contains("<execution_baton>"), "baton wrapped in XML tag")
  check(baton.markdown.utf8.count <= AgentBaton.maxCapsuleBytes, "baton stays compact")
  check(!baton.negativeMemory.isEmpty, "baton captures negative memory from errors")

  let primary = MachineReviewConfiguration(
    harness: "claude", executable: "/usr/bin/claude", launcher: "/usr/bin/bz",
    server: "/usr/bin/bz-mcp")
  let alt = AutopilotHarness.failoverConfiguration(
    from: primary, detect: { $0 == "codex" ? "/opt/homebrew/bin/codex" : nil })
  equal(alt?.harness, "codex", "Claude usage limit fails over to Codex")
}
