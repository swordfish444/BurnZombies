import AppKit
import BurnCore
import SwiftUI

struct WorktreesView: View {
  @ObservedObject var model: AppModel
  @State private var inventory = WorktreeReply()
  @State private var selected = Set<String>()
  @State private var batchReview: WorktreeReply?
  @State private var finish: WorktreeOperation?
  @State private var search = ""
  @State private var tab = "Worktrees"
  @State private var working = false
  @State private var scanning = false
  @State private var loading = false
  @State private var localDiff: String?
  @State private var message: String?
  @State private var confirmation: WorktreeRecord?
  @State private var completion = ""
  @State private var dirtyAction = false
  @State private var purge: WorktreeOperation?
  init(model: AppModel, initial: WorktreeReply? = nil, initialTab: String = "Worktrees", selectedID: String? = nil) {
    self.model = model
    let value = initial ?? (model.demo ? WorktreeExamples.snapshot() : WorktreeReply())
    _inventory = State(initialValue: value); _tab = State(initialValue: initialTab)
    _selected = State(initialValue: selectedID.map { Set([$0]) } ?? [])
  }
  var rows: [WorktreeRecord] {
    inventory.records.filter { search.isEmpty || ($0.path + ($0.branch ?? "") + $0.state).localizedCaseInsensitiveContains(search) }
      .sorted {
        let rank = ["Ready to retire": 0, "Possibly stale": 1, "Contains local work": 2, "Needs review": 3, "Inspection blocked": 4, "Missing or moved": 5, "Active": 6, "Retired / recoverable": 7]
        return (rank[$0.state] ?? 8, $0.path) < (rank[$1.state] ?? 8, $1.path)
      }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(BurnTheme.orange)
        Text("Worktrees").font(.title2.bold())
        Spacer()
        if working { ProgressView().controlSize(.small) }
        if scanning { Button("Cancel scan") { Task { _ = try? await model.worktree(.init("cancel_scan")) } } }
        Button("Add folder…", action: addRoot).disabled(working)
        Button("Scan") { run(.init("scan")) }.disabled(working || !model.accessReady)
      }.padding(20)
      Picker("View", selection: $tab) { Text("Worktrees").tag("Worktrees"); Text("Recovery").tag("Recovery") }
        .pickerStyle(.segmented).frame(width: 260).padding(.bottom, 16)
      DisclosureGroup("Discovery folders") {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(inventory.policy.roots, id: \.self) { path in
            HStack { Text(path).font(.caption.monospaced()).textSelection(.enabled); Spacer(); Button("Remove") { run(.init("remove_root", path: path)) }.disabled(working) }
          }
          ForEach(inventory.suggestedRoots, id: \.self) { path in
            HStack { Text("Suggested from disk settings: " + path).font(.caption); Spacer(); Button("Add") { run(.init("add_root", path: path), thenScan: true) }.disabled(working) }
          }
          Button("Check recovery key…") { run(.init("check_key")) }
          Text("Adding a discovery folder grants no management or removal permission.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
      }.padding(.horizontal, 20).padding(.bottom, 10)
      if model.demo { Text("Synthetic preview · no files are changed").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8) }
      if let error = model.state.worktreeError { Text(error).foregroundStyle(.orange).padding() }
      if !model.accessReady { Text(model.state.fullDiskAccess.detail).foregroundStyle(.orange).padding() }
      if tab == "Worktrees" {
        HSplitView {
          VStack(alignment: .leading, spacing: 0) {
            TextField("Search repository, branch or state", text: $search).textFieldStyle(.roundedBorder).padding(12)
            if rows.isEmpty {
              ContentUnavailableView("No worktrees discovered", systemImage: "folder.badge.questionmark",
                description: Text("Add a repository folder or its parent, then scan. Discovery does not grant cleanup permission."))
            } else {
              List(selection: $selected) {
                ForEach(Array(Set(rows.map(\.repository))).sorted(), id: \.self) { repository in
                  Section(URL(fileURLWithPath: repository).deletingLastPathComponent().lastPathComponent) {
                    ForEach(rows.filter { $0.repository == repository }) { row in
                      VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(URL(fileURLWithPath: row.path).lastPathComponent).fontWeight(.semibold); Spacer(); if row.kept { Image(systemName: "pin.fill") } }
                        Text(row.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached HEAD").font(.caption).foregroundStyle(.secondary)
                        Text(row.state).font(.caption).foregroundStyle(row.state == "Ready to retire" ? .green : .secondary)
                      }.padding(.vertical, 5).tag(row.id)
                    }
                  }
                }
              }.listStyle(.sidebar)
            }
          }.frame(minWidth: 320, idealWidth: 380)
          ScrollView {
            if let row = inventory.records.first(where: { $0.id == selected.first }) { detail(row) }
            else { ContentUnavailableView("Select a worktree", systemImage: "arrow.left", description: Text("See its evidence, local work, inspection gaps and recovery options.")).padding(.top, 90) }
          }.frame(minWidth: 460)
        }
      } else { recovery }
      if !selected.isEmpty && tab == "Worktrees" {
        Button("Review \(selected.count) selected worktree(s)…") { reviewBatch() }.disabled(working).padding(8)
      }
      Divider()
      VStack(alignment: .leading, spacing: 5) {
        if let message { Text(message).textSelection(.enabled) }
        ForEach(inventory.gaps.prefix(3), id: \.self) { Text($0).foregroundStyle(.orange) }
        Text("\(inventory.records.count) shown · discovery, retirement and recovery retention have separate permissions")
          .foregroundStyle(.secondary)
      }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }.background(Color(red: 0.035, green: 0.035, blue: 0.04)).foregroundStyle(BurnTheme.cream).preferredColorScheme(.dark)
      .task { await load() }
      .onReceive(model.$state) { state in if !working && !model.demo && state.worktrees != nil { Task { await load() } } }
      .alert(dirtyAction ? "Archive and retire this checkout?" : "Retire this clean checkout?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
        TextField("Observed completion and why it is no longer needed", text: $completion)
        Button("Cancel", role: .cancel) { confirmation = nil }
        if dirtyAction {
          Button("Archive and quarantine") { if let row = confirmation { retire(row, dirty: true, quarantine: true) }; confirmation = nil }.disabled(completion.count < 20)
        }
        Button(dirtyAction ? "Archive and retire immediately" : "Retire", role: .destructive) {
          if let row = confirmation { retire(row, dirty: dirtyAction) }; confirmation = nil
        }.disabled(completion.count < 20)
      } message: {
        Text("\(confirmation?.path ?? "")\nAn encrypted recovery copy will be restored and verified before removal. Recovery depends on this Mac's Keychain key. Active consumers and inspection gaps still block the action.")
      }
      .sheet(isPresented: Binding(get: { batchReview != nil }, set: { if !$0 { batchReview = nil } })) {
        VStack(alignment: .leading, spacing: 16) {
          Text("Review exact retirement targets").font(.title2.bold())
          Text("Changed or blocked items are skipped. Each removal receives an independent recovery archive.").foregroundStyle(.secondary)
          List(batchReview?.batch ?? []) { item in
            VStack(alignment: .leading, spacing: 6) { Text(item.path).font(.caption.monospaced()); Text(item.detail).foregroundStyle(item.ready ? .green : .orange) }
          }.frame(minHeight: 250)
          HStack {
            Button("Cancel") { batchReview = nil }; Spacer()
            Button("Retire ready worktrees", role: .destructive) {
              let token = batchReview?.token; batchReview = nil; run(.init("batch_retire", token: token))
            }.disabled(!(batchReview?.batch.contains { $0.ready } ?? false))
          }
        }.padding(24).frame(width: 720, height: 430).preferredColorScheme(.dark)
      }
      .sheet(isPresented: Binding(get: { localDiff != nil }, set: { if !$0 { localDiff = nil } })) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Local changes").font(.title2.bold())
          ScrollView { Text(localDiff ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          Button("Close") { localDiff = nil }
        }.padding(24).frame(width: 800, height: 600).preferredColorScheme(.dark)
      }
      .alert("Retire this quarantined checkout now?", isPresented: Binding(get: { finish != nil }, set: { if !$0 { finish = nil } })) {
        Button("Keep quarantine", role: .cancel) { finish = nil }
        Button("Retire now", role: .destructive) {
          if let op = finish { run(.init("finish_quarantine", id: op.id, revision: op.archiveDigest, evidence: "RETIRE QUARANTINE NOW")) }; finish = nil
        }
      } message: { Text("The seven-day grace is recommended. This explicit action removes the checkout after fresh safety and recovery checks. Its encrypted archive stays available.") }
      .alert("Permanently purge this recovery archive?", isPresented: Binding(get: { purge != nil }, set: { if !$0 { purge = nil } })) {
        Button("Cancel", role: .cancel) { purge = nil }
        Button("Purge recovery", role: .destructive) { if let op = purge { run(.init("purge", id: op.id, evidence: "PURGE RECOVERY")) }; purge = nil }
      } message: { Text("This removes the independent archive. It may be the only complete copy of local files. Original Git recovery refs are retained.") }
  }
  @ViewBuilder func detail(_ row: WorktreeRecord) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(URL(fileURLWithPath: row.path).lastPathComponent).font(.title.bold())
      Text(row.state).font(.headline).foregroundStyle(BurnTheme.orange)
      Text(row.path).font(.caption.monospaced()).textSelection(.enabled)
      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
        GridRow { Text("Branch").foregroundStyle(.secondary); Text(row.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached HEAD") }
        GridRow { Text("Local changes").foregroundStyle(.secondary); Text("\(row.changes) changed entries · \(row.ignored) ignored entries") }
        GridRow { Text("Footprint").foregroundStyle(.secondary); Text(ImpactNumbers.bytes(row.allocated)) }
        GridRow { Text("Consumers").foregroundStyle(.secondary); Text(row.consumer) }
        if let commit = row.lastCommitAt { GridRow { Text("Last commit").foregroundStyle(.secondary); Text(commit.formatted()) } }
        if let file = row.lastFileChange { GridRow { Text("Newest file change").foregroundStyle(.secondary); Text(file.formatted()) } }
        GridRow { Text("Observed").foregroundStyle(.secondary); Text(row.observedAt.formatted()) }
        GridRow { Text("Management").foregroundStyle(.secondary); Text(row.managed ? "Explicitly managed" : "Observed only") }
      }.font(.callout)
      if let days = row.apparentIdleDays { Text("File/commit metadata suggests \(days) day(s) without a change. This is a review hint, not a last-used date or retirement permission.").font(.caption).foregroundStyle(.secondary) }
      if row.blockers.isEmpty && row.gaps.isEmpty { Text("No mechanical blockers found in this inspection. Completion and retirement authority are checked separately.").foregroundStyle(.secondary) }
      ForEach(row.blockers + row.gaps, id: \.self) { reason in Label(reason, systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
      ForEach(inventory.delivery.filter { $0.id == row.id }, id: \.id) { delivery in
        VStack(alignment: .leading, spacing: 6) {
          Text(delivery.detail).font(.caption).foregroundStyle(.secondary)
          Text("Metadata observed \(delivery.observedAt.formatted())").font(.caption2)
          ForEach(delivery.requests, id: \.number) { pr in
            if let url = URL(string: pr.url) { Link("PR #\(pr.number): \(pr.state) · \(pr.headMatches ? "matching head" : "different PR head")", destination: url).font(.caption) }
          }
        }
      }
      ForEach(inventory.advice.filter { $0.id == row.id }) { advice in
        Text(advice.summary).font(.callout)
        Label(advice.nextStep, systemImage: "arrow.right.circle").font(.callout).foregroundStyle(BurnTheme.orange)
      }
      ForEach(inventory.owners.filter { $0.worktreeID == row.id }, id: \.id) { owner in
        VStack(alignment: .leading, spacing: 4) {
          Text("Owner: \(owner.label) · \(owner.state)").font(.caption.bold())
          Text(owner.condition).font(.caption); Text(owner.evidence).font(.caption).foregroundStyle(.secondary)
          Text("Owner evidence updated \(owner.updated.formatted())").font(.caption2).foregroundStyle(.secondary)
        }
      }
      HStack {
        Button("Inspect") { run(.init("inspect", id: row.id)) }
        if !row.missing && !row.retired {
          Button("View local changes") {
            working = true
            Task {
              do { localDiff = try await model.worktree(.init("diff", id: row.id, revision: row.revision)).detail }
              catch { message = error.localizedDescription }; working = false
            }
          }
        }
        Button("Refresh PR metadata") { run(.init("refresh_delivery", id: row.id, revision: row.revision)) }
      }
      HStack {
        Button(row.kept ? "Unkeep" : "Keep") { run(.init(row.kept ? "unkeep" : "keep", id: row.id, revision: row.revision)) }
        if !row.managed && !row.main && !row.ownerManaged && !row.retired {
          Button("Manage this worktree") { run(.init("adopt", id: row.id, revision: row.revision)) }
        }
      }
      if row.missing && !row.ownerManaged {
        HStack {
          Button("Review registration maintenance") { run(.init("registration_advice", id: row.id, revision: row.revision)) }
          Button("Locate moved checkout…") { repair(row) }
        }
      }
      if row.managed && !row.retired {
        HStack {
          Button("Rescue local work") { run(.init("rescue", id: row.id, revision: row.revision)) }
          Button(row.changes + row.ignored > 0 ? "Archive and retire…" : "Retire…") {
            dirtyAction = row.changes + row.ignored > 0; completion = ""; confirmation = row
          }.tint(BurnTheme.orange)
        }
        Toggle("Allow automatic clean retirement for this repository", isOn: Binding(
          get: { inventory.policy.automaticRepositories.contains(row.repository) },
          set: { run(.init("automatic", id: row.id, revision: row.revision, enabled: $0)) }))
        Text("Automatic retirement also requires released owners, a 24-hour grace, fresh checks, independent recovery and the shared automatic disk policy. Dirty retirement stays manual.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if row.retired { Button("View recovery") { tab = "Recovery" } }
    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).disabled(working)
  }
  var recovery: some View {
    List(inventory.operations, id: \.id) { op in
      VStack(alignment: .leading, spacing: 8) {
        HStack { Text(URL(fileURLWithPath: op.originalPath).lastPathComponent).font(.headline); Spacer(); Text(op.phase).foregroundStyle(op.phase == "completed" || op.phase == "rescued" ? .green : .orange) }
        Text(op.detail).font(.callout)
        Text("Archive: \(ImpactNumbers.bytes(op.archiveBytes)) · credited disk: \(ImpactNumbers.bytes(op.diskCredit)) · \(op.date.formatted())").font(.caption).foregroundStyle(.secondary)
        HStack {
          if op.phase == "uncertain" { Button("Reconcile recovery") { run(.init("reconcile", id: op.id, evidence: "RECONCILE RECOVERY")) } }
          if op.archiveDigest != nil && !op.purged {
            Button("Restore to new folder…") { restore(op) }
            if op.phase == "quarantined" { Button("Retire quarantine…") { finish = op } }
            if ["completed", "rescued", "failed", "reconciled-absent"].contains(op.phase) { Button("Purge recovery…", role: .destructive) { purge = op } }
          }
          if op.purgePending == true { Text("Purge was interrupted. Verify recovery or explicitly finish purging.").foregroundStyle(.orange) }
          if op.purged { Text("Independent archive purged").foregroundStyle(.secondary) }
        }
        ForEach(inventory.restores.filter { $0.recoveryID == op.id && $0.phase != "completed" }) { attempt in
          Text(attempt.detail + " Destination: " + attempt.destination).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if !op.restoredPaths.isEmpty { Text("Restored: " + op.restoredPaths.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
      }.padding(10).disabled(working)
    }.overlay { if inventory.operations.isEmpty { ContentUnavailableView("No recovery items", systemImage: "arrow.uturn.backward", description: Text("Verified snapshots and retirement receipts will appear here.")) } }
  }
  func addRoot() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { run(.init("add_root", path: WorkspaceSafety.canonical(url.path)), thenScan: true) }
  }
  func repair(_ row: WorktreeRecord) {
    let panel = NSOpenPanel(); panel.title = "Locate the moved checkout to repair its exact registration"
    panel.canChooseDirectories = true; panel.canChooseFiles = false
    if panel.runModal() == .OK, let url = panel.url { run(.init("repair", id: row.id, revision: row.revision, path: WorkspaceSafety.canonical(url.path))) }
  }
  func restore(_ op: WorktreeOperation) {
    let panel = NSSavePanel(); panel.title = "Restore as a new directory"; panel.nameFieldStringValue = URL(fileURLWithPath: op.originalPath).lastPathComponent + "-restored"
    if panel.runModal() == .OK, let url = panel.url { run(.init("restore", id: op.id, path: WorkspaceSafety.canonical(url.path))) }
  }
  func run(_ q: WorktreeRequest, thenScan: Bool = false) {
    working = true
    scanning = q.action == "scan" || thenScan
    Task {
      let polling = Task {
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 500_000_000)
          if !Task.isCancelled && (q.action == "scan" || thenScan) { await load() }
        }
      }
      defer { polling.cancel() }
      do { let result = try await model.worktree(q); if thenScan { _ = try await model.worktree(.init("scan")) }; await load(); message = result.detail }
      catch { await load(); message = error.localizedDescription }; working = false; scanning = false }
  }
  func retire(_ row: WorktreeRecord, dirty: Bool, quarantine: Bool = false) {
    working = true
    Task {
      do {
        _ = try await model.worktree(.init("confirm", id: row.id, revision: row.revision, evidence: completion))
        let preview = try await model.worktree(.init(dirty ? "preview_dirty" : "preview", id: row.id, revision: row.revision))
        inventory = try await model.worktree(.init(quarantine ? "quarantine" : (dirty ? "retire_dirty" : "retire"), token: preview.token)); tab = "Recovery"; message = inventory.detail
        await load()
      } catch { message = error.localizedDescription }
      working = false
    }
  }
  func reviewBatch() {
    working = true
    let chosen = inventory.records.filter { selected.contains($0.id) }
    Task {
      do { batchReview = try await model.worktree(.init("batch_preview", ids: chosen.map(\.id), revisions: Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.revision) }))) }
      catch { message = error.localizedDescription }
      working = false
    }
  }
  func load() async {
    if model.demo || loading { return }
    loading = true; defer { loading = false }
    do {
      inventory = try await model.worktree(.init("list"))
      while let offset = inventory.nextOffset {
        let page = try await model.worktree(.init("list", offset: offset))
        inventory.records += page.records; inventory.owners += page.owners; inventory.advice += page.advice; inventory.delivery += page.delivery; inventory.nextOffset = page.nextOffset
      }
      while let offset = inventory.nextOperationOffset {
        let page = try await model.worktree(.init("operations", offset: offset))
        inventory.operations += page.operations; inventory.nextOperationOffset = page.nextOperationOffset
      }
    } catch { message = error.localizedDescription }
  }
}
