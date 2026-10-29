import CryptoKit
import Foundation

extension WorktreeService {
  /// SecItem can wait indefinitely for a human. Run it on a dispatch thread so
  /// neither this actor nor the cooperative executor is held by the prompt.
  func readRecoveryKey(_ load: @escaping @Sendable () throws -> SymmetricKey) async throws
    -> SymmetricKey
  {
    guard !closing else { throw StoreError.message("Worktree service is closing.") }
    try Task.checkCancellation()
    let id = UUID()
    // Security.framework offers no safe cancellation of a displayed prompt.
    // Keep the read owned and drain it after the human responds; never retry it.
    workJobs[id] = {}
    defer { workJobs.removeValue(forKey: id) }
    let key: SymmetricKey = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try load() })
      }
    }
    try Task.checkCancellation()
    guard !closing else { throw CancellationError() }
    return key
  }
  func runWork<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    guard !closing else { throw StoreError.message("Worktree service is closing.") }
    try Task.checkCancellation()
    let id = UUID()
    let worker = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      return try body()
    }
    workJobs[id] = { worker.cancel() }
    defer { workJobs.removeValue(forKey: id) }
    return try await withTaskCancellationHandler {
      let value = try await worker.value
      try Task.checkCancellation()
      return value
    } onCancel: {
      worker.cancel()
    }
  }
  public func shutdown() async {
    closing = true
    generation += 1
    scanControl?.cancel()
    scanFlight?.task.cancel()
    for cancel in workJobs.values { cancel() }
    while scanning || executing || !workJobs.isEmpty {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}
