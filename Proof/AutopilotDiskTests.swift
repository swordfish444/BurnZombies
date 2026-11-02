import BurnCore
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
  equal(AgentThreads.state(for: work + "/pro", threads: mixed).thread, "none", "prefix is not a match")
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
  check((size ?? 0) >= 1_048_576, "allocated size should cover the file: \(String(describing: size))")
  check((size ?? .max) < 3_000_000, "allocated size followed a symlink: \(String(describing: size))")
  equal(AutopilotDisk.allocatedSize(folder, deadline: -1), nil, "an expired deadline gives no size")
  equal(AutopilotDisk.allocatedSize(base + "/missing"), nil, "a missing folder has no size")
  equal(AutopilotDisk.allocatedSize(folder + "/link"), nil, "a symlink is never measured")

  // Counting stops at the deadline with what it found so far: a copy too big to measure in
  // time still shows it is big, instead of looking empty.
  equal(AutopilotDisk.countedSize(folder, deadline: 30), size, "a finished count is the size")
  let early = AutopilotDisk.countedSize(folder, deadline: -1)
  check(early != nil && early! <= size!, "an early stop is a lower bound: \(String(describing: early))")
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
  var unknown = linked
  unknown.lastFileChange = nil
  unknown.lastCommitAt = nil
  let unknownNodes = AutopilotDisk.items(worktrees: [unknown], home: home, now: now, sizer: sizer)
    .first { $0.path == old + "/node_modules" }
  equal(unknownNodes?.facts["home"], "repo", "unknown activity must not look stale")

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
    AutopilotDisk.reclaim(item, authority: authority, home: home, inUse: { _ in busy })
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
  refused(forged(home + "/projects-notes", "node_modules"), starter, 0, "a folder with a false label")
  refused(forged(old + "/a/b/c/node_modules", "node_modules"), starter, 0, "deeper than three levels")
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
  equal(burned.bytes, distBytes ?? 0, "receipt reports the measured size")
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
}
