import AppKit
import BurnCore
import SwiftUI

@MainActor final class BurnPitModel: ObservableObject {
  @Published private(set) var snapshot: BlazerMap?
  @Published private(set) var scanning = false

  init(snapshot: BlazerMap? = nil) {
    self.snapshot = snapshot
  }

  func refreshIfNeeded(now: Date = Date()) {
    if let snapshot, now.timeIntervalSince(snapshot.observedAt) < 60 { return }
    refresh()
  }

  func refresh() {
    guard !scanning else { return }
    scanning = true
    Task {
      let result = await Task.detached(priority: .utility) { BlazerMap.scan() }.value
      snapshot = result
      scanning = false
    }
  }
}

struct BurnPitWindow: View {
  @ObservedObject var model: BurnPitModel
  @State private var layer: BurnPitLayer = .all
  @State private var search = ""
  @State private var ledger = false
  @State private var selection: String?
  @State private var coverage = false

  static let minimumSize = NSSize(width: 800, height: 550)

  @MainActor static func makeWindow(model: BurnPitModel) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "BurnZombies — Burn Pit"
    window.isReleasedWhenClosed = false
    window.contentMinSize = minimumSize
    let host = NSHostingView(rootView: BurnPitWindow(model: model))
    host.sizingOptions = []
    window.contentView = host
    window.center()
    return window
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if let snapshot = model.snapshot {
        dashboard(snapshot)
      } else {
        VStack(spacing: 12) {
          ProgressView().controlSize(.regular)
          Text("Reading the local snapshot…").font(.callout)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .combine)
      }
    }
    .padding(22)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(BurnTheme.cream)
    .background {
      RadialGradient(
        colors: [Color(red: 0.22, green: 0.105, blue: 0.055), Color(red: 0.075, green: 0.045, blue: 0.034)],
        center: .topLeading, startRadius: 8, endRadius: 810)
    }
    .preferredColorScheme(.dark)
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(systemName: "flame.fill")
        .font(.system(size: 24, weight: .medium))
        .foregroundStyle(.orange.gradient)
        .frame(width: 46, height: 46)
        .background(BurnTheme.orange.opacity(0.12), in: .rect(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(BurnTheme.orange.opacity(0.3)) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text("BURNZOMBIES / BLAZER EDITION").font(.system(size: 10, weight: .bold, design: .monospaced))
          .tracking(1.4).foregroundStyle(.orange)
        Text("Burn Pit").font(.system(size: 33, weight: .bold, design: .rounded))
      }.accessibilityAddTraits(.isHeader)
      Spacer()
      if model.scanning && model.snapshot != nil { ProgressView().controlSize(.small) }
      if let snapshot = model.snapshot {
        VStack(alignment: .trailing, spacing: 3) {
          Text(snapshot.demo ? "DEMO SNAPSHOT" : "LOCAL SNAPSHOT")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.orange)
          Text(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption).foregroundStyle(BurnTheme.muted)
        }
      }
      Button { model.refresh() } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }.buttonStyle(HuntPillStyle()).disabled(model.scanning)
    }
  }

  private func dashboard(_ snapshot: BlazerMap) -> some View {
    let inventory = BurnPitInventory(rows: snapshot.rows, layer: layer, search: search)
    let showingLedger = ledger || layer == .zombie
    let items = showingLedger ? inventory.matches : inventory.slabs
    let selected = items.first { $0.id == selection } ?? items.first

    return VStack(alignment: .leading, spacing: 13) {
      telemetry(snapshot)
      HStack(spacing: 10) {
        TextField("Search name, path or status", text: $search)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 165, maxWidth: 300)
        Picker("Layer", selection: $layer) {
          ForEach(BurnPitLayer.allCases) { layer in Text(layer.rawValue).tag(layer) }
        }.labelsHidden().pickerStyle(.menu).frame(width: 141)
        if layer != .zombie {
          Button {
            ledger.toggle()
          } label: {
            Label(showingLedger ? "Show Furnace" : "Evidence Ledger",
                  systemImage: showingLedger ? "flame" : "list.bullet.rectangle")
          }.buttonStyle(HuntPillStyle())
        }
        Spacer(minLength: 6)
        Text(showingLedger ? "\(inventory.matches.count) findings" :
              "\(inventory.slabs.count) mapped · \(inventory.matches.count) matching")
          .font(.caption).monospacedDigit().foregroundStyle(BurnTheme.muted)
      }

      HStack(alignment: .top, spacing: 12) {
        if showingLedger {
          evidenceLedger(inventory.matches, selected: selected?.id)
        } else {
          furnace(inventory, selected: selected?.id)
        }
        evidence(selected).frame(width: 247)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Button {
        coverage.toggle()
      } label: {
        Label("Snapshot coverage", systemImage: "info.circle")
      }
      .buttonStyle(HuntPillStyle())
      .popover(isPresented: $coverage, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 9) {
          Text("Snapshot coverage").font(.headline)
          ForEach(snapshot.notes.indices, id: \.self) { index in
            Text(snapshot.notes[index]).font(.callout).fixedSize(horizontal: false, vertical: true)
          }
        }.padding(18).frame(width: 395, alignment: .leading)
      }
    }
  }

  private func telemetry(_ snapshot: BlazerMap) -> some View {
    let volume = snapshot.volume
    let known = volume.totalBytes > 0
    return HStack(alignment: .top, spacing: 24) {
      VStack(alignment: .leading, spacing: 3) {
        metric("Home volume", known ? "\(BlazerXRay.formatBytes(volume.freeBytes)) free" : "Unavailable",
               known ? "\(BlazerXRay.formatBytes(volume.totalBytes)) total" : "")
        if known {
          ProgressView(value: min(100, max(0, volume.usedPercent)), total: 100)
            .tint(.orange).frame(maxWidth: 295)
            .accessibilityLabel("Disk used")
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      metric("Disk pressure", known ? (volume.overdriveActive ? "Overdrive" : "Nominal") : "Unknown",
             volume.exhaustBytesPerHour > 0 ? "+\(BlazerXRay.formatBytes(volume.exhaustBytesPerHour))/hr" : "")
        .frame(maxWidth: .infinity, alignment: .leading)
      metric("Agent sessions", "\(snapshot.liveSessions) live", "\(snapshot.indexedSessions) indexed")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 10)
    .overlay(alignment: .top) { Rectangle().fill(BurnTheme.line).frame(height: 1) }
    .overlay(alignment: .bottom) { Rectangle().fill(BurnTheme.line).frame(height: 1) }
  }

  private func metric(_ name: String, _ value: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      label(name)
      Text(value).font(.title3.bold()).monospacedDigit()
      if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(BurnTheme.muted) }
    }
  }

  private func furnace(_ inventory: BurnPitInventory, selected: String?) -> some View {
    let overlapping = inventory.overlapping == 1 ? "1 overlapping path" : "\(inventory.overlapping) overlapping paths"
    let smaller = inventory.smaller == 1 ? "1 smaller finding" : "\(inventory.smaller) smaller findings"
    let omitted = [inventory.overlapping > 0 ? overlapping : nil, inventory.smaller > 0 ? smaller : nil]
      .compactMap { $0 }.joined(separator: " · ")

    return VStack(alignment: .leading, spacing: 9) {
      Text(layer == .folder ? "Disk folder allocation" : "Cache and worktree allocation")
        .font(.headline).accessibilityAddTraits(.isHeader)
      Text("Slab area shows estimated disk bytes").font(.caption).foregroundStyle(BurnTheme.muted)
      if inventory.slabs.isEmpty {
        ContentUnavailableView(
          "No measured disk items", systemImage: "externaldrive",
          description: Text("Open the Evidence Ledger for findings without a disk estimate."))
      } else {
        BurnPitFurnace(rows: inventory.slabs, selection: selected) { selection = $0 }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack(spacing: 12) {
          ForEach([BlazerMap.Row.Kind.cache, .worktree, .folder], id: \.self) { kind in
            if inventory.slabs.contains(where: { $0.kind == kind }) { key(kind) }
          }
        }
        if !omitted.isEmpty {
          Text("\(omitted) in Evidence Ledger")
            .font(.caption).foregroundStyle(BurnTheme.muted)
        }
      }
    }.padding(13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(panel)
  }

  private func evidenceLedger(_ rows: [BlazerMap.Row], selected: String?) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("Evidence Ledger").font(.headline).accessibilityAddTraits(.isHeader)
      if rows.isEmpty {
        ContentUnavailableView("No matching findings", systemImage: "magnifyingglass")
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(rows, id: \.id) { row in
              Button { selection = row.id } label: {
                HStack(spacing: 12) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(.callout.weight(.semibold)).lineLimit(1)
                    key(row.kind)
                  }
                  Spacer(minLength: 0)
                  Text(row.state).font(.caption).foregroundStyle(BurnTheme.muted).lineLimit(2)
                  Text(sizeText(row)).font(.caption).monospacedDigit().frame(minWidth: 80, alignment: .trailing)
                }
                .padding(8)
                .background(.white.opacity(selected == row.id ? 0.10 : 0.02), in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
              }.buttonStyle(.plain).clickPointer()
                .accessibilityAddTraits(selected == row.id ? .isSelected : [])
            }
          }
        }
      }
    }.padding(13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(panel)
  }

  private func evidence(_ row: BlazerMap.Row?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        label("Selected evidence")
        if let row {
          Text(row.name).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
          key(row.kind)
          Text(row.state).font(.callout.weight(.medium))
          if let path = row.path {
            Text(path).font(.system(.caption, design: .monospaced))
              .foregroundStyle(BurnTheme.muted).textSelection(.enabled)
          }
          if !row.detail.isEmpty {
            Text(row.detail).font(.callout).foregroundStyle(BurnTheme.muted).textSelection(.enabled)
          }
          Divider()
          fact(row.memoryBytes != nil ? "Resident RAM" : "Disk estimate", sizeText(row))
          fact("Last activity", dateText(row.lastUsed))
          fact("Observed", dateText(row.observedAt))
          fact("Source", row.source)
        } else {
          Text("Select a finding to see its details.").font(.callout).foregroundStyle(BurnTheme.muted)
        }
      }.frame(maxWidth: .infinity, alignment: .topLeading).padding(13)
    }.frame(maxHeight: .infinity).background(panel)
  }

  private var panel: some View {
    RoundedRectangle(cornerRadius: 11).fill(Color(red: 0.145, green: 0.099, blue: 0.072))
      .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(BurnTheme.line) }
  }

  private func label(_ title: String) -> some View {
    Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced))
      .tracking(0.9).foregroundStyle(BurnTheme.muted)
  }

  private func key(_ kind: BlazerMap.Row.Kind) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2).fill(kind.burnPitTint).frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(kind.burnPitLabel).font(.caption).foregroundStyle(BurnTheme.muted)
    }
  }

  private func fact(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(BurnTheme.muted)
      Text(value).font(.callout).textSelection(.enabled)
    }
  }

  private func sizeText(_ row: BlazerMap.Row) -> String {
    if let disk = row.diskBytes { return BlazerXRay.formatBytes(disk) }
    if let ram = row.memoryBytes { return "\(BlazerXRay.formatBytes(ram)) RAM" }
    return "Unknown"
  }

  private func dateText(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
  }
}
