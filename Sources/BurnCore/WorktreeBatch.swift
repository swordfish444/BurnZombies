import Foundation

extension WorktreeService {
  func batchPreview(_ q: WorktreeRequest, caller: String) async throws -> WorktreeReply {
    guard let ids = q.ids, !ids.isEmpty, ids.count <= 50, Set(ids).count == ids.count,
      let revisions = q.revisions, Set(ids) == Set(revisions.keys), batches.count < 16
    else { throw StoreError.message("Review 1–50 exact unique IDs with their current revisions.") }
    var reply = try snapshot()
    var prepared: [WorktreePlan] = []
    for id in ids {
      do {
        let p = try await preview(
          .init("preview", id: id, revision: revisions[id]), caller: caller, dirty: false,
          automatic: false, interactive: true)
        prepared.append(p)
        reply.batch.append(
          .init(
            id: id, path: p.identity.path,
            detail: "Ready: clean retirement with independent recovery.", ready: true))
      } catch {
        reply.batch.append(
          .init(
            id: id, path: (try? record(id).path) ?? "Unknown", detail: error.localizedDescription,
            ready: false))
      }
    }
    // Issue the batch after all inspections; each original revision is still
    // checked at execution. The token lifetime covers review, not backup duration.
    let issued = Date()
    prepared = prepared.map {
      var p = $0
      p.created = issued
      plans[p.token] = p
      return p
    }
    let token = UUID().uuidString
    batches[token] = (caller, prepared)
    reply.token = token
    reply.detail =
      "Review exact targets. Only ready items can execute; changed items will be skipped."
    return reply
  }
  func batchRetire(_ q: WorktreeRequest, caller: String) async throws -> WorktreeReply {
    guard let token = q.token, let batch = batches.removeValue(forKey: token), batch.0 == caller,
      batch.1.allSatisfy({ (0...60).contains(Date().timeIntervalSince($0.created)) })
    else {
      throw StoreError.message(
        "Exact caller-bound one-use batch preview required within 60 seconds.")
    }
    var results: [WorktreeBatchItem] = []
    for p in batch.1 {
      // The whole batch was consumed on time. Revalidate the originally approved
      // identity, content, claims and policy for every item as it reaches the head.
      if var queued = plans[p.token] {
        queued.created = Date()
        plans[p.token] = queued
      }
      do {
        _ = try await retire(p.token, caller: caller, dirty: false)
        results.append(
          .init(
            id: p.worktreeID, path: p.identity.path, detail: "Retirement verified.", ready: true))
      } catch {
        results.append(
          .init(
            id: p.worktreeID, path: p.identity.path,
            detail: "Skipped: " + error.localizedDescription, ready: false))
      }
    }
    try store.put(results, kind: "batch", id: token)
    var reply = try snapshot()
    reply.batch = results
    reply.detail =
      "\(results.filter(\.ready).count) retirements verified; \(results.filter { !$0.ready }.count) skipped. No skipped item was forced."
    return reply
  }
}
