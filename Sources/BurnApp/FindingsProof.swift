#if DEBUG
  import AppKit
  import BurnCore
  import SwiftUI
  import Vision

  /// Render the production window with a large inbox without showing or focusing it.
  @MainActor func findingsProof(output: String) throws {
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let model = AppModel(demo: true)
    model.state.inbox.proposals = (0..<1000).map { index in
      CleanupProposal(
        action: .process, resources: ["fixture-\(index)"], revision: "fixture",
        title: "Disposable helper \(index)", detail: "Synthetic layout proof; no cleanup.",
        recovery: "No action is performed.", ready: true, fixture: true)
    }
    model.state.inbox.totalProposals = 1000
    let window = FindingsView.makeWindow(model: model, notificationsExpanded: true)
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    window.contentView?.layoutSubtreeIfNeeded()
    guard let host = window.contentView, host.bounds.height <= 760,
      host.bounds.width <= 1100, !window.isVisible, !window.isKeyWindow
    else { throw StoreError.message("Large inbox expanded its window off-screen: \(window.frame)") }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw StoreError.message("Findings render unavailable")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let image = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:])
    else {
      throw StoreError.message("Findings image unavailable")
    }
    try png.write(to: URL(fileURLWithPath: output))
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([text])
    let visible = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
      separator: "\n")
    for control in [
      "Search findings", "Notify me about findings", "Notifications and workflow rules",
      "Worktrees", "Hunt now",
    ] {
      guard visible.localizedCaseInsensitiveContains(control) else {
        throw StoreError.message("Large inbox clips control: " + control + "; visible: " + visible)
      }
    }
    print(
      "PASS 1000-row native Findings window stays bounded with visible notification controls; no window shown or focused"
    )
  }
#endif
