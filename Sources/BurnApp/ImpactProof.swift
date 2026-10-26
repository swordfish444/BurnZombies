#if DEBUG
import AppKit
import BurnCore
import SwiftUI
import Vision

/// Renders the shipped view after selection changes, without a window or observer.
@MainActor func impactProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let model = AppModel(demo: true)
  let host = NSHostingView(rootView: ImpactWindowView(model: model))
  host.frame = NSRect(x: 0, y: 0, width: 1008, height: 930)
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
  }
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for (period, count) in [(ImpactPeriod.week, 368), (.all, 880), (.today, 128)] {
    model.impactPeriod = period
    settle()
    let numbers = ImpactNumbers.make(model, period: model.impactPeriod)
    guard model.impactPeriod == period, numbers.count == count else {
      throw StoreError.message("Filter did not update selection and totals")
    }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw StoreError.message("Impact render unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    // Read the rendered counter, not just the model: transitions can retain an old value.
    let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
    guard let counters = bitmap.cgImage?.cropping(to: CGRect(
      x: 40 * scale, y: 400 * scale, width: 928 * scale, height: 85 * scale)) else {
      throw StoreError.message("Rendered counters unavailable")
    }
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLevel = .accurate
    recognition.recognitionLanguages = ["en-US"]
    recognition.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: counters, options: [:]).perform([recognition])
    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    guard visible.contains(String(count)) else {
      throw StoreError.message("Rendered counter did not update to \(count): \(visible)")
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw StoreError.message("Impact PNG unavailable")
    }
    try png.write(to: directory.appendingPathComponent(period.rawValue + ".png"))
    print("PASS native \(period.rawValue) render: \(numbers.count) burns, \(numbers.memory) bytes")
  }
  model.previewBurn()
  settle()
  guard ImpactNumbers.make(model, period: model.impactPeriod).count == 146,
    model.burnPulse == 1 else { throw StoreError.message("Preview burn did not update the selected period once") }
  model.impactPeriod = .week
  model.impactTab = "Burn Log"; settle()
  model.impactTab = "Impact"; settle()
  guard model.impactPeriod == .week else { throw StoreError.message("Navigation reset the filter") }
  print("PASS offscreen period rendering, receipt updates and tab navigation without a window")
}
#endif
