#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Exercises compact states in memory. No observer, cleanup, window or app activation.
@MainActor func miniProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for name in ["empty", "populated", "paused", "quiet-day", "unmeasured"] {
    let model = AppModel(demo: true)
    if name == "empty" || name == "paused" { model.state.catalog = Catalog() }
    if name == "paused" { model.machineReview.phase = "paused" }
    if name == "quiet-day" {
      let today = Calendar.current.startOfDay(for: Date())
      model.state.catalog.events.removeAll { ($0.verificationDate ?? $0.date) >= today }
    }
    if name == "unmeasured" {
      for index in model.state.catalog.events.indices {
        model.state.catalog.events[index].responseBeforeMS = nil
        model.state.catalog.events[index].responseAfterMS = nil
      }
    }
    let view = MiniImpactView(model: model)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: MiniImpactView.size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw StoreError.message("Compact render unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let cgImage = bitmap.cgImage,
      let png = bitmap.representation(using: .png, properties: [:]) else {
      throw StoreError.message("Compact PNG unavailable")
    }
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([recognition])
    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
    try visible.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    guard visible.contains("View impact"), visible.contains("Burn Log"),
      visible.contains("Memory pressure"), visible.contains("CPU time saved") else {
      throw StoreError.message("Compact labels or footer clipped: \(visible)")
    }
    if name == "populated" {
      guard visible.contains("24%"), !visible.contains("Still warming up") else {
        throw StoreError.message("Measured boost not displayed")
      }
    } else {
      guard visible.contains("Still warming up"), visible.contains("More cleanups will reveal your boost") else {
        throw StoreError.message("Missing compact warmup state: \(visible)")
      }
    }
    if name == "empty" || name == "paused" {
      guard view.numbers.count == 0, visible.contains("Ready for your first burn") else {
        throw StoreError.message("First-burn empty state not displayed")
      }
    } else {
      guard visible.contains("Last burn"), !visible.contains("Ready for your first burn") else {
        throw StoreError.message("Existing cleanup history presented as first use")
      }
    }
    if name == "paused" && !visible.contains("Review paused") {
      throw StoreError.message("Paused reviewer hidden by compact status")
    }
    guard host.frame.size == MiniImpactView.size else { throw StoreError.message("Popover size changed") }
    print("PASS offscreen compact \(name): 360 × 488, readable labels and footer")
  }
}
#endif
