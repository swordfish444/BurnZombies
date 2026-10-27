#if DEBUG
import AppKit
import BurnCore
import SwiftUI

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
  print("PASS offscreen native Settings render, draft/save/reopen, disabled-state preservation, invalid-input refusal and default reset")
}
#endif
