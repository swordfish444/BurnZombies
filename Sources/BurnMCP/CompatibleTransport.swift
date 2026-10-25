import Foundation
import Logging
import MCP

/// Swift SDK 0.12.1 decodes experimental capabilities as strings instead of arbitrary JSON.
/// Ignore capabilities this server never consumes; keep SDK framing and RPC validation intact.
/// Remove when https://github.com/modelcontextprotocol/swift-sdk/issues/262 is released.
actor CompatibleTransport: Transport {
  private let base = StdioTransport()
  nonisolated let logger = Logger(label: "burnzombies.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
  func connect() async throws { try await base.connect() }
  func disconnect() async { await base.disconnect() }
  func send(_ data: Data) async throws { try await base.send(data) }
  func receive() -> AsyncThrowingStream<Data, Error> {
    let base = base
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await data in await base.receive() {
            continuation.yield(Self.compatibleInitialize(data))
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  private static func compatibleInitialize(_ data: Data) -> Data {
    guard var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      message["method"] as? String == "initialize",
      var parameters = message["params"] as? [String: Any],
      var capabilities = parameters["capabilities"] as? [String: Any],
      capabilities["experimental"] != nil else { return data }
    capabilities.removeValue(forKey: "experimental")
    parameters["capabilities"] = capabilities
    message["params"] = parameters
    return (try? JSONSerialization.data(withJSONObject: message)) ?? data
  }
}
