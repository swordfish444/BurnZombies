import AppKit
import BurnCore
import SwiftUI

/// An inline prerequisite, never an automatic window or system permission prompt.
struct FullDiskAccessView: View {
  @ObservedObject var model: AppModel
  private var installedPath: String {
    Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.path : "~/Applications/BurnZombies.app"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Image(systemName: model.accessReady ? "checkmark.shield.fill" : "lock.shield")
          .foregroundStyle(model.accessReady ? Color.green : BurnTheme.orange)
        Text("Full Disk Access").font(.headline)
        Spacer(minLength: 4)
        Text(model.accessReady ? "Available" : "Required")
          .font(.caption.weight(.semibold)).foregroundStyle(model.accessReady ? Color.secondary : BurnTheme.orange)
      }
      if model.accessReady {
        Text("Access check passed. Cleanup still requires ownership and safety checks; unreadable locations stay protected.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("One permission. Whole-Mac discovery.").font(.callout.weight(.semibold))
        Text("BurnZombies waits for Full Disk Access before scanning folders or running AI reviews.")
          .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 7) {
          Text("1. Open Privacy & Security → Full Disk Access.")
          Text("2. Add BurnZombies with + and turn it on.")
          Text("3. If macOS asks, quit and reopen BurnZombies. Then confirm below.")
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
        Text(installedPath).font(.caption2.monospaced()).textSelection(.enabled)
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("This permission allows access to protected files. Active work, personal data and uncertain cleanup targets remain protected by BurnZombies’ safety checks.")
          .font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 8) {
        Button("Open Full Disk Access") { model.openFullDiskAccessSettings() }
          .buttonStyle(.borderedProminent).tint(BurnTheme.orange).clickPointer()
          .accessibilityIdentifier("open-full-disk-access")
        Button(model.accessReady ? "Check access" : "I enabled access — check again") { model.recheckFullDiskAccess() }
          .buttonStyle(.bordered).clickPointer().disabled(model.working)
          .accessibilityIdentifier("check-full-disk-access")
      }
      if !model.accessReady {
        Text("If an update needs access again, remove the old entry, add this copy of BurnZombies, then enable it.")
          .font(.caption).foregroundStyle(.secondary)
        Text(model.state.fullDiskAccess.detail).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.padding(16)
      .background(BurnTheme.orange.opacity(model.accessReady ? 0.035 : 0.07), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BurnTheme.orange.opacity(model.accessReady ? 0.15 : 0.45)))
      .accessibilityIdentifier("full-disk-access-setup")
  }
}
