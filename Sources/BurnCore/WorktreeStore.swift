import CSQLite
import Darwin
import Foundation

/// Only WorktreeService owns a live store. FULLMUTEX also protects fixture/backup use.
public final class WorktreeStore: @unchecked Sendable {
  private var db: OpaquePointer?
  public let root: URL
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  public init(root: URL, databaseName: String = "worktrees.sqlite") throws {
    guard ["worktrees.sqlite", "intent.sqlite"].contains(databaseName) else {
      throw StoreError.message("Unsupported state database.")
    }
    _ = try Store(root: root)
    self.root = URL(fileURLWithPath: WorkspaceSafety.canonical(root.path))
    let path = self.root.appendingPathComponent(databaseName).path
    var s = stat()
    if lstat(path, &s) == 0 {
      guard s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else {
        throw StoreError.message("Unsafe worktree database; worktree operations paused.")
      }
    } else if errno != ENOENT {
      throw StoreError.message("Worktree database identity unavailable.")
    }
    guard
      sqlite3_open_v2(
        path, &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
        nil) == SQLITE_OK
    else {
      let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no SQLite handle"
      if let db { sqlite3_close(db) }
      db = nil
      throw StoreError.message("Cannot open worktree database: " + reason)
    }
    do {
      guard chmod(path, 0o600) == 0 else {
        throw StoreError.message("Cannot protect worktree database.")
      }
      sqlite3_busy_timeout(db, 2000)
      try execute("PRAGMA synchronous=FULL")
      let v = try scalar("PRAGMA user_version")
      guard v == "0" || v == "1" else {
        throw StoreError.message(
          "Unsupported worktree database version; preserve state and update.")
      }
      try execute(
        "CREATE TABLE IF NOT EXISTS documents (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))"
      )
      try execute("PRAGMA user_version=1")
      guard try scalar("PRAGMA quick_check") == "ok" else {
        throw StoreError.message("Worktree database integrity failed.")
      }
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }
  deinit { sqlite3_close(db) }
  private func statement(_ sql: String) throws -> OpaquePointer {
    var p: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else {
      throw StoreError.message("Worktree database query failed.")
    }
    return p
  }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw StoreError.message("Worktree database transaction failed.")
    }
  }
  private func scalar(_ sql: String) throws -> String {
    let p = try statement(sql)
    defer { sqlite3_finalize(p) }
    guard sqlite3_step(p) == SQLITE_ROW, let text = sqlite3_column_text(p, 0) else {
      throw StoreError.message("Worktree database result unavailable.")
    }
    return String(cString: text)
  }
  public func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
  public func put<T: Encodable>(_ value: T, kind: String, id: String) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= 4_194_304 else {
      throw StoreError.message("Worktree record exceeds storage limit.")
    }
    let p = try statement(
      "INSERT INTO documents(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload"
    )
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    sqlite3_bind_text(p, 2, id, -1, transient)
    _ = data.withUnsafeBytes {
      sqlite3_bind_blob(p, 3, $0.baseAddress, Int32(data.count), transient)
    }
    guard sqlite3_step(p) == SQLITE_DONE else {
      throw StoreError.message("Cannot persist worktree state.")
    }
  }
  public func values<T: Decodable>(_ type: T.Type, kind: String, limit: Int = 10_000) throws -> [T]
  {
    let p = try statement("SELECT payload FROM documents WHERE kind=? ORDER BY id LIMIT ?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    sqlite3_bind_int(p, 2, Int32(min(max(limit, 1), 100_000) + 1))
    var values: [T] = []
    while true {
      let code = sqlite3_step(p)
      if code == SQLITE_DONE { return values }
      guard code == SQLITE_ROW, values.count < limit, sqlite3_column_bytes(p, 0) <= 4_194_304,
        let bytes = sqlite3_column_blob(p, 0)
      else { throw StoreError.message("Incomplete or oversized worktree query; preserved.") }
      values.append(
        try JSONDecoder().decode(
          T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(p, 0)))))
    }
  }
  public func value<T: Decodable>(_ type: T.Type, kind: String, id: String) throws -> T? {
    let p = try statement("SELECT payload FROM documents WHERE kind=? AND id=?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    sqlite3_bind_text(p, 2, id, -1, transient)
    let code = sqlite3_step(p)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW, sqlite3_column_bytes(p, 0) <= 4_194_304,
      let bytes = sqlite3_column_blob(p, 0)
    else { throw StoreError.message("Worktree lookup failed or exceeded its bounds.") }
    return try JSONDecoder().decode(
      T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(p, 0))))
  }
  /// Scoped intent queries bind both field and value. No caller-provided SQL.
  public func matching<T: Decodable>(
    _ type: T.Type, kind: String, field: String, value: String, limit: Int = 10000
  ) throws -> [T] {
    guard ["workflow", "ruleID", "outcome", "proposal", "state", "action"].contains(field),
      (1...100000).contains(limit)
    else {
      throw StoreError.message("Unsupported scoped state query.")
    }
    let p = try statement(
      "SELECT payload FROM documents WHERE kind=? AND json_extract(payload,?)=? ORDER BY rowid DESC LIMIT ?"
    )
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    sqlite3_bind_text(p, 2, "$." + field, -1, transient)
    sqlite3_bind_text(p, 3, value, -1, transient)
    sqlite3_bind_int(p, 4, Int32(limit + 1))
    return try decodeRows(type, statement: p, limit: limit)
  }
  /// Permission revocation is not a paged presentation query. Revoke every
  /// unconsumed approval in this scope, regardless of resolved history size.
  public func invalidateApprovals(workflow: String) throws {
    let p = try statement(
      "UPDATE documents SET payload=json_set(json_remove(payload,'$.approvedRevision','$.approvedUntil'),'$.state',CASE json_extract(payload,'$.state') WHEN 'approved' THEN 'review' ELSE json_extract(payload,'$.state') END) WHERE kind='proposal' AND json_extract(payload,'$.workflow')=? AND json_extract(payload,'$.operationID') IS NULL"
    )
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, workflow, -1, transient)
    guard sqlite3_step(p) == SQLITE_DONE else {
      throw StoreError.message("Could not revoke workflow approvals.")
    }
  }
  public func overlapping<T: Decodable>(_ type: T.Type, kind: String, resources: [String]) throws
    -> [T]
  {
    guard !resources.isEmpty, resources.count <= 64 else {
      throw StoreError.message("Invalid resource scope.")
    }
    let markers = Array(repeating: "?", count: resources.count).joined(separator: ",")
    let p = try statement(
      "SELECT payload FROM documents WHERE kind=? AND EXISTS(SELECT 1 FROM json_each(documents.payload,'$.resources') WHERE value IN ("
        + markers + ")) LIMIT 10001")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    for (i, value) in resources.enumerated() {
      sqlite3_bind_text(p, Int32(i + 2), value, -1, transient)
    }
    return try decodeRows(type, statement: p, limit: 10000)
  }
  private func decodeRows<T: Decodable>(_ type: T.Type, statement p: OpaquePointer, limit: Int)
    throws -> [T]
  {
    var result: [T] = []
    while true {
      let code = sqlite3_step(p)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW, result.count < limit, sqlite3_column_bytes(p, 0) <= 4_194_304,
        let bytes = sqlite3_column_blob(p, 0)
      else { throw StoreError.message("Scoped query exceeded coverage limits.") }
      result.append(
        try JSONDecoder().decode(
          T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(p, 0)))))
    }
  }
  public func count(kind: String) throws -> Int {
    let p = try statement("SELECT count(*) FROM documents WHERE kind=?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    guard sqlite3_step(p) == SQLITE_ROW else {
      throw StoreError.message("State count unavailable.")
    }
    return Int(sqlite3_column_int64(p, 0))
  }
  public func findingPage(offset: Int, limit: Int = 1000) throws -> [CleanupProposal] {
    guard (0...1_000_000).contains(offset), (1...1000).contains(limit) else {
      throw StoreError.message("Invalid finding page.")
    }
    let p = try statement(
      """
      SELECT payload FROM documents WHERE kind='proposal' ORDER BY
      CASE json_extract(payload,'$.state')
        WHEN 'pending verification' THEN 0 WHEN 'approved' THEN 1
        WHEN 'review' THEN CASE WHEN json_extract(payload,'$.ready')=1 THEN 2 ELSE 4 END
        WHEN 'kept' THEN 3 ELSE 5 END,
      json_extract(payload,'$.observed') DESC, rowid DESC LIMIT ? OFFSET ?
      """)
    defer { sqlite3_finalize(p) }
    sqlite3_bind_int(p, 1, Int32(limit))
    sqlite3_bind_int(p, 2, Int32(offset))
    return try decodeRows(CleanupProposal.self, statement: p, limit: limit)
  }
  public func notificationProposals(now: Date) throws -> [CleanupProposal] {
    let p = try statement(
      """
      SELECT payload FROM documents AS p WHERE kind='proposal'
      AND json_extract(payload,'$.state')='review' AND json_extract(payload,'$.ready')=1
      AND json_extract(payload,'$.fixture')=0 AND json_extract(payload,'$.observed') >= ?
      AND (json_extract(payload,'$.action') != 'worktree' OR json_extract(payload,'$.notificationEligible')=1)
      AND coalesce(json_extract(payload,'$.snoozedUntil'),0) <= ?
      AND NOT EXISTS (SELECT 1 FROM documents AS n WHERE n.kind='notification-sent'
        AND n.id = p.id || ':' || json_extract(p.payload,'$.revision'))
      ORDER BY json_extract(payload,'$.created') ASC, rowid ASC LIMIT 100
      """)
    defer { sqlite3_finalize(p) }
    sqlite3_bind_double(p, 1, now.addingTimeInterval(-300).timeIntervalSinceReferenceDate)
    sqlite3_bind_double(p, 2, now.timeIntervalSinceReferenceDate)
    return try decodeRows(CleanupProposal.self, statement: p, limit: 100)
  }
  public func openProposals(action: CleanupAction) throws -> [CleanupProposal] {
    let p = try statement(
      "SELECT payload FROM documents WHERE kind='proposal' AND json_extract(payload,'$.action')=? AND json_extract(payload,'$.operationID') IS NULL AND json_extract(payload,'$.state') IN ('review','approved') LIMIT 100001"
    )
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, action.rawValue, -1, transient)
    return try decodeRows(CleanupProposal.self, statement: p, limit: 100000)
  }
  public func remove(kind: String, id: String) throws {
    let p = try statement("DELETE FROM documents WHERE kind=? AND id=?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    sqlite3_bind_text(p, 2, id, -1, transient)
    guard sqlite3_step(p) == SQLITE_DONE else {
      throw StoreError.message("Could not remove preference history.")
    }
  }
  /// Presentation retention never removes operation bindings, Keeps, native
  /// recovery journals or evidence supporting an active rule/pending decision.
  public func compactIntentPresentation(now: Date) throws {
    let statements: [(String, Double)] = [
      (
        "DELETE FROM documents WHERE kind='proposal' AND json_extract(payload,'$.state')='absent' AND json_extract(payload,'$.operationID') IS NULL AND json_extract(payload,'$.observed') < ?",
        now.addingTimeInterval(-90 * 86400).timeIntervalSinceReferenceDate
      ),
      (
        "DELETE FROM documents WHERE kind='delivery' AND CAST(payload AS REAL) < ?",
        now.addingTimeInterval(-30 * 86400).timeIntervalSinceReferenceDate
      ),
      (
        """
        DELETE FROM documents AS d WHERE d.kind='decision' AND json_extract(d.payload,'$.date') < ?
        AND NOT EXISTS (SELECT 1 FROM documents AS r WHERE r.kind='rule'
          AND json_extract(r.payload,'$.workflow')=json_extract(d.payload,'$.workflow')
          AND json_extract(r.payload,'$.enabled')=1)
        AND NOT EXISTS (SELECT 1 FROM documents AS p WHERE p.kind='proposal'
          AND p.id=json_extract(d.payload,'$.proposal')
          AND json_extract(p.payload,'$.state') IN ('kept','approved','review','pending verification'))
        """, now.addingTimeInterval(-90 * 86400).timeIntervalSinceReferenceDate
      ),
      (
        """
        UPDATE documents SET payload=json_set(json_remove(payload,'$.path'),'$.detail','Historical resolved finding; native operation binding retained.','$.title','Historical finding')
        WHERE kind='proposal' AND json_extract(payload,'$.observed') < ?
        AND json_extract(payload,'$.state') IN ('verified','refused','absent')
        AND NOT EXISTS (SELECT 1 FROM documents AS r WHERE r.kind='rule'
          AND json_extract(r.payload,'$.workflow')=json_extract(documents.payload,'$.workflow')
          AND json_extract(r.payload,'$.enabled')=1)
        """, now.addingTimeInterval(-90 * 86400).timeIntervalSinceReferenceDate
      ),
    ]
    try transaction {
      for (sql, cutoff) in statements {
        let p = try statement(sql)
        defer { sqlite3_finalize(p) }
        sqlite3_bind_double(p, 1, cutoff)
        guard sqlite3_step(p) == SQLITE_DONE else {
          throw StoreError.message("History retention failed; operation authority retained.")
        }
      }
    }
  }
  public func page<T: Decodable>(
    _ type: T.Type, kind: String, offset: Int, limit: Int = 100, newest: Bool = false
  ) throws -> [T] {
    guard offset >= 0, offset <= 1_000_000, (1...1000).contains(limit) else {
      throw StoreError.message("Invalid worktree page bounds.")
    }
    let p = try statement(
      "SELECT payload FROM documents WHERE kind=? ORDER BY " + (newest ? "rowid DESC" : "id")
        + " LIMIT ? OFFSET ?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient)
    sqlite3_bind_int(p, 2, Int32(limit))
    sqlite3_bind_int(p, 3, Int32(offset))
    var result: [T] = []
    var total = 0
    while true {
      let code = sqlite3_step(p)
      if code == SQLITE_DONE { return result }
      let size = Int(sqlite3_column_bytes(p, 0))
      total += size
      guard code == SQLITE_ROW, size <= 4_194_304, total <= 16_777_216,
        let bytes = sqlite3_column_blob(p, 0)
      else { throw StoreError.message("Worktree page exceeds bounded coverage.") }
      result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: size)))
    }
  }
  public func backup(to destination: URL) throws {
    let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Backup destination exists or is unsafe.") }
    close(fd)
    var copy: OpaquePointer?
    guard
      sqlite3_open_v2(
        destination.path, &copy,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK
    else {
      sqlite3_close(copy)
      throw StoreError.message("Cannot create database backup.")
    }
    defer { sqlite3_close(copy) }
    guard let backup = sqlite3_backup_init(copy, "main", db, "main") else {
      throw StoreError.message("Cannot start database backup.")
    }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK, chmod(destination.path, 0o600) == 0 else {
      throw StoreError.message("Database backup failed.")
    }
  }
}
