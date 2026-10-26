import BurnCore
import SwiftUI

@MainActor final class ReviewSettingsModel: ObservableObject {
  @Published var model = ""
  @Published var thinking = ""
  @Published var configuration: MachineReviewConfiguration?
  @Published var notice: String?
  @Published var failed = false
  let root: URL
  let catalog: [ReviewModelOption]
  init(root: URL = Store.defaultRoot, catalog: [ReviewModelOption] = ReviewModelOption.localCodexCatalog()) {
    self.root = root; self.catalog = catalog
    do {
      configuration = try MachineReviewConfiguration.load(root: root)
      model = configuration?.model ?? ""; thinking = configuration?.reasoningEffort ?? ""
    } catch { notice = error.localizedDescription; failed = true }
  }
  var levels: [String] {
    guard let configuration else { return [] }
    if configuration.harness == "codex", let selected = catalog.first(where: { $0.id == model }), !selected.efforts.isEmpty {
      return selected.efforts.filter { configuration.thinkingLevels.contains($0) }
    }
    return configuration.thinkingLevels
  }
  var validation: String? {
    guard var candidate = configuration else { return "Run setup to select a harness." }
    candidate.model = MachineReviewConfiguration.selectionValue(model)
    candidate.reasoningEffort = MachineReviewConfiguration.selectionValue(thinking)
    do { try candidate.validateSelection() } catch { return error.localizedDescription }
    if !thinking.isEmpty && !levels.contains(thinking) { return "Choose a thinking level supported by this model." }
    return nil
  }
  var changed: Bool {
    MachineReviewConfiguration.selectionValue(model) != configuration?.model
      || MachineReviewConfiguration.selectionValue(thinking) != configuration?.reasoningEffort
  }
  func save() {
    guard let configuration else { return }
    guard validation == nil else { notice = validation; failed = true; return }
    do {
      self.configuration = try MachineReviewConfiguration.saveSelection(root: root,
        expectedHarness: configuration.harness, model: model, thinking: thinking)
      model = self.configuration?.model ?? ""; thinking = self.configuration?.reasoningEffort ?? ""
      notice = "Saved for the next review."; failed = false
    } catch { notice = error.localizedDescription; failed = true }
  }
}

struct ReviewSettingsView: View {
  @ObservedObject var settings: ReviewSettingsModel
  private let orange = Color(red: 1, green: 0.34, blue: 0.12)
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Review intelligence").font(.headline)
        Spacer()
        Text(settings.configuration?.harnessName ?? "Not configured").font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("Model").font(.callout.weight(.medium))
        HStack(spacing: 8) {
          TextField("Harness default", text: $settings.model).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("review-model")
          if settings.configuration?.harness == "codex", !settings.catalog.isEmpty {
            Menu {
              Button("Harness default") { settings.model = "" }
              Divider()
              ForEach(settings.catalog) { option in Button(option.name) { settings.model = option.id } }
            } label: { Image(systemName: "chevron.down") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Choose a model")
          }
        }
      }
      if settings.configuration?.thinkingLevels.isEmpty == false {
        Picker("Thinking level", selection: $settings.thinking) {
          Text("Harness default").tag("")
          ForEach(settings.levels, id: \.self) { Text($0.capitalized).tag($0) }
          if !settings.thinking.isEmpty && !settings.levels.contains(settings.thinking) {
            Text("\(settings.thinking.capitalized) — unavailable").tag(settings.thinking)
          }
        }.accessibilityIdentifier("review-thinking")
      } else {
        LabeledContent("Thinking level", value: "Managed by harness").font(.callout)
      }
      Text("Applies to future background reviews. Current work keeps running.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Use defaults") { settings.model = ""; settings.thinking = ""; settings.notice = nil }
          .buttonStyle(.plain).foregroundStyle(.secondary)
        Spacer()
        Button("Save") { settings.save() }.buttonStyle(.borderedProminent).tint(orange)
          .disabled(!settings.changed || settings.validation != nil).accessibilityIdentifier("save-review-settings")
      }
      if let text = settings.validation ?? settings.notice {
        Text(text).font(.caption).foregroundStyle(settings.validation != nil || settings.failed ? orange : .secondary)
      }
    }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
      .disabled(settings.configuration == nil)
  }
}
