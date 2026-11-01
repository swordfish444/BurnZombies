import CBurn
import Darwin
import Foundation

public enum DiskRecovery {
  @discardableResult public static func recordRestoreFeedback(
    _ receipt: DiskReceipt, ledger: IntentLedger
  ) -> String? {
    guard receipt.restoreRequested == true else { return nil }
    let fallback = CleanupProposal(
      action: .disk, resources: [receipt.candidateID],
      revision: receipt.sourceFingerprint ?? receipt.id.uuidString,
      title: URL(fileURLWithPath: receipt.path).lastPathComponent,
      detail: "Restoration requested for this exact output.", path: receipt.path,
      recovery: "Inspect its native recovery receipt.", ready: false,
      fixture: receipt.fixture == true)
    return ledger.recordRecovery(
      operationID: receipt.id.uuidString, fallback: fallback,
      attemptID: receipt.id.uuidString + ":disk-restore")
  }
  /// Reconcile only recorded identities and full manifests. A partial deletion
  /// renamed back to the original directory is not an intact original.
  public static func reconcile(
    _ receipt: DiskReceipt, root: URL, restore: Bool,
    visibility: @Sendable (String) -> Int32 = { bz_path_in_use($0) }
  ) throws -> DiskReceipt {
    guard ["prepared", "unverified"].contains(receipt.outcome),
      let device = receipt.sourceDevice, let inode = receipt.sourceInode,
      let fingerprint = receipt.sourceFingerprint, !fingerprint.isEmpty,
      WorkspaceSafety.canonical(root.path) == root.path,
      WorkspaceSafety.canonical(receipt.path) == receipt.path
    else {
      throw StoreError.message(
        "Original identity or manifest unavailable. Preserve both locations and resolve manually.")
    }
    let pending = root.appendingPathComponent("disk-pending-" + receipt.id.uuidString).path
    func metadata(_ path: String) throws -> stat? {
      var value = stat()
      if lstat(path, &value) == 0 { return value }
      guard errno == ENOENT else {
        throw StoreError.message("Recovery path visibility is incomplete.")
      }
      return nil
    }
    func intact(_ path: String, _ value: stat) throws {
      guard value.st_dev == device, UInt64(value.st_ino) == inode,
        value.st_mode & S_IFMT == S_IFDIR,
        value.st_uid == getuid()
      else { throw StoreError.message("Recovery directory identity changed; preserved.") }
      let manifest = try DiskInventory.manifest(path)
      guard manifest.complete, !manifest.unsafe, manifest.fingerprint == fingerprint else {
        throw StoreError.message(
          "Recovery contents changed or are incomplete. Preserve the remaining data; no intact recovery can be claimed."
        )
      }
    }
    let source = try metadata(receipt.path)
    let moved = try metadata(pending)
    guard source == nil || moved == nil else {
      throw StoreError.message(
        "Both locations contain data; preserve them and resolve ownership manually.")
    }
    var result = receipt
    if let source {
      try intact(receipt.path, source)
      result.outcome = "refused"
      result.rationale =
        "Original directory and full recorded contents are intact; pending location absent. No cleanup or recovery credit. A new decision is required."
    } else if let moved {
      try intact(pending, moved)
      guard restore else {
        throw StoreError.message(
          "Intact pending output is preserved at \(pending). Choose Restore intact pending output to return it without overwriting anything."
        )
      }
      let parent = URL(fileURLWithPath: receipt.path).deletingLastPathComponent().path
      guard let parentMetadata = try metadata(parent), parentMetadata.st_mode & S_IFMT == S_IFDIR,
        visibility(pending) == 0, try metadata(receipt.path) == nil
      else {
        throw StoreError.message(
          "Destination or pending consumer visibility changed; recovery preserved.")
      }
      guard renamex_np(pending, receipt.path, UInt32(RENAME_EXCL)) == 0 else {
        throw StoreError.message(
          "Could not restore without replacing the destination; pending data preserved.")
      }
      guard let returned = try metadata(receipt.path), try metadata(pending) == nil else {
        throw StoreError.message("Restoration remains uncertain; preserve both paths.")
      }
      try intact(receipt.path, returned)
      result.outcome = "refused"
      result.rationale =
        "Exact pending directory restored and its full original contents verified. No cleanup credit. A new decision is required."
    } else {
      let parent = URL(fileURLWithPath: receipt.path).deletingLastPathComponent().path
      guard let value = try metadata(parent), value.st_mode & S_IFMT == S_IFDIR else {
        throw StoreError.message("Original parent is unavailable; absence cannot be reconciled.")
      }
      result.outcome = "reconciled"
      result.rationale =
        "Both recorded locations are absent; removal attribution is unknown. Reservation reconciled without cleanup or disk credit."
    }
    result.diskReclaimedBytes = 0
    result.allocatedRemoved = 0
    return result
  }
}
