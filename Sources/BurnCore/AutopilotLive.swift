import CryptoKit
import Darwin
import Foundation

extension AutopilotSources {
  /// Production wiring: the monitor's process records and burns, the worktree inventory,
  /// agent threads, junk folders, and the three executors. Proofs pass a `junk` cache that
  /// measures slowly. `keys` reads the backup key for burns without a keychain question. `docker`
  /// comes only from the running app, so no proof reaches the Mac's real Docker.
  public static func live(
    monitor: Monitor, root: URL = Store.defaultRoot, home: String = NSHomeDirectory(),
    junk: AutopilotJunkCache = AutopilotJunkCache(),
    recoveryKey: SymmetricKey? = nil,
    keys: AutopilotRecoveryKey = .shared, docker: AutopilotDockerCache? = nil
  ) -> AutopilotSources {
    // Kept with Autopilot's state, so a restart doesn't size and date every copy again.
    let store = try? AutopilotStore(root: root)
    let sizes = AutopilotSizes(store: store)
    let ages = AutopilotAges(store: store, walks: junk.walks)
    let skipped = AutopilotSkipped()
    // Without verified Full Disk Access, Autopilot leaves the places macOS protects alone.
    @Sendable func scope() -> ProtectedLocations { .current(root: root, homes: [home]) }
    // The temp folder is the real user's: a stand-in home has none.
    let trail = home == NSHomeDirectory() ? AutopilotBrowserTrail.temporaryFolder() : nil
    return AutopilotSources(
      threads: { AgentThreads.index(home: home) },
      processes: { threads in
        let records = await monitor.autopilotRecords()
        let preferences = await monitor.autopilotPreferences()
        return AutopilotProcesses.items(
          records, threads: threads, protectedPIDs: AgentSafety.ancestors(of: getpid()) ?? [],
          launchAgents: launchAgentPIDs(), claimed: await monitor.autopilotClaimedKeys(),
          preferences: preferences, home: home, protected: scope())
      },
      worktreeRecords: {
        let protected = scope()
        var places: [String] = []
        let records = await monitor.autopilotWorktreeRecords().filter { record in
          guard
            let place = protected.place(record.path) ?? protected.place(record.repository)
              ?? protected.pointerPlace(record.path)
          else { return true }
          if !record.retired && !record.main && !record.bare { places.append(place) }
          return false
        }
        skipped.set(places)
        return records
      },
      worktrees: { records, threads, cache in
        var delivery = cache
        // Git checks go only to copies big enough to be worth assessing.
        let worth = sizes.fill(records).filter { $0.allocated >= AutopilotPolicy.worthBytes }
        let items = AutopilotWorktrees.items(
          ages.fill(worth), threads: threads, delivery: &delivery, budget: 150)
        return (items, delivery)
      },
      disk: { records in
        junk.items(records, home: home, protected: scope(), trail: trail)
          + (docker?.items() ?? [])
      },
      burnProcess: { item, authority, why in
        guard let key = item.processKey else {
          throw StoreError.message("I lost track of which program that was.")
        }
        return try await monitor.autopilotBurn(
          key, authority: authority, label: item.name, rationale: why)
      },
      processOutcome: { await monitor.autopilotOutcome($0) },
      retireWorktree: { item, authority in
        let protected = scope()
        if let path = item.path,
          let place = protected.resolution(path).place ?? protected.pointerPlace(path)
        {
          return .refused(item, authority: authority, AutopilotDisk.protectedRefusal(place))
        }
        let receipt = junk.clearing(item.path) {
          AutopilotWorktrees.retire(
            item, authority: authority, root: root, protected: scope(), recoveryKey: recoveryKey,
            authorize: { Autopilot.executorAllowed(item, authority: authority, root: root) },
            keys: keys)
        }
        if receipt.outcome == "burned" { junk.forget(under: item.path) }
        return receipt
      },
      restoreWorktree: {
        try AutopilotWorktrees.restore(
          $0, protected: scope(), recoveryKey: recoveryKey, keys: keys)
      },
      reclaimDisk: { item, authority in
        // It has no folder. Only Docker removes anything, by exact record.
        if let docker, AutopilotDockerCache.isCache(item) {
          return docker.reclaim(
            item, authority: authority,
            authorize: { Autopilot.executorAllowed(item, authority: authority, root: root) })
        }
        let protected = scope()
        if let path = item.path, let place = protected.resolution(path).place {
          return .refused(item, authority: authority, AutopilotDisk.protectedRefusal(place))
        }
        let receipt = junk.clearing(item.path) {
          AutopilotDisk.reclaim(
            item, authority: authority, home: home, protected: scope(), root: root,
            recoveryKey: recoveryKey,
            authorize: { Autopilot.executorAllowed(item, authority: authority, root: root) },
            keys: keys)
        }
        if receipt.outcome == "burned" { junk.forget(under: item.path) }
        return receipt
      },
      inspect: { AutopilotInspector.inspect($0, protected: scope()) },
      evidence: { AutopilotEvidence.read($0, relativePath: $1, protected: scope()) },
      coverageNotes: {
        guard !scope().unrestricted else { return [] }
        let places = skipped.get()
        var note =
          "Full Disk Access is off, so I skip the places macOS protects: "
          + ProtectedLocations.summary + "."
        if !places.isEmpty {
          let names = places.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
          note +=
            places.count == 1
            ? " 1 old copy is in " + names[0] + "."
            : " \(places.count) old copies are in " + ProtectedLocations.list(names) + "."
        }
        return [note + " Turn on Full Disk Access to cover them too. Everything else is covered."]
      },
      recoveryKeyWait: { keys.wait },
      allowRecoveryKey: { try keys.allow() },
      retryRecoveryKey: { keys.retry() },
      processCount: {
        let uid = getuid()
        return await monitor.autopilotRecords().values.filter {
          $0.missingSince == nil && $0.latest.uid == uid
        }.count
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

/// Old copies Autopilot skipped because they are in places macOS protects, by place.
final class AutopilotSkipped: @unchecked Sendable {
  private let lock = NSLock()
  private var places: [String] = []
  func set(_ value: [String]) { lock.withLock { places = value } }
  func get() -> [String] { lock.withLock { places } }
}

/// Discovery runs in bounded background slices, preserving progress until every target has had
/// its turn. Completed checkouts wait six hours; newly discovered or newly dated copies run on the
/// next tick. When `slicePause` is set, unfinished rounds self-continue after a brief breather so
/// cold-start scans complete in minutes instead of waiting 15 minutes between slices.
public final class AutopilotJunkCache: @unchecked Sendable {
  private struct ScanContext {
    var records: [WorktreeRecord]
    var home: String
    var protected: ProtectedLocations
    var trail: String?
  }
  public static let maxContinuousSlices = 15
  private let lock = NSLock()
  private var cached: [AutopilotItem] = []
  private var cycleStarted: Date?
  private var progress = AutopilotDisk.ScanProgress()
  /// Inventory changes schedule work; they never certify that a checkout was fully scanned.
  private var observed: [String: Bool] = [:]
  private var latestContext: ScanContext?
  private var firstRoundNotified = false
  private var running = false
  /// Where its walk is, so a burn never finds BZ inside what it removes. Copies' age looks
  /// share it.
  public let walks = AutopilotWalks()
  private let sizer: (String, () -> Bool) -> UInt64?
  private let scanBudget: TimeInterval
  private let slicePause: TimeInterval?
  private let onFirstRoundComplete: (@Sendable () -> Void)?
  private let clock: () -> Date
  private static let unfinished =
    "I haven't finished checking this folder again, so I left it alone."
  /// `sizer` measures one junk folder and gives up as soon as its second argument says to.
  public init(
    sizer: @escaping (String, () -> Bool) -> UInt64? = {
      AutopilotDisk.allocatedSize($0, stop: $1)
    },
    scanBudget: TimeInterval = 60, slicePause: TimeInterval? = nil,
    onFirstRoundComplete: (@Sendable () -> Void)? = nil,
    clock: @escaping () -> Date = Date.init
  ) {
    self.sizer = sizer
    self.scanBudget = scanBudget
    self.slicePause = slicePause
    self.onFirstRoundComplete = onFirstRoundComplete
    self.clock = clock
  }

  /// Runs a burn of `path` with the walk out of it. The check for programs using a folder sees
  /// every program of this user, BZ included, so the walk's open folders and its Git would get
  /// the burn refused for hours.
  public func clearing<T>(_ path: String?, _ burn: () -> T) -> T {
    guard let path else { return burn() }
    return walks.clearing(path, burn)
  }

  func items(
    _ records: [WorktreeRecord], home: String, protected: ProtectedLocations,
    trail: String? = nil
  ) -> [AutopilotItem] {
    lock.withLock {
      latestContext = ScanContext(records: records, home: home, protected: protected, trail: trail)
    }
    startSliceIfNeeded(remainingContinuations: slicePause == nil ? 0 : Self.maxContinuousSlices - 1)
    // A folder listed before Full Disk Access was turned off is not looked at now.
    return lock.withLock {
      cached.filter {
        $0.path.map { protected.resolve($0) != nil && FileManager.default.fileExists(atPath: $0) }
          ?? false
      }
    }
  }

  private func startSliceIfNeeded(remainingContinuations: Int) {
    let scheduled: (walk: AutopilotDisk.ScanProgress, context: ScanContext)? = lock.withLock {
      guard !running, let context = latestContext,
        FileManager.default.fileExists(atPath: context.home)
      else { return nil }
      let now = clock()
      if cycleStarted == nil
        || (progress.roundFinished
          && cycleStarted.map({ now.timeIntervalSince($0) >= 6 * 3600 }) == true)
      {
        progress = AutopilotDisk.ScanProgress()
        observed = [:]
        cycleStarted = now
        // Old bytes stay useful while discovery resumes, but their old age/eligibility cannot
        // authorize cleanup before this cycle has successfully checked that target again.
        for index in cached.indices { cached[index].protectedReason = Self.unfinished }
      }
      for record in context.records {
        let dated = Self.dated(record)
        if observed[record.id] == nil || (observed[record.id] == false && dated) {
          let path = WorkspaceSafety.canonical(record.path)
          progress.invalidate(path)
          hold(under: [path])
        }
        observed[record.id] = dated
      }
      guard !progress.complete else { return nil }
      running = true
      return (progress, context)
    }
    guard let (walk, context) = scheduled else { return }
    Thread.detachNewThread { [self, walk, context, remainingContinuations] in
      var next = walk
      let fresh = AutopilotDisk.scan(
        worktrees: context.records, home: context.home,
        sizer: { folder in sizer(folder) { walks.wanted(folder) } }, protected: context.protected,
        walks: walks, trail: context.trail, progress: &next, budget: scanBudget, clock: clock)
      // Self-continue only when the scan genuinely paused because its slice budget expired, not
      // when a finished round politely stepped out of a folder currently being burned.
      let hitBudget = !next.roundFinished
      let skipped = walks.skipped()
      for path in skipped { next.invalidate(path) }
      let (notify, shouldContinue): ((@Sendable () -> Void)?, Bool) = lock.withLock {
        // Aggregated browser leftovers can be partial too. Keep an earlier observation
        // until every included measurement is known, while allowing a first partial discovery.
        let accepted = fresh.items.filter { item in
          item.path.map { fresh.measured.contains($0) } == true
            || !cached.contains(where: { $0.id == item.id })
        }
        let ids = Set(accepted.map(\.id))
        cached.removeAll {
          ids.contains($0.id)
            || $0.path.map { fresh.measured.contains($0) || fresh.discarded.contains($0) } == true
        }
        cached += accepted
        hold(under: fresh.incomplete.union(skipped))
        cached.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        progress = next
        running = false
        var callback: (@Sendable () -> Void)?
        if !firstRoundNotified && next.roundFinished {
          firstRoundNotified = true
          callback = onFirstRoundComplete
        }
        let more = slicePause != nil && remainingContinuations > 0 && hitBudget
        return (callback, more)
      }
      notify?()
      if shouldContinue, let pause = slicePause {
        Thread.sleep(forTimeInterval: max(0.01, pause))
        startSliceIfNeeded(remainingContinuations: remainingContinuations - 1)
      }
    }
  }
  /// Called with the cache lock held. Overlap also protects a browser aggregate when one of
  /// its children is unknown. A later successful observation replaces, rather than clears, it.
  private func hold(under paths: Set<String>) {
    guard !paths.isEmpty else { return }
    for index in cached.indices {
      if let path = cached[index].path,
        paths.contains(where: { AutopilotWalks.overlap($0, path) })
      {
        cached[index].protectedReason = Self.unfinished
      }
    }
  }
  func forget(under path: String?) {
    guard let path else { return }
    lock.withLock { cached.removeAll { $0.path == path || ($0.path ?? "").hasPrefix(path + "/") } }
  }
  /// Whether a walk can tell how old the copy is: junk counts as inside an old copy only then.
  private static func dated(_ record: WorktreeRecord) -> Bool {
    record.main || record.lastFileChange != nil || record.lastCommitAt != nil
  }
}

/// Where the junk walk is, by real path, so a burn never finds BZ itself inside what it removes.
/// The walk doesn't go into a folder being burned and leaves one it is in at its next step; the
/// burn waits for it to go.
public final class AutopilotWalks: @unchecked Sendable {
  private let condition = NSCondition()
  private var burning: [String] = []
  private var walking: [String] = []
  /// What the walk skipped or left for a burn since `skipped()` last asked.
  private var left: [String] = []

  /// Runs `burn` once no walk is inside `path`, or once `patience` has passed: a walk still in
  /// there is then for the burn's own check to judge.
  func clearing<T>(_ path: String, patience: TimeInterval = 10, _ burn: () -> T) -> T {
    let real = WorkspaceSafety.canonical(path)
    condition.withLock {
      burning.append(real)
      let limit = Date().addingTimeInterval(patience)
      while walking.contains(where: { Self.overlap($0, real) }), condition.wait(until: limit) {}
    }
    defer {
      condition.withLock {
        if let index = burning.firstIndex(of: real) { burning.remove(at: index) }
      }
    }
    return burn()
  }

  /// Whether the walk may go into `target` now. Once in, it is there until `leave`.
  func enter(_ target: String) -> Bool {
    condition.withLock {
      if burning.contains(where: { Self.overlap($0, target) }) {
        left.append(target)
        return false
      }
      walking.append(target)
      return true
    }
  }

  /// Whether a burn wants the walk out of `path`.
  func wanted(_ path: String) -> Bool {
    condition.withLock { burning.contains { Self.overlap($0, path) } }
  }

  func leave(_ target: String, early: Bool) {
    condition.withLock {
      if let index = walking.firstIndex(of: target) { walking.remove(at: index) }
      if early { left.append(target) }
      condition.broadcast()
    }
  }

  func skipped() -> [String] {
    condition.withLock {
      defer { left = [] }
      return left
    }
  }

  /// One folder is the other or inside it.
  static func overlap(_ a: String, _ b: String) -> Bool {
    WorkspaceSafety.contains(a, b) || WorkspaceSafety.contains(b, a)
  }
}

/// Live detail for one item when the AI asks to look closely. Nothing here is stored.
public enum AutopilotInspector {
  public static func inspect(_ item: AutopilotItem, protected: ProtectedLocations = .limited())
    -> [String: String]
  {
    if AutopilotDockerCache.isCache(item) { return AutopilotDockerCache.inspect(item) }
    if item.kind != .process, let path = item.path,
      let place = protected.resolution(path).place ?? protected.pointerPlace(path)
    {
      return ["state": AutopilotDisk.protectedRefusal(place)]
    }
    var result: [String: String]
    switch item.kind {
    case .process: result = process(item)
    case .worktree: result = worktree(item)
    case .disk: result = folder(item)
    }
    let evidence = AutopilotEvidence.overview(item, protected: protected)
    if !evidence.isEmpty { result["projectEvidence"] = evidence }
    return result
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
      children.isEmpty
      ? "none"
      : children.map { "\($0.name) (\($0.identity.pid))" }.joined(
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
    let modified =
      (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
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
