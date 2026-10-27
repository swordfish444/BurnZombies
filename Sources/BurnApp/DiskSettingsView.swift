import BurnCore
import SwiftUI

@MainActor final class DiskSettingsModel: ObservableObject {
  @Published var policy = DiskPolicy()
  @Published var inventory = DiskSnapshot()
  @Published var expanded = false
  @Published var advanced = false
  @Published var reviewStatus = ""
  @Published var roots = ""
  @Published var protectedPaths = ""
  @Published var notice: String?
  @Published var preset = "custom"
  let root: URL
  init(root: URL = Store.defaultRoot) { self.root = root; reload() }
  func reload() {
    do {
      let store = try Store(root: root); policy = try DiskPolicy.load(store)
      policy.minimumCandidateMB = max(10_000, policy.minimumCandidateMB)
      refreshInventory()
      roots = policy.roots.joined(separator: "\n"); protectedPaths = policy.protectedPaths.joined(separator: "\n")
    } catch { notice = error.localizedDescription }
  }
  var candidates: [DiskCandidate] {
    inventory.candidates.filter { $0.bytes >= DiskCandidate.minimumReviewBytes }.map { candidate in
      var current = candidate
      current.userRule = policy.rules.first(where: { $0.path == candidate.path })?.disposition ?? "review"
      return current
    }.sorted { a, b in
      if (a.userRule == "keep") != (b.userRule == "keep") { return b.userRule == "keep" }
      if (a.decision == "recommend") != (b.decision == "recommend") { return a.decision == "recommend" }
      return a.bytes > b.bytes
    }
  }
  func refreshInventory() {
    do {
      let store = try Store(root: root); inventory = try DiskSnapshot.load(store)
      if let data = try? store.read(root.appendingPathComponent("machine-review-state.json"), limit: 65536),
        let state = try? JSONDecoder().decode(MachineReviewState.self, from: data) {
        reviewStatus = state.phase == "paused" ? state.detail : ""
      }
    } catch { notice = error.localizedDescription }
  }
  func save() {
    func paths(_ value: String) -> [String] { Array(Set(value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted() }
    policy.roots = paths(roots); policy.protectedPaths = paths(protectedPaths)
    do { try policy.save(Store(root: root)); notice = "Saved. New recommendations will appear after the next scan and scheduled review." }
    catch { notice = error.localizedDescription }
  }
  func rule(_ candidate: DiskCandidate, _ disposition: String) {
    if disposition == "regenerable" { policy.mode = "automatic" }
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
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Make room for your next run.").font(.headline)
            if settings.inventory.freeBytes > 0 {
              Text("\(ImpactNumbers.bytes(settings.inventory.freeBytes)) free · goal \(settings.policy.targetFreeGB) GB")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button { settings.refreshInventory() } label: { Image(systemName: "arrow.clockwise") }.clickPointer().help("Refresh recommendations")
        }
        Text("Your AI recommends what to clear and what to keep. Only items of 10 GB or more appear here.")
          .font(.caption).foregroundStyle(.secondary)
        if settings.policy.mode == "off" { Text("Disk review is off. Enable it in Advanced.").font(.callout) }
        else if !settings.reviewStatus.isEmpty { Text(settings.reviewStatus).font(.caption).foregroundStyle(.orange) }
        if settings.candidates.isEmpty {
          Label("No items of 10 GB or more in the latest scan.", systemImage: "checkmark.circle")
            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
        }
        ForEach(settings.candidates.prefix(6)) { candidate in recommendation(candidate) }
        if let notice = settings.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        DisclosureGroup(isExpanded: $settings.advanced) { advanced.padding(.top, 14) } label: {
          Text("Advanced").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }.disclosureGroupStyle(ClickDisclosureStyle())
      }.padding(.top, 14)
    } label: { Label("Disk cleanup", systemImage: "externaldrive").font(.callout.weight(.medium)) }.disclosureGroupStyle(ClickDisclosureStyle())
    .padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    .confirmationDialog("Approve cleanup of this folder?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
      Button("Approve cleanup", role: .destructive) { if let candidate = confirm { settings.rule(candidate, "regenerable") }; confirm = nil }.clickPointer()
    } message: {
      Text("\(confirm?.path ?? "")\n\nConfirm its contents are replaceable output. This enables automatic cleanup for approved folders. Your AI and fresh safety checks must still approve each removal. Useful evidence, active work and incomplete visibility remain protected.")
    }
    .task(id: settings.expanded) {
      guard settings.expanded else { return }
      settings.refreshInventory()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(15)) } catch { return }
        settings.refreshInventory()
      }
    }
    .accessibilityIdentifier("disk-cleanup-settings")
  }
  private func recommendation(_ candidate: DiskCandidate) -> some View {
    let fresh = candidate.reviewable || candidate.recommendationEligible == true
    return
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .firstTextBaseline) {
        Text(ImpactNumbers.bytes(candidate.bytes)).font(.title3.weight(.semibold)).foregroundStyle(orange)
        Spacer()
        Text(candidate.userRule == "keep" ? "Kept by you" : !fresh ? "Protected" : candidate.decision == "recommend" ? "AI suggests cleanup" : candidate.decision == "keep" ? "AI suggests keeping" : "Awaiting AI review")
          .font(.caption.weight(.medium)).foregroundStyle(.secondary)
      }
      let url = URL(fileURLWithPath: candidate.path)
      Text(url.deletingLastPathComponent().lastPathComponent + " / " + url.lastPathComponent)
        .font(.callout.weight(.medium)).lineLimit(2).help(candidate.path)
      Text(candidate.userRule == "keep" ? "This folder is protected by your preference." : fresh ? candidate.rationale ?? candidate.guardReason : candidate.guardReason).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if candidate.userRule == "keep" {
          Button("Reconsider") { settings.rule(candidate, "review") }.clickPointer()
        } else {
          Button("Keep") { settings.rule(candidate, "keep") }.clickPointer()
        }
        Spacer()
        if candidate.userRule == "regenerable" {
          Label("Approved · safety checks still apply", systemImage: "checkmark.shield").font(.caption2).foregroundStyle(.secondary)
        } else if fresh, candidate.userRule != "keep", candidate.decision == "recommend", candidate.kind != "worktree" {
          Button("Approve cleanup…") { confirm = candidate }.clickPointer().buttonStyle(.borderedProminent).tint(orange)
        }
      }.font(.caption)
    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }
  private var advanced: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Disk cleanup", selection: $settings.policy.mode) {
        Text("Recommend").tag("recommend"); Text("Automatic").tag("automatic"); Text("Off").tag("off")
      }.clickPointer().accessibilityIdentifier("disk-mode")
      Picker("Aggressiveness", selection: $settings.preset) {
        Text("Custom").tag("custom"); Text("Conservative").tag("conservative"); Text("Balanced").tag("balanced"); Text("Proactive").tag("proactive")
      }.clickPointer().onChange(of: settings.preset) { _, value in settings.policy.preset(value) }
      Stepper("Keep at least \(settings.policy.minimumAgeDays) days", value: $settings.policy.minimumAgeDays, in: 1...90).clickPointer()
      Stepper("Keep newest \(settings.policy.keepNewest) evidence runs", value: $settings.policy.keepNewest, in: 1...20).clickPointer()
      Stepper("Scan every \(settings.policy.scanHours) hours", value: $settings.policy.scanHours, in: 1...24).clickPointer()
      Stepper("Free-space goal: \(settings.policy.targetFreeGB) GB", value: $settings.policy.targetFreeGB, in: 10...1000, step: 10).clickPointer()
      Stepper("Remove at most \(settings.policy.maximumGBPerDay) GB / day", value: $settings.policy.maximumGBPerDay, in: 1...500).clickPointer()
      field("Folders to inspect", value: $settings.roots, height: 50)
      field("Always protect", value: $settings.protectedPaths, height: 44)
      field("Preferences for your AI", value: $settings.policy.instructions, height: 65)
      HStack { Button("Reload") { settings.reload() }.clickPointer(); Spacer(); Button("Save settings") { settings.save() }.clickPointer().buttonStyle(.borderedProminent).tint(orange) }
      Text("Age and size never grant removal permission. Incomplete visibility blocks cleanup. Existing worktrees stay with their owning manager.")
        .font(.caption).foregroundStyle(.secondary)
      if !settings.policy.rules.isEmpty {
        Text("Saved preferences").font(.caption.weight(.semibold))
        ForEach(settings.policy.rules) { rule in
          HStack {
            Text("\(rule.disposition) · \(rule.path)").font(.caption).lineLimit(2)
            Spacer()
            Button("Forget") { settings.policy.rules.removeAll { $0.path == rule.path }; settings.save() }.clickPointer()
          }.font(.caption)
        }
      }
      Text(settings.inventory.detail).font(.caption2).foregroundStyle(.secondary)
      Text("Advice uses the same limited background reviewer, with up to three large items per review. Unchanged recommendations are reused. Local scans use no model tokens.").font(.caption2).foregroundStyle(.secondary)
    }
  }
  private func field(_ title: String, value: Binding<String>, height: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.weight(.medium)); TextEditor(text: value).font(.caption.monospaced()).frame(height: height).padding(5).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15))) }
  }
}
