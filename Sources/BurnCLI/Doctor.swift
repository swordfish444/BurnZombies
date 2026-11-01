import BurnCore
import Foundation

enum Doctor {
  static func run() async throws {
    let root = Store.defaultRoot
    let config = try MachineReviewConfiguration.load(root: root)
    var result: [String: Any] = [
      "version": BuildIdentity.version, "build": BuildIdentity.build,
      "configured": config != nil, "configuredHarness": config?.harness ?? "none",
      "backgroundReviewsEnabled": config?.enabled == true,
      "supportedHarnesses": ["codex", "claude"],
      "availableHarnesses": ["codex", "claude"].filter {
        MachineReviewConfiguration.detect($0) != nil
      },
      "harnessAuthentication":
        "Not inferred from installation. A real review verifies the selected account separately.",
      "cleanupRequested": false,
    ]
    if let config {
      result["configuredExecutableAvailable"] = FileManager.default.isExecutableFile(
        atPath: config.executable)
      result["mcpServerAvailable"] = FileManager.default.isExecutableFile(atPath: config.server)
      result["huntIntervalHours"] = config.effectiveHuntIntervalHours
    }
    do {
      let text = try await AgentConnection.callAsync(.init("access_status"))
      let reply = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
      result["appResponding"] = reply?["ok"] as? Bool == true
      result["runningAppVersion"] = reply?["appVersion"] ?? "unknown (older app)"
      result["runningAppBuild"] = reply?["appBuild"] ?? "unknown (older app)"
      result["runningAppMatchesCLI"] =
        (reply?["appVersion"] as? String == BuildIdentity.version)
        && (reply?["appBuild"] as? String == BuildIdentity.build)
      result["access"] =
        reply?["fullDiskAccess"] ?? reply?["accessStatus"]
        ?? "See access-status for the exact current state."
    } catch {
      result["appResponding"] = false
      result["appError"] = error.localizedDescription
    }
    if let data = try? Store(root: root).read(
      root.appendingPathComponent("machine-review-state.json"), limit: 65536),
      let state = try? JSONDecoder().decode(MachineReviewState.self, from: data)
    {
      result["reviewPhase"] = state.phase
      result["reviewDetail"] = state.detail
    }
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: result, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
  }
}
