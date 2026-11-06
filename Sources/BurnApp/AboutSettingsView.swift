import AppKit
import BurnCore
import Foundation
import SwiftUI

@MainActor final class AppUpdateSettingsModel: ObservableObject {
  enum Phase: Equatable {
    case idle, checking, available, upToDate, downloading, verifying, waiting, restarting, failed
  }
  typealias Check = @Sendable () async throws -> AppUpdateRelease
  typealias Prepare =
    @Sendable (AppUpdateRelease, @escaping @Sendable (AppUpdateProgress) -> Void) async throws ->
    AppUpdatePlan
  typealias Install = @MainActor (AppUpdatePlan) async throws -> Void
  @Published var phase: Phase = .idle
  @Published var release: AppUpdateRelease?
  @Published var fraction: Double?
  @Published var message: String?
  @Published var result: AppUpdateResult?
  let version: String
  let build: String
  let root: URL
  let checkRelease: Check
  let prepare: Prepare
  let install: Install
  private var task: Task<Void, Never>?
  private var operation: UUID?

  init(
    version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      as? String ?? BuildIdentity.version,
    build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? BuildIdentity.build,
    root: URL = Store.defaultRoot, check: @escaping Check = { try await AppUpdateClient.check() },
    prepare: @escaping Prepare = { release, progress in
      try await AppUpdatePreparation.prepare(
        release, destination: Bundle.main.bundleURL, progress: progress)
    }, install: @escaping Install
  ) {
    self.version = version
    self.build = build
    self.root = root
    checkRelease = check
    self.prepare = prepare
    self.install = install
  }
  var busy: Bool {
    result?.state == "installing"
      || [.checking, .downloading, .verifying, .waiting, .restarting].contains(phase)
  }
  var updateAvailable: Bool {
    guard let release, let current = try? AppVersion(version) else { return false }
    return release.version > current
  }
  var canCancel: Bool { [.checking, .downloading, .verifying].contains(phase) }
  var status: String {
    if result?.state == "installing" { return "Finishing the update…" }
    switch phase {
    case .idle: return "Check for the latest version of BurnZombies."
    case .checking: return "Checking for updates…"
    case .available: return "Version \(release?.version.description ?? "") is available."
    case .upToDate: return "You're up to date."
    case .downloading: return "Downloading the update…"
    case .verifying: return "Verifying the update…"
    case .waiting: return "Finishing current work before restarting…"
    case .restarting: return "Restarting BurnZombies…"
    case .failed: return message ?? "Couldn't check for updates. Please try again."
    }
  }
  func check() {
    guard !busy else { return }
    let id = UUID()
    operation = id
    phase = .checking
    message = nil
    fraction = nil
    task = Task {
      do {
        let found = try await checkRelease()
        try Task.checkCancellation()
        guard operation == id else { return }
        release = found
        phase = found.version > (try AppVersion(version)) ? .available : .upToDate
      } catch {
        guard operation == id else { return }
        message = error.localizedDescription
        phase = .failed
      }
      if operation == id {
        task = nil
        operation = nil
      }
    }
  }
  func update() {
    guard !busy, let release, let current = try? AppVersion(version), release.version > current
    else { return }
    let id = UUID()
    operation = id
    phase = .downloading
    message = nil
    fraction = nil
    task = Task {
      var prepared: AppUpdatePlan?
      do {
        let plan = try await prepare(release) { progress in
          Task { @MainActor in
            guard self.operation == id else { return }
            switch progress {
            case .downloading(let fraction):
              if self.phase == .downloading { self.fraction = fraction }
            case .verifying:
              if [.downloading, .verifying].contains(self.phase) {
                self.phase = .verifying
                self.fraction = nil
              }
            }
          }
        }
        prepared = plan
        try Task.checkCancellation()
        guard operation == id else { throw CancellationError() }
        phase = .waiting
        try await install(plan)
        phase = .restarting
      } catch {
        if let plan = prepared, !FileManager.default.fileExists(atPath: plan.backup.path),
          !FileManager.default.fileExists(
            atPath: plan.workspace.appendingPathComponent("ready").path)
        {
          try? FileManager.default.removeItem(at: plan.workspace)
        }
        guard operation == id else { return }
        message = error.localizedDescription
        phase = .failed
      }
      if operation == id {
        task = nil
        operation = nil
      }
    }
  }
  func cancel() {
    guard canCancel else { return }
    operation = nil
    task?.cancel()
    task = nil
    fraction = nil
    phase = release == nil ? .idle : updateAvailable ? .available : .upToDate
  }
  func refreshResult() {
    result = AppUpdateResult.load(root: root)
  }
  func waitForOperation() async { await task?.value }
}

struct AboutSettingsView: View {
  @ObservedObject var updates: AppUpdateSettingsModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Version \(updates.version) (\(updates.build))")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .textSelection(.enabled).accessibilityIdentifier("about-version")
        Spacer(minLength: 0)
        actionButtons
      }
      if updates.phase != .idle || updates.result?.state == "installing" {
        HStack(alignment: .top, spacing: 8) {
          if updates.busy {
            ProgressView().controlSize(.mini)
          }
          Text(updates.status).font(.caption).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(updates.phase == .failed ? Color.orange : Color.secondary)
            .accessibilityIdentifier("update-status")
          Spacer(minLength: 0)
          if updates.updateAvailable && !updates.busy {
            Button("Check again") { updates.check() }.buttonStyle(.link).clickPointer()
              .font(.caption).fixedSize().accessibilityIdentifier("update-check")
          }
          if let release = updates.release, !updates.busy {
            Link("Release notes", destination: release.notes).clickPointer().font(.caption)
              .fixedSize()
          }
        }
      }
      if updates.phase == .downloading, let fraction = updates.fraction {
        ProgressView(value: fraction).accessibilityLabel("Update download")
      }
      if let result = updates.result, result.state == "failed" {
        Text(result.detail).font(.caption).foregroundStyle(Color.orange)
        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("update-result")
      }
    }
    .help("Checks GitHub only when you ask. Updating restarts BZ and keeps your settings.")
    .task {
      updates.refreshResult()
      while updates.result?.state == "installing" {
        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
        updates.refreshResult()
      }
    }
  }
  private var actionButtons: some View {
    HStack(spacing: 8) {
      if updates.updateAvailable && [.available, .failed].contains(updates.phase) {
        Button("Update and Restart") { updates.update() }
          .buttonStyle(.link).clickPointer()
          .accessibilityIdentifier("update-install")
      } else if !updates.busy {
        Button("Check for Updates") { updates.check() }.clickPointer()
          .buttonStyle(.link)
          .accessibilityIdentifier("update-check")
      } else if updates.canCancel {
        Button("Cancel") { updates.cancel() }.buttonStyle(.link).clickPointer().accessibilityIdentifier(
          "update-cancel")
      }
    }
    .font(.caption).fixedSize()
  }
}

enum AppUpdateHandoff {
  static func launch(_ plan: AppUpdatePlan) async throws {
    try await Task.detached {
      try plan.verifyBeforeQuit()
      try AppUpdateVerification.verifySignature(plan.helper)
    }.value
    try Task.checkCancellation()
    let process = Process()
    process.executableURL = plan.helper
    process.arguments = ["--finish-update", plan.file.path]
    process.currentDirectoryURL = plan.workspace
    process.environment = ProcessInfo.processInfo.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    do {
      let ready = plan.workspace.appendingPathComponent("ready")
      for _ in 0..<150 {
        if let data = try? Store(root: plan.workspace).read(ready, limit: 16),
          data == Data("ready".utf8)
        {
          return
        }
        guard process.isRunning else {
          throw StoreError.message(
            "The update helper couldn't start. Your current app is unchanged.")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      throw StoreError.message(
        "The update helper didn't become ready. Your current app is unchanged.")
    } catch {
      if process.isRunning { process.terminate() }
      throw error
    }
  }
}
