import AppKit
import BurnCore
import Darwin
import Foundation

enum AppUpdateHelper {
  static func run(_ file: URL) async throws {
    let plan = try AppUpdatePlan.load(file)
    let started = Date()
    var parentExited = false
    do {
      try plan.verifyBeforeQuit()
      guard case .found(let parent) = Native().probe(plan.parent.pid),
        parent.identity == plan.parent, parent.uid == getuid(),
        parent.executable == plan.app.appendingPathComponent("Contents/MacOS/BurnZombiesApp").path
      else {
        throw StoreError.message("The app requesting this update is no longer the same process.")
      }
      try AppUpdateVerification.verifySignature(plan.helper)
      try Store(root: plan.workspace).write(
        Data("ready".utf8), to: plan.workspace.appendingPathComponent("ready"), limit: 16)
      let deadline = ProcessInfo.processInfo.systemUptime + 120
      while true {
        switch Native().probe(plan.parent.pid) {
        case .absent: break
        case .found(let process) where process.identity != plan.parent: break
        default:
          guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw StoreError.message("The app is still closing. Its current bundle was preserved.")
          }
          try await Task.sleep(nanoseconds: 100_000_000)
          continue
        }
        break
      }
      parentExited = true
      try await AppUpdateInstallation.install(
        plan,
        launch: { app in
          try await restart(app, showSettings: plan.reopenSettings == true)
        },
        stop: { app in
          try await stopObserver(at: app)
        })
    } catch {
      if AppUpdateResult.load().map({ $0.date < started || $0.state != "failed" }) ?? true {
        try? AppUpdateResult(
          state: "failed", version: plan.replacement.version,
          detail: "The update couldn't finish. \(error.localizedDescription)"
        ).save()
        if parentExited, (try? AppUpdateBundle.read(plan.app)) == plan.previous {
          try? await restart(plan.app, showSettings: plan.reopenSettings == true)
        }
      }
      throw error
    }
  }

  private static func restart(_ app: URL, showSettings: Bool) async throws {
    let environment = AgentSessionEnvironment.login(ProcessInfo.processInfo.environment)
    let expected = try AppUpdateBundle.read(app)
    let cli = app.appendingPathComponent("Contents/MacOS/burnzombies")
    _ = try await Task.detached {
      try AppUpdateVerification.tool(
        cli.path, ["start-observer"] + (showSettings ? ["--show-settings"] : []), seconds: 60,
        environment: environment)
    }.value
    let data = try await Task.detached {
      try AppUpdateVerification.tool(cli.path, ["doctor"], seconds: 15, environment: environment)
    }.value
    guard let doctor = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      doctor["appResponding"] as? Bool == true, doctor["runningAppMatchesCLI"] as? Bool == true,
      doctor["runningAppVersion"] as? String == expected.version,
      doctor["runningAppBuild"] as? String == expected.build
    else {
      throw StoreError.message(
        "The updated app did not become ready. Restoring the previous version.")
    }
  }
}
