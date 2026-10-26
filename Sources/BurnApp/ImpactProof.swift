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
  // AppKit-backed glyph views need a backing surface, but it is never shown.
  let surface = NSWindow(contentRect: host.frame, styleMask: .borderless,
    backing: .buffered, defer: false)
  surface.contentView = host
  func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
  }
  func clickPeriod(_ option: ImpactPeriod) throws {
    settle()
    let index = ImpactPeriod.allCases.firstIndex(of: option)!
    // Bottom of the actual button: the decorative halo previously extended into
    // this row. Deliver local events only; never post desktop input or show a window.
    let point = NSPoint(x: 697 + index * 104, y: host.isFlipped ? 108 : 930 - 108)
    guard let target = host.hitTest(point) else { throw StoreError.message("No period hit target") }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: surface.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
        throw StoreError.message("Period event unavailable")
      }
      if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
    }
    settle()
    guard model.impactPeriod == option else { throw StoreError.message("Actual period click did not select \(option.rawValue)") }
  }
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  for (period, count) in [(ImpactPeriod.week, 368), (.all, 880), (.today, 128)] {
    try clickPeriod(period)
    settle()
    let numbers = ImpactNumbers.make(model, period: model.impactPeriod)
    guard model.impactPeriod == period, numbers.count == count else {
      throw StoreError.message("Filter did not update selection and totals")
    }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw StoreError.message("Impact render unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard !surface.isVisible, !surface.isKeyWindow else {
      throw StoreError.message("Proof surface must stay offscreen")
    }
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
    guard let heading = bitmap.cgImage?.cropping(to: CGRect(
      x: 80 * scale, y: 120 * scale, width: 540 * scale, height: 230 * scale)) else {
      throw StoreError.message("Rendered headline unavailable")
    }
    try VNImageRequestHandler(cgImage: heading, options: [:]).perform([recognition])
    let headline = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: " ")
    guard headline.contains("TAME THE"), headline.contains("HORDE") else {
      throw StoreError.message("Rendered headline incomplete: \(headline)")
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
  for period in [ImpactPeriod.week, .today, .all, .week] { try clickPeriod(period) }
  model.impactTab = "Burn Log"; settle()
  model.impactTab = "Impact"; settle()
  guard model.impactPeriod == .week else { throw StoreError.message("Navigation reset the filter") }
  print("PASS real period hit targets in both directions, offscreen rendering, receipt updates and tab navigation")
}
#endif
