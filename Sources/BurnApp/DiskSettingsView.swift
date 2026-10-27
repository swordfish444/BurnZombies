import BurnCore
import SwiftUI

@MainActor final class DiskSettingsModel: ObservableObject {
  @Published var policy = DiskPolicy()
  @Published var inventory = DiskSnapshot()
  @Published var expanded = false
  @Published var roots = ""
  @Published var protectedPaths = ""
  @Published var notice: String?
  @Published var preset = "custom"
  let root: URL
  init(root: URL = Store.defaultRoot) { self.root = root; reload() }
  func reload() {
    do {
      let store = try Store(root: root); policy = try DiskPolicy.load(store); inventory = try DiskSnapshot.load(store)
      roots = policy.roots.joined(separator: "\n"); protectedPaths = policy.protectedPaths.joined(separator: "\n")
    } catch { notice = error.localizedDescription }
  }
  func save() {
    func paths(_ value: String) -> [String] { Array(Set(value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted() }
    policy.roots = paths(roots); policy.protectedPaths = paths(protectedPaths)
    do { try policy.save(Store(root: root)); notice = "Saved. The next native scan applies these rules; no review starts from Settings." }
    catch { notice = error.localizedDescription }
  }
  func rule(_ candidate: DiskCandidate, _ disposition: String) {
    policy.rules.removeAll { $0.path == candidate.path }
    policy.rules.append(.init(path: candidate.path, disposition: disposition,
      note: disposition == "regenerable" ? "User explicitly classified this exact folder as regenerable output. Preserve active consumers and retention rules." : "User disk cleanup preference."))
    save()
  }
}
struct DiskSettingsView: View {
  @StateObject var settings: DiskSettingsModel
  @State private var confirm: DiskCandidate?
  init(root: URL = Store.defaultRoot) { _settings = StateObject(wrappedValue: DiskSettingsModel(root: root)) }
  init(model: DiskSettingsModel) { _settings = StateObject(wrappedValue: model) }
  private let orange = Color(red: 1, green: 0.34, blue: 0.12)
  var body: some View {
    DisclosureGroup(isExpanded: $settings.expanded) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Reclaim the leftovers. Keep the work.").font(.headline)
        Picker("Disk cleanup", selection: $settings.policy.mode) {
          Text("Recommend").tag("recommend"); Text("Automatic").tag("automatic"); Text("Off").tag("off")
        }.accessibilityIdentifier("disk-mode")
        Text("Automatic removal requires an exact regenerable-folder rule and fresh safety checks. Worktrees remain with their owning manager.").font(.caption).foregroundStyle(.secondary)
        Picker("Aggressiveness", selection: $settings.preset) {
          Text("Custom").tag("custom"); Text("Conservative").tag("conservative"); Text("Balanced").tag("balanced"); Text("Proactive").tag("proactive")
        }.onChange(of: settings.preset) { _, value in settings.policy.preset(value) }
        Stepper("Keep at least \(settings.policy.minimumAgeDays) days", value: $settings.policy.minimumAgeDays, in: 1...90)
        Stepper("Keep newest \(settings.policy.keepNewest) evidence runs", value: $settings.policy.keepNewest, in: 1...20)
        Stepper("Native scan every \(settings.policy.scanHours) hours", value: $settings.policy.scanHours, in: 1...24)
        Stepper("Free-space target: \(settings.policy.targetFreeGB) GB", value: $settings.policy.targetFreeGB, in: 10...1000, step: 10)
        Stepper("Remove at most \(settings.policy.maximumGBPerDay) GB / day", value: $settings.policy.maximumGBPerDay, in: 1...500)
        Stepper("Minimum candidate: \(settings.policy.minimumCandidateMB) MB", value: $settings.policy.minimumCandidateMB, in: 1...100_000, step: 128)
        Text("More aggressive changes timing and volume, never safety. Active work, secrets, tracked files, unclear ownership and incomplete visibility stay protected.").font(.caption).foregroundStyle(.secondary)
        field("Inspect these roots", value: $settings.roots, height: 50)
        field("Always protect these paths", value: $settings.protectedPaths, height: 44)
        field("Preferences for the reviewing agent", value: $settings.policy.instructions, height: 65)
        Text("For example: keep release evidence for 30 days; never discard repro cases; prefer rebuildable caches. Rules are saved locally and do not retrain a model.").font(.caption).foregroundStyle(.secondary)
        HStack { Button("Reload") { settings.reload() }; Spacer(); Button("Save disk settings") { settings.save() }.buttonStyle(.borderedProminent).tint(orange) }
        if let notice = settings.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        Divider()
        HStack { Text("Latest inventory").font(.headline); Spacer(); if settings.inventory.date != .distantPast { Text(settings.inventory.date, style: .relative).font(.caption).foregroundStyle(.secondary) } }
        if settings.inventory.freeBytes > 0 { Text("\(ImpactNumbers.bytes(settings.inventory.freeBytes)) free").font(.title3.weight(.semibold)) }
        Text(settings.inventory.detail).font(.caption).foregroundStyle(.secondary)
        ForEach(settings.inventory.candidates.prefix(12)) { candidate in
          VStack(alignment: .leading, spacing: 6) {
            HStack { Text(candidate.kind == "worktree" ? "Worktree" : ImpactNumbers.bytes(candidate.bytes)).font(.subheadline.weight(.semibold)); Spacer(); Text(candidate.userRule).font(.caption).foregroundStyle(orange) }
            Text(candidate.path).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
            Text(candidate.rationale ?? candidate.guardReason).font(.caption).foregroundStyle(.secondary)
            if candidate.kind != "worktree" {
              HStack {
                Button("Keep") { settings.rule(candidate, "keep") }
                Button("Review") { settings.rule(candidate, "review") }
                Spacer()
                Button("Regenerable…") { confirm = candidate }
              }.font(.caption)
            }
          }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
        if !settings.policy.rules.isEmpty {
          Text("Saved rules").font(.subheadline.weight(.semibold))
          ForEach(settings.policy.rules) { rule in
            HStack { Text("\(rule.disposition) · \(rule.path)").font(.caption).lineLimit(2); Spacer(); Button("Forget") { settings.policy.rules.removeAll { $0.path == rule.path }; settings.save() } }.font(.caption)
          }
        }
        Text("No model is called for scanning or settings changes. Only a fresh eligible candidate below your free-space target enters the existing hourly, usage-limited review queue.").font(.caption2).foregroundStyle(.secondary)
      }.padding(.top, 12)
    } label: { Label("Disk cleanup tuning", systemImage: "externaldrive").font(.callout.weight(.medium)) }
    .padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    .confirmationDialog("Mark this exact folder as regenerable?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
      Button("Allow removal after review", role: .destructive) { if let candidate = confirm { settings.rule(candidate, "regenerable") }; confirm = nil }
    } message: { Text("\(confirm?.path ?? "")\n\nConfirm its contents can be recreated and are not valuable evidence or user data. Automatic mode may permanently remove this folder after retention, harness review and fresh native checks. This does not allow deletion of the worktree.") }
    .accessibilityIdentifier("disk-cleanup-settings")
  }
  private func field(_ title: String, value: Binding<String>, height: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.weight(.medium)); TextEditor(text: value).font(.caption.monospaced()).frame(height: height).padding(5).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15))) }
  }
}
