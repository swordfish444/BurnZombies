import Darwin
import Foundation

public struct BlazerXRayReport: Codable, Sendable, Equatable {
  public struct CategoryTotal: Codable, Sendable, Equatable {
    public var category: String
    public var label: String
    public var count: Int
    public var bytes: UInt64
    public init(category: String, label: String, count: Int, bytes: UInt64) {
      self.category = category
      self.label = label
      self.count = count
      self.bytes = bytes
    }
  }

  public var observedAt: Date
  public var durationMS: Int
  public var volume: BlazerOverdrive.VolumeTelemetry
  public var indexedSessions: Int
  public var liveSessions: Int
  public var failoverHarnesses: [String]
  public var disguisedBytes: UInt64
  public var disguisedCategories: [CategoryTotal]
  public var topDisguisedItems: [AutopilotItem]
  public var thrashFindings: [AgentThrashFinding]

  public init(
    observedAt: Date, durationMS: Int, volume: BlazerOverdrive.VolumeTelemetry,
    indexedSessions: Int, liveSessions: Int, failoverHarnesses: [String],
    disguisedBytes: UInt64, disguisedCategories: [CategoryTotal],
    topDisguisedItems: [AutopilotItem], thrashFindings: [AgentThrashFinding]
  ) {
    self.observedAt = observedAt
    self.durationMS = durationMS
    self.volume = volume
    self.indexedSessions = indexedSessions
    self.liveSessions = liveSessions
    self.failoverHarnesses = failoverHarnesses
    self.disguisedBytes = disguisedBytes
    self.disguisedCategories = disguisedCategories
    self.topDisguisedItems = topDisguisedItems
    self.thrashFindings = thrashFindings
  }
}

/// Fast (< 3s) live diagnostic X-Ray combining APFS Overdrive velocity, Anatomical Disguised Waste
/// sizing, Multi-Brain harness readiness, and Living Zombie Thrash detection.
public enum BlazerXRay {
  /// Fast shallow/bounded directory sizer for instant X-Ray diagnostics so massive SDK/DerivedData
  /// trees size in milliseconds without blocking the terminal.
  public static func fastSize(_ path: String, entryCap: Int = 6_000) -> UInt64? {
    var rootInfo = stat()
    guard lstat(path, &rootInfo) == 0 else { return nil }
    if rootInfo.st_mode & S_IFMT == S_IFREG {
      return UInt64(max(0, rootInfo.st_blocks)) * 512
    }
    guard rootInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
    let dev = rootInfo.st_dev
    var total: UInt64 = 0
    var stack = [path]
    var seen = 0
    while let dir = stack.popLast() {
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
      for name in names {
        let child = dir + "/" + name
        var info = stat()
        guard lstat(child, &info) == 0, info.st_dev == dev else { continue }
        seen += 1
        let mode = info.st_mode & S_IFMT
        if mode == S_IFREG {
          total += UInt64(max(0, info.st_blocks)) * 512
        } else if mode == S_IFDIR {
          stack.append(child)
        }
        if seen >= entryCap { return total }
      }
    }
    return total
  }

  public static func scan(
    home: String = NSHomeDirectory(), root: URL = Store.defaultRoot,
    tempRoots: [String]? = nil, now: Date = Date(),
    statVolume: ((String) -> (free: UInt64, total: UInt64)?)? = nil,
    sizer: ((String) -> UInt64?)? = nil
  ) -> BlazerXRayReport {
    let started = ProcessInfo.processInfo.systemUptime
    let base = WorkspaceSafety.canonical(home)
    let volume = BlazerOverdrive.readOnlyTelemetry(
      root: root, volumePath: base, now: now, statVolume: statVolume)
    let threads = AgentThreads.index(home: base, now: now)
    let liveCount = threads.filter(\.live).count
    let itemSizer = sizer ?? { fastSize($0, entryCap: 12_000) }
    let protected = ProtectedLocations.current(root: root, homes: [base])

    let anatomical = BlazerAnatomy.scan(
      home: base, root: root, threads: threads, tempRoots: tempRoots,
      overdrive: volume.overdriveActive, now: now, sizer: itemSizer, protected: protected)

    var byKind: [String: (label: String, count: Int, bytes: UInt64)] = [:]
    for item in anatomical {
      let raw = item.facts["anatomical"] ?? "other"
      let label = BlazerAnatomy.SignatureKind(rawValue: raw)?.categoryLabel ?? "Disguised cache"
      let prev = byKind[raw] ?? (label: label, count: 0, bytes: 0)
      byKind[raw] = (label: label, count: prev.count + 1, bytes: prev.bytes + item.bytes)
    }
    let categories = byKind.map { key, val in
      BlazerXRayReport.CategoryTotal(
        category: key, label: val.label, count: val.count, bytes: val.bytes)
    }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category < $1.category }

    let thrash = AgentThrashScanner.scan(home: base, now: now, threads: threads, limit: 12)
    let availableHarnesses = ["claude", "codex", "gemini"].filter {
      MachineReviewConfiguration.detect($0) != nil
    }
    let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)

    return BlazerXRayReport(
      observedAt: now,
      durationMS: max(1, elapsedMS),
      volume: volume,
      indexedSessions: threads.count,
      liveSessions: liveCount,
      failoverHarnesses: availableHarnesses,
      disguisedBytes: anatomical.reduce(0) { $0 + $1.bytes },
      disguisedCategories: categories,
      topDisguisedItems: Array(anatomical.prefix(8)),
      thrashFindings: thrash)
  }

  public static func formatTerminal(_ r: BlazerXRayReport) -> String {
    var out: [String] = []
    let bar = String(repeating: "=", count: 72)
    out.append(bar)
    out.append(
      "  BURNZOMBIES : BLAZER X-RAY  ·  v\(BuildIdentity.version) (\(r.durationMS) ms)")
    out.append(bar)

    let freeStr = formatBytes(r.volume.freeBytes)
    let totalStr = formatBytes(r.volume.totalBytes)
    let usedPct = String(format: "%.1f%%", r.volume.usedPercent)
    let rateStr =
      r.volume.exhaustBytesPerHour > 0
      ? formatBytes(r.volume.exhaustBytesPerHour) + "/hr" : "steady"
    let modeBadge =
      r.volume.overdriveActive
      ? "[OVERDRIVE ENGAGED: \(r.volume.overdriveReason ?? "high pressure")]"
      : "[NOMINAL WATCH]"
    out.append("  DISK PRESSURE   \(freeStr) free / \(totalStr) (\(usedPct) used)  ·  burn: \(rateStr)")
    out.append("  SWEEP ENGINE    \(modeBadge)")
    let brains =
      r.failoverHarnesses.isEmpty ? "rules-only" : r.failoverHarnesses.joined(separator: " -> ")
    out.append(
      "  AGENT MESH      \(r.indexedSessions) indexed sessions (\(r.liveSessions) live)  ·  brains: \(brains)"
    )
    out.append("")

    out.append(
      "  ANATOMICAL DISGUISED WASTE  (\(formatBytes(r.disguisedBytes)) reclaimable outside standard names)"
    )
    if r.disguisedCategories.isEmpty {
      out.append("    ✓ Clean — zero disguised DerivedData, orphaned SDK trees, or dead scratch.")
    } else {
      for cat in r.disguisedCategories {
        let b = formatBytes(cat.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)
        out.append("    • \(b)  \(cat.label) (\(cat.count) item\(cat.count == 1 ? "" : "s"))")
      }
      out.append("    Top targets:")
      for item in r.topDisguisedItems.prefix(5) {
        let b = formatBytes(item.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)
        out.append("      -> \(b)  \(item.name)  [\(item.path ?? "")]")
      }
    }
    out.append("")

    out.append("  LIVING ZOMBIES & AGENT THRASH  (\(r.thrashFindings.count) detected)")
    if r.thrashFindings.isEmpty {
      out.append("    ✓ Zero loop zombies, token vampires, or focus-stealing browsers.")
    } else {
      for f in r.thrashFindings.prefix(8) {
        let state = f.live ? "LIVE" : "HIST"
        out.append("    • [\(state)] [\(f.kind.badge)] \(f.agent):\(f.sessionID.prefix(12))")
        out.append("        \(f.summary)")
      }
    }
    out.append(bar)
    return out.joined(separator: "\n")
  }

  public static func formatBytes(_ bytes: UInt64) -> String {
    if bytes >= 1_000_000_000_000 {
      return String(format: "%.2f TB", Double(bytes) / 1_000_000_000_000.0)
    } else if bytes >= 1_000_000_000 {
      return String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
    } else if bytes >= 1_000_000 {
      return String(format: "%.0f MB", Double(bytes) / 1_000_000.0)
    } else if bytes >= 1_000 {
      return String(format: "%.0f KB", Double(bytes) / 1_000.0)
    }
    return "\(bytes) B"
  }
}
