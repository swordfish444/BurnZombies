import AppKit
import BurnCore
import SwiftUI

/// An inline prerequisite; a completed setup recedes into a quiet status row.
struct FullDiskAccessView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: model.accessReady ? 8 : 12) {
      HStack(spacing: 9) {
        Image(systemName: model.accessReady ? "checkmark.circle.fill" : "lock.shield")
          .foregroundStyle(model.accessReady ? Color(red: 0.48, green: 0.76, blue: 0.39) : BurnTheme.orange)
        Text("Full Disk Access").font(.headline)
          .foregroundStyle(model.accessReady ? Color.secondary : Color.primary)
        Spacer(minLength: 4)
        Text(model.accessReady ? "Complete" : "Required")
          .font(.caption.weight(.semibold)).foregroundStyle(model.accessReady ? Color.secondary : BurnTheme.orange)
      }
      if model.accessReady {
        HStack {
          Text("Access verified. Safety checks stay on.").font(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 4)
          Button("Manage access") { model.openFullDiskAccessSettings() }
            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).clickPointer()
            .accessibilityIdentifier("manage-full-disk-access")
        }
      } else {
        Text("One permission. Whole-Mac discovery.").font(.callout.weight(.semibold))
        Text("BurnZombies waits for Full Disk Access before scanning folders or running AI reviews.")
          .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 7) {
          Text("1. Open Privacy & Security → Full Disk Access.")
          Text("2. Add BurnZombies with + and turn it on.")
          Text("3. Return to BurnZombies. We’ll check access once. If macOS asks, quit and reopen the app, then check below.")
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 8) {
          Text(model.installedAppPath).font(.caption2.monospaced()).textSelection(.enabled)
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button { model.copyInstalledAppPath() } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain).foregroundStyle(.secondary).clickPointer()
            .help("Copy app path for +, then Command-Shift-G").accessibilityLabel("Copy app path")
        }
        Text("This permission allows access to protected files. Active work, personal data and uncertain cleanup targets remain protected by BurnZombies’ safety checks.")
          .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
          Button("Open Full Disk Access") { model.openFullDiskAccessSettings() }
            .buttonStyle(.borderedProminent).tint(BurnTheme.orange).clickPointer()
            .accessibilityIdentifier("open-full-disk-access")
          Button("Check access") { model.recheckFullDiskAccess() }
            .buttonStyle(.bordered).clickPointer().disabled(model.working)
            .accessibilityIdentifier("check-full-disk-access")
        }
        Text("If an update needs access again, remove the old entry, add this copy of BurnZombies, then enable it.")
          .font(.caption).foregroundStyle(.secondary)
        Text(model.state.fullDiskAccess.detail).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.padding(16)
      .background(model.accessReady ? Color.primary.opacity(0.025) : BurnTheme.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.accessReady ? Color.primary.opacity(0.08) : BurnTheme.orange.opacity(0.45)))
      .accessibilityIdentifier("full-disk-access-setup")
  }
}
