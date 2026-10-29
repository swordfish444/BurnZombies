import Foundation

extension WorktreeService {
  func runWork<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    guard !closing else { throw StoreError.message("Worktree service is closing.") }
    try Task.checkCancellation()
    let id = UUID(), worker = Task.detached(priority: .utility) { try Task.checkCancellation(); return try body() }
    workJobs[id] = { worker.cancel() }; defer { workJobs.removeValue(forKey: id) }
    return try await withTaskCancellationHandler {
      let value = try await worker.value; try Task.checkCancellation(); return value
    } onCancel: { worker.cancel() }
  }
  public func shutdown() async {
    closing = true; generation += 1; scanControl?.cancel()
    for cancel in workJobs.values { cancel() }
    while scanning || executing || !workJobs.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
  }
}
