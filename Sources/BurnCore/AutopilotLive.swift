import Darwin
import Foundation

extension AutopilotSources {
  /// Production wiring: the monitor's process records and burns, the worktree inventory,
  /// agent threads, junk folders, and the three executors.
  public static func live(monitor: Monitor, root: URL = Store.defaultRoot) -> AutopilotSources {
    let home = NSHomeDirectory()
    let junk = AutopilotJunkCache()
    return AutopilotSources(
      threads: { AgentThreads.index(home: home) },
      processes: { threads in
        let records = await monitor.autopilotRecords()
        let preferences = await monitor.autopilotPreferences()
        return AutopilotProcesses.items(
          records, threads: threads, protectedPIDs: AgentSafety.ancestors(of: getpid()) ?? [],
          launchAgents: launchAgentPIDs(), preferences: preferences, home: home)
      },
      worktreeRecords: { await monitor.autopilotWorktreeRecords() },
      worktrees: { records, threads, cache in
        var delivery = cache
        let items = AutopilotWorktrees.items(
          records, threads: threads, delivery: &delivery, budget: 150)
        return (items, delivery)
      },
      disk: { records in junk.items(records, home: home) },
      burnProcess: { item, authority, why in
        guard let key = item.processKey else {
          throw StoreError.message("I lost track of which program that was.")
        }
        return try await monitor.autopilotBurn(
          key, authority: authority, label: item.name, rationale: why)
      },
      processOutcome: { await monitor.autopilotOutcome($0) },
      retireWorktree: { item, authority in
        let receipt = AutopilotWorktrees.retire(item, authority: authority, root: root)
        if receipt.outcome == "burned" { junk.forget(under: item.path) }
        return receipt
      },
      restoreWorktree: { try AutopilotWorktrees.restore($0) },
      reclaimDisk: { item, authority in
        let receipt = AutopilotDisk.reclaim(item, authority: authority)
        if receipt.outcome == "burned" { junk.forget(under: item.path) }
        return receipt
      },
      inspect: { AutopilotInspector.inspect($0) },
      coverageNotes: {
        FullDiskAccess.status(root: root).canScan
          ? [] : ["Full Disk Access is off, so a few protected folders are skipped."]
      })
  }

  /// PIDs of the user's LaunchAgents: started on purpose by launchd, never orphans.
  public static func launchAgentPIDs() -> Set<Int32> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["list"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Set(
      String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        $0.split(separator: "\t").first.flatMap { Int32($0) }
      })
  }
}

/// Measuring junk folders is slow, so the list is refreshed at most every six hours in
/// the background and pruned immediately after a burn.
final class AutopilotJunkCache: @unchecked Sendable {
  private let lock = NSLock()
  private var cached: [AutopilotItem] = []
  private var refreshed: Date?
  private var running = false
  func items(_ records: [WorktreeRecord], home: String) -> [AutopilotItem] {
    let due: Bool = lock.withLock {
      guard !running, refreshed.map({ Date().timeIntervalSince($0) >= 6 * 3600 }) ?? true else {
        return false
      }
      running = true
      return true
    }
    if due {
      Thread.detachNewThread { [self] in
        let fresh = AutopilotDisk.items(worktrees: records, home: home)
        lock.withLock {
          cached = fresh
          refreshed = Date()
          running = false
        }
      }
    }
    return lock.withLock {
      cached.filter { $0.path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    }
  }
  func forget(under path: String?) {
    guard let path else { return }
    lock.withLock { cached.removeAll { $0.path == path || ($0.path ?? "").hasPrefix(path + "/") } }
  }
}

/// Live detail for one item when the AI asks to look closely. Nothing here is stored.
public enum AutopilotInspector {
  public static func inspect(_ item: AutopilotItem) -> [String: String] {
    switch item.kind {
    case .process: return process(item)
    case .worktree: return worktree(item)
    case .disk: return folder(item)
    }
  }

  static func process(_ item: AutopilotItem) -> [String: String] {
    let native = Native()
    guard let pid = item.pid, case .found(let o) = native.probe(pid),
      o.identity.key == item.processKey
    else { return ["state": "It already stopped or changed."] }
    var result = [
      "commandLine": native.commandLine(pid) ?? "unavailable",
      "workingFolder": native.currentDirectory(pid) ?? "unknown",
      "parentPID": String(o.parent), "processGroup": o.pgid.map { String($0) } ?? "unknown",
      "memory": AutopilotPolicy.format(o.rss), "agent": native.agent(pid) ?? "unknown",
      "listening": native.listening(pid).map { $0 ? "yes" : "no" } ?? "unknown",
      "started": Date(timeIntervalSince1970: TimeInterval(o.identity.seconds)).formatted(),
    ]
    let children = native.scan().observations.filter { $0.parent == pid }.prefix(12)
    result["children"] =
      children.isEmpty ? "none" : children.map { "\($0.name) (\($0.identity.pid))" }.joined(
        separator: ", ")
    return result
  }

  static func worktree(_ item: AutopilotItem) -> [String: String] {
    guard let path = item.path, FileManager.default.fileExists(atPath: path) else {
      return ["state": "The folder is gone."]
    }
    func git(_ args: [String]) -> String {
      (try? WorktreeGit.run(path, args, seconds: 10)).map {
        String(decoding: $0.prefix(4000), as: UTF8.self)
      } ?? "unavailable"
    }
    var result = [
      "status": git(["status", "--short", "--branch", "--untracked-files=normal"]),
      "recentCommits": git(["log", "-5", "--format=%h %cr %s"]),
      "branch": git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(
        in: .whitespacesAndNewlines),
      "aheadBehindUpstream": git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "size": AutopilotPolicy.format(item.bytes),
    ]
    result["saved"] = (try? AutopilotWorktrees.delivery(path: path).saved) ?? "unknown"
    let top = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    result["topLevel"] = top.sorted().prefix(40).joined(separator: ", ")
    return result
  }

  static func folder(_ item: AutopilotItem) -> [String: String] {
    guard let path = item.path,
      let entries = try? FileManager.default.contentsOfDirectory(atPath: path)
    else { return ["state": "The folder is gone."] }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    let producers = [
      "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Package.swift",
      "build.gradle", "build.gradle.kts", "Cargo.toml", "pyproject.toml", "requirements.txt",
      "Podfile", "Gemfile",
    ].filter { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
    let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
      as? Date
    return [
      "entries": String(entries.count),
      "sample": entries.sorted().prefix(30).joined(separator: ", "),
      "producersNextToIt": producers.isEmpty ? "none" : producers.joined(separator: ", "),
      "modified": modified?.formatted() ?? "unknown",
      "size": AutopilotPolicy.format(item.bytes),
    ]
  }
}
