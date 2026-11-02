import CBurn
import Foundation

/// Where a worktree's commits are saved. Cached per HEAD; recomputed at retire time.
public struct AutopilotDelivery: Codable, Sendable, Equatable {
  public var head: String
  /// `merged`, `pushed`, `local` or `unknown`.
  public var saved: String
  public var checked: Date
  public init(head: String, saved: String, checked: Date = Date()) {
    self.head = head
    self.saved = saved
    self.checked = checked
  }
}

/// Old copies: facts from the worktree inventory plus Git delivery state, and a
/// restorable retirement that keeps every local change in a safety ref.
public enum AutopilotWorktrees {
  public static func items(
    _ records: [WorktreeRecord], threads: [AgentThread],
    delivery: inout [String: AutopilotDelivery], now: Date = Date(), budget: Int = 100
  ) -> [AutopilotItem] {
    []
  }
  public static func delivery(path: String) throws -> AutopilotDelivery {
    throw StoreError.message("Not implemented.")
  }
  public static func retire(
    _ item: AutopilotItem, authority: String, root: URL,
    inUse: (String) -> Int32 = { bz_path_in_use($0) }
  ) -> AutopilotReceipt {
    .refused(item, authority: authority, "Not implemented.")
  }
  public static func restore(_ receipt: AutopilotReceipt) throws {
    throw StoreError.message("Not implemented.")
  }
}
