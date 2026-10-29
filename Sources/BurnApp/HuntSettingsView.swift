import BurnCore
import SwiftUI

@MainActor final class HuntSettingsModel: ObservableObject {
  @Published var automatic = true
  @Published var intervalHours = 4
  @Published private(set) var configuration: MachineReviewConfiguration?
  @Published var notice: String?
  @Published var failed = false
  let root: URL

  init(root: URL = Store.defaultRoot) {
    self.root = root
    do {
      configuration = try MachineReviewConfiguration.load(root: root)
      automatic = configuration?.enabled ?? true
      intervalHours = configuration?.effectiveHuntIntervalHours ?? 4
    } catch { notice = error.localizedDescription; failed = true }
  }
  var changed: Bool {
    guard let configuration else { return false }
    return automatic != configuration.enabled || intervalHours != configuration.effectiveHuntIntervalHours
  }
  var validation: String? {
    guard configuration != nil else { return "Run setup to select a harness." }
    return MachineReviewConfiguration.huntIntervals.contains(intervalHours) ? nil : "Choose a supported hunt frequency."
  }
  func save() {
    guard let configuration else { return }
    guard validation == nil else { notice = validation; failed = true; return }
    do {
      // Reload so a schedule draft never overwrites a newly selected model or harness.
      guard var latest = try MachineReviewConfiguration.load(root: root), latest.harness == configuration.harness else {
        throw StoreError.message("The hunt harness changed. Reopen Settings before saving.")
      }
      latest.enabled = automatic
      latest.huntIntervalHours = intervalHours
      try latest.save(root: root)
      self.configuration = latest
      notice = automatic ? "Saved for future hunts." : "Automatic hunts are off."
      failed = false
    } catch { notice = error.localizedDescription; failed = true }
  }
}

struct HuntSettingsView: View {
  @ObservedObject var settings: HuntSettingsModel
  var onSaved: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Image(systemName: "scope").foregroundStyle(BurnTheme.orange)
        Text("Zombie hunts").font(.headline)
        Spacer()
        Text("Whole Mac").font(.caption).foregroundStyle(.secondary)
      }
      Toggle("Automatic hunts", isOn: $settings.automatic)
        .toggleStyle(.switch).tint(BurnTheme.orange).clickPointer()
        .accessibilityIdentifier("automatic-hunts")
      Picker("Hunt every", selection: $settings.intervalHours) {
        ForEach(MachineReviewConfiguration.huntIntervals, id: \.self) { hours in
          Text(hours == 1 ? "1 hour" : hours == 4 ? "4 hours · Default" : "\(hours) hours").tag(hours)
        }
      }.clickPointer().disabled(!settings.automatic).accessibilityIdentifier("hunt-frequency")
      Text("Hunt Zombies stays available from the menu bar when automatic hunts are off.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        if let notice = settings.validation ?? settings.notice {
          Text(notice).font(.caption)
            .foregroundStyle(settings.failed || settings.validation != nil ? BurnTheme.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Save") {
          settings.save()
          if !settings.failed { onSaved() }
        }.clickPointer().buttonStyle(.borderedProminent).tint(BurnTheme.orange)
          .disabled(!settings.changed || settings.validation != nil).accessibilityIdentifier("save-hunt-settings")
      }
    }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
      .disabled(settings.configuration == nil)
  }
}
