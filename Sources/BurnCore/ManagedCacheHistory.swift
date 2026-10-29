import Foundation

public extension ManagedCacheAttempt {
  static func blockedIDs(_ attempts: [Self], inventory: BuildKitCache.Inventory, now: Date = Date()) -> Set<String> {
    var blocked = Set<String>()
    for attempt in attempts where attempt.plan.inventory.owner.daemonID == inventory.owner.daemonID {
      if ["prepared", "uncertain"].contains(attempt.outcome) {
        blocked.formUnion(attempt.plan.recordIDs)
      } else {
        blocked.formUnion(attempt.receipt?.removedIDs ?? [])
        for id in attempt.plan.recordIDs where !(attempt.receipt?.removedIDs.contains(id) ?? false) {
          let old = attempt.plan.inventory.records.first { $0.id == id }
          let current = inventory.records.first { $0.id == id }
          // A verified refusal/no-change is not a permanent blacklist. Require
          // changed exact resource facts and the normal hourly cadence first.
          if now.timeIntervalSince(attempt.date) < 3600 || old == current { blocked.insert(id) }
        }
      }
    }
    return blocked
  }
}
