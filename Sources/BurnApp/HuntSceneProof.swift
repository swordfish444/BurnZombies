#if DEBUG
import AppKit
import SwiftUI

/// Deterministic native scene frames. No live hunt, model call, visible window,
/// screenshot permission, synthetic cleanup receipt or application activation.
@MainActor func huntSceneProof(output: String) throws {
  NSApp.setActivationPolicy(.prohibited)
  NSApp.appearance = NSAppearance(named: .darkAqua)
  BurnTheme.registerFonts()
  let directory = URL(fileURLWithPath: output, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let cases: [(String, HuntSceneMode, TimeInterval?, Bool)] = [
    ("idle", .idle, 0, false), ("walking", .searching, 1.5, false),
    ("scan-25", .searching, 4.875, false), ("scan-75", .searching, 7.625, false),
    ("scan-100", .searching, 9.25, false), ("detected", .detected, 1, false),
    ("burning", .burning, 1.5, false), ("complete", .complete, 0, false),
    ("paused", .paused, 0, false), ("reduced-motion", .searching, nil, true),
    ("worktree-eradicated", .burning, 1.5, false)
  ]
  var frames: [String: Data] = [:]
  for (name, mode, time, reduced) in cases {
    let view = HuntSceneView(mode: mode,
      celebrationTitle: name == "worktree-eradicated" ? "WORKTREE ERADICATED" : nil,
      isVisible: false, elapsedOverride: time, reduceMotionOverride: reduced)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 310)
    let surface = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    surface.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 620,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
      throw NSError(domain: "HuntSceneProof", code: 1, userInfo: [NSLocalizedDescriptionKey: "Scene bitmap unavailable"])
    }
    bitmap.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]), !surface.isVisible, !surface.isKeyWindow else {
      throw NSError(domain: "HuntSceneProof", code: 2, userInfo: [NSLocalizedDescriptionKey: "Scene proof surfaced a window or could not render"])
    }
    try png.write(to: directory.appendingPathComponent(name + ".png")); frames[name] = png
    surface.contentView = nil
  }
  guard frames["scan-25"] != frames["scan-75"], frames["scan-75"] != frames["scan-100"],
    frames["detected"] != frames["burning"], frames["burning"] != frames["worktree-eradicated"] else {
    throw NSError(domain: "HuntSceneProof", code: 3, userInfo: [NSLocalizedDescriptionKey: "Scene states failed to produce distinct frames"])
  }
  print("PASS 11 offscreen hunt scene frames: walking, feet-to-head 25/75/100 scans, detected, flamethrower, worktree celebration, idle/complete/paused and reduced motion; no windows or model calls")
}
#endif
