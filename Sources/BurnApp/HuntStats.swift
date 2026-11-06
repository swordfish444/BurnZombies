import BurnCore
import SwiftUI

/// Freed so far, then one card per area: what the AI judged there, what burned and what BZ saw.
/// Every number is a count of real things. An area the hunt hasn't looked at yet says so, with no
/// number at all.
struct HuntStats: View {
  let snapshot: HuntSnapshot
  let running: Bool
  let layout: HuntLayout

  static let kinds = ["process", "worktree", "disk"]

  var body: some View {
    HStack(alignment: .top, spacing: layout.gap) {
      hero.frame(width: layout.unit)
      ForEach(Self.kinds, id: \.self) { kind in
        HuntLaneCard(
          kind: kind, lane: snapshot.lanes?.first { $0.kind == kind }, running: running,
          stopped: snapshot.phase == "stopped", roomy: layout.roomyLanes
        ).frame(width: layout.unit)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The payoff: memory and disk together, the one big number on the page.
  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(running ? "Freed so far" : "Freed this hunt")
        .font(.system(size: 12, weight: .medium)).foregroundStyle(BurnTheme.muted)
      HuntBytes(bytes: snapshot.memoryReclaimed + snapshot.diskReclaimed, size: 38)
        .padding(.top, 9)
      Text("\(snapshot.burned.formatted()) zombie\(snapshot.burned == 1 ? "" : "s") burned")
        .font(.system(size: 13, weight: .semibold)).padding(.top, 10)
      Text(
        ImpactNumbers.bytes(snapshot.memoryReclaimed) + " memory · "
          + ImpactNumbers.bytes(snapshot.diskReclaimed) + " disk"
      )
      .font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted)
      .lineLimit(1).minimumScaleFactor(0.85).padding(.top, 3)
      if snapshot.deep == true, !running, let spent = snapshot.spentUSD {
        Text("for " + HuntOptions.dollars(spent) + " of AI")
          .font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted).padding(.top, 2)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 13)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(HuntStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("hunt-freed")
  }
}

/// One area of the hunt: its state, how much of it the AI judged, what burned and what BZ found.
struct HuntLaneCard: View {
  let kind: String
  let lane: HuntLane?
  let running: Bool
  let stopped: Bool
  let roomy: Bool

  private var title: String {
    switch kind {
    case "process": return "Programs"
    case "worktree": return "Old copies"
    default: return "Junk and caches"
    }
  }
  private var symbol: String {
    switch kind {
    case "process": return "cpu"
    case "worktree": return "arrow.triangle.branch"
    default: return "folder"
    }
  }
  private func found(_ lane: HuntLane) -> String {
    switch kind {
    case "process": return "\(lane.seen.formatted()) running"
    case "worktree": return "\(lane.seen.formatted()) copies found"
    default: return "\(lane.seen.formatted()) folders found"
    }
  }
  private var total: Int { lane.map { max($0.toJudge, $0.judged) } ?? 0 }
  /// "AI" while the AI works through it; "Done", "Clear" or "Stopped" once there's nothing more.
  private var state: String {
    guard let lane else { return "Up next" }
    if total == 0 { return running ? "Clear" : "Done" }
    if lane.judged >= total { return "Done" }
    return running ? "AI" : stopped ? "Stopped" : "Done"
  }
  private var tint: Color? {
    switch state {
    case "AI": return BurnTheme.orange
    case "Done": return AutopilotTheme.green
    default: return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: roomy ? 6 : 4) {
        if roomy {
          Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            .foregroundStyle(BurnTheme.muted)
        }
        Text(title).font(.system(size: roomy ? 12.5 : 12, weight: .semibold)).lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: 4)
        HuntTag(text: state, tint: tint, compact: !roomy)
      }
      count.frame(height: 25, alignment: .bottomLeading).padding(.top, 6)
      bar.padding(.top, 8)
      if let lane {
        Text(
          lane.burned > 0
            ? "Burned \(lane.burned.formatted()) · " + ImpactNumbers.bytes(lane.bytes)
            : "Nothing burned yet"
        )
        .font(.system(size: 12.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
        .foregroundStyle(lane.burned > 0 ? BurnTheme.cream : BurnTheme.muted)
        .padding(.top, 8)
        Text(found(lane)).font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted)
          .lineLimit(1).minimumScaleFactor(0.85).padding(.top, 2)
      }
    }
    .padding(.horizontal, roomy ? 14 : 12).padding(.vertical, 13)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(HuntStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var count: some View {
    if let lane, total > 0 {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(lane.judged.formatted())
          .font(.system(size: 21, weight: .semibold, design: .rounded))
          .contentTransition(.numericText())
        Text("of \(total.formatted()) judged").font(.system(size: 11.5))
          .foregroundStyle(BurnTheme.muted)
      }.lineLimit(1).minimumScaleFactor(0.8)
    } else {
      Text(lane == nil ? "Not looked at yet" : "Nothing to judge")
        .font(.system(size: 13, weight: .medium)).foregroundStyle(BurnTheme.muted)
    }
  }

  private var bar: some View {
    let done = total > 0 ? min(1, Double(lane?.judged ?? 0) / Double(total)) : 0
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(HuntStyle.track)
        Capsule().fill(BurnTheme.orange).frame(width: proxy.size.width * done)
      }
    }.frame(height: 3)
  }
}

/// Hunts from before Autopilot: their totals, with what they freed first.
struct HuntTotals: View {
  let snapshot: HuntSnapshot
  let layout: HuntLayout

  private var receipts: Bool { snapshot.receiptEvidenceAvailable != false }

  var body: some View {
    HStack(alignment: .top, spacing: layout.gap) {
      cell(
        receipts ? ImpactNumbers.bytes(snapshot.memoryReclaimed) : nil, "Memory released",
        payoff: snapshot.memoryReclaimed > 0)
      cell(
        receipts ? ImpactNumbers.bytes(snapshot.diskReclaimed) : nil, "Disk reclaimed",
        payoff: snapshot.diskReclaimed > 0)
      cell(receipts ? snapshot.burned.formatted() : nil, "Zombies burned")
      cell(receipts ? snapshot.worktreesCleaned.formatted() : nil, "Worktrees cleaned")
      cell(snapshot.processCount.formatted(), "Processes seen")
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// A total with its label above it. Without receipts BZ can't count what burned, so it says so
  /// with a dash rather than a zero.
  private func cell(_ value: String?, _ label: String, payoff: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(BurnTheme.muted)
        .lineLimit(1).minimumScaleFactor(0.85)
      Text(value ?? "—")
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .foregroundStyle(value == nil ? BurnTheme.muted : payoff ? BurnTheme.orange : BurnTheme.cream)
        .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(HuntStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
