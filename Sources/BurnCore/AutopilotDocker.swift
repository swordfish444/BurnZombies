import Foundation

/// Stub so the failing proof compiles; replaced by the real thing.
public final class AutopilotDockerCache: @unchecked Sendable {
  public typealias Open =
    @Sendable () throws -> (engine: BuildKitCache, target: BuildKitCache.Target)
  public static let folder = "docker-build-cache"
  public static func isCache(_ item: AutopilotItem) -> Bool { item.facts["folder"] == folder }
  public init(open: @escaping Open, alive: @escaping @Sendable (String) -> Bool) {}
  public func look(now: Date = Date()) {}
  public func items(now: Date = Date()) -> [AutopilotItem] { [] }
  public func reclaim(
    _ item: AutopilotItem, authority: String, authorize: @escaping () -> Bool
  ) -> AutopilotReceipt {
    .refused(item, authority: authority, "Not yet.")
  }
}

extension BuildKitCache {
  public struct Retention: Codable, Equatable, Sendable {
    public var keepNewest: Int
    public var minimumAgeDays: Int
    public static let standard = Retention(keepNewest: 0, minimumAgeDays: 0)
  }
  public func inspect(target: Target, retention: Retention, now: Date = Date()) throws -> Inventory {
    throw StoreError.message("Not yet.")
  }
  public static func removalOrder(_ inventory: Inventory) -> [String] { [] }
}
