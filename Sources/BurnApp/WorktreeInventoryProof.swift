#if DEBUG
  import BurnCore
  import Foundation

  @MainActor private final class InventoryPageGate {
    var waiting = false
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
      if released { return }
      waiting = true
      await withCheckedContinuation { continuation = $0 }
    }
    func release() {
      released = true
      continuation?.resume()
      continuation = nil
    }
  }

  @MainActor func worktreeInventoryProof() async throws {
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw StoreError.message(message) }
    }
    var initial = WorktreeReply()
    initial.records = (0..<205).map {
      var row = WorktreeRecord(id: "row-\($0)", path: "/example/\($0)", repository: "/example/.git")
      row.revision = "before"
      return row
    }
    initial.totalRecords = 205
    let model = WorktreeInventory(initial: initial)
    try check(model.needsRefresh(initial, observedAt: nil), "First snapshot did not refresh")
    try check(
      !model.needsRefresh(initial, observedAt: nil), "Unchanged status requested another reload")
    try check(
      model.needsRefresh(initial, observedAt: Date(timeIntervalSince1970: 1)),
      "New observation did not refresh evidence outside the first page")
    let gate = InventoryPageGate()
    var passes = 0
    let request: (WorktreeRequest) async throws -> WorktreeReply = { q in
      let offset = q.offset ?? 0
      if offset == 0 { passes += 1 }
      if offset == 100 && passes == 1 { await gate.wait() }
      var page = initial
      page.records = Array(initial.records[offset..<min(offset + 100, 205)]).map {
        var row = $0
        row.revision = "pass-\(passes)"
        return row
      }
      page.nextOffset = offset + 100 < 205 ? offset + 100 : nil
      return page
    }
    let first = Task { await model.load(request) }
    defer {
      gate.release()
      first.cancel()
    }
    for _ in 0..<100 where !gate.waiting { try await Task.sleep(for: .milliseconds(5)) }
    try check(gate.waiting, "Page-2 request never reached the test gate")
    try check(
      model.value.records.count == 205 && model.value.records.last?.revision == "before",
      "Reload replaced the complete inventory with an incomplete first page")
    var blocked = false
    do { _ = try model.chosen(["row-204"]) } catch { blocked = true }
    try check(blocked, "Batch review was allowed while inventory was reloading")
    await model.load(request)
    gate.release()
    await first.value
    try check(passes == 2, "Refresh requested during pagination was dropped")
    try check(
      model.value.records.count == 205 && Set(model.value.records.map(\.id)).count == 205,
      "Queued refresh mixed or omitted inventory pages")
    try check(
      model.value.records.allSatisfy { $0.revision == "pass-2" },
      "Superseded pagination published stale rows")
    try check(
      try model.chosen(["row-204"]).map(\.id) == ["row-204"],
      "Selection beyond page one disappeared after reload")
    blocked = false
    do { _ = try model.chosen(["row-204", "missing"]) } catch { blocked = true }
    try check(blocked, "Batch preview silently omitted a selected identity")
    await model.load { q in
      if q.offset != nil { throw StoreError.message("Synthetic unavailable page") }
      return try await request(q)
    }
    try check(
      !model.loading && model.error != nil && model.value.records.count == 205,
      "Failed pagination discarded the prior complete inventory")
    var duplicate = initial
    duplicate.records = [initial.records[0], initial.records[0]]
    let invalid = WorktreeInventory(initial: duplicate)
    blocked = false
    do { _ = try invalid.chosen(["row-0", "row-1"]) } catch { blocked = true }
    try check(blocked, "Duplicate selected rows replaced a missing identity")
    let previous = model.value.records.map(\.id)
    await model.load { q in
      var page = try await request(q)
      if q.offset == 100 { page.records[0] = initial.records[99] }
      return page
    }
    try check(
      model.error != nil && model.value.records.map(\.id) == previous,
      "Live pagination published duplicate worktree identities")
    await model.load { q in
      var page = try await request(q)
      if q.offset != nil { page.totalRecords = 204 }
      return page
    }
    try check(
      model.error != nil && model.value.records.map(\.id) == previous,
      "Live pagination published a shifted inventory count")
    await model.load { q in
      var page = try await request(q)
      if q.offset == 200 { page.records.removeLast() }
      return page
    }
    try check(
      model.error != nil && model.value.records.map(\.id) == previous,
      "Incomplete pagination replaced a complete inventory")
    let scanGate = InventoryPageGate()
    var scanPasses = 0
    let scanRequest: (WorktreeRequest) async throws -> WorktreeReply = { q in
      if q.offset == nil { scanPasses += 1 }
      if q.offset == 100 && scanPasses == 1 { await scanGate.wait() }
      var page = try await request(q)
      page.records = page.records.map {
        var row = $0
        row.revision = "scan-\(scanPasses)"
        return row
      }
      return page
    }
    let polling = Task { await model.load(scanRequest) }
    defer {
      scanGate.release()
      polling.cancel()
    }
    for _ in 0..<100 where !scanGate.waiting { try await Task.sleep(for: .milliseconds(5)) }
    try check(scanGate.waiting, "Scan poller did not reach the held page")
    let completion = Task { await model.load(stopping: polling, request: scanRequest) }
    await Task.yield()
    scanGate.release()
    await completion.value
    try check(
      !model.loading && scanPasses == 2 && model.value.records.count == 205
        && model.value.records.allSatisfy { $0.revision == "scan-2" },
      "Cancelling the scan poller lost the final inventory reload")
    print(
      "PASS atomic 205-row pagination, queued reload, selection beyond page one, failed-page preservation, final refresh after scan-poller cancellation, and rejection of duplicate/incomplete pages"
    )
  }
#endif
