import CBurn
import Foundation

/// Junk folders: rebuildable output inside projects and old copies, and global developer
/// caches. Only known rebuildable kinds are ever removed autonomously.
public enum AutopilotDisk {
  /// Folder name → `folder` fact.
  public static let rebuildable: [String: String] = [:]
  public static func items(
    worktrees: [WorktreeRecord], home: String = NSHomeDirectory(), now: Date = Date(),
    sizer: (String) -> UInt64? = { _ in nil }
  ) -> [AutopilotItem] {
    []
  }
  public static func reclaim(
    _ item: AutopilotItem, authority: String, inUse: (String) -> Int32 = { bz_path_in_use($0) }
  ) -> AutopilotReceipt {
    .refused(item, authority: authority, "Not implemented.")
  }
}
