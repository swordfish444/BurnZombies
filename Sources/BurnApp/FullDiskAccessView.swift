import AppKit
import BurnCore
import SwiftUI

/// An inline optional setup; a completed setup recedes into a quiet status row.
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
        Text(model.accessReady ? "Complete" : "Optional")
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
        Text("Covers the folders macOS protects.").font(.callout.weight(.semibold))
        Text(
          "BurnZombies already works everywhere else. Full Disk Access adds "
            + ProtectedLocations.summary + ".")
          .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 7) {
          Text("1. Click Allow Full Disk Access. BurnZombies puts itself in the list for you.")
          Text("2. Switch on BurnZombies and enter your Mac password or use Touch ID.")
          Text("3. Choose Quit & Reopen if macOS asks. We’ll verify access automatically.")
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
        Text("This permission allows access to protected files. Active work, personal data and uncertain cleanup targets remain protected by BurnZombies’ safety checks.")
          .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
          Button("Allow Full Disk Access") { model.openFullDiskAccessSettings() }
            .buttonStyle(.borderedProminent).tint(BurnTheme.orange).clickPointer()
            .accessibilityIdentifier("open-full-disk-access")
          Button("Check access") { model.recheckFullDiskAccess() }
            .buttonStyle(.bordered).clickPointer().disabled(model.working)
            .accessibilityIdentifier("check-full-disk-access")
        }
        Text("If an update needs access again, remove the old BurnZombies entry with −, then click Allow Full Disk Access.")
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
