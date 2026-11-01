import BurnCore
import Darwin
import Foundation

func diskRecoveryProof() async throws {
  let base = URL(fileURLWithPath: "/private/tmp/bz-disk-recovery-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  for phase in ["before-rename", "after-rename", "after-removal", "partial-return", "replacement"] {
    let root = base.appendingPathComponent(phase)
    let store = try Store(root: root)
    let source = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("must survive recovery".utf8).write(to: source.appendingPathComponent("result"))
    var identity = stat()
    guard lstat(source.path, &identity) == 0 else {
      throw StoreError.message("Fixture identity missing")
    }
    let manifest = try DiskInventory.manifest(source.path)
    let id = UUID()
    let values: [String: Any] = [
      "id": id.uuidString, "candidateID": "fixture-output", "path": source.path,
      "date": Date().timeIntervalSinceReferenceDate, "outcome": "prepared",
      "allocatedRemoved": manifest.bytes,
      "diskReclaimedBytes": 0, "rationale": "Interrupted sacrificial output operation",
      "sourceDevice": identity.st_dev,
      "sourceInode": UInt64(identity.st_ino), "sourceFingerprint": manifest.fingerprint,
    ]
    let receipt = try JSONDecoder().decode(
      DiskReceipt.self, from: JSONSerialization.data(withJSONObject: values))
    var catalog = Catalog()
    catalog.diskReceipts = [receipt]
    try store.save(catalog)
    let ledger = try IntentLedger(root: root)
    let proposal = try ledger.present(
      CleanupProposal(
        action: .disk, resources: ["fixture-output"], revision: "one",
        title: "Fixture output", detail: "Exact isolated recovery fixture",
        recovery: "Native restoration", ready: true, fixture: true))
    try ledger.decide(proposal.id, revision: proposal.revision, decision: "approve")
    try ledger.reserve(proposal, operationID: id.uuidString)
    let pending = root.appendingPathComponent("disk-pending-" + id.uuidString)
    if phase == "after-rename" || phase == "after-removal" {
      try FileManager.default.moveItem(at: source, to: pending)
    }
    if phase == "after-removal" { try FileManager.default.removeItem(at: pending) }
    if phase == "partial-return" {
      try FileManager.default.removeItem(at: source.appendingPathComponent("result"))
    }
    if phase == "replacement" {
      try FileManager.default.moveItem(
        at: source, to: root.appendingPathComponent("preserved-original"))
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      try Data("different".utf8).write(to: source.appendingPathComponent("result"))
    }
    let monitor = try Monitor(
      legacyAuthority: false, discoveryHome: nil, root: root, workspaceVisibility: { _ in 0 },
      accessCheck: fixtureAccess)
    let loaded = await monitor.snapshot()
    equal(
      loaded.catalog.diskReceipts?.first?.outcome, "unverified",
      "Restart failed to surface interrupted disk receipt")
    if phase == "partial-return" || phase == "replacement" {
      do {
        _ = try await monitor.reconcileDisk(id, restore: true)
        failTest("Conflicting recovery was accepted")
      } catch {}
      equal(try ledger.snapshot().operations.first?.outcome, "uncertain")
    } else {
      if phase == "after-rename" {
        do {
          _ = try await monitor.reconcileDisk(id, restore: false)
          failTest("Pending recovery silently moved")
        } catch {}
        check(FileManager.default.fileExists(atPath: pending.path))
      }
      _ = try await monitor.reconcileDisk(id, restore: phase == "after-rename")
      let reconciled = await monitor.snapshot()
      equal(
        reconciled.catalog.diskReceipts?.first?.outcome,
        phase == "after-removal" ? "reconciled" : "refused")
      equal(reconciled.catalog.lifetimeDiskReclaimedBytes ?? 0, 0)
      equal(reconciled.catalog.diskReceipts?.first?.diskReclaimedBytes, 0)
      if phase != "after-removal" {
        equal(
          try Data(contentsOf: source.appendingPathComponent("result")),
          Data("must survive recovery".utf8))
      }
      if phase == "after-rename" {
        throwsError(try ledger.veto(["fixture-output"]))
        throwsError(try IntentLedger(root: root).veto(["fixture-output"]))
        equal(try store.load().diskReceipts?.first?.restoreRequested, true)
        // The native restore marker recovers exact protection even if both the
        // intent transaction and its fallback file fail before a restart.
        var replay = reconciled.catalog.diskReceipts!.first!
        replay.id = UUID()
        replay.candidateID = "feedback-failure-output"
        var durable = try store.load()
        durable.diskReceipts?.append(replay)
        try store.save(durable)
        let intentDB = try WorktreeStore(root: root, databaseName: "intent.sqlite")
        try intentDB.put("corrupt fixture", kind: "proposal", id: "bad-feedback")
        let latch = root.appendingPathComponent("intent-suspended")
        try FileManager.default.createDirectory(at: latch, withIntermediateDirectories: false)
        try Data("obstruction".utf8).write(to: latch.appendingPathComponent("fixture"))
        check(DiskRecovery.recordRestoreFeedback(replay, ledger: ledger) != nil)
        var isDirectory: ObjCBool = false
        check(
          FileManager.default.fileExists(atPath: latch.path, isDirectory: &isDirectory)
            && isDirectory.boolValue)
        try FileManager.default.removeItem(at: latch)
        try intentDB.remove(kind: "proposal", id: "bad-feedback")
        let reopened = try IntentLedger(root: root)
        let nativeRequest = try store.load().diskReceipts!.last!
        isNil(DiskRecovery.recordRestoreFeedback(nativeRequest, ledger: reopened))
        throwsError(try reopened.veto(["feedback-failure-output"]))
      } else {
        try ledger.veto(["fixture-output"])
      }
    }
    await monitor.shutdownWorktrees()
  }
  print(
    "PASS disk crash before rename, after rename and after removal reconcile with zero credit; partial deletion and replacement identity stay blocked"
  )
}
