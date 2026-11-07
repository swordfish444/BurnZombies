import AppKit
import BurnCore
import SwiftUI

/// Optional setup: what Full Disk Access adds and the few steps to turn it on.
struct FullDiskAccessView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Full Disk Access").font(.headline)
      Text("BZ works without it. Turn it on so BZ can also check " + ProtectedLocations.summary + ".")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Text("1. Click Open Settings.")
        Text("2. Turn on BurnZombies. Not there? Click + and add it.")
        Text("3. Come back. BZ checks by itself.")
      }.font(.callout).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Text(model.installedAppPath).font(.caption2.monospaced()).textSelection(.enabled)
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Button { model.copyInstalledAppPath() } label: { Image(systemName: "doc.on.doc") }
          .buttonStyle(.borderless).foregroundStyle(.secondary).clickPointer()
          .help("Copy where BZ is, for the + button").accessibilityLabel("Copy app path")
      }
      HStack(spacing: 8) {
        Button("Open Settings") { model.openFullDiskAccessSettings() }
          .buttonStyle(.borderedProminent).tint(BurnTheme.orange).clickPointer()
          .accessibilityIdentifier("open-full-disk-access")
        Button("Check again") { model.recheckFullDiskAccess() }
          .buttonStyle(.bordered).clickPointer().disabled(model.working)
          .accessibilityIdentifier("check-full-disk-access")
      }
      if model.state.fullDiskAccess.state == .unknown {
        Text("BZ couldn't tell if it's on yet.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(BurnTheme.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("full-disk-access-setup")
  }
}
