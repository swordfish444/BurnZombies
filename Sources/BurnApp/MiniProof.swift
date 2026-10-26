#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Exercises compact states in memory. No observer, cleanup, visible window or app activation.
@MainActor func miniProof(output: String, catalog: Catalog? = nil) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let cases = catalog == nil ? ["empty", "populated", "paused", "quiet-day", "pruned", "unmeasured", "zero-memory", "legacy-negative", "slower", "noisy"] : ["receipt-replay"]
  for name in cases {
    let model = AppModel(demo: true)
    if let catalog { model.state.catalog = catalog }
    if name == "empty" || name == "paused" { model.state.catalog = Catalog() }
    if name == "paused" { model.machineReview.phase = "paused" }
    if name == "quiet-day" {
      let today = Calendar.current.startOfDay(for: Date())
      model.state.catalog.events.removeAll { ($0.verificationDate ?? $0.date) >= today }
    }
    if name == "pruned" { model.state.catalog.events = [] }
    if name == "unmeasured" || name == "zero-memory" {
      for index in model.state.catalog.events.indices {
        model.state.catalog.events[index].responseBeforeMS = nil
        model.state.catalog.events[index].responseAfterMS = nil
        model.state.catalog.events[index].responseBeforeSamples = nil
        model.state.catalog.events[index].responseAfterSamples = nil
        if name == "zero-memory" { model.state.catalog.events[index].residentBefore = 0 }
      }
    }
    if ["legacy-negative", "slower", "noisy"].contains(name) {
      for i in model.state.catalog.events.indices {
        model.state.catalog.events[i].responseBeforeMS = 2.22125
        model.state.catalog.events[i].responseAfterMS = 2.88971
        model.state.catalog.events[i].responseBeforeSamples = name == "legacy-negative" ? nil :
          (name == "noisy" ? [1, 2, 3, 20, 30, 40, 50] : Array(repeating: 2.22125, count: 7))
        model.state.catalog.events[i].responseAfterSamples = name == "legacy-negative" ? nil : Array(repeating: 2.88971, count: 7)
      }
    }
    let view = MiniImpactView(model: model)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: MiniImpactView.size)
    // Supply a native backing scale without ever ordering a window onto the screen.
    let surface = NSWindow(contentRect: host.frame, styleMask: .borderless,
      backing: .buffered, defer: false)
    surface.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    guard !surface.isVisible, !surface.isKeyWindow else {
      throw StoreError.message("Proof surface must stay offscreen")
    }
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
    if name == "receipt-replay" {
      guard !view.numbers.boost.contains("-"), visible.contains(String(view.numbers.count)) else {
        throw StoreError.message("Receipt replay failed: \(visible)")
      }
      print("Receipt replay: \(view.numbers.count) burns, \(ImpactNumbers.cpuTime(view.numbers.cpuSeconds)), speed \(view.numbers.boost)")
    } else if name == "populated" {
      guard visible.contains("24%"), !visible.contains("Still warming up") else {
        throw StoreError.message("Measured boost not displayed")
      }
    } else if ["legacy-negative", "slower", "noisy", "unmeasured"].contains(name) {
      guard visible.contains("AGENT BOOST"), visible.contains("Memory reclaimed"),
        visible.contains("128 helpers cleared"), !visible.contains("23%"), view.numbers.boost == "—" else {
        throw StoreError.message("Verified resource benefit missing: \(visible)")
      }
    } else if name == "zero-memory" {
      guard visible.contains("Helpers cleared"), visible.contains("Dead weight. Gone.") else {
        throw StoreError.message("Zero-memory cleanup benefit missing: \(visible)")
      }
    } else if name == "quiet-day" || name == "pruned" {
      guard visible.contains("Ready for the next burn"), visible.contains("880 helpers cleared all time") else {
        throw StoreError.message("Lifetime benefit missing on a quiet day: \(visible)")
      }
    } else {
      guard visible.contains("Still warming up"), visible.contains("Your first cleanup starts here") else {
        throw StoreError.message("Missing compact warmup state: \(visible)")
      }
    }
    if view.numbers.lifetimeCount > 0 {
      guard !visible.contains("Still warming up"), !visible.contains("No clear boost") else {
        throw StoreError.message("Verified cleanup presented as no benefit: \(visible)")
      }
    }
    if name == "empty" || name == "paused" {
      guard view.numbers.count == 0, visible.contains("Ready for your first burn") else {
        throw StoreError.message("First-burn empty state not displayed")
      }
    } else if name != "pruned" {
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
