#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Exercises the shipped view/controller without starting an observer or showing a window.
@MainActor func settingsProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-settings-ui-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var config = MachineReviewConfiguration(harness: "codex", executable: "/bin/true", launcher: "/bin/true", server: "/bin/true")
  config.enabled = false; try config.save(root: root)
  let settings = ReviewSettingsModel(root: root, catalog: [])
  settings.model = "example-model"; settings.thinking = "high"
  guard try MachineReviewConfiguration.load(root: root)?.model == nil else { throw StoreError.message("Draft saved prematurely") }
  settings.save()
  let restored = ReviewSettingsModel(root: root, catalog: [])
  guard restored.model == "example-model", restored.thinking == "high", restored.configuration?.enabled == false,
    !FileManager.default.fileExists(atPath: root.appendingPathComponent("review-request").path) else {
    throw StoreError.message("Settings failed round-trip or started a review")
  }
  let host = NSHostingView(rootView: ReviewSettingsView(settings: restored).padding(20)
    .frame(width: 440).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
  host.frame = NSRect(x: 0, y: 0, width: 440, height: 460)
  host.layoutSubtreeIfNeeded()
  guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw StoreError.message("Settings render unavailable") }
  host.cacheDisplay(in: host.bounds, to: bitmap)
  guard let png = bitmap.representation(using: .png, properties: [:]) else { throw StoreError.message("Settings PNG unavailable") }
  try png.write(to: URL(fileURLWithPath: output))
  restored.thinking = "invalid"
  restored.save()
  guard restored.failed, try MachineReviewConfiguration.load(root: root)?.reasoningEffort == "high" else {
    throw StoreError.message("Invalid draft replaced saved selection")
  }
  restored.model = ""; restored.thinking = ""; restored.save()
  guard try MachineReviewConfiguration.load(root: root)?.model == nil,
    try MachineReviewConfiguration.load(root: root)?.reasoningEffort == nil else { throw StoreError.message("Reset failed") }
  let usage = UsageHistoryModel(root: root)
  guard !usage.expanded else { throw StoreError.message("Usage must be collapsed by default") }
  var ledger = ReviewLedger()
  let now = Date()
  for hour in [0, 2, 5, 20, 28, 50, 96, 192, 500] {
    _ = ledger.reserve(harness: hour % 2 == 0 ? "codex" : "claude", evidenceCount: 1, now: now.addingTimeInterval(-Double(hour)*3600))
    let model = hour % 2 == 0 ? "gpt-6.1-sol" : "claude-opus-5-5"
    ledger.entries[ledger.entries.count - 1].usage = ReviewUsage.parse(Data("{\"type\":\"bz.usage\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(12000 + hour * 10),\"cached_input_tokens\":8000,\"output_tokens\":400}}".utf8))
  }
  try ledger.save(store: Store(root: root)); usage.reload()
  func renderUsage(_ suffix: String, height: CGFloat) throws {
    let view = NSHostingView(rootView: UsageHistoryView(model: usage).padding(20).frame(width: 440)
      .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
    view.frame = NSRect(x: 0, y: 0, width: 440, height: height)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw StoreError.message("Usage render unavailable") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw StoreError.message("Usage PNG unavailable") }
    try png.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension(suffix + ".png"))
  }
  try renderUsage("usage-collapsed", height: 90)
  usage.expanded = true; usage.days = 1; usage.hourly = true
  let daily = usage.report.total.input
  try renderUsage("usage-hourly", height: 900)
  guard UsageHistoryModel.ranges == [1, 7, 30] else { throw StoreError.message("Usage range options changed") }
  usage.days = 7
  let weekly = usage.report.total.input
  guard weekly > daily else { throw StoreError.message("7 day range did not include older usage") }
  usage.days = 30; usage.hourly = false; usage.costChart = true
  guard usage.report.total.input > weekly else { throw StoreError.message("30 day range did not include older usage") }
  try renderUsage("usage-daily", height: 900)
  usage.selectedModel = "gpt-6.1-sol"
  let selected = usage.report.total.input
  usage.selectedModel = ""
  guard usage.report.total.input > selected else { throw StoreError.message("Usage model filter did not narrow totals") }
  usage.selectedModel = "gpt-6.1-sol"; try renderUsage("usage-model", height: 800)
  print("PASS collapsed usage, exactly 1/7/30 day ranges, model rollups, persisted pricing and native chart renders")
  let disk = DiskSettingsModel(root: root)
  guard !disk.expanded, !disk.advanced, disk.policy.mode == "recommend" else { throw StoreError.message("Disk settings must begin collapsed and recommend-only") }
  disk.policy.preset("proactive"); disk.policy.instructions = "Keep release evidence for 30 days."; disk.save()
  let diskRestored = DiskSettingsModel(root: root)
  guard diskRestored.policy.minimumAgeDays == 2, diskRestored.policy.instructions == disk.policy.instructions else { throw StoreError.message("Disk tuning persistence failed") }
  disk.expanded = true
  let candidate = try JSONDecoder().decode(DiskCandidate.self, from: JSONSerialization.data(withJSONObject: [
    "id": "disk:ui", "path": root.appendingPathComponent("demo-project/build").path,
    "repository": root.appendingPathComponent("demo-project").path, "kind": "generated", "bytes": 18_000_000_000,
    "newest": now.addingTimeInterval(-40*86400).timeIntervalSinceReferenceDate, "fingerprint": "ui-only",
    "complete": true, "guardReason": "Needs an exact retention rule.", "reviewable": false, "userRule": "review",
    "policyRevision": disk.policy.revision, "recommendationEligible": true, "decision": "recommend",
    "rationale": "Old build output is a worthwhile cleanup candidate. Confirm this folder can be rebuilt, then approve cleanup; active work stays protected."
  ]))
  var small = candidate; small.id = "disk:small"; small.bytes = 9_999_999_999
  var boundary = candidate; boundary.id = "disk:boundary"; boundary.bytes = 10_000_000_000
  disk.inventory.candidates = [small, candidate, boundary]
  guard disk.candidates.map(\.id) == [candidate.id, boundary.id] else { throw StoreError.message("Disk UI did not enforce 10 GB floor") }
  disk.inventory.candidates = [candidate]; disk.inventory.freeBytes = 80_000_000_000
  try disk.inventory.save(Store(root: root))
  var discoveryNode = DiskSpaceNode(path: "/example/build-environments", scanRoot: "/example", allocated: 74_000_000_000,
    unshared: 32_000_000_000, files: 180_000, complete: true, measured: now)
  discoveryNode.members = (1...12).map { "/example/build-environments/run-\($0)/compiler-cache" }
  disk.discovery.nodes = [discoveryNode]
  disk.discovery.advice[discoveryNode.id] = DiskAdvice(id: discoveryNode.id, revision: discoveryNode.revision,
    title: "Trim repeated compiler caches", summary: "These build outputs can be recreated. Keep source, manifests and the latest accepted evidence.",
    nextStep: "Use the build tool’s cache cleanup after the current builds finish.", disposition: "owner-cleanup", date: now)
  try disk.discovery.save(Store(root: root))
  let diskHost = NSHostingView(rootView: DiskSettingsView(model: disk).padding(20).frame(width: 440)
    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
  diskHost.frame = NSRect(x: 0, y: 0, width: 440, height: 480); diskHost.layoutSubtreeIfNeeded()
  if let bitmap = diskHost.bitmapImageRepForCachingDisplay(in: diskHost.bounds) {
    diskHost.cacheDisplay(in: diskHost.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("disk.png"))
  }
  disk.rule(candidate, "keep")
  guard try DiskPolicy.load(Store(root: root)).rules.first?.disposition == "keep",
    disk.policy.mode == "recommend" else { throw StoreError.message("Keep must not enable removal") }
  disk.rule(candidate, "regenerable")
  let approved = try DiskPolicy.load(Store(root: root))
  guard approved.mode == "automatic", approved.rules.count == 1, approved.rules[0].path == candidate.path,
    approved.rules[0].disposition == "regenerable", !FileManager.default.fileExists(atPath: root.appendingPathComponent("review-request").path) else {
    throw StoreError.message("Exact-folder approval changed scope or dispatched a model")
  }
  print("PASS simplified AI recommendations, 10 GB floor, collapsed advanced controls, exact-folder approval and durable preferences without model dispatch")
  let accessModel = AppModel(demo: true)
  for accessState in [FullDiskAccessState.required, .unknown, .granted] {
    accessModel.state.fullDiskAccess = .init(state: accessState,
      detail: accessState == .unknown ? "Access could not be verified. Enable BurnZombies in System Settings, then check again." : "Full Disk Access is required before discovery.")
    let accessHost = NSHostingView(rootView: FullDiskAccessView(model: accessModel).padding(20)
      .frame(width: 440).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
    accessHost.frame = NSRect(x: 0, y: 0, width: 440, height: 580)
    accessHost.layoutSubtreeIfNeeded()
    guard let bitmap = accessHost.bitmapImageRepForCachingDisplay(in: accessHost.bounds) else {
      throw StoreError.message("Access setup render unavailable")
    }
    accessHost.cacheDisplay(in: accessHost.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage,
      let png = bitmap.representation(using: .png, properties: [:]) else {
      throw StoreError.message("Access setup PNG unavailable")
    }
    let label = accessState == .granted ? "available" : accessState == .required ? "required" : "unknown"
    try png.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("access-" + label + ".png"))
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([recognition])
    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    guard visible.contains("Full Disk Access"), visible.contains("Open Full Disk Access") else {
      throw StoreError.message("Required access controls clipped: \(visible)")
    }
    if accessState != .granted {
      guard visible.contains("Required"), visible.contains("I enabled access"), visible.contains("whole-Mac") || visible.contains("Whole-Mac") else {
        throw StoreError.message("Setup requirement or explicit confirmation missing: \(visible)")
      }
    } else if !visible.contains("Available") { throw StoreError.message("Granted access state missing") }
    guard NSApp.windows.allSatisfy({ !$0.isVisible && !$0.isKeyWindow }) else {
      throw StoreError.message("Access setup proof showed a window")
    }
  }
  print("PASS inline required/unknown/available access setup renders without opening System Settings or showing a window")
  print("PASS offscreen native Settings render, draft/save/reopen, disabled-state preservation, invalid-input refusal and default reset")
}
#endif
