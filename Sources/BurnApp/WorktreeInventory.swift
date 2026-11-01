import BurnCore
import Foundation
import SwiftUI

/// Publish one complete inventory so selection and detail never see a partial page.
@MainActor final class WorktreeInventory: ObservableObject {
  @Published private(set) var value: WorktreeReply
  @Published private(set) var loading = false
  private(set) var error: String?
  private var generation: UInt64 = 0
  private var lastSnapshot: Data?
  private var lastObservation: Date?
  init(initial: WorktreeReply) { value = initial }

  func needsRefresh(_ snapshot: WorktreeReply, observedAt: Date?) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try? encoder.encode(snapshot)
    guard encoded == nil || encoded != lastSnapshot || observedAt != lastObservation else {
      return false
    }
    lastSnapshot = encoded
    lastObservation = observedAt
    return true
  }

  func chosen(_ selected: Set<String>) throws -> [WorktreeRecord] {
    guard !loading else {
      throw StoreError.message("Wait for the worktree inventory to finish loading.")
    }
    let rows = value.records.filter { selected.contains($0.id) }
    guard rows.count == selected.count, Set(rows.map(\.id)) == selected else {
      throw StoreError.message(
        "Some selected worktrees are no longer available. Review the selection again.")
    }
    return rows
  }

  // A scan's poller can own the active page load. Drain it before the final
  // reload so its cancellation cannot discard the action's queued refresh.
  func load(
    stopping poller: Task<Void, Never>, request: (WorktreeRequest) async throws -> WorktreeReply
  ) async {
    poller.cancel()
    await poller.value
    await load(request)
  }

  func load(_ request: (WorktreeRequest) async throws -> WorktreeReply) async {
    generation &+= 1
    if loading { return }  // The active loader will service this newer generation.
    loading = true
    defer { loading = false }
    repeat {
      let current = generation
      do {
        var next = try await request(.init("list"))
        while let offset = next.nextOffset, current == generation {
          try Task.checkCancellation()
          let page = try await request(.init("list", offset: offset))
          guard page.totalRecords == next.totalRecords else {
            throw StoreError.message(
              "Worktree discovery changed during loading. Refresh the inventory again.")
          }
          next.records += page.records
          next.owners += page.owners
          next.advice += page.advice
          next.delivery += page.delivery
          next.nextOffset = page.nextOffset
        }
        while let offset = next.nextOperationOffset, current == generation {
          try Task.checkCancellation()
          let page = try await request(.init("operations", offset: offset))
          next.operations += page.operations
          next.nextOperationOffset = page.nextOperationOffset
        }
        try Task.checkCancellation()
        if current == generation {
          guard Set(next.records.map(\.id)).count == next.records.count,
            next.records.count == (next.totalRecords ?? next.records.count),
            Set(next.operations.map(\.id)).count == next.operations.count
          else {
            throw StoreError.message(
              "Worktree inventory changed during pagination. Refresh the inventory again.")
          }
          value = next
          error = nil
        }
      } catch is CancellationError { return } catch {
        if current == generation { self.error = error.localizedDescription }
      }
      if current == generation { return }
    } while !Task.isCancelled
  }
}
