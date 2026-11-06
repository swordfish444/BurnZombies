import SwiftUI

/// Presentation only. Opening a section never changes saved settings or cleanup authority.
@MainActor final class SettingsExpansion: ObservableObject {
  enum Section: String, CaseIterable {
    case permissions = "Permissions"
    case autopilot = "Autopilot"
    case intelligence = "AI reviews & usage"
    case general = "Notifications & startup"
    case protection = "Protection & privacy"
  }
  @Published var expanded: Set<Section> = []
  func binding(_ section: Section) -> Binding<Bool> {
    Binding(get: { self.expanded.contains(section) }, set: { open in
      if open { self.expanded.insert(section) } else { self.expanded.remove(section) }
    })
  }
}

struct SettingsSection<Content: View>: View {
  let section: SettingsExpansion.Section
  @ObservedObject var expansion: SettingsExpansion
  @ViewBuilder var content: () -> Content

  var body: some View {
    DisclosureGroup(isExpanded: expansion.binding(section)) {
      VStack(alignment: .leading, spacing: 14, content: content)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
    } label: {
      Text(section.rawValue).font(.callout.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .disclosureGroupStyle(ClickDisclosureStyle())
    .padding(14)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityIdentifier("settings-section-" + String(describing: section))
  }
}
