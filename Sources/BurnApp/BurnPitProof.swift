#if DEBUG
  import AppKit
  import BurnCore
  import Vision

  @MainActor func burnPitProof(output: String) throws {
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .darkAqua)

    var snapshot = BlazerMap.demoSnapshot()
    snapshot.rows.append(.init(
      id: "nested-cache", kind: .cache, name: "Nested cache",
      path: "~/.codex/worktrees/ios-v2-release/build", state: "Inventoried",
      detail: "", source: "Demo fixture", diskBytes: 1_000_000_000))
    let inventory = BurnPitInventory(rows: snapshot.rows, layer: .all, search: "")
    guard inventory.overlapping == 1, inventory.matches.contains(where: { $0.id == "nested-cache" }),
      !inventory.slabs.contains(where: { $0.id == "nested-cache" || $0.kind == .zombie || $0.kind == .folder })
    else { throw StoreError.message("Burn Pit mixed measures or lost an overlapping finding.") }

    let frame = CGRect(x: 0, y: 0, width: 620, height: 340)
    let slabs = BurnPitSlab.layout(inventory.slabs, in: frame)
    let totalBytes = inventory.slabs.reduce(0.0) { $0 + Double($1.diskBytes ?? 0) }
    let expectedArea = frame.width * frame.height
    guard slabs.count == inventory.slabs.count,
      slabs.allSatisfy({ slab in
        let area = slab.frame.width * slab.frame.height
        let weight = Double(slab.row.diskBytes ?? 0) / totalBytes
        return abs(area / expectedArea - weight) < 0.0001
      })
    else { throw StoreError.message("Burn Pit slab area does not match measured disk bytes.") }

    let zombies = BurnPitInventory(rows: snapshot.rows, layer: .zombie, search: "gradle")
    guard zombies.slabs.isEmpty, zombies.matches.count == 1, zombies.matches.first?.memoryBytes != nil
    else { throw StoreError.message("Burn Pit lost a searchable RAM observation.") }

    let window = BurnPitWindow.makeWindow(model: BurnPitModel(snapshot: snapshot))
    defer { window.close() }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, size) in [("furnace", NSSize(width: 1040, height: 680)),
                         ("compact", BurnPitWindow.minimumSize)] {
      window.setContentSize(size)
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      window.contentView?.layoutSubtreeIfNeeded()
      guard let host = window.contentView, host.bounds.width <= size.width + 1,
        host.bounds.height <= size.height + 1, !window.isVisible, !window.isKeyWindow,
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
      else { throw StoreError.message("Burn Pit proof window exceeded its viewport or took focus.") }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let image = bitmap.cgImage, let png = bitmap.representation(using: .png, properties: [:])
      else { throw StoreError.message("Burn Pit image unavailable.") }
      try png.write(to: directory.appendingPathComponent(name + ".png"))
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
      for label in ["Burn Pit", "Evidence Ledger", "25.2 GB", "Selected evidence", "Snapshot coverage"] {
        guard visible.localizedCaseInsensitiveContains(label) else {
          throw StoreError.message("Burn Pit \(name) is missing \(label): \(visible)")
        }
      }
    }
    print("PASS Burn Pit measures, search and layout at default and minimum size without opening a window")
  }
#endif
