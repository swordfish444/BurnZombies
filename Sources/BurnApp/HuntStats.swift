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
      HuntFreedCard(
        running: running, memory: snapshot.memoryReclaimed, disk: snapshot.diskReclaimed,
        burned: snapshot.burned,
        cost: snapshot.deep == true && !running
          ? snapshot.spentUSD.map { "for " + HuntOptions.dollars($0) + " of AI" } : nil
      ).frame(width: layout.unit)
      ForEach(Self.kinds, id: \.self) { kind in
        HuntLaneCard(
          kind: kind, lane: snapshot.lanes?.first { $0.kind == kind }, roomy: layout.roomyLanes
        ).frame(width: layout.unit)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// Before any hunt: the same row at rest, so every state shares one layout. Nothing has been
/// counted, so it shows no numbers at all: what was freed says nothing yet, and each area that it
/// hasn't been looked at.
struct HuntStatsAtRest: View {
  /// Autopilot hunts have lanes; older hunts their totals.
  let autopilot: Bool
  let layout: HuntLayout

  var body: some View {
    HStack(alignment: .top, spacing: layout.gap) {
      rest("Freed so far", "Nothing yet").accessibilityIdentifier("hunt-freed")
      if autopilot {
        ForEach(HuntStats.kinds, id: \.self) { kind in
          HuntLaneCard(kind: kind, lane: nil, roomy: layout.roomyLanes).frame(width: layout.unit)
        }
      } else {
        ForEach(["Zombies burned", "Worktrees cleaned", "Processes seen"], id: \.self) { label in
          rest(label, "—")
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func rest(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(BurnTheme.muted)
        .lineLimit(1)
      Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(BurnTheme.muted)
        .frame(height: 25, alignment: .bottomLeading).padding(.top, 7)
    }
    .padding(.horizontal, 14).padding(.vertical, 13)
    .frame(width: layout.unit, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(HuntStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// The payoff: memory and disk together, the one big number on the page. Nothing freed yet reads
/// quiet rather than as an orange zero, and without receipts it is a dash.
struct HuntFreedCard: View {
  let running: Bool
  let memory: UInt64
  let disk: UInt64
  /// Zombies burned, when this card says it; older hunts count them in a card of their own.
  var burned: Int? = nil
  var cost: String? = nil
  var receipts = true

  var body: some View {
    // What it cost rides along on the label when the card is wide enough, so a finished deep hunt
    // doesn't make the whole row taller; narrow, it gets its own line.
    ViewThatFits(in: .horizontal) {
      card(costInLabel: true)
      card(costInLabel: false)
    }
    .background(HuntStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("hunt-freed")
  }

  private func card(costInLabel: Bool) -> some View {
    let label = running ? "Freed so far" : "Freed this hunt"
    return VStack(alignment: .leading, spacing: 0) {
      Text(costInLabel ? [label, cost].compactMap { $0 }.joined(separator: " ") : label)
        .font(.system(size: 12, weight: .medium)).foregroundStyle(BurnTheme.muted)
        .lineLimit(1).fixedSize()
      Group {
        if receipts {
          HuntBytes(bytes: memory + disk, size: 38)
        } else {
          Text("—").font(BurnTheme.display(38)).foregroundStyle(BurnTheme.muted).antonTrimmed(38)
        }
      }.padding(.top, 9)
      if let burned, receipts {
        Text("\(burned.formatted()) zombie\(burned == 1 ? "" : "s") burned")
          .font(.system(size: 13, weight: .semibold)).padding(.top, 10)
      }
      Text(
        receipts
          ? ImpactNumbers.bytes(memory) + " memory · " + ImpactNumbers.bytes(disk) + " disk"
          : "Receipts unavailable"
      )
      .font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted)
      .lineLimit(1).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
      .padding(.top, burned != nil && receipts ? 3 : 10)
      if let cost, !costInLabel {
        Text(cost).font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted)
          .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 13)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// One area of the hunt: how much of it the AI judged, what burned and what BZ found. Its state
/// is in its words and its bar; a small check says it is done.
struct HuntLaneCard: View {
  let kind: String
  let lane: HuntLane?
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
  private var done: Bool { total > 0 && (lane?.judged ?? 0) >= total }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 11, weight: .medium))
          .foregroundStyle(BurnTheme.muted)
        Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        if done {
          Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
            .foregroundStyle(AutopilotTheme.green).accessibilityLabel("Done")
        }
        Spacer(minLength: 0)
      }
      count.frame(height: 25, alignment: .bottomLeading).padding(.top, 7)
      bar.padding(.top, 8)
      if let lane {
        Text(
          lane.burned > 0
            ? "Burned \(lane.burned.formatted()) · " + ImpactNumbers.bytes(lane.bytes)
            : "Nothing burned yet"
        )
        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(lane.burned > 0 ? BurnTheme.cream : BurnTheme.muted)
        .padding(.top, 9)
        Text(found(lane)).font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted)
          .lineLimit(1).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
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
    let share = total > 0 ? min(1, Double(lane?.judged ?? 0) / Double(total)) : 0
    return GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(HuntStyle.track)
        Capsule().fill(BurnTheme.orange).frame(width: proxy.size.width * share)
      }
    }.frame(height: 3)
  }
}

/// Hunts from before Autopilot, on the same grid: what they freed first, then the zombies and
/// worktrees they burned and the processes they saw.
struct HuntTotals: View {
  let snapshot: HuntSnapshot
  let running: Bool
  let layout: HuntLayout

  private var receipts: Bool { snapshot.receiptEvidenceAvailable != false }

  var body: some View {
    HStack(alignment: .top, spacing: layout.gap) {
      HuntFreedCard(
        running: running, memory: snapshot.memoryReclaimed, disk: snapshot.diskReclaimed,
        receipts: receipts
      ).frame(width: layout.unit)
      cell(receipts ? snapshot.burned.formatted() : nil, "Zombies burned")
      cell(receipts ? snapshot.worktreesCleaned.formatted() : nil, "Worktrees cleaned")
      cell(snapshot.processCount.formatted(), "Processes seen")
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// A total with its label above it. Without receipts BZ can't count what burned, so it says so
  /// with a dash rather than a zero.
  private func cell(_ value: String?, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(BurnTheme.muted)
        .lineLimit(1)
      Text(value ?? "—")
        .font(.system(size: 22, weight: .semibold, design: .rounded))
        .foregroundStyle(value == nil ? BurnTheme.muted : BurnTheme.cream)
        .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 16).padding(.vertical, 13)
    .frame(width: layout.unit, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(HuntStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
