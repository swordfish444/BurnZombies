import BurnCore
import Darwin
import Foundation

/// Zero-persistence, read-only diagnostic (`burnzombies audit [--json]`).
/// Starts no daemon, creates no state files or Login Items, sends no signals, and deletes nothing.
enum Audit {
  struct Report: Codable {
    var freeDiskBytes: UInt64
    var freeDiskHuman: String
    var orphanProcesses: Int
    var robotBrowsers: Int
    var processMemoryBytes: UInt64
    var worktreesTotal: Int
    var worktreesByPlace: [String: Int]
    var worktreesLocked: Int
    var worktreeBytes: UInt64
    var reclaimableCacheItems: Int
    var reclaimableCacheBytes: UInt64
    var totalReclaimableBytes: UInt64
    var recommendation: String
  }

  static func run(_ args: [String]) throws {
    let asJSON = args.contains("--json")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let now = Date()
    let freeBytes = AutopilotSweeper.freeDiskBytes(at: home) ?? 0
    let protected = ProtectedLocations.limited(homes: [home])

    // 1. Live process snapshot (read-only)
    let scan = Native().scan()
    let threads = AgentThreads.index(home: home, now: now)
    var records: [String: Record] = [:]
    for obs in scan.observations {
      records[obs.identity.key] = Record(obs)
    }
    let launchAgents = AutopilotSources.launchAgentPIDs()
    let processItems = AutopilotProcesses.items(
      records, threads: threads, protectedPIDs: AgentSafety.ancestors(of: getpid()) ?? [],
      launchAgents: launchAgents, claimed: [], preferences: Preferences(), now: now,
      home: home, protected: protected)
    let actionableProcs = processItems.filter { $0.protectedReason == nil }
    let robotCount = actionableProcs.filter { $0.facts["robot"] == "abandoned" }.count
    let procBytes = actionableProcs.reduce(UInt64(0)) { $0 + $1.bytes }

    // 2. Bounded read-only worktree discovery (in default code roots, no state writes)
    let defaultRoots = [
      home + "/Code", home + "/code", home + "/Projects", home + "/projects",
      home + "/git", home + "/src", home + "/dev", home + "/workspace", home + "/Developer",
      home + "/.claude/worktrees", home + "/.codex/worktrees", home + "/.cursor/worktrees",
    ].filter { path in
      var st = stat()
      return protected.allows(path) && lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
    var wtRecords: [WorktreeRecord] = []
    var seenRepos = Set<String>()
    for root in defaultRoots {
      for wt in discoverLinkedWorktrees(under: root, protected: protected, seenRepos: &seenRepos) {
        wtRecords.append(wt)
      }
    }
    var delivery: [String: AutopilotDelivery] = [:]
    let wtItems = AutopilotWorktrees.items(
      wtRecords, threads: threads, delivery: &delivery, now: now, budget: 40, protected: protected)
    var byPlace: [String: Int] = [:]
    var lockedCount = 0
    var wtBytes: UInt64 = 0
    for rec in wtRecords where !rec.main {
      if rec.locked { lockedCount += 1 }
      wtBytes += rec.allocated
    }
    for item in wtItems where item.protectedReason != "This is your main project folder." {
      let place = item.facts["place"] ?? "other"
      byPlace[place, default: 0] += 1
    }

    // 3. Global developer caches & settled AI scratch (fast time-bounded pass)
    let trail = AutopilotBrowserTrail.temporaryFolder()
    var progress = AutopilotDisk.ScanProgress()
    let diskBatch = AutopilotDisk.scan(
      worktrees: [], home: home, caches: true, mains: false, now: now,
      sizer: { AutopilotDisk.countedSize($0, deadline: 1.5) },
      protected: protected, trail: trail, progress: &progress, budget: 8)
    let cacheBytes = diskBatch.items.reduce(UInt64(0)) { $0 + $1.bytes }

    let totalReclaimable = procBytes + wtBytes + cacheBytes
    let recommendation: String
    if freeBytes > 250_000_000_000 && actionableProcs.isEmpty && totalReclaimable < 5_000_000_000 {
      recommendation =
        "Your Mac looks clean (\(AutopilotPolicy.format(freeBytes)) free, 0 orphaned agent processes, \(AutopilotPolicy.format(totalReclaimable)) reclaimable). You probably don't need BurnZombies right now."
    } else if robotCount > 0 || totalReclaimable >= 10_000_000_000 || freeBytes < 100_000_000_000 {
      recommendation =
        "Found \(AutopilotPolicy.format(totalReclaimable)) of agent worktrees/caches and \(actionableProcs.count) orphaned process(es) (\(robotCount) abandoned robot browser(s)). Worth trying in preview mode: burnzombies setup --look-only --observe-only --no-login-item."
    } else {
      recommendation =
        "Modest leftovers found (\(AutopilotPolicy.format(totalReclaimable)), \(actionableProcs.count) orphan candidate(s)). Try --look-only --observe-only if you want visibility without automatic burns."
    }

    let report = Report(
      freeDiskBytes: freeBytes,
      freeDiskHuman: AutopilotPolicy.format(freeBytes),
      orphanProcesses: actionableProcs.count,
      robotBrowsers: robotCount,
      processMemoryBytes: procBytes,
      worktreesTotal: wtRecords.filter { !$0.main }.count,
      worktreesByPlace: byPlace,
      worktreesLocked: lockedCount,
      worktreeBytes: wtBytes,
      reclaimableCacheItems: diskBatch.items.count,
      reclaimableCacheBytes: cacheBytes,
      totalReclaimableBytes: totalReclaimable,
      recommendation: recommendation)

    if asJSON {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      print(String(decoding: try encoder.encode(report), as: UTF8.self))
      return
    }

    let placesSummary =
      byPlace.isEmpty
      ? "none"
      : byPlace.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    print(
      """
      BurnZombies Read-Only Audit (zero files modified, no daemon started)
      ─────────────────────────────────────────────────────────────────────
      Free disk space:        \(report.freeDiskHuman)
      Orphaned processes:     \(report.orphanProcesses) (\(report.robotBrowsers) abandoned robot browser\(report.robotBrowsers == 1 ? "" : "s"), \(AutopilotPolicy.format(report.processMemoryBytes)))
      Linked Git worktrees:   \(report.worktreesTotal) (\(placesSummary); locked=\(report.worktreesLocked); \(AutopilotPolicy.format(report.worktreeBytes)))
      Dev caches & AI temp:   \(report.reclaimableCacheItems) item\(report.reclaimableCacheItems == 1 ? "" : "s") (\(AutopilotPolicy.format(report.reclaimableCacheBytes)))
      Total estimated bloat:  \(AutopilotPolicy.format(report.totalReclaimableBytes))

      Verdict: \(report.recommendation)
      """)
  }

  /// Shallow read-only Git worktree finder (depth <= 2 under a root, zero state mutations).
  private static func discoverLinkedWorktrees(
    under root: String, protected: ProtectedLocations, seenRepos: inout Set<String>
  ) -> [WorktreeRecord] {
    var out: [WorktreeRecord] = []
    var queue: [(String, Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty && visited < 400 {
      let (dir, depth) = queue.removeFirst()
      visited += 1
      var dotGit = stat()
      if lstat(dir + "/.git", &dotGit) == 0 {
        if (dotGit.st_mode & S_IFMT) == S_IFDIR {
          let common = WorkspaceSafety.canonical(dir + "/.git")
          if seenRepos.insert(common).inserted {
            out += parseWorktreeList(repoPath: dir, common: common)
          }
          continue
        }
      }
      guard depth < 2, let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
      else { continue }
      for name in names where !name.hasPrefix(".") && name != "node_modules" {
        let child = dir + "/" + name
        var st = stat()
        if protected.allows(child), lstat(child, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
          queue.append((child, depth + 1))
        }
      }
    }
    return out
  }

  private static func parseWorktreeList(repoPath: String, common: String) -> [WorktreeRecord] {
    guard
      let data = try? WorktreeGit.run(repoPath, ["worktree", "list", "--porcelain"], seconds: 5),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    var records: [WorktreeRecord] = []
    var currentPath: String?
    var branch: String?
    var head: String?
    var locked = false
    var bare = false
    var isFirst = true

    func flush() {
      guard let path = currentPath else { return }
      var rec = WorktreeRecord(
        id: AutopilotItem.hash(common + "|" + path), path: path, repository: common)
      rec.main = isFirst
      rec.branch = branch
      rec.head = head
      rec.locked = locked
      rec.bare = bare
      if !isFirst && !bare {
        rec.allocated = AutopilotDisk.countedSize(path, deadline: 1.0) ?? 0
      }
      records.append(rec)
      isFirst = false
      currentPath = nil
      branch = nil
      head = nil
      locked = false
      bare = false
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.isEmpty {
        flush()
      } else if line.hasPrefix("worktree ") {
        currentPath = String(line.dropFirst("worktree ".count))
      } else if line.hasPrefix("HEAD ") {
        head = String(line.dropFirst("HEAD ".count))
      } else if line.hasPrefix("branch ") {
        branch = String(line.dropFirst("branch ".count))
      } else if line == "locked" || line.hasPrefix("locked ") {
        locked = true
      } else if line == "bare" {
        bare = true
      }
    }
    flush()
    return records
  }
}
