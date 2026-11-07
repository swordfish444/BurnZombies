import Foundation

/// What the Burn Log says about a program, by how its burn ended. Monitor saves these, and the log
/// reads them from here, so a row saved in older words reads the same as a new one.
public enum BurnWords {
  public static let lostTrack =
    "BZ lost track while checking, maybe after a restart or sleep. This one doesn't count."
  public static let keptRunning =
    "Something kept running after BZ asked it to stop. BZ didn't force it. This one doesn't count."
  public static let cameBack =
    "A new one started right after, so this one doesn't count. Something may keep starting it."
  public static func stopped(_ count: Int = 1) -> String {
    "Stopped. BZ checked for 2 minutes and \(count > 1 ? "they" : "it") stayed gone. "
      + "The memory number may read a little high, since programs can share memory."
  }
  /// Nil for an outcome nobody planned for: the row then says what it was saved with.
  public static func program(_ outcome: String, count: Int = 1) -> String? {
    switch outcome {
    case "verified": return stopped(count)
    case "verifying": return "BZ asked it to stop and is checking."
    case "prepared": return "BZ is checking before it stops this."
    case "unverified": return lostTrack
    case "partial": return keptRunning
    case "reappeared": return cameBack
    case "refused": return "BZ didn't stop it, so this one doesn't count."
    default: return nil
    }
  }
  /// A row's result when it didn't end in a burn.
  static func status(_ outcome: String) -> String {
    switch outcome {
    case "verifying", "prepared": return "Checking"
    case "unverified", "uncertain": return "Not sure"
    case "partial": return "Still running"
    case "reappeared": return "Came back"
    case "refused": return "Left alone"
    case "reconciled": return "Not found"
    default: return outcome.capitalized
    }
  }
}

/// One line of the Burn Log, whichever way the burn was made.
public enum BurnLogRow: Identifiable, Sendable {
  case helpers(CleanupEvent)
  case worktree(WorkspaceReceipt)
  case output(DiskReceipt)
  /// What Autopilot burned: an old copy or junk folder, or a program the catalog has let go of.
  case autopilot(AutopilotReceipt)

  /// The three things BZ burns, as the log's key names them.
  public enum Kind: String, CaseIterable, Sendable {
    case program = "Program"
    case copy = "Old copy"
    case folder = "Junk folder"
  }
  public var kind: Kind {
    switch self {
    case .helpers: return .program
    case .worktree: return .copy
    case .output: return .folder
    case .autopilot(let receipt):
      switch receipt.kind {
      case .process: return .program
      case .worktree: return .copy
      case .disk: return .folder
      }
    }
  }
  public var id: UUID {
    switch self {
    case .helpers(let event): return event.id
    case .worktree(let receipt): return receipt.id
    case .output(let receipt): return receipt.id
    case .autopilot(let receipt): return receipt.id
    }
  }
  public var date: Date {
    switch self {
    case .helpers(let event): return event.date
    case .worktree(let receipt): return receipt.date
    case .output(let receipt): return receipt.date
    case .autopilot(let receipt): return receipt.date
    }
  }
  /// When a burn that counts finished. Nil while it's being checked, when it didn't work, when it
  /// came back, and for a test.
  public var finishedAt: Date? {
    switch self {
    case .helpers(let event):
      guard event.outcome == "verified", event.fixture != true else { return nil }
      return event.verificationDate ?? event.date
    case .worktree(let receipt):
      guard receipt.outcome == "verified", receipt.fixture != true else { return nil }
      return receipt.verifiedAt ?? receipt.date
    case .output(let receipt):
      guard receipt.outcome == "verified", receipt.fixture != true else { return nil }
      return receipt.date
    case .autopilot(let receipt):
      return receipt.outcome == "burned" ? receipt.date : nil
    }
  }
  /// What the row is called.
  public var title: String {
    let test = "Test · doesn't count"
    switch self {
    case .helpers(let event): return event.fixture == true ? test : event.label
    case .worktree(let receipt):
      return receipt.fixture == true ? test : Self.folderName(receipt.identity.path)
    case .output(let receipt):
      return receipt.fixture == true ? test : Self.folderName(receipt.path)
    case .autopilot(let receipt): return receipt.name
    }
  }
  /// What came of it, on the right of the row.
  public var result: String {
    switch self {
    case .helpers(let event):
      guard event.outcome == "verified" else { return BurnWords.status(event.outcome) }
      var parts = [String]()
      if event.verifiedCount > 1 { parts.append("\(event.verifiedCount) programs") }
      if event.residentBefore > 0 {
        parts.append(ImpactNumbers.bytes(event.residentBefore) + " memory")
      }
      return parts.isEmpty ? "Burned" : parts.joined(separator: " · ")
    case .worktree(let receipt):
      guard receipt.outcome == "verified" else { return BurnWords.status(receipt.outcome) }
      return Self.freed(receipt.diskReclaimedBytes, "disk")
    case .output(let receipt):
      guard receipt.outcome == "verified" else { return BurnWords.status(receipt.outcome) }
      return Self.freed(receipt.diskReclaimedBytes, "disk")
    case .autopilot(let receipt):
      guard receipt.outcome == "burned" else { return BurnWords.status(receipt.outcome) }
      return Self.freed(receipt.bytes, receipt.kind == .process ? "memory" : "disk")
    }
  }
  /// What an opened row says.
  public var words: String {
    switch self {
    case .helpers(let event):
      return BurnWords.program(event.outcome, count: event.targets.count) ?? event.detail
    case .worktree(let receipt):
      switch receipt.outcome {
      case "verified": return "Removed. Its commits are saved, so you can get them back."
      case "prepared", "unverified":
        return "BZ got cut off partway. Its commits are still saved. This one doesn't count."
      default: return receipt.detail
      }
    case .output(let receipt): return Self.words(receipt) + "\n" + receipt.path
    case .autopilot(let receipt):
      if receipt.kind == .process, receipt.outcome == "burned" { return BurnWords.stopped() }
      var words = receipt.detail
        .replacingOccurrences(
          of: "Unique contents are encrypted and restorable.", with: AutopilotDisk.backedUpWords
        )
        .replacingOccurrences(
          of: "so you can restore it.", with: "so you can restore it in Findings.")
      if let path = receipt.restore?.path, !path.isEmpty, !words.contains(path) {
        words += "\n" + path
      }
      return words
    }
  }

  private static func freed(_ bytes: UInt64, _ place: String) -> String {
    bytes > 0 ? ImpactNumbers.bytes(bytes) + " " + place : "Burned"
  }
  private static func folderName(_ path: String) -> String {
    (path as NSString).lastPathComponent
  }
  /// The old cleaner's rows. It saved why it burned a folder, and where the folder waits if the burn
  /// was cut off, so those stay. Everything else about a row follows from how it ended.
  private static func words(_ receipt: DiskReceipt) -> String {
    let recovery = " Recovery location if interrupted: "
    let saved = receipt.rationale.components(separatedBy: recovery)
    switch receipt.outcome {
    case "verified": return saved[0]
    case "prepared", "unverified":
      let waiting = saved.count > 1 ? saved[1].components(separatedBy: " Interrupted cleanup:")[0] : ""
      return "BZ got cut off partway"
        + (waiting.isEmpty ? "" : " and it's waiting at " + waiting)
        + ". Check it, or put it back."
    case "refused": return "Nothing was removed, so this one doesn't count."
    case "reconciled":
      return "BZ can't find it in either place, so it can't say what happened. This one doesn't count."
    default: return receipt.rationale
    }
  }
}

extension Catalog {
  /// The Burn Log, newest first: every burn in the last 30 days, once. The stored lists aren't in
  /// date order: `prune` moves what's still being checked to the front of its list. A program is
  /// also in Autopilot's receipts, and the catalog knows more about it, so it shows from here.
  public func burnLog(autopilot: [AutopilotReceipt] = [], now: Date = Date()) -> [BurnLogRow] {
    var rows: [BurnLogRow] = events.map { .helpers($0) }
    rows += (workspaceReceipts ?? []).map { .worktree($0) }
    rows += (diskReceipts ?? []).map { .output($0) }
    let listed = Set(events.map(\.id))
    let oldest = now.addingTimeInterval(-30 * 86400)
    for receipt in autopilot
    where ["burned", "restored"].contains(receipt.outcome) && receipt.date > oldest
      && !(receipt.eventID.map(listed.contains) ?? false)
    {
      rows.append(.autopilot(receipt))
    }
    return rows.sorted { $0.date > $1.date }
  }
}
