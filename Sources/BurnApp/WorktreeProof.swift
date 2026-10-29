import AppKit
import BurnCore
import SwiftUI
import Vision

enum WorktreeExamples {
  static func snapshot() -> WorktreeReply {
    var reply = WorktreeReply()
    var ready = WorktreeRecord(
      id: "example-ready", path: "/example/atlas/release-docs", repository: "/example/atlas/.git")
    ready.branch = "refs/heads/codex/release-docs"
    ready.revision = "example-revision"
    ready.consumer = "none observed"
    ready.managed = true
    ready.confirmedRevision = ready.revision
    ready.allocated = 428_000_000
    var dirty = WorktreeRecord(
      id: "example-dirty", path: "/example/atlas/local-experiment", repository: ready.repository)
    dirty.branch = "refs/heads/codex/local-experiment"
    dirty.consumer = "none observed"
    dirty.managed = true
    dirty.changes = 3
    dirty.ignored = 2
    dirty.allocated = 1_640_000_000
    var active = WorktreeRecord(
      id: "example-active", path: "/example/atlas/current-integration", repository: ready.repository
    )
    active.branch = "refs/heads/codex/integration"
    active.consumer = "in use"
    active.kept = true
    active.allocated = 810_000_000
    var blocked = WorktreeRecord(
      id: "example-blocked", path: "/example/atlas/external-volume", repository: ready.repository)
    blocked.gaps = ["Registered directory is missing or its volume is unavailable."]
    blocked.missing = true
    reply.records = [ready, dirty, active, blocked]
    var op = WorktreeOperation(
      id: "example-recovery", worktreeID: ready.id, originalPath: ready.path,
      repository: ready.repository, head: String(repeating: "a", count: 40), phase: "completed",
      kind: "clean", date: Date(),
      recoveryPath: "/example/private-recovery",
      detail: "Example: encrypted independent recovery verified before retirement.",
      allocated: ready.allocated)
    op.archiveDigest = "example-integrity"
    op.archiveBytes = 34_000_000
    op.diskCredit = 390_000_000
    op.completedAt = Date()
    reply.operations = [op]
    reply.detail = "Preview with synthetic fixtures. No files are changed."
    return reply
  }
}

#if DEBUG
  @MainActor func worktreeViewProof(output: String) throws {
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, tab, selected) in [
      ("inventory", "Worktrees", "example-ready"), ("local-work", "Worktrees", "example-dirty"),
      ("recovery", "Recovery", "example-ready"), ("blocked", "Worktrees", "example-blocked"),
    ] {
      let model = AppModel(demo: true)
      let host = NSHostingView(
        rootView: WorktreesView(
          model: model, initial: WorktreeExamples.snapshot(), initialTab: tab, selectedID: selected)
      )
      host.frame = NSRect(x: 0, y: 0, width: 1120, height: 760)
      let window = NSWindow(
        contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.contentView = host
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      guard !window.isVisible, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
      else { throw StoreError.message("Offscreen native view rendering unavailable.") }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]), let cg = bitmap.cgImage
      else { throw StoreError.message("Worktree screenshot unavailable.") }
      try png.write(to: directory.appendingPathComponent(name + ".png"))
      let text = VNRecognizeTextRequest()
      text.recognitionLevel = .accurate
      try VNImageRequestHandler(cgImage: cg, options: [:]).perform([text])
      let visible = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n")
      try visible.write(
        to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
      guard visible.contains("Worktrees"), visible.contains("Recovery"),
        tab == "Recovery" ? visible.contains("Restore to new folder") : visible.contains("Observed")
      else { throw StoreError.message("Worktree view is clipped or missing controls: " + name) }
    }
    print(
      "PASS four native worktree/recovery fixture views rendered and OCR checked without presenting a window"
    )
  }
#endif
