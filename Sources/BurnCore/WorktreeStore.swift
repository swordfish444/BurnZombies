import CSQLite
import Darwin
import Foundation

/// Only WorktreeService owns a live store. FULLMUTEX also protects fixture/backup use.
public final class WorktreeStore: @unchecked Sendable {
  private var db: OpaquePointer?
  public let root: URL
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  public init(root: URL) throws {
    _ = try Store(root: root)
    self.root = URL(fileURLWithPath: WorkspaceSafety.canonical(root.path))
    let path = self.root.appendingPathComponent("worktrees.sqlite").path
    var s = stat()
    if lstat(path, &s) == 0 {
      guard s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else {
        throw StoreError.message("Unsafe worktree database; worktree operations paused.")
      }
    } else if errno != ENOENT { throw StoreError.message("Worktree database identity unavailable.") }
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
      let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no SQLite handle"
      if let db { sqlite3_close(db) }; db = nil
      throw StoreError.message("Cannot open worktree database: " + reason)
    }
    do {
      guard chmod(path, 0o600) == 0 else { throw StoreError.message("Cannot protect worktree database.") }
      sqlite3_busy_timeout(db, 2000)
      try execute("PRAGMA synchronous=FULL")
      let v = try scalar("PRAGMA user_version")
      guard v == "0" || v == "1" else { throw StoreError.message("Unsupported worktree database version; preserve state and update.") }
      try execute("CREATE TABLE IF NOT EXISTS documents (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))")
      try execute("PRAGMA user_version=1")
      guard try scalar("PRAGMA quick_check") == "ok" else { throw StoreError.message("Worktree database integrity failed.") }
    } catch { sqlite3_close(db); db = nil; throw error }
  }
  deinit { sqlite3_close(db) }
  private func statement(_ sql: String) throws -> OpaquePointer {
    var p: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else { throw StoreError.message("Worktree database query failed.") }
    return p
  }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.message("Worktree database transaction failed.") }
  }
  private func scalar(_ sql: String) throws -> String {
    let p = try statement(sql); defer { sqlite3_finalize(p) }
    guard sqlite3_step(p) == SQLITE_ROW, let text = sqlite3_column_text(p, 0) else { throw StoreError.message("Worktree database result unavailable.") }
    return String(cString: text)
  }
  public func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do { let result = try body(); try execute("COMMIT"); return result }
    catch { try? execute("ROLLBACK"); throw error }
  }
  public func put<T: Encodable>(_ value: T, kind: String, id: String) throws {
    let data = try JSONEncoder().encode(value)
    guard data.count <= 4_194_304 else { throw StoreError.message("Worktree record exceeds storage limit.") }
    let p = try statement("INSERT INTO documents(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient); sqlite3_bind_text(p, 2, id, -1, transient)
    _ = data.withUnsafeBytes { sqlite3_bind_blob(p, 3, $0.baseAddress, Int32(data.count), transient) }
    guard sqlite3_step(p) == SQLITE_DONE else { throw StoreError.message("Cannot persist worktree state.") }
  }
  public func values<T: Decodable>(_ type: T.Type, kind: String, limit: Int = 10_000) throws -> [T] {
    let p = try statement("SELECT payload FROM documents WHERE kind=? ORDER BY id LIMIT ?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient); sqlite3_bind_int(p, 2, Int32(min(max(limit, 1), 100_000) + 1))
    var values: [T] = []
    while true {
      let code = sqlite3_step(p)
      if code == SQLITE_DONE { return values }
      guard code == SQLITE_ROW, values.count < limit, sqlite3_column_bytes(p, 0) <= 4_194_304,
        let bytes = sqlite3_column_blob(p, 0) else { throw StoreError.message("Incomplete or oversized worktree query; preserved.") }
      values.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(p, 0)))))
    }
  }
  public func value<T: Decodable>(_ type: T.Type, kind: String, id: String) throws -> T? {
    let p = try statement("SELECT payload FROM documents WHERE kind=? AND id=?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient); sqlite3_bind_text(p, 2, id, -1, transient)
    let code = sqlite3_step(p)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW, sqlite3_column_bytes(p, 0) <= 4_194_304, let bytes = sqlite3_column_blob(p, 0) else { throw StoreError.message("Worktree lookup failed or exceeded its bounds.") }
    return try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(p, 0))))
  }
  public func page<T: Decodable>(_ type: T.Type, kind: String, offset: Int, limit: Int = 100, newest: Bool = false) throws -> [T] {
    guard offset >= 0, offset <= 1_000_000, (1...1000).contains(limit) else { throw StoreError.message("Invalid worktree page bounds.") }
    let p = try statement("SELECT payload FROM documents WHERE kind=? ORDER BY " + (newest ? "rowid DESC" : "id") + " LIMIT ? OFFSET ?")
    defer { sqlite3_finalize(p) }
    sqlite3_bind_text(p, 1, kind, -1, transient); sqlite3_bind_int(p, 2, Int32(limit)); sqlite3_bind_int(p, 3, Int32(offset))
    var result: [T] = [], total = 0
    while true {
      let code = sqlite3_step(p)
      if code == SQLITE_DONE { return result }
      let size = Int(sqlite3_column_bytes(p, 0)); total += size
      guard code == SQLITE_ROW, size <= 4_194_304, total <= 16_777_216, let bytes = sqlite3_column_blob(p, 0) else { throw StoreError.message("Worktree page exceeds bounded coverage.") }
      result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: size)))
    }
  }
  public func backup(to destination: URL) throws {
    let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Backup destination exists or is unsafe.") }; close(fd)
    var copy: OpaquePointer?
    guard sqlite3_open_v2(destination.path, &copy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
      sqlite3_close(copy); throw StoreError.message("Cannot create database backup.")
    }
    defer { sqlite3_close(copy) }
    guard let backup = sqlite3_backup_init(copy, "main", db, "main") else { throw StoreError.message("Cannot start database backup.") }
    let step = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK, chmod(destination.path, 0o600) == 0 else { throw StoreError.message("Database backup failed.") }
  }
}
