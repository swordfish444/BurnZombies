import BurnCore
import CryptoKit
import Darwin
import Foundation

// Agent threads and junk folders against a fake home in a temporary directory only.
func autopilotDiskProof() async throws {
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-disk-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = WorkspaceSafety.canonical(temporary.path)
  defer { try? fm.removeItem(atPath: base) }
  let now = Date()
  try adkThreadsProof(base: base + "/threads", now: now)
  try adkSizeProof(base: base + "/sizes")
  try adkJunkProof(base: base + "/junk", now: now)
  try adkCopyAgeProof(base: base + "/age", now: now)
  try adkWalkProof(base: base + "/walk", now: now)
  try await adkJunkCacheProof(base: base + "/cache", now: now)
  try await adkOwnWalkProof(base: base + "/walks", now: now)
}

private func adkWrite(_ text: String, to path: String, modified: Date? = nil) throws {
  let url = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
  if let modified {
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
  }
}

private func adkJSON(_ object: [String: Any]) -> String {
  let data =
    (try? JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
  return String(decoding: data, as: UTF8.self) + "\n"
}

private func adkMillis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

private func adkNear(_ date: Date?, _ expected: Date) -> Bool {
  date.map { abs($0.timeIntervalSince(expected)) < 1 } ?? false
}

private func adkGit(_ path: String, _ args: [String]) throws {
  _ = try WorktreeGit.line(path, args)
}

private func adkRepository(_ path: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  try adkGit(path, ["init", "--initial-branch=main"])
  try adkGit(path, ["config", "user.name", "Synthetic proof"])
  try adkGit(path, ["config", "user.email", "proof@example.invalid"])
}

/// Commits what is staged as if it were `date`. The bounded Git runner can't set commit dates.
private func adkCommit(_ path: String, at date: Date) throws {
  let git = Process()
  git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  git.arguments = ["-C", path, "commit", "-q", "-m", "fixture"]
  let stamp = "@\(Int(date.timeIntervalSince1970)) +0000"
  git.environment = [
    "PATH": "/usr/bin:/bin", "HOME": path, "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp,
  ]
  git.standardOutput = FileHandle.nullDevice
  git.standardError = FileHandle.nullDevice
  try git.run()
  git.waitUntilExit()
  guard git.terminationStatus == 0 else { throw StoreError.message("Fixture commit failed.") }
}

/// A process id above every running one, so `kill(pid, 0)` reports ESRCH.
private func adkUnusedPID() -> Int32? {
  for pid in stride(from: Int32(99_990), to: 99_000, by: -1)
  where kill(pid, 0) != 0 && errno == ESRCH {
    return pid
  }
  return nil
}

private func adkRollout(id: String, cwd: String) -> String {
  adkJSON([
    "timestamp": "2026-11-02T10:00:00.000Z", "type": "session_meta",
    "payload": ["id": id, "cwd": cwd, "originator": "codex_cli_rs"],
  ])
    + adkJSON([
      "type": "response_item", "payload": ["role": "user", "content": "SECRET MESSAGE BODY"],
    ])
}

private func adkThreadsProof(base: String, now: Date) throws {
  let fm = FileManager.default
  let home = base + "/home"
  let work = base + "/work"
  let elsewhere = base + "/elsewhere"
  let alive = getpid()
  guard let dead = adkUnusedPID() else {
    throw StoreError.message("No unused process id for the ended-session fixture.")
  }

  // Claude Code keeps one registry file per running chat.
  let sessions = home + "/.claude/sessions"
  try adkWrite(
    adkJSON([
      "pid": Int(alive), "sessionId": "live-1", "cwd": work + "/alpha", "name": "Alpha chat",
      "updatedAt": adkMillis(now.addingTimeInterval(-30)), "status": "busy",
    ]), to: sessions + "/\(alive).json")
  try adkWrite(
    adkJSON([
      "pid": Int(dead), "sessionId": "ended-1", "cwd": work + "/beta", "name": "Beta chat",
      "updatedAt": String(adkMillis(now.addingTimeInterval(-7200))), "status": "idle",
    ]), to: sessions + "/\(dead).json")

  // Past chats: only the newest transcript of each project folder is read.
  let projects = home + "/.claude/projects"
  try adkWrite(
    adkJSON(["type": "summary", "summary": "no folder on this line"])
      + adkJSON(["type": "user", "cwd": work + "/gamma", "sessionId": "hist-1"]),
    to: projects + "/-gamma/hist-1.jsonl", modified: now.addingTimeInterval(-120))
  try adkWrite(
    adkJSON(["type": "user", "cwd": work + "/stale-cwd", "sessionId": "hist-0"]),
    to: projects + "/-gamma/hist-0.jsonl", modified: now.addingTimeInterval(-3 * 86_400))
  try adkWrite(
    adkJSON(["type": "summary", "summary": "never had a folder"]),
    to: projects + "/-delta/d-1.jsonl", modified: now.addingTimeInterval(-60))
  try adkWrite(
    adkJSON(["type": "user", "cwd": work + "/eps", "sessionId": "hist-2"]),
    to: projects + "/-eps/hist-2.jsonl", modified: now.addingTimeInterval(-7200))
  try adkWrite(
    adkJSON(["type": "user", "cwd": work + "/alpha", "sessionId": "live-1"]),
    to: projects + "/-alpha/live-1.jsonl", modified: now.addingTimeInterval(-2 * 86_400))
  let padding = String(repeating: "x", count: 70_000)
  try adkWrite(
    "{\"type\":\"file-history-snapshot\",\"pad\":\"\(padding)\"}\n"
      + adkJSON(["type": "user", "cwd": work + "/too-late", "sessionId": "big-1"]),
    to: projects + "/-bigfirst/big-1.jsonl", modified: now.addingTimeInterval(-60))
  try adkWrite(
    "{\"cwd\":\"\(work)/cut\",\"type\":\"user\",\"pad\":\"\(padding)\"}\n",
    to: projects + "/-cutline/cut-1.jsonl", modified: now.addingTimeInterval(-60))
  // Links are never followed: not a project folder, not a transcript.
  try adkWrite(
    adkJSON(["type": "user", "cwd": work + "/linked-folder", "sessionId": "lf-1"]),
    to: elsewhere + "/projects/lf-1.jsonl", modified: now)
  try fm.createSymbolicLink(
    atPath: projects + "/-linkedfolder", withDestinationPath: elsewhere + "/projects")
  try adkWrite(
    adkJSON(["type": "user", "cwd": work + "/linked-file", "sessionId": "lfile-1"]),
    to: elsewhere + "/lfile-1.jsonl", modified: now)
  try fm.createDirectory(atPath: projects + "/-linkedfile", withIntermediateDirectories: true)
  try fm.createSymbolicLink(
    atPath: projects + "/-linkedfile/lfile-1.jsonl",
    withDestinationPath: elsewhere + "/lfile-1.jsonl")

  // Codex: the first line of each recent rollout names the chat and its folder.
  let codex = home + "/.codex/sessions"
  try adkWrite(
    adkRollout(id: "cx-1", cwd: work + "/zeta"),
    to: codex + "/2026/11/02/rollout-2026-11-02T10-00-00-cx-1.jsonl",
    modified: now.addingTimeInterval(-60))
  try adkWrite(
    adkRollout(id: "cx-2", cwd: work + "/eta"),
    to: codex + "/2026/10/20/rollout-2026-10-20T09-00-00-cx-2.jsonl",
    modified: now.addingTimeInterval(-5 * 86_400))
  try adkWrite(
    adkRollout(id: "cx-3", cwd: work + "/too-old"),
    to: codex + "/2025/01/01/rollout-2025-01-01T09-00-00-cx-3.jsonl",
    modified: now.addingTimeInterval(-40 * 86_400))
  try adkWrite(
    adkRollout(id: "cx-4", cwd: work + "/theta"),
    to: codex + "/2025/01/02/rollout-2025-01-02T09-00-00-cx-4.jsonl",
    modified: now.addingTimeInterval(-86_400))
  try adkWrite(
    "{\"timestamp\":\"t\",\"type\":\"session_meta\",\"payload\":{\"id\":\"cx-big\","
      + "\"cwd\":\"\(work)/big\",\"instructions\":\"\(padding)\"}}\n"
      + adkJSON(["type": "response_item", "payload": ["content": "SECRET MESSAGE BODY"]]),
    to: codex + "/2026/11/02/rollout-2026-11-02T11-00-00-cx-big.jsonl",
    modified: now.addingTimeInterval(-90))
  try adkWrite(
    adkJSON(["type": "event_msg"]), to: codex + "/2026/11/02/rollout-2026-11-02T12-00-00-bad.jsonl",
    modified: now)
  try adkWrite(
    adkRollout(id: "cx-notes", cwd: work + "/notes"), to: codex + "/2026/11/02/notes.jsonl",
    modified: now)
  try adkWrite(
    adkRollout(id: "cx-linked", cwd: work + "/linked-rollout"),
    to: elsewhere + "/rollout-valid.jsonl", modified: now)
  try fm.createSymbolicLink(
    atPath: codex + "/2026/11/02/rollout-2026-11-02T13-00-00-link.jsonl",
    withDestinationPath: elsewhere + "/rollout-valid.jsonl")

  let threads = AgentThreads.index(home: home, now: now)
  func thread(_ id: String) -> AgentThread? { threads.first { $0.id == id } }

  let live = thread("claude:live-1")
  equal(live?.cwd, work + "/alpha", "live session cwd")
  equal(live?.agent, "claude", "live session agent")
  equal(live?.live, true, "a session whose pid exists is live")
  equal(live?.pid, alive, "live session pid")
  equal(live?.title, "Alpha chat", "live session title")
  check(adkNear(live?.lastActive, now.addingTimeInterval(-30)), "numeric updatedAt is epoch ms")
  equal(
    threads.filter { $0.id == "claude:live-1" }.count, 1,
    "a live session's transcript must not add a second thread")

  let ended = thread("claude:ended-1")
  equal(ended?.cwd, work + "/beta", "ended session cwd")
  equal(ended?.live, false, "a dead pid is an ended session")
  equal(ended?.pid, nil, "an ended session keeps no pid")
  check(adkNear(ended?.lastActive, now.addingTimeInterval(-7200)), "string updatedAt is epoch ms")

  let gamma = thread("claude:hist-1")
  equal(gamma?.cwd, work + "/gamma", "transcript cwd is the first cwd in its lines")
  equal(gamma?.agent, "claude", "transcript agent")
  equal(gamma?.live, true, "a transcript written two minutes ago is live")
  check(adkNear(gamma?.lastActive, now.addingTimeInterval(-120)), "transcript mtime")
  check(thread("claude:hist-0") == nil, "only the newest transcript of a project is read")
  check(!threads.contains { $0.cwd == work + "/stale-cwd" }, "older transcript cwd leaked")
  equal(thread("claude:hist-2")?.cwd, work + "/eps", "old transcript cwd")
  equal(thread("claude:hist-2")?.live, false, "a two hour old transcript is not live")
  check(thread("claude:big-1") == nil, "a cwd beyond the 64 KB read limit is never read")
  equal(
    thread("claude:cut-1")?.cwd, work + "/cut",
    "a line cut by the read limit is scanned for its cwd")
  check(
    thread("claude:lf-1") == nil && thread("claude:lfile-1") == nil, "symlinks must not be followed"
  )

  let zeta = thread("codex:cx-1")
  equal(zeta?.cwd, work + "/zeta", "codex cwd")
  equal(zeta?.agent, "codex", "codex agent")
  equal(zeta?.live, true, "a rollout written a minute ago is live")
  check(adkNear(zeta?.lastActive, now.addingTimeInterval(-60)), "rollout mtime")
  equal(thread("codex:cx-2")?.cwd, work + "/eta", "older codex cwd")
  equal(thread("codex:cx-2")?.live, false, "a rollout from five days ago is not live")
  check(thread("codex:cx-3") == nil, "rollouts untouched for 30 days are skipped")
  equal(thread("codex:cx-4")?.cwd, work + "/theta", "a resumed old rollout counts by mtime")
  equal(thread("codex:cx-big")?.cwd, work + "/big", "an oversized first line is scanned")
  equal(thread("codex:cx-big")?.live, true, "oversized rollout mtime")
  check(thread("codex:cx-notes") == nil, "only rollout-*.jsonl files are read")
  check(thread("codex:cx-linked") == nil, "symlinked rollouts must not be followed")
  equal(threads.count, 9, "unexpected threads: \(threads.map(\.id).sorted())")
  check(!String(describing: threads).contains("SECRET"), "message content must never be stored")
  check(Set(threads.map(\.id)).count == threads.count, "thread ids must be unique")

  // A live chat wins over an ended one in the same folder, and the newest activity is reported.
  let mixed = [
    AgentThread(
      id: "a", agent: "claude", cwd: work + "/proj/sub", live: false,
      lastActive: now.addingTimeInterval(-10)),
    AgentThread(
      id: "b", agent: "codex", cwd: work + "/proj", live: true,
      lastActive: now.addingTimeInterval(-500)),
  ]
  let both = AgentThreads.state(for: work + "/proj", threads: mixed)
  equal(both.thread, "live", "live beats ended")
  check(adkNear(both.lastActive, now.addingTimeInterval(-10)), "newest activity of matches")
  equal(AgentThreads.state(for: work + "/proj/sub", threads: mixed).thread, "ended", "only ended")
  equal(
    AgentThreads.state(for: work + "/pro", threads: mixed).thread, "none", "prefix is not a match")
  equal(AgentThreads.state(for: work + "/alpha", threads: threads).thread, "live", "indexed live")
  equal(AgentThreads.state(for: work + "/beta", threads: threads).thread, "ended", "indexed ended")
  equal(AgentThreads.state(for: work + "/nobody", threads: threads).thread, "none", "no thread")
}

private func adkSizeProof(base: String) throws {
  let fm = FileManager.default
  let folder = base + "/folder"
  let external = base + "/external"
  try adkWrite(String(repeating: "7", count: 1_048_576), to: folder + "/data.bin")
  try adkWrite(String(repeating: "8", count: 5_242_880), to: external + "/big.bin")
  try fm.createSymbolicLink(atPath: folder + "/link", withDestinationPath: external)
  let size = AutopilotDisk.allocatedSize(folder)
  check(
    (size ?? 0) >= 1_048_576, "allocated size should cover the file: \(String(describing: size))")
  check(
    (size ?? .max) < 3_000_000, "allocated size followed a symlink: \(String(describing: size))")
  equal(AutopilotDisk.allocatedSize(folder, deadline: -1), nil, "an expired deadline gives no size")
  equal(AutopilotDisk.allocatedSize(base + "/missing"), nil, "a missing folder has no size")
  equal(AutopilotDisk.allocatedSize(folder + "/link"), nil, "a symlink is never measured")

  // Counting stops at the deadline with what it found so far: a copy too big to measure in
  // time still shows it is big, instead of looking empty.
  equal(AutopilotDisk.countedSize(folder, deadline: 30), size, "a finished count is the size")
  let early = AutopilotDisk.countedSize(folder, deadline: -1)
  check(
    early != nil && early! <= size!, "an early stop is a lower bound: \(String(describing: early))")
  equal(AutopilotDisk.countedSize(folder + "/data.bin", deadline: 30), nil, "a file is no folder")

  // Old copies the inventory never measured get sized a bounded amount per tick and are
  // remembered for a day.
  var measured = [String]()
  let sizes = AutopilotSizes { path, _ in
    measured.append(path)
    return path.hasSuffix("unreadable") ? nil : 7_000_000_000
  }
  func record(_ name: String, allocated: UInt64 = 0) -> WorktreeRecord {
    var r = WorktreeRecord(id: "id-" + name, path: base + "/" + name, repository: base + "/repo")
    r.allocated = allocated
    return r
  }
  let now = Date()
  let records = [record("known", allocated: 2_000_000), record("new"), record("unreadable")]
  equal(sizes.fill(records, budget: 0, now: now).map(\.allocated), [2_000_000, 0, 0], "no budget")
  equal(measured, [], "nothing measured without a budget")
  equal(sizes.fill(records, now: now).map(\.allocated), [2_000_000, 7_000_000_000, 0])
  equal(measured, [base + "/new", base + "/unreadable"], "only unmeasured copies are sized")
  equal(sizes.fill(records, now: now.addingTimeInterval(3600)).map(\.allocated)[1], 7_000_000_000)
  equal(measured.count, 3, "a size is remembered; an unreadable copy is tried again")
  _ = sizes.fill(records, now: now.addingTimeInterval(2 * 86_400))
  equal(measured.filter { $0.hasSuffix("/new") }.count, 2, "a day later it is measured again")

  // Sizes are kept with Autopilot's state: after a restart yesterday's are still good, and only
  // a size a day old, or a copy that couldn't be measured, is measured again.
  let root = URL(fileURLWithPath: base + "/state", isDirectory: true)
  var counted = [String]()
  func restarted() throws -> AutopilotSizes {
    AutopilotSizes(store: try AutopilotStore(root: root)) { path, _ in
      counted.append(path)
      return path.hasSuffix("unreadable") ? nil : 7_000_000_000
    }
  }
  _ = try restarted().fill(records + [record("gone")], now: now.addingTimeInterval(-23 * 3600))
  equal(counted.count, 3, "every unmeasured copy is sized")
  equal(
    try restarted().fill(records, now: now).map(\.allocated), [2_000_000, 7_000_000_000, 0],
    "a restart keeps yesterday's sizes")
  equal(counted.count, 4, "only the copy that couldn't be measured is tried again")
  _ = try restarted().fill(records, now: now.addingTimeInterval(2 * 3600))
  equal(counted.filter { $0.hasSuffix("/new") }.count, 2, "a size a day old is measured again")
  equal(
    try AutopilotStore(root: root).sizes().keys.sorted(), ["id-new"], "and an old one isn't kept")
}

private func adkJunkProof(base: String, now: Date) throws {
  let fm = FileManager.default
  let day: TimeInterval = 86_400
  let home = base + "/home"
  let repo = home + "/git/p6-bodycam"
  let old = home + "/git/p6-bodycam-old"
  let external = base + "/external"
  let derived = home + "/Library/Developer/Xcode/DerivedData"
  let playwright = home + "/Library/Caches/ms-playwright/chromium-1"
  // The build an installed Playwright uses is never junk.
  let newestPlaywright = home + "/Library/Caches/ms-playwright/chromium-2"
  let npm = home + "/.npm/_cacache"
  let ssh = home + "/.ssh/keys-repo"
  let cloud = home + "/Library/Mobile Documents/com~apple~CloudDocs/synced"
  let outside = base + "/outside/proj"
  let filler = String(repeating: "x", count: 1024)

  let kinds: [String: String] = [
    "node_modules": "node_modules", ".build": "build-output", "build": "build-output",
    "dist": "build-output", "target": "build-output", ".next": "build-output",
    ".nuxt": "build-output", ".svelte-kit": "build-output", ".turbo": "build-output",
    ".parcel-cache": "build-output", ".output": "build-output", "DerivedData": "xcode-derived",
    ".gradle": "package-cache", ".cache": "package-cache", "Pods": "package-cache",
    ".venv": "python-env", "venv": "python-env", "__pycache__": "python-env",
    ".pytest_cache": "python-env", ".mypy_cache": "python-env", ".ruff_cache": "python-env",
    ".tox": "python-env",
  ]
  equal(AutopilotDisk.rebuildable, kinds, "rebuildable folder table")

  // A project with a committed build/ folder, and a linked copy of it that went stale.
  try adkRepository(repo)
  try adkWrite("src\n", to: repo + "/src.txt")
  try adkWrite("committed output\n", to: repo + "/build/out.txt")
  try adkWrite(".build/\nnode_modules/\ndist/\n", to: repo + "/.gitignore")
  try adkGit(repo, ["add", "."])
  try adkGit(repo, ["commit", "-m", "fixture"])
  try adkGit(repo, ["worktree", "add", "--detach", old])
  for relative in [
    "node_modules/pkg/index.js", "node_modules/pkg/node_modules/inner.js", ".build/debug/app",
    ".cache/blob", "packages/web/node_modules/dep/index.js", "a/b/c/node_modules/deep.js",
    "vendor/lib/node_modules/x.js",
  ] {
    try adkWrite(filler, to: old + "/" + relative)
  }
  // Another repository inside the copy is somebody's project, not build output.
  try fm.createDirectory(atPath: old + "/vendor/lib/.git", withIntermediateDirectories: true)
  for relative in ["node_modules/pkg/index.js", "dist/bundle.js"] {
    try adkWrite(filler, to: repo + "/" + relative)
  }
  let staleDate = now.addingTimeInterval(-40 * day)
  for relative in ["node_modules", ".build", ".cache", "packages/web/node_modules"] {
    try fm.setAttributes([.modificationDate: staleDate], ofItemAtPath: old + "/" + relative)
  }
  try fm.setAttributes(
    [.modificationDate: now.addingTimeInterval(-3 * day)], ofItemAtPath: repo + "/node_modules")

  // A shortcut named node_modules, and global caches (one of them a shortcut too).
  try adkWrite(filler, to: external + "/real-modules/x.js")
  try adkWrite(filler, to: external + "/gradle-caches/x")
  try fm.createDirectory(atPath: old + "/tools", withIntermediateDirectories: true)
  try fm.createSymbolicLink(
    atPath: old + "/tools/node_modules", withDestinationPath: external + "/real-modules")
  try fm.createDirectory(atPath: home + "/.gradle", withIntermediateDirectories: true)
  try fm.createSymbolicLink(
    atPath: home + "/.gradle/caches", withDestinationPath: external + "/gradle-caches")
  try adkWrite(filler, to: derived + "/MyApp-abc/Build/x.o")
  try adkWrite(filler, to: derived + "/Small-def/x.o")
  try adkWrite("plist", to: derived + "/info.plist")
  try adkWrite(filler, to: playwright + "/chrome")
  try adkWrite(filler, to: newestPlaywright + "/chrome")
  // Playwright's own record: the one installed package uses chromium-2.
  let playwrightPackage = base + "/tools/node_modules/playwright-core"
  try adkWrite(#"{"browsers":[{"name":"chromium","revision":"2"}]}"#, to: playwrightPackage + "/browsers.json")
  try adkWrite(playwrightPackage, to: home + "/Library/Caches/ms-playwright/.links/one")
  try adkWrite(filler, to: home + "/Library/Caches/Yarn/v6/x")
  try adkWrite(filler, to: npm + "/content/x")

  // Checkouts the rails must skip entirely: private folders, iCloud and outside the home.
  for path in [ssh, cloud, outside] {
    try adkRepository(path)
    try adkWrite(filler, to: path + "/node_modules/x.js")
  }

  var sizes: [String: UInt64] = [:]
  sizes[old + "/node_modules"] = 3_000_000_000
  sizes[old + "/.build"] = 400_000_000
  sizes[old + "/.cache"] = 50_000_000
  sizes[old + "/packages/web/node_modules"] = 150_000_000
  sizes[repo + "/node_modules"] = 500_000_000
  sizes[repo + "/dist"] = 12_000_000_000
  sizes[derived + "/MyApp-abc"] = 2_000_000_000
  sizes[derived + "/Small-def"] = 50_000_000
  sizes[playwright] = 300_000_000
  sizes[newestPlaywright] = 300_000_000
  sizes[home + "/Library/Caches/Yarn"] = 10_000_000
  sizes[npm] = 700_000_000
  var asked: [String] = []
  // Anything not listed reports 5 GB, so a rail that fails to hold shows up as an extra item.
  let sizer: (String) -> UInt64? = { path in
    asked.append(path)
    return sizes[path] ?? 5_000_000_000
  }

  let linked = WorktreeRecord(id: "old", path: old, repository: repo + "/.git")
  var stale = linked
  stale.lastFileChange = now.addingTimeInterval(-40 * day)
  stale.lastCommitAt = now.addingTimeInterval(-41 * day)
  var primary = WorktreeRecord(id: "main", path: repo, repository: repo + "/.git")
  primary.main = true
  let guarded = [ssh, cloud, outside].map {
    WorktreeRecord(id: "guarded:" + $0, path: $0, repository: $0 + "/.git")
  }

  let items = AutopilotDisk.items(
    worktrees: [stale] + guarded, home: home, now: now, sizer: sizer)
  func item(_ path: String) -> AutopilotItem? { items.first { $0.path == path } }
  func disk(_ folder: String, _ place: String, _ age: String, _ size: String) -> [String: String] {
    ["kind": "disk", "folder": folder, "home": place, "stale": age, "size": size]
  }

  let expected: Set<String> = [
    old + "/node_modules", old + "/.build", old + "/packages/web/node_modules",
    repo + "/node_modules", repo + "/dist", derived + "/MyApp-abc", playwright, npm,
  ]
  equal(
    Set(items.compactMap { $0.path }), expected,
    "junk folders found (tracked build/, depth 4, nested repo, shortcuts and small ones excluded)")
  equal(items.count, expected.count, "one item per folder")
  check(items.allSatisfy { $0.kind == .disk }, "every junk folder is a disk item")
  equal(items.map { $0.bytes }, items.map { $0.bytes }.sorted(by: >), "biggest first")
  equal(
    item(old + "/node_modules")?.facts, disk("node_modules", "stale-worktree", "month", "large"),
    "node_modules in a stale linked copy")
  equal(
    item(old + "/.build")?.facts, disk("build-output", "stale-worktree", "month", "medium"),
    "ignored .build in a stale linked copy")
  equal(
    item(old + "/packages/web/node_modules")?.facts,
    disk("node_modules", "stale-worktree", "month", "medium"), "folders three levels down count")
  equal(
    item(repo + "/node_modules")?.facts, disk("node_modules", "repo", "day", "medium"),
    "the main checkout is found from the copy's repository and is never stale-worktree")
  equal(
    item(repo + "/dist")?.facts, disk("build-output", "repo", "today", "huge"), "huge fresh dist")
  equal(
    item(derived + "/MyApp-abc")?.facts, disk("xcode-derived", "global-cache", "today", "large"),
    "DerivedData child")
  equal(
    item(playwright)?.facts, disk("package-cache", "global-cache", "today", "medium"),
    "Playwright browsers")
  equal(
    item(npm)?.facts, disk("package-cache", "global-cache", "today", "medium"), "npm cache")
  let nodes = item(old + "/node_modules")
  equal(nodes?.id, "disk:" + AutopilotItem.hash(old + "/node_modules"), "item id")
  equal(nodes?.name, "node_modules in p6-bodycam-old", "item name")
  equal(
    nodes?.detail, "Downloaded packages for p6-bodycam-old. npm rebuilds them when needed.",
    "item detail")
  equal(nodes?.bytes, 3_000_000_000, "item bytes come from the sizer")
  func touched(_ path: String) -> Date? {
    let attributes = try? fm.attributesOfItem(atPath: path)
    return attributes?[.modificationDate] as? Date
  }
  func near(_ date: Date?, _ expected: Date?) -> Bool {
    guard let date, let expected else { return false }
    return abs(date.timeIntervalSince(expected)) < 1
  }
  check(near(nodes?.lastUsed, staleDate), "a folder was last used when it last changed")
  check(
    near(item(repo + "/node_modules")?.lastUsed, now.addingTimeInterval(-3 * day)),
    "in the main checkout too")
  check(
    near(item(npm)?.lastUsed, touched(npm)),
    "a global cache was last used when it last changed")
  check(
    near(item(derived + "/MyApp-abc")?.lastUsed, touched(derived + "/MyApp-abc")),
    "and so was each build folder in DerivedData")
  check(items.allSatisfy { $0.lastUsed != nil }, "every folder has a date")
  check(items.allSatisfy { $0.title == nil }, "folders are named by what they are")
  equal(
    item(old + "/packages/web/node_modules")?.name, "node_modules in p6-bodycam-old/packages/web",
    "nested item name")
  equal(item(repo + "/dist")?.name, "dist in p6-bodycam", "main checkout item name")
  let excludedFolders: [String] = [
    ssh, cloud, outside, old + "/tools", old + "/build", old + "/vendor", old + "/a",
    repo + "/build", home + "/.gradle", old + "/node_modules/pkg",
  ]
  for forbidden in excludedFolders {
    checkFalse(
      asked.contains(where: { $0 == forbidden || $0.hasPrefix(forbidden + "/") }),
      "sized a folder the rails exclude: \(forbidden)")
  }
  checkFalse(asked.contains(where: { $0.contains("/.git/") }), "walked into .git")

  // A copy touched recently is an ordinary folder; unknown activity is never stale.
  var fresh = stale
  fresh.lastFileChange = now.addingTimeInterval(-2 * day)
  let recent = AutopilotDisk.items(worktrees: [fresh], home: home, now: now, sizer: sizer)
  let recentNodes = recent.first { $0.path == old + "/node_modules" }
  equal(recentNodes?.facts["home"], "repo", "a copy changed two days ago is not stale")
  equal(recentNodes?.facts["stale"], "day", "copy activity counts toward the stale bucket")
  // The date a card shows is the one the age comes from: the copy's work counts as use of the
  // folders in it, even when the folder itself is older.
  check(
    abs((recentNodes?.lastUsed ?? .distantFuture).timeIntervalSince(fresh.lastFileChange!)) < 1,
    "a folder in a copy changed two days ago was used two days ago")
  var unknown = linked
  unknown.lastFileChange = nil
  unknown.lastCommitAt = nil
  let unknownNodes = AutopilotDisk.items(worktrees: [unknown], home: home, now: now, sizer: sizer)
    .first { $0.path == old + "/node_modules" }
  equal(unknownNodes?.facts["home"], "repo", "unknown activity must not look stale")

  let copiesOnly = AutopilotDisk.items(
    worktrees: [stale] + guarded, home: home, caches: false, now: now, sizer: sizer)
  equal(
    Set(copiesOnly.compactMap { $0.path }),
    expected.subtracting([derived + "/MyApp-abc", playwright, npm]),
    "without the global caches, only junk in checkouts")
  let copyOnly = AutopilotDisk.items(
    worktrees: [stale] + guarded, home: home, caches: false, mains: false, now: now, sizer: sizer)
  let copyJunk: Set<String> = [
    old + "/node_modules", old + "/.build", old + "/packages/web/node_modules",
  ]
  equal(
    Set(copyOnly.compactMap { $0.path }), copyJunk,
    "without main checkouts either, only junk in the copy itself")

  let both = AutopilotDisk.items(worktrees: [primary, stale], home: home, now: now, sizer: sizer)
  equal(both.count, expected.count, "listing the main checkout as well adds nothing")
  equal(Set(both.compactMap { $0.path }).count, both.count, "no folder is listed twice")

  var gone = stale
  gone.missing = true
  var retired = stale
  retired.retired = true
  let globals = AutopilotDisk.items(worktrees: [gone, retired], home: home, now: now, sizer: sizer)
  equal(globals.count, 3, "missing and retired copies are skipped; global caches remain")
  check(globals.allSatisfy { $0.facts["home"] == "global-cache" }, "only global caches remain")
  equal(
    AutopilotDisk.items(worktrees: [stale], home: home, now: now, sizer: { _ in nil }).count, 0,
    "folders that cannot be sized are skipped")

  // Reclaim: every rail is checked again on the live path.
  guard let packages = item(old + "/node_modules"), let dist = item(repo + "/dist"),
    let derivedItem = item(derived + "/MyApp-abc")
  else { throw StoreError.message("Fixture items missing: \(items.compactMap { $0.path })") }
  let starter = "starter:starter-rebuildable-junk"
  func forged(_ path: String, _ folder: String) -> AutopilotItem {
    AutopilotItem(
      id: "disk:" + AutopilotItem.hash(path), kind: .disk, name: "forged", path: path,
      bytes: 200_000_000,
      facts: ["folder": folder, "home": "repo", "stale": "older", "size": "medium"])
  }
  func burn(_ item: AutopilotItem, _ authority: String, _ busy: Int32) -> AutopilotReceipt {
    AutopilotDisk.reclaim(
      item, authority: authority, home: home, inUse: { _ in busy },
      root: URL(fileURLWithPath: home).appendingPathComponent("proof-state"),
      recoveryKey: SymmetricKey(data: Data(repeating: 0x74, count: 32)))
  }
  func refused(_ item: AutopilotItem, _ authority: String, _ busy: Int32, _ message: String) {
    let receipt = burn(item, authority, busy)
    equal(receipt.outcome, "refused", message)
    check(!receipt.detail.isEmpty, message + ": a refusal explains itself")
    equal(receipt.itemID, item.id, message + ": receipt item")
    equal(receipt.authority, authority, message + ": receipt authority")
    equal(receipt.bytes, 0, message + ": a refusal frees nothing")
  }

  refused(packages, starter, 1, "a folder in use")
  refused(packages, starter, -1, "a folder that cannot be checked")
  check(fm.fileExists(atPath: old + "/node_modules/pkg/index.js"), "in-use folder was touched")

  let link = old + "/tools/node_modules"
  refused(forged(link, "node_modules"), starter, 0, "a symlink")
  let linkTarget = try? fm.destinationOfSymbolicLink(atPath: link)
  equal(linkTarget, external + "/real-modules", "the symlink was changed")
  check(fm.fileExists(atPath: external + "/real-modules/x.js"), "symlink target was touched")

  refused(forged(old + "/build", "build-output"), starter, 0, "a folder Git tracks")
  refused(forged(repo + "/build", "build-output"), starter, 0, "a folder Git tracks in main")
  check(fm.fileExists(atPath: old + "/build/out.txt"), "tracked build folder was touched")
  check(fm.fileExists(atPath: repo + "/build/out.txt"), "tracked build folder was touched in main")

  try adkWrite(filler, to: home + "/scratch/data.txt")
  let scratch = forged(home + "/scratch", "other")
  refused(scratch, starter, 0, "an unknown folder with a starter rule")
  refused(scratch, "ai:0.95", 0, "an unknown folder with an AI verdict")
  let ruleReceipt = burn(scratch, "rule:abc", 1)
  equal(ruleReceipt.outcome, "refused", "operator rules may use the Trash, but not while in use")
  notEqual(ruleReceipt.detail, burn(scratch, starter, 0).detail)
  refused(scratch, "operator", -1, "the operator cannot override an unchecked folder")
  check(fm.fileExists(atPath: home + "/scratch/data.txt"), "unknown folder was touched")

  try adkWrite(filler, to: home + "/projects-notes/readme.txt")
  refused(
    forged(home + "/projects-notes", "node_modules"), starter, 0, "a folder with a false label")
  refused(
    forged(old + "/a/b/c/node_modules", "node_modules"), starter, 0, "deeper than three levels")
  refused(forged(home, "node_modules"), starter, 0, "the home folder itself")
  refused(forged(old + "/nope/node_modules", "node_modules"), starter, 0, "a folder that is gone")
  refused(forged(ssh + "/node_modules", "node_modules"), starter, 0, "inside .ssh")
  refused(forged(cloud + "/node_modules", "node_modules"), starter, 0, "inside iCloud Drive")
  refused(forged(outside + "/node_modules", "node_modules"), starter, 0, "outside the home folder")
  let untouched: [String] = [
    home + "/projects-notes/readme.txt", home + "/git", ssh + "/node_modules/x.js",
    cloud + "/node_modules/x.js", outside + "/node_modules/x.js",
    old + "/a/b/c/node_modules/deep.js",
  ]
  for path in untouched {
    check(fm.fileExists(atPath: path), "refused folder was touched: \(path)")
  }

  // Rebuildable folders are deleted and their measured size is reported.
  let distBytes = AutopilotDisk.allocatedSize(repo + "/dist")
  check((distBytes ?? 0) > 0, "fixture folder has a size")
  let burned = burn(dist, starter, 0)
  equal(burned.outcome, "burned", "rebuildable folder: \(burned.detail)")
  check(burned.bytes <= (distBytes ?? 0), "recovery storage is never credited as disk reclaimed")
  check(burned.restore?.recovery != nil, "a generic dist folder has encrypted recovery")
  equal(burned.itemID, dist.id, "receipt item")
  equal(burned.authority, starter, "receipt authority")
  equal(burned.kind, .disk, "receipt kind")
  check(!burned.detail.isEmpty, "a burn explains itself")
  checkFalse(fm.fileExists(atPath: repo + "/dist"), "dist should be gone")
  check(fm.fileExists(atPath: repo + "/src.txt"), "source was touched")
  check(fm.fileExists(atPath: repo + "/build/out.txt"), "tracked output was touched")
  check(fm.fileExists(atPath: repo + "/node_modules/pkg/index.js"), "sibling junk was touched")
  let again = burn(dist, starter, 0)
  equal(again.outcome, "refused", "a folder that is already gone is not burned twice")

  let derivedBytes = AutopilotDisk.allocatedSize(derived + "/MyApp-abc")
  let cleared = burn(derivedItem, starter, 0)
  equal(cleared.outcome, "burned", "global cache: \(cleared.detail)")
  equal(cleared.bytes, derivedBytes ?? 0, "global cache size")
  checkFalse(fm.fileExists(atPath: derived + "/MyApp-abc"), "DerivedData child should be gone")
  check(fm.fileExists(atPath: derived + "/Small-def/x.o"), "other DerivedData child was touched")

  // Clearing junk must not make the copy it sits in look worked in today: removing a folder
  // stamps its parent with the current time. On a real Mac two quiet copies looked used today.
  let quiet = home + "/git/p6-bodycam-quiet"
  try adkGit(repo, ["worktree", "add", "--detach", quiet])
  for relative in ["node_modules/pkg/index.js", "packages/web/node_modules/dep/index.js"] {
    try adkWrite(filler, to: quiet + "/" + relative)
  }
  for relative in (fm.enumerator(atPath: quiet)?.allObjects as? [String] ?? []) + [""] {
    try fm.setAttributes(
      [.modificationDate: staleDate],
      ofItemAtPath: relative.isEmpty ? quiet : quiet + "/" + relative)
  }
  func newest(_ path: String) throws -> Date? {
    try WorktreeInspection.files(path, permitLinks: true).0.map {
      Date(timeIntervalSince1970: Double($0.modified) + Double($0.nanos) / 1e9)
    }.max()
  }
  let firstChange = try newest(quiet)
  check(adkNear(firstChange, staleDate), "the quiet copy starts out untouched")
  for relative in ["node_modules", "packages/web/node_modules"] {
    let junk = burn(forged(quiet + "/" + relative, "node_modules"), starter, 0)
    equal(junk.outcome, "burned", "junk in a quiet copy: \(junk.detail)")
  }
  let lastChange = try newest(quiet)
  check(
    adkNear(lastChange, staleDate),
    "clearing junk counted as using the copy: \(String(describing: lastChange))")
}

/// An old commit alone never makes a copy old. The inventory can't walk a copy that holds another
/// repository (a submodule, SwiftPM's checkouts), so it dates that copy by its last commit only and
/// the copy itself has no age. Its junk counts as inside an old copy only when a walk of the copy's
/// own files, past its junk folders and Git's data, finds nothing changed in two weeks.
private func adkCopyAgeProof(base: String, now: Date) throws {
  let fm = FileManager.default
  let day: TimeInterval = 86_400
  let old = now.addingTimeInterval(-40 * day)
  let yesterday = now.addingTimeInterval(-1.5 * day)
  let home = base + "/home"
  let repo = home + "/git/shop"
  let copy = home + "/git/shop-wip"
  try adkRepository(repo)
  try adkWrite("src\n", to: repo + "/src.txt")
  try adkWrite("node_modules/\n.build/\n", to: repo + "/.gitignore")
  try adkGit(repo, ["add", "."])
  try adkCommit(repo, at: old)
  try adkGit(repo, ["worktree", "add", "--detach", copy])
  for relative in [
    "node_modules/pkg/index.js", ".build/checkouts/dep/Package.swift", "vendor/lib/lib.c",
  ] {
    try adkWrite("x\n", to: copy + "/" + relative)
  }
  // A SwiftPM checkout inside the junk, a vendored repository outside it, and an empty folder.
  for relative in [".build/checkouts/dep/.git", "vendor/lib/.git", "private"] {
    try fm.createDirectory(atPath: copy + "/" + relative, withIntermediateDirectories: true)
  }
  func age(_ relative: String, _ date: Date) throws {
    let path = relative.isEmpty ? copy : copy + "/" + relative
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
  }
  // Everything in the copy last changed weeks ago, except Git's own data.
  let entries = fm.enumerator(atPath: copy)?.allObjects as? [String] ?? []
  for relative in entries + [""] where (relative as NSString).lastPathComponent != ".git" {
    try age(relative, old)
  }

  let record = WorktreeInspection.inspect(
    WorktreeRecord(id: "wip", path: copy, repository: repo + "/.git"), visibility: { _ in 0 },
    protected: .limited(homes: [home]))
  check(adkNear(record.lastCommitAt, old), "the copy's last commit is weeks old")
  equal(record.lastFileChange, nil, "the inventory's walk stops at another repository")
  check(
    record.gaps.contains("Nested repository is protected."),
    "the copy's file walk could not finish: \(record.gaps)")
  func junk(_ r: WorktreeRecord) -> AutopilotItem? {
    AutopilotDisk.items(
      worktrees: [r], home: home, caches: false, mains: false, now: now,
      sizer: { _ in 3_000_000_000 }
    ).first { $0.path == copy + "/node_modules" }
  }

  let untouched = junk(record)
  equal(untouched?.facts["home"], "stale-worktree", "junk in a copy untouched for weeks")
  equal(untouched?.facts["stale"], "month", "weeks since anything in the copy changed")

  // Work from yesterday that isn't committed yet.
  try adkWrite("edited\n", to: copy + "/src.txt", modified: yesterday)
  try age("", old)
  let edited = junk(record)
  equal(edited?.facts["home"], "repo", "a commit from weeks ago hid yesterday's edits")
  equal(edited?.facts["stale"], "day", "yesterday's edits count toward the stale bucket")
  try age("src.txt", old)

  // Inside the junk only the folder's own time counts, so a big node_modules never stops the walk.
  try age("node_modules/pkg/index.js", now)
  equal(junk(record)?.facts["home"], "stale-worktree", "a file deep inside the junk doesn't count")
  try age("node_modules", yesterday)
  equal(junk(record)?.facts["home"], "repo", "packages added to the junk yesterday count")
  try age("node_modules", old)

  // A file date from an earlier walk goes stale once the walks stop finishing.
  var walkedBefore = record
  walkedBefore.lastFileChange = old
  try age("src.txt", yesterday)
  equal(junk(walkedBefore)?.facts["home"], "repo", "an earlier walk's date hid yesterday's edits")
  try age("src.txt", old)
  equal(junk(walkedBefore)?.facts["home"], "stale-worktree", "with nothing newer, the copy is old")

  // A folder the walk can't read could hold newer work.
  equal(chmod(copy + "/private", 0), 0)
  defer { _ = chmod(copy + "/private", 0o755) }
  equal(junk(record)?.facts["home"], "repo", "a copy BurnZombies can't read in full has no age")
}

/// The inventory's walk reads every folder of a copy. On macOS 27 a skip asked for at a file or a
/// link lands on the next folder in the same listing, and a linked copy's `.git` is a file: that
/// folder's dates and sizes went missing, and so did anything in it the walk must refuse.
private func adkWalkProof(base: String, now: Date) throws {
  let fm = FileManager.default
  let old = now.addingTimeInterval(-40 * 86_400)
  let yesterday = now.addingTimeInterval(-1.5 * 86_400)
  let repo = base + "/shop"
  try adkRepository(repo)
  try adkWrite("src\n", to: repo + "/src.txt")
  try adkGit(repo, ["add", "."])
  try adkCommit(repo, at: old)
  // A folder's entries in the order a walk meets them.
  func listing(_ folder: String) -> [String] {
    guard
      let walk = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
    else { return [] }
    var names: [String] = []
    while let url = walk.nextObject() as? URL {
      if walk.level == 1 { names.append(url.lastPathComponent) }
    }
    return names
  }
  // Adds folders to `parent` until one is listed after an entry `marker` picks, where a skip asked
  // for at that entry lands. The volume lists entries by a hash of their names.
  func folder(after marker: (String) -> Bool, in parent: String, holding file: String) throws
    -> String?
  {
    for n in 0..<128 {
      try adkWrite("x\n", to: parent + "/folder\(n)/" + file)
      let names = listing(parent)
      guard let start = names.firstIndex(where: marker) else { continue }
      if let found = names[start...].first(where: { $0.hasPrefix("folder") }) { return found }
    }
    return nil
  }
  func entries(_ copy: String) -> Set<String> {
    Set((fm.enumerator(atPath: copy)?.allObjects as? [String] ?? []).filter { $0 != ".git" })
  }
  func walked(_ copy: String) throws -> Set<String> {
    Set(try WorktreeInspection.files(copy, permitLinks: true).0.map(\.path)).subtracting([""])
  }
  // Every entry's own date, links included: the walk counts a link's own date.
  func age(_ copy: String, _ date: Date) {
    let seconds = Int(date.timeIntervalSince1970)
    for relative in entries(copy).union([""]) {
      var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
      _ = lutimes(relative.isEmpty ? copy : copy + "/" + relative, &times)
    }
  }
  func inspect(_ copy: String) -> WorktreeRecord {
    WorktreeInspection.inspect(
      WorktreeRecord(id: copy, path: copy, repository: repo + "/.git"), visibility: { _ in 0 },
      protected: .limited(homes: [base]))
  }

  // The folder listed after a linked copy's `.git` file holds the copy's newest, biggest work.
  let gitCopy = base + "/shop-git"
  try adkGit(repo, ["worktree", "add", "--detach", gitCopy])
  guard let afterGit = try folder(after: { $0 == ".git" }, in: gitCopy, holding: "work.txt") else {
    failTest("no folder is listed after .git: \(listing(gitCopy))")
    return
  }
  let big = gitCopy + "/" + afterGit + "/big.bin"
  try Data(repeating: 0x5a, count: 1 << 20).write(to: URL(fileURLWithPath: big))
  age(gitCopy, old)
  try fm.setAttributes([.modificationDate: yesterday], ofItemAtPath: big)
  equal(try walked(gitCopy).symmetricDifference(entries(gitCopy)), [], "the walk missed entries")
  let dated = inspect(gitCopy)
  equal(dated.gaps, [], "the copy's walk finished")
  check(
    adkNear(dated.lastFileChange, yesterday),
    "yesterday's work in \(afterGit) dates the copy: \(String(describing: dated.lastFileChange))")
  check(dated.allocated >= 1 << 20, "\(afterGit) counts toward the size: \(dated.allocated)")
  try fm.createDirectory(
    atPath: gitCopy + "/" + afterGit + "/inner/.git", withIntermediateDirectories: true)
  check(
    inspect(gitCopy).gaps.contains("Nested repository is protected."),
    "a project inside \(afterGit) stops the walk")

  // Links are never followed. The folder listed after one holds a file hard-linked from a store.
  let linkCopy = base + "/shop-links"
  try adkGit(repo, ["worktree", "add", "--detach", linkCopy])
  let deps = linkCopy + "/deps"
  try fm.createDirectory(atPath: deps, withIntermediateDirectories: true)
  for n in 0..<8 {
    try fm.createSymbolicLink(atPath: deps + "/link\(n)", withDestinationPath: "folder0")
  }
  guard let afterLink = try folder(after: { $0.hasPrefix("link") }, in: deps, holding: "index.js")
  else {
    failTest("no folder is listed after a link: \(listing(deps))")
    return
  }
  equal(try walked(linkCopy).symmetricDifference(entries(linkCopy)), [], "the walk missed entries")
  try adkWrite("shared\n", to: base + "/store/shared.js")
  equal(link(base + "/store/shared.js", deps + "/" + afterLink + "/shared.js"), 0)
  check(
    inspect(linkCopy).gaps.contains("Hardlinked files require owner handling."),
    "a hard link inside \(afterLink) stops the walk")
}

/// Autopilot's live junk list walks every copy at most every six hours, plus each copy the
/// inventory reports after a walk began and each copy whose age it learns after its walk, on its
/// own and right away: a new install's first scan reports copies over several ticks, and their
/// ages only once each copy is inspected.
private func adkJunkCacheProof(base: String, now: Date) async throws {
  let fm = FileManager.default
  let day: TimeInterval = 86_400
  let home = base + "/home"
  let repo = home + "/git/shop"
  try adkRepository(repo)
  try adkWrite("node_modules/\ndist/\n", to: repo + "/.gitignore")
  try adkGit(repo, ["add", "."])
  try adkGit(repo, ["commit", "-m", "fixture"])
  // The live walk measures real allocated bytes, so each junk folder clones one 100 MB chunk.
  let chunk = base + "/chunk"
  try Data(count: 104_857_600).write(to: URL(fileURLWithPath: chunk))
  func junk(_ folder: String) throws {
    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    if clonefile(chunk, folder + "/part", 0) != 0 {
      try fm.copyItem(atPath: chunk, toPath: folder + "/part")
    }
  }
  var primary = WorktreeRecord(id: "shop", path: repo, repository: repo + "/.git")
  primary.main = true
  func copy(_ name: String) throws -> WorktreeRecord {
    let path = home + "/git/" + name
    try adkGit(repo, ["worktree", "add", "--detach", path])
    try junk(path + "/node_modules/pkg")
    var record = WorktreeRecord(id: name, path: path, repository: repo + "/.git")
    record.lastFileChange = now.addingTimeInterval(-30 * day)
    record.lastCommitAt = now.addingTimeInterval(-31 * day)
    return record
  }
  let first = try copy("shop-first")
  let late = try copy("shop-late")
  let inspected = try copy("shop-inspected")
  var pending = inspected
  pending.lastFileChange = nil
  pending.lastCommitAt = nil
  // Another project, found later: its main checkout has junk of its own.
  let toolsPath = home + "/git/tools"
  try adkRepository(toolsPath)
  try adkWrite("node_modules/\n", to: toolsPath + "/.gitignore")
  try adkGit(toolsPath, ["add", "."])
  try adkGit(toolsPath, ["commit", "-m", "fixture"])
  try junk(toolsPath + "/node_modules/pkg")
  var tools = WorktreeRecord(id: "tools", path: toolsPath, repository: toolsPath + "/.git")
  tools.main = true

  let state = URL(fileURLWithPath: base + "/state")
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: state, accessCheck: fixtureAccess)
  // A fixture key: a proof never reads, or makes, the Mac's real backup key.
  let sources = AutopilotSources.live(
    monitor: monitor, root: state, home: home,
    recoveryKey: SymmetricKey(data: Data(repeating: 0x77, count: 32)))
  /// Asks for the list as each Autopilot tick does, until `done` holds or `seconds` pass.
  func ask(
    _ records: [WorktreeRecord], seconds: TimeInterval = 10, until done: ([AutopilotItem]) -> Bool
  ) async -> [AutopilotItem] {
    let deadline = Date().addingTimeInterval(seconds)
    var items = sources.disk(records)
    while !done(items), Date() < deadline {
      try? await Task.sleep(nanoseconds: 50_000_000)
      items = sources.disk(records)
    }
    return items
  }
  func place(_ record: WorktreeRecord, _ items: [AutopilotItem]) -> String? {
    items.first { $0.path == record.path + "/node_modules" }?.facts["home"]
  }

  var items = await ask([primary, first]) { place(first, $0) != nil }
  equal(place(first, items), "stale-worktree", "the first walk lists junk in an old copy")
  // Junk that appears later in checkouts already walked waits for the six-hourly walk.
  let later = [first.path + "/dist", repo + "/dist"]
  for folder in later { try junk(folder) }
  items = await ask([primary, first, late]) { place(late, $0) != nil }
  equal(
    place(late, items), "stale-worktree",
    "a copy found after the first walk is walked within seconds, not ten minutes on")
  items = await ask([primary, first, late, pending]) { place(inspected, $0) != nil }
  equal(place(inspected, items), "repo", "a copy of unknown age is walked, and never looks old")
  items = await ask([primary, first, late, inspected]) { place(inspected, $0) == "stale-worktree" }
  equal(
    place(inspected, items), "stale-worktree", "a copy is walked again once its age is known")
  check(place(first, items) != nil && place(late, items) != nil, "earlier walks' junk stays listed")
  items = await ask([primary, first, late, inspected, tools]) { place(tools, $0) != nil }
  equal(place(tools, items), "repo", "a new project's main checkout is walked with its record")
  items = await ask([primary, first, late, inspected, tools], seconds: 1) { items in
    items.contains { later.contains($0.path ?? "") }
  }
  checkFalse(
    items.contains { later.contains($0.path ?? "") },
    "checkouts already walked, main checkouts included, wait for the six-hourly walk")
  await monitor.shutdownWorktrees()
}

/// BZ's own junk walk counted as a program using what it burned: the check sees every program of
/// this user, BZ included. A copy dated in the same look it burned was walked at that moment, and
/// its refusal stood for six hours. Here the walk holds each folder it measures open, as the native
/// walker does for a moment with every folder it reads, and stays there until a burn wants it out.
private func adkOwnWalkProof(base: String, now: Date) async throws {
  let fm = FileManager.default
  let home = base + "/home"
  let repo = home + "/git/shop"
  try adkRepository(repo)
  try adkWrite("node_modules/\n", to: repo + "/.gitignore")
  try adkGit(repo, ["add", "."])
  try adkGit(repo, ["commit", "-m", "fixture"])
  let chunk = base + "/chunk"
  try Data(count: 104_857_600).write(to: URL(fileURLWithPath: chunk))
  var primary = WorktreeRecord(id: "shop", path: repo, repository: repo + "/.git")
  primary.main = true
  func copy(_ name: String) throws -> WorktreeRecord {
    let path = home + "/git/" + name
    try adkGit(repo, ["worktree", "add", "--detach", path])
    try fm.createDirectory(atPath: path + "/node_modules/pkg", withIntermediateDirectories: true)
    try adkWrite("{}", to: path + "/node_modules/.package-lock.json")
    try adkWrite("{}", to: path + "/node_modules/pkg/package.json")
    if clonefile(chunk, path + "/node_modules/pkg/part", 0) != 0 {
      try fm.copyItem(atPath: chunk, toPath: path + "/node_modules/pkg/part")
    }
    var record = WorktreeRecord(id: name, path: path, repository: repo + "/.git")
    record.lastFileChange = now.addingTimeInterval(-40 * 86_400)
    record.lastCommitAt = record.lastFileChange
    return record
  }
  let retired = try copy("shop-a")
  let cleared = try copy("shop-b")
  let held = try copy("shop-c")
  let later = try copy("shop-d")
  func junkOf(_ record: WorktreeRecord) -> String { record.path + "/node_modules" }
  let copyItem = AutopilotItem(
    id: "worktree:shop-a", kind: .worktree, name: "shop-a", path: retired.path, bytes: 100 << 20,
    facts: ["saved": "merged", "changes": "none"])
  let junkItem = AutopilotItem(
    id: "disk:" + AutopilotItem.hash(junkOf(cleared)), kind: .disk, name: "node_modules in shop-b",
    path: junkOf(cleared), bytes: 100 << 20, facts: ["folder": "node_modules"])

  let reached = Calls()
  let released = Calls()
  let junk = AutopilotJunkCache(sizer: { folder, stop in
    let handle = open(folder, O_RDONLY | O_DIRECTORY)
    defer { if handle >= 0 { close(handle) } }
    reached.add(folder)
    let deadline = Date().addingTimeInterval(20)
    while released.all.isEmpty, !stop(), Date() < deadline { usleep(2_000) }
    return AutopilotDisk.allocatedSize(folder, stop: stop)
  })
  let state = URL(fileURLWithPath: base + "/state")
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: state, accessCheck: fixtureAccess)
  let sources = AutopilotSources.live(
    monitor: monitor, root: state, home: home, junk: junk,
    recoveryKey: SymmetricKey(data: Data(repeating: 0x74, count: 32)))
  func reach(_ folder: String) async -> Bool {
    let deadline = Date().addingTimeInterval(20)
    while !reached.all.contains(folder), Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return reached.all.contains(folder)
  }

  // The walk is in the first copy, the one to burn.
  _ = sources.disk([primary, retired, cleared])
  let first = await reach(junkOf(retired))
  check(first, "the walk measures the first copy's junk")
  let refused = AutopilotWorktrees.retire(copyItem, authority: "operator", root: state)
  equal(
    refused.detail, "Something is using it right now.",
    "BZ's own walk in a copy counts as something using it")
  let burned = sources.retireWorktree(copyItem, "operator")
  if burned.outcome == "refused",
    burned.detail == "I could not check whether something is using it, so I left it alone.",
    WorktreeConsumerSnapshot(roots: [retired.path]).gap != nil {
    check(fm.fileExists(atPath: retired.path), "incomplete native visibility preserves the copy")
    print("PASS native copy cleanup held for incomplete consumer visibility")
  } else {
    equal(burned.outcome, "burned", "the burn steps the walk out of the copy first: \(burned.detail)")
    checkFalse(fm.fileExists(atPath: retired.path), "the copy is gone")
  }

  // It went on to the next copy, whose junk is to go.
  let next = await reach(junkOf(cleared))
  check(next, "the walk goes on to the next copy")
  let kept = AutopilotDisk.reclaim(junkItem, authority: "operator", home: home)
  equal(
    kept.detail, "Something is using that folder right now, so I left it alone.",
    "BZ's own walk in a junk folder counts as something using it")
  let reclaimed = sources.reclaimDisk(junkItem, "operator")
  if reclaimed.outcome == "refused",
    reclaimed.detail == "I couldn't tell if something is using that folder, so I left it alone.",
    WorktreeConsumerSnapshot(roots: [junkOf(cleared)]).gap != nil {
    check(fm.fileExists(atPath: junkOf(cleared)), "incomplete native visibility preserves the junk")
    print("PASS native junk cleanup held for incomplete consumer visibility")
  } else {
    equal(
      reclaimed.outcome, "burned", "the burn steps the walk out of the folder: \(reclaimed.detail)")
    checkFalse(fm.fileExists(atPath: junkOf(cleared)), "the junk is gone")
  }
  released.add("measure at full speed")

  // A walk that starts while a copy burns doesn't go in; once the burn is over, it does.
  let records = [primary, retired, cleared, held, later]
  func listed(_ items: [AutopilotItem], _ record: WorktreeRecord) -> Bool {
    items.contains { $0.path == junkOf(record) }
  }
  let during = junk.clearing(held.path) {
    var items = sources.disk(records)
    let deadline = Date().addingTimeInterval(20)
    while !listed(items, later), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      items = sources.disk(records)
    }
    return items
  }
  check(listed(during, later), "a walk measures the copies nothing burns")
  checkFalse(listed(during, held), "but not the copy being burned")
  checkFalse(reached.all.contains(junkOf(held)), "it doesn't even look inside")
  var after = sources.disk(records)
  let deadline = Date().addingTimeInterval(20)
  while !listed(after, held), Date() < deadline {
    try await Task.sleep(nanoseconds: 50_000_000)
    after = sources.disk(records)
  }
  check(listed(after, held), "a copy left for a burn that didn't happen is walked again")
  checkFalse(
    (burned.outcome == "burned" && listed(after, retired))
      || (reclaimed.outcome == "burned" && listed(after, cleared)),
    "what burned is not listed: \(after.map(\.name))")
  await monitor.shutdownWorktrees()
}
