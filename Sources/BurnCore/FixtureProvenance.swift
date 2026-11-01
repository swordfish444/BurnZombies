import Foundation

/// Explicit acceptance-test provenance, never inferred from a name/path/age.
/// The private proof controller records exact native identities before action.
/// This changes accounting only; it never relaxes an executor predicate.
public struct FixtureProvenance: Codable, Sendable {
  public var version = 1
  public var resources: Set<String> = []
  public var operations: Set<String> = []
  public init() {}
  public static func load(root: URL) throws -> Self {
    let url = root.appendingPathComponent("fixture-provenance.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
    let value = try JSONDecoder().decode(
      Self.self, from: Store(root: root).read(url, limit: 1_048_576))
    guard value.version == 1, value.resources.count + value.operations.count <= 10000 else {
      throw StoreError.message(
        "Fixture provenance is unsupported or exceeds its bounds; accounting is unknown.")
    }
    return value
  }
  public func save(root: URL) throws {
    guard version == 1, resources.count + operations.count <= 10000,
      resources.allSatisfy({ !$0.isEmpty && $0.count <= 300 }),
      operations.allSatisfy({ UUID(uuidString: $0) != nil })
    else {
      throw StoreError.message("Exact bounded native fixture identities required.")
    }
    try Store(root: root).write(
      JSONEncoder().encode(self), to: root.appendingPathComponent("fixture-provenance.json"),
      limit: 1_048_576)
  }
  public func matches(_ ids: [String]) -> Bool {
    !ids.isEmpty && ids.allSatisfy(resources.contains)
  }
  /// Correct only receipts with explicit matching proof identities, once. Keep
  /// the original native receipts and recovery material; never reset all history.
  public func classify(_ catalog: inout Catalog) -> Bool {
    var changed = false
    for i in catalog.events.indices where catalog.events[i].fixture != true {
      let e = catalog.events[i]
      guard
        operations.contains(where: { $0.lowercased() == e.id.uuidString.lowercased() })
          || matches(e.targets.map { $0.identity.key })
      else { continue }
      catalog.events[i].fixture = true
      changed = true
      if e.outcome == "verified" {
        catalog.lifetimeVerified = max(0, catalog.lifetimeVerified - e.verifiedCount)
        catalog.lifetimeActions = max(0, catalog.lifetimeActions - 1)
        if let value = catalog.lifetimeResidentReleased {
          catalog.lifetimeResidentReleased = value - min(value, e.residentBefore)
        }
        if let value = catalog.lifetimeCPUSecondsSaved {
          catalog.lifetimeCPUSecondsSaved = max(0, value - (e.cpuSecondsSavedEstimate ?? 0))
        }
      }
    }
    for i in catalog.diskReceipts?.indices ?? 0..<0 where catalog.diskReceipts?[i].fixture != true {
      guard let r = catalog.diskReceipts?[i],
        operations.contains(where: { $0.lowercased() == r.id.uuidString.lowercased() })
          || matches([r.candidateID])
      else { continue }
      catalog.diskReceipts?[i].fixture = true
      changed = true
      if r.outcome == "verified", let value = catalog.lifetimeDiskReclaimedBytes {
        catalog.lifetimeDiskReclaimedBytes = value - min(value, r.diskReclaimedBytes)
      }
    }
    for i in catalog.workspaceReceipts?.indices ?? 0..<0
    where catalog.workspaceReceipts?[i].fixture != true {
      guard let r = catalog.workspaceReceipts?[i],
        operations.contains(where: { $0.lowercased() == r.id.uuidString.lowercased() })
          || matches(["worktree:" + r.workspaceID])
      else { continue }
      catalog.workspaceReceipts?[i].fixture = true
      changed = true
      if r.outcome == "verified" {
        if let value = catalog.lifetimeWorktreesCleaned {
          catalog.lifetimeWorktreesCleaned = max(0, value - 1)
        }
        if let value = catalog.lifetimeDiskReclaimedBytes {
          catalog.lifetimeDiskReclaimedBytes = value - min(value, r.diskReclaimedBytes)
        }
      }
    }
    for i in catalog.managedCacheAttempts?.indices ?? 0..<0
    where catalog.managedCacheAttempts?[i].fixture != true {
      guard let a = catalog.managedCacheAttempts?[i],
        operations.contains(where: { $0.lowercased() == a.plan.id.uuidString.lowercased() })
          || matches(CleanupProposal.cache(a.plan).resources)
      else { continue }
      catalog.managedCacheAttempts?[i].fixture = true
      changed = true
    }
    return changed
  }
}
