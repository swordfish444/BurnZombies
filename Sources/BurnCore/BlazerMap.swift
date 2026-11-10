import CSQLite
import Darwin
import Foundation

/// Read-only projection for the map. Disk and resident memory are distinct measures.
/// A row records evidence, never authorization or guaranteed APFS recovery.
public struct BlazerMap: Encodable, Sendable {
  public struct Row: Encodable, Sendable {
    public enum Kind: String, Encodable, Sendable { case worktree, cache, zombie, folder }
    public var id: String
    public var kind: Kind
    public var name: String
    public var path: String? = nil
    public var state: String
    public var detail: String
    public var source: String
    public var diskBytes: UInt64? = nil
    public var memoryBytes: UInt64? = nil
    public var lastUsed: Date? = nil
    public var observedAt: Date? = nil
    public var live = false

    public init(
      id: String, kind: Kind, name: String, path: String? = nil, state: String,
      detail: String, source: String, diskBytes: UInt64? = nil, memoryBytes: UInt64? = nil,
      lastUsed: Date? = nil, observedAt: Date? = nil, live: Bool = false
    ) {
      self.id = id
      self.kind = kind
      self.name = name
      self.path = path
      self.state = state
      self.detail = detail
      self.source = source
      self.diskBytes = diskBytes
      self.memoryBytes = memoryBytes
      self.lastUsed = lastUsed
      self.observedAt = observedAt
      self.live = live
    }
  }

  public var observedAt: Date
  public var durationMS: Int
  public var volume: BlazerOverdrive.VolumeTelemetry
  public var indexedSessions: Int
  public var liveSessions: Int
  public var rows: [Row]
  public var notes: [String]
  public var demo = false

  public init(
    observedAt: Date, durationMS: Int, volume: BlazerOverdrive.VolumeTelemetry,
    indexedSessions: Int, liveSessions: Int, rows: [Row], notes: [String], demo: Bool = false
  ) {
    self.observedAt = observedAt
    self.durationMS = durationMS
    self.volume = volume
    self.indexedSessions = indexedSessions
    self.liveSessions = liveSessions
    self.rows = rows
    self.notes = notes
    self.demo = demo
  }

  public static func scan(home: String = NSHomeDirectory(), root: URL = Store.defaultRoot) -> Self {
    let started = ProcessInfo.processInfo.systemUptime
    let now = Date()
    // Cached observations may have been made by the signed app with greater visibility.
    let scope = ProtectedLocations.limited(homes: [home])
    let xray = BlazerXRay.scan(home: home, root: root, now: now, topItemLimit: 200, protected: scope)
    var notes = [
      "Local, bounded snapshot. Skips macOS-protected locations and external volumes.",
      "Disk estimates can overlap and don't predict how much APFS would free. Process sizes are RAM.",
    ]
    func visible(_ path: String?) -> String? {
      guard let path, path.hasPrefix("/"), scope.allows(path) else { return nil }
      return path
    }
    func leaf(_ path: String) -> String { (path as NSString).lastPathComponent }
    var rows = [Row]()
    var seenCaches = Set<String>()
    for item in xray.topDisguisedItems {
      guard let path = visible(item.path), seenCaches.insert(path).inserted else { continue }
      rows.append(Row(
        id: item.id, kind: .cache, name: leaf(path), path: path,
        state: item.protectedReason == nil ? "Signature detected" : "Held",
        detail: item.protectedReason ?? item.detail, source: "Anatomical X-Ray · bounded estimate",
        diskBytes: item.bytes, lastUsed: item.lastUsed, observedAt: item.observedAt))
    }
    if xray.disguisedCategories.reduce(0, { $0 + $1.count }) > xray.topDisguisedItems.count {
      notes.append("X-Ray shows the first 200 disguised cache findings.")
    }
    for finding in xray.thrashFindings {
      rows.append(Row(
        id: finding.id, kind: .zombie, name: finding.kind.badge.capitalized,
        path: visible(finding.cwd), state: finding.live ? "Live signal" : "Historical signal",
        detail: "\(finding.agent.capitalized) · \(finding.summary)", source: "Thrash Hunter · heuristic",
        lastUsed: finding.lastActive, observedAt: now, live: finding.live))
    }
    notes.append("Thrash Hunter shows up to 12 signals; they are leads, not cleanup decisions.")

    do {
      let worktrees = try cachedWorktrees(root: root)
      let available = worktrees.filter {
        !$0.main && !$0.bare && !$0.retired && visible($0.path) != nil
          && scope.allows($0.repository) && $0.protectedPlace == nil
      }.sorted { $0.allocated == $1.allocated ? $0.path < $1.path : $0.allocated > $1.allocated }
      for record in available.prefix(1_500) {
        let state = record.missing ? "Missing or moved" : record.state
        let reason = (record.blockers + record.gaps).prefix(2).joined(separator: " ")
        let repo = leaf(record.repository)
        let branch = record.branch?.replacingOccurrences(of: "refs/heads/", with: "")
        let checkout = leaf(record.path)
        let name = branch ?? (checkout == repo ? repo : "\(repo) / \(checkout)")
        let detail = [
          "Repository: " + repo, record.ownerManaged ? "Agent managed" : nil,
          record.locked ? "Git worktree lock recorded" : nil, reason.isEmpty ? nil : reason,
        ].compactMap { $0 }.joined(separator: " · ")
        rows.append(Row(
          id: "map-worktree:" + record.id, kind: .worktree, name: name,
          path: record.path, state: state, detail: detail, source: "Saved worktree inventory",
          diskBytes: !record.missing && record.allocated > 0 ? record.allocated : nil,
          lastUsed: [record.lastCommitAt, record.lastFileChange].compactMap { $0 }.max(),
          observedAt: record.observedAt))
      }
      if available.count > 1_500 { notes.append("Showing the 1,500 largest inventoried worktrees.") }
      if available.isEmpty { notes.append("The saved inventory has no visible linked worktrees.") }
    } catch {
      notes.append("Saved worktree inventory unavailable. Run a worktree scan in the app and regenerate.")
    }

    do {
      let store = try Store(reading: root)
      let catalog = try store.load()
      if catalog.lastSample == nil { notes.append("No saved process observations.") }
      let orphans = catalog.records.values.filter {
        $0.missingSince == nil && $0.latest.uid == getuid()
          && ($0.latest.zombie || $0.orphanSince != nil)
      }.sorted { $0.latest.time > $1.latest.time }
      if orphans.count > 120 { notes.append("Only the 120 most recent saved orphan observations were checked.") }
      for record in orphans.prefix(120) {
        guard case .found(let current) = Native().probe(record.latest.identity.pid, now: now),
          current.identity == record.latest.identity, current.uid == getuid(),
          current.zombie || (current.parent == 1 && record.orphanSince != nil)
        else { continue }
        rows.append(Row(
          id: "map-process:" + record.id, kind: .zombie, name: current.name,
          path: visible(current.executable), state: current.zombie ? "Exited child" : "Observed orphan",
          detail: "PID \(current.identity.pid) · "
            + (current.zombie
              ? "Exited; macOS handles reaping." : "The observer saw it reparent to launchd. It may still be in use."),
          source: "Observer history + live process identity",
          memoryBytes: current.metricsValid ? current.rss : nil,
          lastUsed: record.lastBusy ?? record.firstSeen, observedAt: now, live: !current.zombie))
      }

      let disk = FileManager.default.fileExists(atPath: root.appendingPathComponent("disk-inventory.json").path)
        ? try? DiskSnapshot.load(store) : nil
      let diskRows = (disk?.candidates ?? catalog.diskCandidates ?? []).filter { visible($0.path) != nil }
        .sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes }
      for item in diskRows.prefix(200) where seenCaches.insert(item.path).inserted {
        rows.append(Row(
          id: "map-cache:" + item.id, kind: .cache, name: leaf(item.path), path: item.path,
          state: item.complete ? "Inventoried" : "Partial measurement",
          detail: item.guardReason, source: "Saved cache inventory", diskBytes: item.bytes,
          lastUsed: item.newest, observedAt: item.observedAt ?? disk?.date))
      }
      let discovery = FileManager.default.fileExists(atPath: root.appendingPathComponent("disk-discovery.json").path)
        ? try? DiskDiscoveryState.load(store) : nil
      let folders = (discovery?.nodes ?? catalog.diskDiscovery ?? [])
        .filter { $0.members == nil && visible($0.path) != nil }
        .sorted { $0.allocated == $1.allocated ? $0.path < $1.path : $0.allocated > $1.allocated }
      for item in folders.prefix(200) {
        rows.append(Row(
          id: item.id, kind: .folder, name: leaf(item.path), path: item.path,
          state: item.complete ? "Measured" : "Partial measurement",
          detail: "\(item.files) files · \(BlazerXRay.formatBytes(item.unshared)) observed unshared",
          source: "Saved Disk Discovery", diskBytes: item.allocated, observedAt: item.measured))
      }
      if diskRows.count > 200 || folders.count > 200 {
        notes.append("Storage inventory shows up to 200 cache candidates and 200 folders.")
      }
      if folders.isEmpty { notes.append("No visible saved folder measurements. Volume telemetry is independent.") }
    } catch {
      notes.append("Saved process and disk inventory unavailable.")
    }
    return Self(
      observedAt: now, durationMS: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
      volume: xray.volume, indexedSessions: xray.indexedSessions, liveSessions: xray.liveSessions,
      rows: rows, notes: notes)
  }

  // The inventory service's list also projects cleanup proposals. Read the existing rows
  // directly, without opening the writable service, running Git, or starting an observer.
  private static func cachedWorktrees(root: URL) throws -> [WorktreeRecord] {
    let unavailable = StoreError.message("Saved worktree inventory is unavailable or incomplete.")
    let path = root.appendingPathComponent("worktrees.sqlite").path
    var info = stat()
    guard lstat(root.path, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFDIR,
      lstat(path, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
      info.st_mode & S_IFMT == S_IFREG
    else { throw unavailable }
    var db: OpaquePointer?
    let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
    defer { if let db { sqlite3_close(db) } }
    guard result == SQLITE_OK, let db else { throw unavailable }
    sqlite3_busy_timeout(db, 250)
    var versionQuery: OpaquePointer?
    let versionResult = sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &versionQuery, nil)
    let versionOK = versionResult == SQLITE_OK && sqlite3_step(versionQuery) == SQLITE_ROW
      && sqlite3_column_int(versionQuery, 0) == 1
    sqlite3_finalize(versionQuery)
    guard versionOK else { throw unavailable }
    var query: OpaquePointer?
    // Version 1 stores the last observation for each worktree as JSON.
    let sql = """
      SELECT kind, payload FROM documents
      WHERE kind = 'record' OR (kind = 'policy' AND id = 'current')
      ORDER BY kind, id LIMIT 10002
      """
    guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
      throw unavailable
    }
    defer { sqlite3_finalize(query) }
    let decoder = JSONDecoder()
    var policy = WorktreePolicy()
    var rows = [WorktreeRecord]()
    while true {
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { break }
      let count = Int(sqlite3_column_bytes(query, 1))
      guard code == SQLITE_ROW, rows.count <= 10_000, count > 0, count <= 65_536,
        let kind = sqlite3_column_text(query, 0), let bytes = sqlite3_column_blob(query, 1)
      else { throw unavailable }
      let data = Data(bytes: bytes, count: count)
      if String(cString: kind) == "policy" {
        policy = try decoder.decode(WorktreePolicy.self, from: data)
        try policy.validate()
      } else {
        rows.append(try decoder.decode(WorktreeRecord.self, from: data))
      }
    }
    guard rows.count <= 10_000 else { throw unavailable }
    let roots = policy.roots + [root.appendingPathComponent("workspaces").path]
    return rows.filter { row in
      roots.contains { row.path == $0 || row.path.hasPrefix($0 + "/") }
    }
  }
}
