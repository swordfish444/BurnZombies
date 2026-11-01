import BurnCore
import SwiftUI

struct FindingsView: View {
  @ObservedObject var model: AppModel
  @State private var search = ""
  @State private var offset = 0
  @State private var loadedPage: FindingsSnapshot?
  @State private var selectedFinding: CleanupProposal?
  var inbox: FindingsSnapshot { offset == 0 ? model.state.inbox : loadedPage ?? FindingsSnapshot() }
  @State private var rule: CleanupProposal?
  @State private var cap = 1
  @State private var shadow = true
  @State private var worktreeConfirmation: CleanupProposal?
  @State private var history: [CleanupDecision] = []
  @State private var expiry = Date().addingTimeInterval(30 * 86400)
  var proposals: [CleanupProposal] {
    inbox.proposals.filter {
      search.isEmpty
        || ($0.title + $0.detail + $0.state + ($0.path ?? "")).localizedCaseInsensitiveContains(
          search)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Findings").font(.title.bold())
        Spacer()
        Button("Worktrees") { model.openWorktrees?() }
        Button("Hunt now") { model.requestAgentCleanup() }
      }
      Text(
        "\(model.state.processCount) visible processes · \(model.state.worktreeError == nil ? String(model.state.worktrees?.totalRecords ?? 0) : "unknown") discovered worktrees · \(model.state.inbox.proposals.filter { $0.ready && $0.state == "review" && $0.observed >= Date().addingTimeInterval(-300) }.count) ready on the first page"
      )
      .font(.callout).foregroundStyle(.secondary)
      if let coverage = model.state.passiveCoverage {
        Text(coverage).font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.state.inbox.error {
        Text(error).foregroundStyle(.orange)
        Button("Reconcile saved recovery feedback") { model.reconcileFindingFeedback() }
      }
      if let error = model.state.worktreeError { Text(error).foregroundStyle(.orange) }
      HSplitView {
        VStack {
          TextField("Search findings", text: $search).textFieldStyle(.roundedBorder)
          HStack {
            Button("Previous") { offset = max(0, offset - 1000) }.disabled(offset == 0)
            Text(
              "\(offset + 1)–\(offset + inbox.proposals.count) of \(model.state.inbox.totalProposals)"
            ).font(.caption)
            Button("Next") { offset += 1000 }.disabled(
              offset + inbox.proposals.count >= model.state.inbox.totalProposals)
          }
          List(proposals, selection: $model.findingSelection) { p in
            VStack(alignment: .leading, spacing: 5) {
              Text(p.title).fontWeight(.semibold)
              Text(
                p.state == "review"
                  ? (p.ready && p.observed >= Date().addingTimeInterval(-300)
                    ? "Needs your decision" : "Inspect or refresh evidence") : p.state.capitalized
              )
              .font(.caption).foregroundStyle(p.state == "kept" ? .green : .secondary)
              if p.fixture {
                Text("Test fixture · excluded from real impact").font(.caption).foregroundStyle(
                  .orange)
              }
            }.padding(.vertical, 5).tag(p.id)
          }
        }.frame(minWidth: 300)
        ScrollView {
          if let p = selectedFinding?.id == model.findingSelection
            ? selectedFinding : inbox.proposals.first(where: { $0.id == model.findingSelection })
          {
            detail(p)
          } else {
            ContentUnavailableView(
              "Review what was found", systemImage: "magnifyingglass",
              description: Text(
                "Select a finding to see its evidence, protection and recovery options. Discovery alone never authorizes removal."
              ))
          }
        }.frame(minWidth: 450)
      }
      DisclosureGroup("Notifications and workflow rules") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Notify me about findings",
            isOn: Binding(
              get: { model.state.catalog.preferences.notifications }, set: model.setNotifications))
          Stepper(
            "At most \(model.state.catalog.preferences.notificationBudget ?? 3) prompts per day, plus one initial digest",
            value: Binding(
              get: { model.state.catalog.preferences.notificationBudget ?? 3 },
              set: model.setNotificationBudget), in: 1...5)
          Toggle(
            "Show target details and eligible approval actions in notifications",
            isOn: Binding(
              get: { model.state.catalog.preferences.notificationDetails == true },
              set: model.setNotificationDetails))
          Text(
            "Default notifications show no target details. Missed or ignored notifications never approve cleanup."
          ).font(.caption).foregroundStyle(.secondary)
          Toggle(
            "Use my scoped decisions in AI reviews",
            isOn: Binding(
              get: { model.state.catalog.preferences.shareDecisionHistory != false },
              set: model.setDecisionSharing))
          ForEach(model.state.inbox.rules) { r in
            HStack {
              VStack(alignment: .leading) {
                Text(r.title).font(.caption)
                Text(
                  "\(r.enabled ? (r.shadow == true ? "Shadow only — never executes" : "Enabled") : "Paused") · at most \(r.maximumPerDay)/day · expires \(r.expires.formatted(date: .abbreviated, time: .omitted)) · \(r.canaryVerified ? "canary verified" : "one-item canary pending")"
                ).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Pause") { model.pauseRule(r) }.disabled(!r.enabled)
            }
          }
          if model.state.inbox.legacyAuthority {
            Text(
              "Existing cleanup permissions were retained with their original native ownership, retention and protection requirements. Keep and new workflow limits apply to every route."
            ).font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.top, 6)
      }
      if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
    }.padding(20).preferredColorScheme(.dark)
      .task(id: offset) { if offset > 0 { loadedPage = await model.findingPage(offset) } }
      .task(id: model.findingSelection) { await reloadSelectedFinding() }
      .onReceive(model.$state) { _ in Task { await reloadSelectedFinding() } }
      .sheet(item: $worktreeConfirmation) { p in
        VStack(alignment: .leading, spacing: 16) {
          Text("Manage, preserve and retire this checkout?").font(.title2.bold())
          Text(p.path ?? p.title).textSelection(.enabled)
          Text(p.detail).textSelection(.enabled)
          Text(p.recovery)
          Text(
            "This is a one-time decision for this exact revision. It grants no permission for other checkouts. Active owners or changed contents will stop the action."
          ).foregroundStyle(.secondary)
          HStack {
            Button("Cancel") { worktreeConfirmation = nil }
            Spacer()
            Button("Adopt, archive and retire once", role: .destructive) {
              model.decideFinding(p, decision: "approve")
              worktreeConfirmation = nil
            }
          }
        }.padding(24).frame(width: 620)
      }
      .sheet(item: $rule) { p in
        VStack(alignment: .leading, spacing: 16) {
          Text("Enable this exact workflow?").font(.title2.bold())
          Text(p.workflowDetail ?? p.detail).textSelection(.enabled)
          Text(p.recovery).foregroundStyle(.secondary)
          Text("Current matching examples and exclusions").font(.headline)
          ForEach(model.state.inbox.proposals.filter { $0.workflow == p.workflow }.prefix(8)) {
            match in
            Text(
              "\(match.title): \(match.ready ? "would match current native evidence" : "blocked — " + match.detail)"
            ).font(.caption)
          }
          Toggle("Shadow only: show matches without allowing automatic cleanup", isOn: $shadow)
          Stepper("At most \(cap) actions per day", value: $cap, in: 1...10)
          DatePicker(
            "Expires", selection: $expiry, in: Date()...Date().addingTimeInterval(365 * 86400),
            displayedComponents: .date)
          Text(
            "Starts with one item. Current native safety checks and independent AI review remain required. Success never expands this scope or cap."
          ).font(.callout)
          HStack {
            Button("Cancel") { rule = nil }
            Spacer()
            Button(shadow ? "Save shadow rule" : "Enable exact rule") {
              model.grantRule(p, cap: cap, expires: expiry, shadow: shadow)
              rule = nil
            }
          }
        }.padding(24).frame(width: 600)
      }
  }
  private func reloadSelectedFinding() async {
    guard let id = model.findingSelection else {
      selectedFinding = nil
      return
    }
    let current = await model.findingDetail(id)
    if model.findingSelection == id { selectedFinding = current }
  }
  @ViewBuilder func detail(_ p: CleanupProposal) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(p.title).font(.title2.bold())
      Text(p.detail).textSelection(.enabled)
      if let path = p.path { Text(path).font(.caption.monospaced()).textSelection(.enabled) }
      if p.bytes > 0 {
        Text(
          ByteCountFormatter.string(fromByteCount: Int64(clamping: p.bytes), countStyle: .file)
            + " observed footprint; not guaranteed recovery."
        ).foregroundStyle(.secondary)
      }
      Text(p.recovery).foregroundStyle(.secondary)
      Text("Observed \(p.observed.formatted(date: .abbreviated, time: .shortened))").font(.caption)
      Button("Refresh this finding’s evidence") { Task { await model.refreshFinding(p.id) } }
      if p.observed < Date().addingTimeInterval(-300) {
        Text("Evidence needs refreshing before approval.").foregroundStyle(.orange)
      }
      if p.action == .worktree, let key = p.resources.first {
        Button("Inspect worktree, owners and recovery…") {
          model.openWorktreeID?(String(key.dropFirst(9)))
        }
      }
      if p.state == "kept" {
        Button("Clear Keep and review again") { model.decideFinding(p, decision: "clear-keep") }
      } else if p.operationID == nil {
        HStack {
          Button(
            p.action == .ownerStop
              ? "Stop when idle"
              : p.action == .worktree ? "Adopt, archive and retire once" : "Approve once",
            role: .destructive
          ) {
            if p.action == .worktree {
              worktreeConfirmation = p
            } else {
              model.decideFinding(p, decision: "approve")
            }
          }
          .disabled(
            !p.ready || p.observed < Date().addingTimeInterval(-300)
              || model.findingBusy.contains(p.id))
          Button("Keep") { model.decideFinding(p, decision: "keep") }
          Button("Tomorrow") { model.decideFinding(p, decision: "snooze") }
        }
      } else {
        Text("Operation: \(p.state). Only verified native receipts count as cleanup.").font(
          .callout)
        Button("I needed this — pause its workflow") {
          model.decideFinding(
            p, decision: "needed", reason: "Operator reported this resource was needed.")
        }
      }
      if p.action == .ownerStop, p.ready, p.workflow != nil {
        Button("Review recurring rule…") {
          cap = 1
          shadow = true
          rule = p
        }

        Text(
          "Matching history: \(history.filter { $0.decision == "approve" }.count) approvals, \(history.filter { $0.decision == "keep" }.count) keeps. These are decisions, not a safety probability."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(history.prefix(12)) { event in
          Text(
            "\(event.date.formatted(date: .abbreviated, time: .shortened)) · \(event.decision) · \(event.reason)"
          ).font(.caption)
        }
        Button("Forget workflow preferences and pause its automation", role: .destructive) {
          if let workflow = p.workflow {
            model.forgetWorkflow(workflow)
            history = []
          }
        }
      }
    }.task(id: p.id) {
      if let workflow = p.workflow {
        history = await model.findingHistory(workflow)
      } else {
        history = []
      }
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
  }
}
