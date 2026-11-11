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
    let sweepURL = root.appendingPathComponent("autopilot/sweep.json")
    if FileManager.default.fileExists(atPath: sweepURL.path),
      let autopilot = try? AutopilotStore(root: root),
      let sweep = try? autopilot.sweep()
    {
      let now = Date()
      result["autopilotEnabled"] = sweep.enabled
      if let lookOnly = sweep.lookOnly { result["lookOnly"] = lookOnly }
      if let failover = sweep.failoverHarness,
        (sweep.primaryBlockedUntil ?? .distantPast) > now
      {
        result["activeHarness"] = failover
        result["failoverHarness"] = failover
      } else if let config, config.enabled {
        result["activeHarness"] = config.harness
      }
      if !sweep.enabled {
        result["reviewPhase"] = "disabled"
        result["reviewDetail"] = "Autopilot is turned off."
      } else if sweep.running {
        result["reviewPhase"] = "hunting"
        result["reviewDetail"] = sweep.log.last?.message ?? "AI sweep is running."
      } else if let retry = sweep.retryAfter, retry > now {
        result["reviewPhase"] = "backing_off"
        result["reviewDetail"] =
          sweep.lastError ?? sweep.log.last?.message ?? "Waiting to retry AI sweep."
      } else if config?.enabled == true {
        result["reviewPhase"] = "active"
        if let failover = sweep.failoverHarness,
          (sweep.primaryBlockedUntil ?? .distantPast) > now
        {
          let label = failover == "codex" ? "Codex" : "Claude Code"
          result["reviewDetail"] =
            "Autopilot is active (using \(label) while primary AI limit resets)."
        } else {
          result["reviewDetail"] =
            sweep.log.last?.message ?? "Watching this Mac and burning safe leftovers."
        }
      } else {
        result["reviewPhase"] = "rules_only"
        result["reviewDetail"] = "Rules are active; AI sweeps are turned off."
      }
    } else if let data = try? Store(root: root).read(
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
