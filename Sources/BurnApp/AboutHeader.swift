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
  let answerNanoseconds: UInt64
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
    }, answerNanoseconds: UInt64 = 8_000_000_000, install: @escaping Install
  ) {
    self.version = version
    self.build = build
    self.root = root
    checkRelease = check
    self.prepare = prepare
    self.install = install
    self.answerNanoseconds = answerNanoseconds
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
  /// A quick check's answer stays beside the version. The line under the header is for the rest.
  var showsStatusLine: Bool {
    result?.state == "installing" || ![.idle, .checking, .upToDate].contains(phase)
  }
  /// A failed update stands until it's retried, unless that version got here another way.
  var failedUpdate: String? {
    guard let result, result.state == "failed", let target = try? AppVersion(result.version),
      let current = try? AppVersion(version), target > current
    else { return nil }
    return result.detail
  }
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
  /// "You're up to date" and "Couldn't check" are true for a moment, and the header is on every
  /// tab. A failed update with a newer version waiting stays: there's something to retry.
  func settleAnswer() async {
    let shown = phase
    guard shown == .upToDate || (shown == .failed && !updateAvailable) else { return }
    try? await Task.sleep(nanoseconds: answerNanoseconds)
    if !Task.isCancelled, phase == shown { phase = .idle }
  }
  func waitForOperation() async { await task?.value }
}

/// The top of the panel on every tab: BZ's name on the left, its version and updates on the right.
struct AboutHeader: View {
  @ObservedObject var updates: AppUpdateSettingsModel
  let subtitle: String
  var working = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "flame.fill").font(.title2).foregroundStyle(BurnTheme.ember)
        VStack(alignment: .leading, spacing: 2) {
          Text("BurnZombies").font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        // By the name, not the version: this is BZ at work, not an update in progress.
        if working { ProgressView().controlSize(.small) }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 2) {
          Text("Version \(updates.version) (\(updates.build))")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .textSelection(.enabled).accessibilityIdentifier("about-version")
          actionButtons
        }
        .fixedSize()
        .help("Checks GitHub only when you ask. Updating restarts BZ and keeps your settings.")
      }
      if updates.showsStatusLine {
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
      if let failure = updates.failedUpdate {
        Text(failure).font(.caption).foregroundStyle(Color.orange)
          .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("update-result")
      }
    }
    .task {
      updates.refreshResult()
      while updates.result?.state == "installing" {
        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
        updates.refreshResult()
      }
    }
    .task(id: updates.phase) { await updates.settleAnswer() }
  }
  /// One line beside the version whatever the updater is doing, so the panel doesn't jump.
  private var actionButtons: some View {
    HStack(spacing: 6) {
      if updates.phase == .upToDate {
        Text(updates.status).foregroundStyle(.secondary).accessibilityIdentifier("update-status")
      } else if updates.updateAvailable && [.available, .failed].contains(updates.phase) {
        Button("Update and Restart") { updates.update() }
          .buttonStyle(.link).clickPointer()
          .accessibilityIdentifier("update-install")
      } else if !updates.busy {
        Button("Check for Updates") { updates.check() }.clickPointer()
          .buttonStyle(.link)
          .accessibilityIdentifier("update-check")
      } else if updates.canCancel {
        if updates.phase == .checking {
          ProgressView().controlSize(.mini)
          Text(updates.status).foregroundStyle(.secondary).accessibilityIdentifier("update-status")
        }
        Button("Cancel") { updates.cancel() }.buttonStyle(.link).clickPointer().accessibilityIdentifier(
          "update-cancel")
      } else {
        // Nothing to press while BZ restarts. A blank keeps the version from moving.
        Text(" ").accessibilityHidden(true)
      }
    }
    .font(.caption)
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
