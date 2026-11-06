import BurnCore
import Foundation

// Every case runs real Git against sacrificial repositories in a temporary folder. The
// operator's worktrees and the real Application Support folder are never touched.

@discardableResult
private func apGit(_ directory: String, _ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments =
    [
      "-c", "protocol.file.allow=always", "-c", "core.hooksPath=/dev/null", "-c",
      "commit.gpgsign=false", "-C", directory,
    ] + arguments
  var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
  environment["GIT_CONFIG_NOSYSTEM"] = "1"
  environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
  environment["GIT_TERMINAL_PROMPT"] = "0"
  environment["GIT_AUTHOR_NAME"] = "Proof"
  environment["GIT_AUTHOR_EMAIL"] = "proof@example.invalid"
  environment["GIT_COMMITTER_NAME"] = "Proof"
  environment["GIT_COMMITTER_EMAIL"] = "proof@example.invalid"
  process.environment = environment
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let output = String(decoding: data, as: UTF8.self)
  guard process.terminationStatus == 0 else {
    throw StoreError.message("git \(arguments.joined(separator: " ")) failed: \(output)")
  }
  return output
}

private func apLine(_ directory: String, _ arguments: [String]) throws -> String {
  try apGit(directory, arguments).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func apWrite(_ path: String, _ text: String) throws {
  let url = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
}

private func apRead(_ path: String) -> String? {
  try? String(contentsOfFile: path, encoding: .utf8)
}

private func apExists(_ path: String) -> Bool {
  var info = stat()
  return lstat(path, &info) == 0
}

private struct APWorld {
  var base: String
  var main: String
  var state: URL
  func path(_ name: String) -> String { base + "/" + name }
  func addWorktree(_ name: String, branch: String) throws -> String {
    let target = path(name)
    try apGit(main, ["worktree", "add", "-b", branch, target, "main"])
    return target
  }
  func ref(for item: AutopilotItem) -> String {
    "refs/burnzombies/retired/" + String(item.id.dropFirst("worktree:".count).prefix(16))
  }
}

private func apRecord(_ path: String, in repository: String) throws -> WorktreeRecord {
  let common = WorkspaceSafety.canonical(
    try WorktreeGit.line(repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
  let rows = try WorktreeDiscovery.parse(
    WorktreeGit.run(repository, ["worktree", "list", "--porcelain", "-z"]), repository: common)
  guard let row = rows.first(where: { $0.path == path }) else {
    throw StoreError.message("No worktree record for \(path)")
  }
  return WorktreeInspection.inspect(row, visibility: { _ in 0 })
}

private func apItem(
  _ path: String, _ world: APWorld, cache: inout [String: AutopilotDelivery], now: Date = Date()
) throws -> AutopilotItem {
  let record = try apRecord(path, in: world.main)
  let items = AutopilotWorktrees.items(
    [record], threads: [], delivery: &cache, now: now, budget: 10)
  guard let item = items.first else { throw StoreError.message("No item for \(path)") }
  return item
}

// MARK: Facts from records built directly (no Git)

private func apDirectProof() {
  let now = Date()
  func record(
    _ name: String, path: String? = nil, repository: String = "/bz-test/git/project/.git"
  ) -> WorktreeRecord {
    var r = WorktreeRecord(
      id: "id-" + name, path: path ?? "/bz-test/git/project-" + name, repository: repository)
    r.head = "abc123"
    r.branch = "refs/heads/feature-" + name
    r.status = "inspected"
    r.consumer = "none observed"
    r.allocated = 50_000_000
    r.lastFileChange = now.addingTimeInterval(-40 * 86_400)
    r.lastCommitAt = now.addingTimeInterval(-41 * 86_400)
    return r
  }
  func catalog(
    _ records: [WorktreeRecord], threads: [AgentThread] = [], saved: String = "merged"
  ) -> [AutopilotItem] {
    var cache: [String: AutopilotDelivery] = [:]
    for r in records {
      cache[r.id] = AutopilotDelivery(head: "abc123", saved: saved, checked: now)
    }
    return AutopilotWorktrees.items(
      records, threads: threads, delivery: &cache, now: now, budget: 0)
  }
  func one(_ r: WorktreeRecord, threads: [AgentThread] = []) -> AutopilotItem {
    catalog([r], threads: threads)[0]
  }

  var skipped = [record("missing"), record("retired"), record("bare")]
  skipped[0].missing = true
  skipped[1].retired = true
  skipped[2].bare = true
  equal(
    catalog(skipped + [record("kept")]).map(\.name), ["project-kept"],
    "missing, retired and bare records are skipped")

  // Hard rails, in kid-simple sentences.
  var primary = record("primary")
  primary.main = true
  equal(one(primary).protectedReason, "This is your main project folder.", "main checkout")
  var locked = record("locked")
  locked.locked = true
  check(one(locked).protectedReason?.contains("locked") == true, "locked copy is protected")
  var busy = record("busy")
  busy.consumer = "in use"
  equal(one(busy).protectedReason, "Something is using it right now.", "in-use copy")
  equal(one(busy).facts["inUse"], "yes", "in-use fact")
  let chatty = record("chatty")
  let live = AgentThread(
    id: "t1", agent: "claude", cwd: chatty.path + "/src", live: true, lastActive: now)
  equal(
    one(chatty, threads: [live]).protectedReason, "A chat is still working in it.",
    "copy with a live chat")
  equal(one(chatty, threads: [live]).facts["thread"], "live", "live thread fact")
  var rebasing = record("rebasing")
  rebasing.blockers = ["Git state requires completion: rebase-merge"]
  check(one(rebasing).protectedReason != nil, "copy in the middle of a Git operation")
  var codex = record("codex", path: "/bz-test/.codex/worktrees/a1b2/project")
  codex.ownerManaged = true
  isNil(one(codex).protectedReason)
  equal(one(codex).facts["place"], "codex", "owner-managed copies are not protected")
  isNil(one(record("plain")).protectedReason)

  // Facts follow the spec table.
  let plain = one(record("plain"))
  equal(plain.id, "worktree:id-plain")
  equal(plain.name, "project-plain")
  equal(plain.path, "/bz-test/git/project-plain")
  equal(plain.bytes, 50_000_000)
  equal(plain.facts["kind"], "worktree")
  equal(plain.facts["repo"], "project")
  equal(plain.facts["place"], "sibling")
  equal(plain.facts["saved"], "merged")
  equal(plain.facts["changes"], "none")
  equal(plain.facts["stale"], "month")
  equal(plain.facts["thread"], "none")
  equal(plain.facts["inUse"], "no")
  equal(plain.facts["size"], "small")
  for (path, place) in [
    ("/bz-test/.patrol6/worktrees/abc/project", "patrol6"),
    ("/bz-test/.codex/worktrees/1a2b/project", "codex"),
    ("/bz-test/.claude/worktrees/feature", "claude"),
    ("/bz-test/.claude-worktrees/feature", "claude"),
    ("/bz-test/conductor/workspaces/project/lima", "conductor"),
    ("/bz-test/git/project-feature", "sibling"),
    ("/Volumes/Work/project-feature", "other"),
  ] {
    equal(one(record("p", path: path)).facts["place"], place, "place of " + path)
  }
  equal(
    one(record("r", path: "/srv/git/service-copy", repository: "/srv/git/service.git"))
      .facts["repo"], "service", "repository folder name")
  equal(
    one(record("r", path: "/srv/git/service-copy", repository: "/srv/git/service.git"))
      .facts["place"], "sibling", "bare repository folder")

  func changes(_ status: String, _ count: Int) -> String? {
    var r = record("c")
    r.status = status
    r.changes = count
    return one(r).facts["changes"]
  }
  equal(changes("", 7), "unknown", "never inspected")
  equal(changes("x", 0), "none")
  equal(changes("x", 1), "small")
  equal(changes("x", 20), "small")
  equal(changes("x", 21), "large")

  func stale(_ days: Double?, chat: AgentThread? = nil) -> String? {
    var r = record("s")
    r.lastFileChange = days.map { now.addingTimeInterval(-$0 * 86_400) }
    r.lastCommitAt = r.lastFileChange
    return one(r, threads: chat.map { [$0] } ?? []).facts["stale"]
  }
  // Each age names its lower bound, like the idle ages of programs: "month" is 30+ days.
  equal(stale(0.5), "today")
  equal(stale(3), "day")
  equal(stale(9), "week", "9 days untouched is a week, not a month")
  equal(stale(29), "week")
  equal(stale(40), "month")
  equal(stale(100), "older")
  equal(stale(nil), "unknown", "no dates at all")
  // Without the file walk, an old commit can't say a copy sat unused: its files may be newer.
  var unwalked = record("s")
  unwalked.lastFileChange = nil
  unwalked.lastCommitAt = now.addingTimeInterval(-60 * 86_400)
  equal(one(unwalked).facts["stale"], "unknown", "only an old commit, no file dates")
  checkFalse(one(unwalked).detail.contains("untouched"), "no age claimed without file dates")
  let ended = AgentThread(
    id: "t2", agent: "codex", cwd: "/bz-test/git/project-s", live: false,
    lastActive: now.addingTimeInterval(-3600))
  equal(stale(40, chat: ended), "today", "chat activity counts as use")
  equal(one(record("s"), threads: [ended]).facts["thread"], "ended", "finished chat fact")

  // A question card names a copy by the task it was for, and says when it was last used: the
  // newest of the same dates the age is read from.
  equal(
    one(record("u")).lastUsed, now.addingTimeInterval(-40 * 86_400),
    "last used when a file last changed")
  isNil(one(unwalked).lastUsed)
  equal(
    one(record("s"), threads: [ended]).lastUsed, ended.lastActive, "a chat's activity is use too")
  equal(one(record("u")).title, "feature u", "named by its branch, in words")
  var nested = record("n")
  nested.branch = "refs/heads/codex/fix-login-selector"
  equal(one(nested).title, "fix login selector", "after the last slash")
  var detached = record("d")
  detached.branch = nil
  isNil(one(detached).title)
  var bare = record("e")
  bare.branch = "refs/heads/"
  isNil(one(bare).title)
  let titled = AgentThread(
    id: "t3", agent: "claude", cwd: "/bz-test/git/project-u/src", live: false,
    title: "Fix the login selector", lastActive: now.addingTimeInterval(-7200))
  let newest = AgentThread(
    id: "t4", agent: "claude", cwd: "/bz-test/git/project-u", live: false,
    title: "Newest chat title", lastActive: now.addingTimeInterval(-3600))
  let untitled = AgentThread(
    id: "t5", agent: "codex", cwd: "/bz-test/git/project-u", live: false,
    lastActive: now.addingTimeInterval(-600))
  let elsewhere = AgentThread(
    id: "t6", agent: "claude", cwd: "/bz-test/git/project-uu", live: false,
    title: "Another project", lastActive: now.addingTimeInterval(-60))
  var named = one(record("u"), threads: [titled, elsewhere])
  equal(named.title, "Fix the login selector", "a chat's title names the task")
  equal(named.lastUsed, titled.lastActive, "a chat in another folder is not this copy's")
  named = one(record("u"), threads: [titled, newest, untitled, elsewhere])
  equal(named.title, "Newest chat title", "the newest chat that has a title")
  equal(named.lastUsed, untitled.lastActive, "a newer chat without one still counts as use")
  equal(one(record("u"), threads: [untitled]).title, "feature u", "an untitled chat names nothing")
  // A chat belongs to a copy the same way for its chat fact and for its title: one in the folder
  // or anywhere inside it, with or without a trailing slash, and never one whose folder only
  // starts with the same letters.
  let within = AgentThread(
    id: "t7", agent: "claude", cwd: "/bz-test/git/project-m/src", live: true,
    title: "Inside the copy", lastActive: now)
  let beside = AgentThread(
    id: "t8", agent: "claude", cwd: "/bz-test/git/project-mm", live: true, title: "Beside it",
    lastActive: now)
  for path in ["/bz-test/git/project-m", "/bz-test/git/project-m/"] {
    equal(AgentThreads.state(for: path, threads: [within, beside]).thread, "live", path)
    equal(AgentThreads.chatTitle(for: path, threads: [within, beside]), "Inside the copy", path)
    equal(AgentThreads.state(for: path, threads: [beside]).thread, "none", path)
    isNil(AgentThreads.chatTitle(for: path, threads: [beside]))
  }

  // The finished-copies starter rule promises "untouched for a month".
  func starter(_ days: Double) -> AutopilotStatus {
    var r = record("m")
    r.lastFileChange = now.addingTimeInterval(-days * 86_400)
    r.lastCommitAt = r.lastFileChange
    return AutopilotPolicy.decide(one(r), memory: AutopilotMemory()).status
  }
  equal(starter(9), .unsure, "a finished copy left 9 days waits for an answer")
  equal(starter(40), .burn, "a finished copy left 40 days burns")

  func size(_ bytes: UInt64) -> String? {
    var r = record("z")
    r.allocated = bytes
    return one(r).facts["size"]
  }
  equal(size(99_999_999), "small")
  equal(size(100_000_000), "medium")
  equal(size(999_999_999), "medium")
  equal(size(1_000_000_000), "large")

  func consumer(_ value: String) -> String? {
    var r = record("u")
    r.consumer = value
    return one(r).facts["inUse"]
  }
  equal(consumer("none observed"), "no")
  equal(consumer("in use"), "yes")
  equal(consumer("unknown"), "unknown")

  // The delivery cache is trusted only for the same HEAD and for under a day.
  let cached = record("cached")
  var table = [
    cached.id: AutopilotDelivery(
      head: "abc123", saved: "pushed", checked: now.addingTimeInterval(-3600))
  ]
  func saved(budget: Int) -> String? {
    AutopilotWorktrees.items([cached], threads: [], delivery: &table, now: now, budget: budget)[0]
      .facts["saved"]
  }
  equal(saved(budget: 0), "pushed", "fresh cache entry is used without Git")
  table[cached.id]?.checked = now.addingTimeInterval(-25 * 3600)
  equal(saved(budget: 0), "unknown", "expired cache entry is not trusted")
  table[cached.id] = AutopilotDelivery(head: "other", saved: "pushed", checked: now)
  equal(saved(budget: 0), "unknown", "cache entry for another HEAD is not trusted")
  table = [:]
  equal(saved(budget: 0), "unknown", "no cache and no budget")
  equal(saved(budget: 1), "unknown", "a lookup that fails is unknown, never a guess")

  // A plain sentence.
  var gps = record(
    "gps", path: "/bz-test/git/p6-bodycam-gps", repository: "/bz-test/git/p6-bodycam/.git")
  gps.branch = "refs/heads/fix-gps"
  gps.lastFileChange = now.addingTimeInterval(-65 * 86_400)
  gps.lastCommitAt = now.addingTimeInterval(-66 * 86_400)
  equal(
    one(gps).detail, "Copy of p6-bodycam on fix-gps — merged, untouched for 2 months.",
    "detail sentence")
}

// MARK: Real repositories

private func apBuild(_ world: APWorld) throws {
  let origin = world.path("origin.git")
  try apGit(world.base, ["init", "--bare", "--initial-branch=main", origin])
  try apGit(world.base, ["init", "--initial-branch=main", world.main])
  try apWrite(world.main + "/.gitignore", "node_modules/\n.env\nbig.bin\n")
  try apWrite(world.main + "/README.md", "project\n")
  try apWrite(world.main + "/tracked.txt", "original\n")
  try apGit(world.main, ["add", "-A"])
  try apGit(world.main, ["commit", "-m", "initial"])
  try apGit(world.main, ["remote", "add", "origin", origin])
  try apGit(world.main, ["push", "-u", "origin", "main"])

  // A finished feature: pushed, then merged into main.
  let merged = try world.addWorktree("merged", branch: "feature-merged")
  try apWrite(merged + "/merged.txt", "done\n")
  try apGit(merged, ["add", "-A"])
  try apGit(merged, ["commit", "-m", "feature work"])
  try apGit(merged, ["push", "origin", "feature-merged"])
  try apGit(world.main, ["merge", "--ff-only", "feature-merged"])
  try apGit(world.main, ["push", "origin", "main"])

  // Pushed but not merged, and work that only exists locally.
  let pushed = try world.addWorktree("pushed", branch: "feature-pushed")
  try apWrite(pushed + "/pushed.txt", "pushed\n")
  try apGit(pushed, ["add", "-A"])
  try apGit(pushed, ["commit", "-m", "pushed work"])
  try apGit(pushed, ["push", "origin", "feature-pushed"])
  let local = try world.addWorktree("localwork", branch: "feature-local")
  try apWrite(local + "/local.txt", "local\n")
  try apGit(local, ["add", "-A"])
  try apGit(local, ["commit", "-m", "local work"])

  // A copy with every kind of leftover: an edit, a deletion, a new file and ignored files.
  let dirty = try world.addWorktree("dirty", branch: "feature-dirty")
  try apWrite(dirty + "/tracked.txt", "edited\n")
  try FileManager.default.removeItem(atPath: dirty + "/README.md")
  try apWrite(dirty + "/untracked.txt", "new\n")
  try apWrite(dirty + "/.env", "SECRET=1\n")
  try apWrite(dirty + "/node_modules/pkg/index.js", "module.exports = 1\n")
  try Data(repeating: 0x41, count: 6 << 20).write(to: URL(fileURLWithPath: dirty + "/big.bin"))

  // Clean copies for the refusal cases.
  for name in ["busy", "racing", "lockme"] {
    _ = try world.addWorktree(name, branch: "feature-" + name)
  }
}

private func apFactsProof(_ world: APWorld, _ items: [String: AutopilotItem]) throws {
  func facts(_ name: String) -> [String: String] { items[name]?.facts ?? [:] }
  equal(facts("merged")["saved"], "merged", "merged copy")
  equal(facts("merged")["changes"], "none")
  equal(facts("merged")["place"], "sibling")
  equal(facts("merged")["repo"], "project")
  equal(facts("merged")["inUse"], "no")
  equal(facts("merged")["thread"], "none")
  equal(facts("merged")["size"], "small")
  equal(facts("merged")["stale"], "today")
  equal(facts("merged")["kind"], "worktree")
  equal(facts("pushed")["saved"], "pushed", "pushed but not merged")
  equal(facts("localwork")["saved"], "local", "commits that only exist here")
  equal(facts("dirty")["saved"], "merged")
  equal(facts("dirty")["changes"], "small", "edit, deletion and new file")
  isNil(items["merged"]?.protectedReason)
  equal(
    items["main"]?.protectedReason, "This is your main project folder.", "main checkout protected")
  check(
    items["merged"]?.detail.hasPrefix("Copy of project on feature-merged — merged") == true,
    "detail names the copy: \(items["merged"]?.detail ?? "nil")")

  // Two months later the same copy reads as old.
  var cache: [String: AutopilotDelivery] = [:]
  let later = try apItem(
    world.path("merged"), world, cache: &cache, now: Date().addingTimeInterval(65 * 86_400))
  equal(later.facts["stale"], "month", "65 days is a month, not yet 3 months")
  equal(
    later.detail, "Copy of project on feature-merged — merged, untouched for 2 months.",
    "detail after two months")

  // A live chat inside a real copy protects it.
  let busyPath = world.path("busy")
  var cache2: [String: AutopilotDelivery] = [:]
  let record = try apRecord(busyPath, in: world.main)
  let chat = AgentThread(
    id: "live", agent: "claude", cwd: busyPath, live: true, lastActive: Date())
  let guarded = AutopilotWorktrees.items(
    [record], threads: [chat], delivery: &cache2, now: Date(), budget: 5)
  equal(guarded.first?.protectedReason, "A chat is still working in it.")
}

private func apDeliveryProof(_ world: APWorld) throws {
  let expectations = [("merged", "merged"), ("pushed", "pushed"), ("localwork", "local")]
  func verify(_ label: String) throws {
    for (name, expected) in expectations {
      let path = world.path(name)
      let result = try AutopilotWorktrees.delivery(path: path)
      equal(result.saved, expected, label + ": " + name)
      let head = try apLine(path, ["rev-parse", "HEAD"])
      equal(result.head, head, label + ": " + name + " head")
    }
  }
  try verify("origin/main fallback")
  try apGit(world.main, ["remote", "set-head", "origin", "main"])
  try verify("origin/HEAD target")

  // The catalog caches what it learned and spends its Git budget in order.
  let records = try ["merged", "pushed", "localwork"].map {
    try apRecord(world.path($0), in: world.main)
  }
  var limited: [String: AutopilotDelivery] = [:]
  let bounded = AutopilotWorktrees.items(
    records, threads: [], delivery: &limited, now: Date(), budget: 2)
  equal(
    bounded.map { $0.facts["saved"] ?? "" }, ["merged", "pushed", "unknown"],
    "the budget bounds Git lookups")
  equal(limited.count, 2, "only looked-up copies are cached")

  var cache: [String: AutopilotDelivery] = [:]
  let pushed = records[1]
  func saved(budget: Int) -> String? {
    AutopilotWorktrees.items(
      [pushed], threads: [], delivery: &cache, now: Date(), budget: budget
    )[0].facts["saved"]
  }
  equal(saved(budget: 1), "pushed")
  equal(cache[pushed.id]?.saved, "pushed", "the lookup is cached")
  cache[pushed.id] = AutopilotDelivery(head: pushed.head ?? "", saved: "merged", checked: Date())
  equal(saved(budget: 0), "merged", "a fresh entry for this HEAD is used without Git")
  cache[pushed.id]?.checked = Date().addingTimeInterval(-25 * 3600)
  equal(saved(budget: 0), "unknown", "an expired entry is not trusted")
  equal(saved(budget: 1), "pushed", "an expired entry is recomputed")

  // With no remotes at all, the local main branch is the default branch.
  let solo = world.path("solo")
  try apGit(world.base, ["init", "--initial-branch=main", solo])
  try apWrite(solo + "/a.txt", "a\n")
  try apGit(solo, ["add", "-A"])
  try apGit(solo, ["commit", "-m", "first"])
  let soloCopy = world.path("solo-copy")
  try apGit(solo, ["worktree", "add", "-b", "solo-feature", soloCopy, "main"])
  let atMain = try AutopilotWorktrees.delivery(path: soloCopy)
  equal(atMain.saved, "merged", "without remotes the local main is the default branch")
  try apGit(soloCopy, ["commit", "--allow-empty", "-m", "ahead"])
  let ahead = try AutopilotWorktrees.delivery(path: soloCopy)
  equal(ahead.saved, "local", "commits beyond every branch are local")
}

// MARK: Refusals

private func apAssertUntouched(_ world: APWorld, _ item: AutopilotItem, _ label: String) throws {
  guard let path = item.path else { return }
  check(apExists(path), label + ": the folder is gone")
  equal(apRead(path + "/tracked.txt"), "original\n", label + ": a file changed")
  let registered = try apGit(world.main, ["worktree", "list", "--porcelain"])
  check(registered.contains("worktree " + path + "\n"), label + ": the registration is gone")
  let backups = try apGit(
    world.main, ["for-each-ref", "--format=%(refname)", world.ref(for: item)])
  check(backups.isEmpty, label + ": a backup was written for a copy that was kept")
}

@discardableResult
private func apExpectRefusal(
  _ world: APWorld, _ item: AutopilotItem, _ label: String,
  inUse: (String) -> Int32 = { _ in 0 }
) throws -> AutopilotReceipt {
  let receipt = AutopilotWorktrees.retire(
    item, authority: "operator", root: world.state, inUse: inUse)
  equal(
    receipt.outcome, "refused",
    label + ": expected a refusal, got \(receipt.outcome): \(receipt.detail)")
  check(!receipt.detail.isEmpty, label + ": the refusal explains nothing")
  isNil(receipt.restore)
  equal(receipt.bytes, 0, label + ": a refusal frees nothing")
  try apAssertUntouched(world, item, label)
  return receipt
}

private func apRefusalProof(_ world: APWorld, _ items: [String: AutopilotItem]) throws {
  let mainItem = items["main"]!
  let protectedRefusal = try apExpectRefusal(world, mainItem, "main checkout")
  equal(protectedRefusal.detail, "This is your main project folder.")
  var unflagged = mainItem
  unflagged.protectedReason = nil
  let railRefusal = try apExpectRefusal(world, unflagged, "main checkout without the flag")
  equal(railRefusal.detail, "This is your main project folder.", "linked-worktree check")

  // Something is using it, or nobody can tell.
  let busy = items["busy"]!
  var asked: [String] = []
  try apExpectRefusal(
    world, busy, "in use",
    inUse: {
      asked.append($0)
      return 1
    })
  equal(asked, [busy.path!], "the in-use check looked at the copy")
  let unknown = try apExpectRefusal(world, busy, "consumers unknown", inUse: { _ in -1 })
  equal(unknown.detail, "I could not check whether something is using it, so I left it alone.")

  // A merge in progress.
  let busyPath = world.path("busy")
  let busyGitDir = try apLine(busyPath, ["rev-parse", "--absolute-git-dir"])
  let busyHead = try apLine(busyPath, ["rev-parse", "HEAD"])
  try apWrite(busyGitDir + "/MERGE_HEAD", busyHead + "\n")
  try apExpectRefusal(world, busy, "merge in progress")
  try FileManager.default.removeItem(atPath: busyGitDir + "/MERGE_HEAD")

  // Locked after it was cataloged, and locked when cataloged.
  let lockPath = world.path("lockme")
  try apGit(world.main, ["worktree", "lock", "--reason", "proof", lockPath])
  try apExpectRefusal(world, items["lockme"]!, "locked after cataloging")
  var cache: [String: AutopilotDelivery] = [:]
  let relocked = try apItem(lockPath, world, cache: &cache)
  check(relocked.protectedReason?.contains("locked") == true, "cataloged lock is a rail")
  try apExpectRefusal(world, relocked, "locked when cataloged")
  try apGit(world.main, ["worktree", "unlock", lockPath])

  // The saved state changed between the catalog and the retire.
  try apGit(world.path("racing"), ["commit", "--allow-empty", "-m", "local only"])
  let race = try apExpectRefusal(world, items["racing"]!, "saved changed since the catalog")
  equal(race.detail, "This copy changed since I last looked.")

  // A fact the catalog had not checked yet may only turn out safe.
  var unchecked = items["localwork"]!
  unchecked.facts["saved"] = "unknown"
  let early = try apExpectRefusal(world, unchecked, "local-only work the catalog had not checked")
  equal(early.detail, "I hadn't finished checking this copy, so I'll judge it again.")
  var uncheckedEdits = items["dirty"]!
  uncheckedEdits.facts["changes"] = "unknown"
  let edits = AutopilotWorktrees.retire(
    uncheckedEdits, authority: "operator", root: world.state, inUse: { _ in 0 })
  equal(edits.outcome, "refused", "edits the catalog had not checked")
  equal(edits.detail, "I hadn't finished checking this copy, so I'll judge it again.")
  equal(apRead(world.path("dirty") + "/tracked.txt"), "edited\n", "the edit is left alone")

  // Nothing there to retire.
  let ghost = AutopilotItem(
    id: "worktree:ghost", kind: .worktree, name: "ghost", path: world.path("ghost"),
    facts: ["saved": "merged", "changes": "none"])
  let gone = AutopilotWorktrees.retire(
    ghost, authority: "operator", root: world.state, inUse: { _ in 0 })
  equal(gone.outcome, "refused", "missing folder")

  // Checked again once the backup is written: something started using it, or the check couldn't
  // tell, which says nothing about the copy.
  for (answer, reason) in [
    (Int32(1), "Something started using it, so I left it alone."),
    (-1, "I could not check whether something is using it, so I left it alone."),
  ] {
    var checks = 0
    let late = AutopilotWorktrees.retire(
      busy, authority: "operator", root: world.state,
      inUse: { _ in
        checks += 1
        return checks == 1 ? 0 : answer
      })
    equal(late.outcome, "refused", "second check \(answer)")
    equal(late.detail, reason, "second check \(answer)")
    equal(checks, 2, "second check \(answer): both checks ran")
    equal(apRead(busyPath + "/tracked.txt"), "original\n", "second check \(answer): the copy stays")
  }
}

// MARK: Retire and restore

/// The catalog had not checked where the work is saved or whether it has changes yet; both
/// turn out safe when the copy is retired.
private func apUncheckedRetire(_ world: APWorld, _ item: AutopilotItem) throws {
  var unchecked = item
  unchecked.facts["saved"] = "unknown"
  unchecked.facts["changes"] = "unknown"
  let receipt = AutopilotWorktrees.retire(
    unchecked, authority: "ai:0.90", root: world.state, inUse: { _ in 0 })
  equal(receipt.outcome, "burned", "pushed and clean once checked: " + receipt.detail)
  checkFalse(apExists(item.path!), "the unchecked copy is gone")
  check(receipt.restore != nil, "the unchecked copy is restorable")
}

private func apCleanRetire(_ world: APWorld, _ item: AutopilotItem) throws {
  let path = item.path!
  let head = try apLine(path, ["rev-parse", "HEAD"])
  var asked: [String] = []
  let receipt = AutopilotWorktrees.retire(
    item, authority: "starter:starter-finished-copies", root: world.state,
    inUse: {
      asked.append($0)
      return 0
    })
  equal(receipt.outcome, "burned", "clean merged copy: " + receipt.detail)
  equal(receipt.authority, "starter:starter-finished-copies")
  equal(receipt.itemID, item.id)
  equal(receipt.bytes, item.bytes, "bytes freed are the copy's size")
  check(asked.contains(path), "the in-use check looked at the copy")
  checkFalse(apExists(path), "the folder is gone")
  let registered = try apGit(world.main, ["worktree", "list", "--porcelain"])
  checkFalse(registered.contains(path), "the registration is gone")
  guard let restore = receipt.restore else {
    failTest("clean retire produced no restore information")
    return
  }
  equal(restore.snapshot, false, "a clean copy needs no snapshot")
  equal(restore.branch, "feature-merged")
  equal(restore.head, head)
  equal(restore.path, path)
  equal(
    WorkspaceSafety.canonical(restore.repository),
    WorkspaceSafety.canonical(world.main + "/.git"), "repository is the common directory")
  check(restore.ref.hasPrefix("refs/burnzombies/retired/"), restore.ref)
  let stored = try apLine(world.main, ["rev-parse", restore.ref])
  equal(stored, head, "the safety ref points at HEAD")
  let branchTip = try apLine(world.main, ["rev-parse", "refs/heads/feature-merged"])
  equal(branchTip, head, "the branch is untouched")

  // Retiring again, or restoring over something else, is refused.
  let again = AutopilotWorktrees.retire(
    item, authority: "operator", root: world.state, inUse: { _ in 0 })
  equal(again.outcome, "refused", "retiring twice")
  try apWrite(path + "/squatter.txt", "mine\n")
  do {
    try AutopilotWorktrees.restore(receipt)
    failTest("restore went ahead although the folder was taken")
  } catch {}
  equal(apRead(path + "/squatter.txt"), "mine\n", "the folder in the way was left alone")
  let listing = try apGit(world.main, ["worktree", "list", "--porcelain"])
  checkFalse(listing.contains("worktree " + path + "\n"), "no registration was created")
  try FileManager.default.removeItem(atPath: path)

  try AutopilotWorktrees.restore(receipt)
  equal(apRead(path + "/merged.txt"), "done\n", "files are back")
  let attached = try apLine(path, ["symbolic-ref", "HEAD"])
  equal(attached, "refs/heads/feature-merged", "the branch is checked out again")
  let restoredHead = try apLine(path, ["rev-parse", "HEAD"])
  equal(restoredHead, head)
  let status = try apGit(path, ["status", "--porcelain"])
  check(status.isEmpty, "the restored copy is clean: " + status)
}

private func apDirtyRetire(_ world: APWorld, _ item: AutopilotItem) throws {
  let path = item.path!
  let head = try apLine(path, ["rev-parse", "HEAD"])
  let receipt = AutopilotWorktrees.retire(
    item, authority: "operator", root: world.state, inUse: { _ in 0 })
  equal(receipt.outcome, "burned", "dirty copy: " + receipt.detail)
  checkFalse(apExists(path), "the folder is gone")
  guard let restore = receipt.restore else {
    failTest("dirty retire produced no restore information")
    return
  }
  equal(restore.snapshot, true, "local changes need a snapshot")
  equal(restore.head, head)
  let parent = try apLine(world.main, ["rev-parse", restore.ref + "^"])
  equal(parent, head, "the snapshot sits on top of HEAD")
  let listing = try apGit(world.main, ["ls-tree", "-r", "--name-only", restore.ref])
  let names = Set(listing.split(separator: "\n").map(String.init))
  check(names.contains("tracked.txt"), "the edited file is in the snapshot")
  check(names.contains("untracked.txt"), "the new file is in the snapshot")
  check(names.contains(".env"), "the small ignored file is in the snapshot")
  checkFalse(names.contains("README.md"), "the deleted file stays deleted in the snapshot")
  checkFalse(
    names.contains(where: { $0.hasPrefix("node_modules") }), "node_modules is not saved")
  checkFalse(names.contains("big.bin"), "a large ignored file is not saved")

  try AutopilotWorktrees.restore(receipt)
  equal(apRead(path + "/tracked.txt"), "edited\n", "the edit is back")
  equal(apRead(path + "/untracked.txt"), "new\n", "the new file is back")
  equal(apRead(path + "/.env"), "SECRET=1\n", "the ignored .env is back")
  checkFalse(apExists(path + "/README.md"), "the deletion is back")
  checkFalse(apExists(path + "/node_modules"), "node_modules was not restored")
  checkFalse(apExists(path + "/big.bin"), "the large ignored file was not restored")
  let status = try apGit(path, ["status", "--porcelain", "--untracked-files=all"])
  equal(
    Set(status.split(separator: "\n").map(String.init)),
    [" D README.md", " M tracked.txt", "?? untracked.txt"], "the changes are uncommitted again")
  let restoredHead = try apLine(path, ["rev-parse", "HEAD"])
  equal(restoredHead, head, "HEAD is where it was")
  let attached = try apLine(path, ["symbolic-ref", "HEAD"])
  equal(attached, "refs/heads/feature-dirty", "the branch is checked out again")
}

/// Test runs leave browser profiles in copies (Chrome keeps one in a folder with `Local State`
/// beside `Default/Preferences`): test state, not work. A copy whose big unsaved files are such a
/// profile is burned without it, and its other unsaved work is backed up. Any other big unsaved
/// files still keep the copy, as does a profile folder that holds a file Git tracks.
private func apBrowserProfileRetire(_ world: APWorld) throws {
  // Sparse: counts its full size, takes no disk.
  func big(_ path: String) throws {
    try apWrite(path, "")
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.truncate(atOffset: 600 << 20)
    try handle.close()
  }
  func profile(_ folder: String) throws {
    try apWrite(folder + "/Local State", "{}\n")
    try apWrite(folder + "/Default/Preferences", "{}\n")
    try big(folder + "/Default/Cache/data_1")
  }
  var cache: [String: AutopilotDelivery] = [:]
  func burn(_ path: String) throws -> AutopilotReceipt {
    AutopilotWorktrees.retire(
      try apItem(path, world, cache: &cache), authority: "operator", root: world.state,
      inUse: { _ in 0 })
  }

  let copy = try world.addWorktree("profiled", branch: "feature-profiled")
  try profile(copy + "/.qa artifacts/browser profile [1]")
  try apWrite(copy + "/notes.txt", "keep me\n")
  let receipt = try burn(copy)
  equal(receipt.outcome, "burned", "a browser profile doesn't keep a copy: " + receipt.detail)
  checkFalse(apExists(copy), "the copy is gone")
  let dropped = AutopilotPolicy.format((600 << 20) + 6)
  check(
    receipt.detail.hasSuffix("Its browser profiles (\(dropped)) weren't kept."),
    "the receipt says what wasn't kept: " + receipt.detail)
  if let restore = receipt.restore {
    let listing = try apGit(world.main, ["ls-tree", "-r", "--name-only", restore.ref])
    let names = listing.split(separator: "\n").map(String.init)
    check(names.contains("notes.txt"), "the other unsaved file is backed up")
    checkFalse(names.contains(where: { $0.hasPrefix(".qa artifacts") }), "the profile isn't")
    try AutopilotWorktrees.restore(receipt)
    equal(apRead(copy + "/notes.txt"), "keep me\n", "the unsaved file is back")
    checkFalse(apExists(copy + "/.qa artifacts"), "the profile isn't")
  } else {
    failTest("the burn left no way to restore it")
  }

  // Only browser profiles are let go.
  let other = try world.addWorktree("bigfiles", branch: "feature-bigfiles")
  try big(other + "/recordings/session.mov")
  let kept = try burn(other)
  equal(kept.outcome, "refused", "other big unsaved files keep the copy")
  equal(kept.detail, "It has big files that aren't saved anywhere else, so I left it alone.")
  check(apExists(other + "/recordings/session.mov"), "and they're still there")
  let fixture = try world.addWorktree("fixture", branch: "feature-fixture")
  try apWrite(fixture + "/fixtures/profile/Default/Preferences", "{}\n")
  try apGit(fixture, ["add", "fixtures"])
  try apGit(fixture, ["commit", "-m", "a profile the tests use"])
  try apWrite(fixture + "/fixtures/profile/Local State", "{}\n")
  try big(fixture + "/fixtures/profile/Default/Cache/data_1")
  equal(try burn(fixture).outcome, "refused", "a profile Git tracks part of is somebody's work")
}

/// Unsaved files too big to back up don't keep a copy for good. Retire names them, so the owner can
/// be asked, and drops them only from a copy known to hold every kind of them (`bigCode=yes` and so
/// on) that burns under a lesson: the policy lets no lesson burn such a copy unless it names those
/// kinds. A folder of throwaway checkouts goes as one, ignored files inside it too, while the small
/// new files beside it are backed up and come back on restore. The owner's Burn now and the AI
/// still leave such a copy alone, and so do a kind that turned up since and a project inside the
/// big files.
private func apBigFilesRetire(_ world: APWorld) throws {
  // Sparse: counts its full size, takes no disk.
  func big(_ path: String, megabytes: UInt64) throws {
    try apWrite(path, "")
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    try handle.truncate(atOffset: megabytes << 20)
    try handle.close()
  }
  var cache: [String: AutopilotDelivery] = [:]
  /// Retires the copy as the catalog has it, carrying the kinds of big files `known` names.
  func burn(_ path: String, known: [String], _ authority: String) throws -> AutopilotReceipt {
    var item = try apItem(path, world, cache: &cache)
    for risk in known { item.facts[risk] = "yes" }
    return AutopilotWorktrees.retire(
      item, authority: authority, root: world.state, inUse: { _ in 0 })
  }
  let checkouts: UInt64 = 7 * (90 << 20)

  let copy = try world.addWorktree("checkouts", branch: "feature-checkouts")
  try apWrite(copy + "/.gitignore", "*.local\n")
  try apGit(copy, ["add", ".gitignore"])
  try apGit(copy, ["commit", "-q", "-m", "Ignore local settings"])
  for n in 1...7 { try big(copy + "/tmp/checkouts/c\(n)/game.ts", megabytes: 90) }
  try apWrite(copy + "/tmp/checkouts/c1/settings.local", "token=1\n")
  try apWrite(copy + "/tmp/results.json", "{\"wins\": 3}\n")
  try apWrite(copy + "/tools/balance.ts", "export const damage = 7\n")
  for (known, authority, who) in [
    (["bigCode"], "operator", "the owner's Burn now"), (["bigCode"], "ai:0.95", "the AI"),
    ([], "rule:lesson", "a lesson, before the copy was known to hold them"),
  ] {
    let receipt = try burn(copy, known: known, authority)
    equal(receipt.outcome, "refused", who + " leaves it alone")
    equal(receipt.detail, "It has big files that aren't saved anywhere else, so I left it alone.")
    equal(receipt.bigFiles?.map(\.path), ["tmp/checkouts"], who + ": the refusal names them")
  }
  let named = try burn(copy, known: [], "rule:lesson").bigFiles?.first
  equal(named?.bytes, checkouts)
  equal(named?.files, 7)
  equal(named?.kind, "TypeScript files")
  check(
    (named?.changed).map { abs($0.timeIntervalSinceNow) < 600 } == true,
    "with when they last changed")
  check(apExists(copy + "/tmp/checkouts/c1/game.ts"), "and leaves them there")

  let receipt = try burn(copy, known: ["bigCode"], "rule:lesson")
  equal(receipt.outcome, "burned", "a lesson that let big code go burns it: " + receipt.detail)
  let gone =
    "Its big unsaved files were deleted for good: tmp/checkouts ("
    + AutopilotPolicy.roughly(checkouts) + " of TypeScript files)."
  check(receipt.detail.hasSuffix(gone), "the receipt says what went: " + receipt.detail)
  equal(receipt.bigFiles?.map(\.path), ["tmp/checkouts"])
  checkFalse(apExists(copy), "the copy is gone")
  if let restore = receipt.restore {
    let listing = try apGit(world.main, ["ls-tree", "-r", "--name-only", restore.ref])
    let names = listing.split(separator: "\n").map(String.init)
    check(names.contains("tmp/results.json"), "the small unsaved files are backed up")
    check(names.contains("tools/balance.ts"), "the new script too")
    checkFalse(names.contains { $0.hasPrefix("tmp/checkouts") }, "the checkouts aren't, ignored or not")
    try AutopilotWorktrees.restore(receipt)
    equal(apRead(copy + "/tools/balance.ts"), "export const damage = 7\n", "the script is back")
    checkFalse(apExists(copy + "/tmp/checkouts"), "the checkouts aren't")
  } else {
    failTest("the burn left no way to restore it")
  }

  // A single big file goes alone; the note beside it is backed up.
  let dump = try world.addWorktree("dump", branch: "feature-dump")
  try big(dump + "/dump.sql", megabytes: 600)
  try apWrite(dump + "/notes.txt", "keep me\n")
  let dropped = try burn(dump, known: ["bigData"], "rule:lesson")
  equal(dropped.outcome, "burned", dropped.detail)
  equal(dropped.bigFiles?.map(\.path), ["dump.sql"])
  if let restore = dropped.restore {
    let listing = try apGit(world.main, ["ls-tree", "-r", "--name-only", restore.ref])
    let names = listing.split(separator: "\n").map(String.init)
    check(names.contains("notes.txt"), "the note is backed up")
    checkFalse(names.contains("dump.sql"), "the dump isn't")
  } else {
    failTest("the dump's copy left no way to restore it")
  }

  // A project in an ignored folder inside the big files keeps the copy too, as the walk of ignored
  // files finds it when nothing is big.
  let ignored = try world.addWorktree("ignored-project", branch: "feature-ignored-project")
  try apWrite(ignored + "/.gitignore", "*.local\n")
  try apGit(ignored, ["add", ".gitignore"])
  try apGit(ignored, ["commit", "-q", "-m", "Ignore local tools"])
  for n in 1...7 { try big(ignored + "/tmp/checkouts/c\(n)/game.ts", megabytes: 90) }
  let tools = ignored + "/tmp/checkouts/c1/tools.local"
  try FileManager.default.createDirectory(atPath: tools, withIntermediateDirectories: true)
  try apGit(tools, ["init", "-q"])
  try apGit(tools, ["commit", "-q", "--allow-empty", "-m", "Tools that exist only here"])
  let hidden = try burn(ignored, known: ["bigCode"], "rule:lesson")
  equal(hidden.outcome, "refused", "a project in an ignored folder inside the big files")
  equal(
    hidden.detail,
    "There is another project folder inside it that I can't back up, so I left it alone.")
  check(apExists(tools + "/.git"), "and it's still there")

  // A project inside the big files keeps the copy, as it does when Git would back it up.
  let nested = try world.addWorktree("nested", branch: "feature-nested")
  for n in 1...7 { try big(nested + "/tmp/checkouts/c\(n)/game.ts", megabytes: 90) }
  let inner = nested + "/tmp/checkouts/c1/inner"
  try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
  try apGit(inner, ["init", "-q"])
  try apGit(inner, ["commit", "-q", "--allow-empty", "-m", "Work that exists only here"])
  let kept = try burn(nested, known: ["bigCode"], "rule:lesson")
  equal(kept.outcome, "refused", "a project inside the big files keeps the copy")
  equal(
    kept.detail,
    "There is another project folder inside it that I can't back up, so I left it alone.")
  check(apExists(inner + "/.git"), "and it's still there")

  // A kind that turned up since the card keeps the copy, named, so it can be asked about.
  let mixed = try world.addWorktree("mixed", branch: "feature-mixed")
  for n in 1...7 { try big(mixed + "/tmp/checkouts/c\(n)/game.ts", megabytes: 90) }
  try big(mixed + "/qa/recordings/take.mp4", megabytes: 600)
  let newKind = try burn(mixed, known: ["bigCode"], "rule:lesson")
  equal(newKind.outcome, "refused", "big videos the lesson never covered keep the copy")
  equal(newKind.bigFiles?.map(\.risks), [["bigCode"], ["bigMedia"]], "both kinds are named, biggest first")
  check(apExists(mixed + "/tmp/checkouts/c1/game.ts"), "and nothing is gone")
}

private func apSubmoduleProof(_ world: APWorld) throws {
  let libOrigin = world.path("lib.git")
  let libSeed = world.path("lib-seed")
  try apGit(world.base, ["init", "--bare", "--initial-branch=main", libOrigin])
  try apGit(world.base, ["init", "--initial-branch=main", libSeed])
  try apWrite(libSeed + "/lib.txt", "lib\n")
  try apGit(libSeed, ["add", "-A"])
  try apGit(libSeed, ["commit", "-m", "lib"])
  try apGit(libSeed, ["remote", "add", "origin", libOrigin])
  try apGit(libSeed, ["push", "-u", "origin", "main"])
  try apGit(world.main, ["submodule", "add", libOrigin, "libs/lib"])
  try apGit(world.main, ["commit", "-m", "add the lib submodule"])
  try apGit(world.main, ["push", "origin", "main"])
  let copy = try world.addWorktree("withsub", branch: "feature-sub")
  try apGit(copy, ["submodule", "update", "--init"])
  let sub = copy + "/libs/lib"
  var cache: [String: AutopilotDelivery] = [:]

  // Unsaved changes inside a submodule keep the copy.
  try apWrite(sub + "/scratch.txt", "unsaved\n")
  let dirty = try apItem(copy, world, cache: &cache)
  try apExpectRefusal(world, dirty, "dirty submodule")
  check(apExists(sub + "/scratch.txt"), "the submodule file is still there")

  // So does a submodule commit that no remote has.
  try FileManager.default.removeItem(atPath: sub + "/scratch.txt")
  try apGit(sub, ["commit", "--allow-empty", "-m", "local only"])
  let ahead = try apItem(copy, world, cache: &cache)
  try apExpectRefusal(world, ahead, "submodule commit only saved here")

  // A clean submodule that the remote has does not get in the way.
  try apGit(sub, ["reset", "--hard", "HEAD~1"])
  let clean = try apItem(copy, world, cache: &cache)
  equal(clean.facts["changes"], "none", "the submodule is back to the recorded commit")
  let receipt = AutopilotWorktrees.retire(
    clean, authority: "operator", root: world.state, inUse: { _ in 0 })
  equal(receipt.outcome, "burned", "clean submodule: " + receipt.detail)
  checkFalse(apExists(copy), "the copy with a submodule is gone")
  try AutopilotWorktrees.restore(receipt)
  check(apExists(copy + "/.gitmodules"), "the copy with a submodule is back")
  let head = try apLine(copy, ["rev-parse", "HEAD"])
  equal(head, receipt.restore?.head, "restored at the saved commit")
}

// MARK: Copies the inventory couldn't walk

/// The inventory's file walk stops at a hard-linked file (or a project inside a copy, or a special
/// file), and such a copy had no age, so no lesson or question reached it. It gets one from a look
/// of its own, a few copies per tick.
private func apUnwalkedAgeProof(_ world: APWorld) throws {
  let fm = FileManager.default
  let day: TimeInterval = 86_400
  // Everything here is made now; looking 40 days later makes it 40 days old.
  let later = Date().addingTimeInterval(40 * day)
  func touch(_ path: String, _ date: Date) throws {
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
  }
  // A file hard-linked from a package store, as pnpm makes them.
  func stuck(_ name: String) throws -> String {
    let copy = try world.addWorktree(name, branch: "feature-" + name)
    try apWrite(world.path(name + "-store.txt"), "shared\n")
    try fm.linkItem(atPath: world.path(name + "-store.txt"), toPath: copy + "/linked.txt")
    return copy
  }
  let untouched = try stuck("stuck-untouched")
  // A new file three and a half days before the look.
  let edited = try stuck("stuck-edited")
  try apWrite(edited + "/notes.txt", "draft\n")
  try touch(edited + "/notes.txt", later - 3.5 * day)
  // Git rewrote the index ten days before.
  let staged = try stuck("stuck-staged")
  try touch(
    try apLine(staged, ["rev-parse", "--path-format=absolute", "--git-path", "index"]),
    later - 10 * day)
  // A file deleted half a day before counts by the folder it was in.
  let deleted = try stuck("stuck-deleted")
  try apWrite(deleted + "/docs/guide.txt", "guide\n")
  try apGit(deleted, ["add", "docs"])
  try apGit(deleted, ["commit", "-m", "guide"])
  try fm.removeItem(atPath: deleted + "/docs/guide.txt")
  try touch(deleted + "/docs", later - day / 2)
  // A junk folder counts by its own time.
  let installed = try stuck("stuck-installed")
  try apWrite(installed + "/node_modules/pkg/index.js", "module.exports = 1\n")
  try touch(installed + "/node_modules", later - 2 * day)

  let paths = [untouched, edited, staged, deleted, installed]
  var records = try paths.map { try apRecord($0, in: world.main) }
  for record in records {
    isNil(record.lastFileChange)
    check(
      record.gaps.contains("Hardlinked files require owner handling."),
      "the walk stops at the linked file: \(record.gaps)")
    checkFalse(record.status.isEmpty, "Git status was read")
  }
  var cache: [String: AutopilotDelivery] = [:]
  func items(_ records: [WorktreeRecord]) -> [AutopilotItem] {
    AutopilotWorktrees.items(records, threads: [], delivery: &cache, now: later, budget: 10)
  }
  func stale(_ records: [WorktreeRecord]) -> [String] {
    items(records).map { $0.facts["stale"] ?? "" }
  }
  let unknown = Array(repeating: "unknown", count: paths.count)
  equal(stale(records), unknown, "no walk, no age")

  var probed: [String] = []
  var given: Set<TimeInterval> = []
  let ages = AutopilotAges { path, seconds, stop in
    probed.append(path)
    given.insert(seconds)
    return AutopilotWorktrees.lastWorked(path: path, seconds: seconds, stop: stop)
  }
  equal(stale(ages.fill(records, budget: 0, now: later)), unknown, "no budget, no look")
  equal(probed, [], "nothing is looked at without a budget")
  equal(
    stale(ages.fill(records, limit: 2, now: later)),
    ["month", "day", "unknown", "unknown", "unknown"], "a few copies per look")
  equal(
    stale(ages.fill(records, limit: 2, now: later)), ["month", "day", "week", "today", "unknown"],
    "the next look dates the next few")
  equal(
    stale(ages.fill(records, limit: 2, now: later)), ["month", "day", "week", "today", "day"],
    "within three looks every copy has an age")
  equal(probed, paths, "each copy is looked at once")
  equal(given, [10], "each look gets its full time, however much of the tick's is left")
  let card = items(ages.fill([records[1]], now: later))[0]
  let lastUsed = card.lastUsed?.timeIntervalSince(later - 3.5 * day) ?? .infinity
  check(
    abs(lastUsed) < 1, "the card says when it was last used: \(String(describing: card.lastUsed))")
  check(card.detail.contains("untouched for 3 days"), "and so does its sentence: " + card.detail)

  // Now a lesson about how long copies sat unused reaches them.
  var memory = AutopilotMemory()
  memory.rules = [
    AutopilotRule(
      kind: .worktree, match: ["stale": ["day", "week", "month", "older"]], verdict: .burn,
      source: .operator, title: "Copies untouched since yesterday")
  ]
  let undated = items([records[1]])[0]
  equal(AutopilotPolicy.decide(undated, memory: memory).status, .unsure, "no age, no lesson")
  equal(AutopilotPolicy.decide(card, memory: memory).status, .burn, "the lesson covers it")

  // Only copies the inventory looked into and couldn't walk are dated.
  let walked = try apRecord(
    try world.addWorktree("walked", branch: "feature-walked"), in: world.main)
  check(walked.lastFileChange != nil, "a copy the inventory walked has its own date")
  var outside = records[0]
  outside.id += "-outside"
  outside.status = ""
  let others = ages.fill([walked, outside], now: later)
  equal(others[0].lastFileChange, walked.lastFileChange, "a walked copy keeps the walk's date")
  isNil(others[1].lastFileChange)
  equal(probed.count, paths.count, "neither is looked at")

  // A date holds until the inventory sees the copy change, or for an hour.
  try apWrite(untouched + "/fresh.txt", "new\n")
  try touch(untouched + "/fresh.txt", later - 3600)
  equal(stale(ages.fill(records, now: later))[0], "month", "unchanged as far as it knows")
  records[0] = try apRecord(untouched, in: world.main)
  equal(stale(ages.fill(records, now: later))[0], "today", "a copy seen changing is dated again")
  equal(probed.count, paths.count + 1)
  try apGit(edited, ["commit", "--allow-empty", "-m", "more"])
  records[1] = try apRecord(edited, in: world.main)
  _ = ages.fill(records, now: later)
  equal(probed.count, paths.count + 2, "so is one whose HEAD moved")
  _ = ages.fill(records, now: later + 3601)
  equal(probed.count, 2 * paths.count + 2, "an hour later each copy is looked at again")

  // The look sees inside what Git lists as one entry: a project inside the copy, and an ignored
  // folder that isn't junk.
  let nested = try stuck("stuck-nested")
  try apGit(world.base, ["init", "--initial-branch=main", nested + "/vendor/lib"])
  try apWrite(nested + "/vendor/lib/src/lib.c", "int lib;\n")
  try touch(nested + "/vendor/lib/src/lib.c", later - 1.5 * day)
  let ignored = try stuck("stuck-ignored")
  try apWrite(ignored + "/.env/keys.txt", "KEY=1\n")
  try touch(ignored + "/.env/keys.txt", later - 1.5 * day)
  let inside = try [nested, ignored].map { try apRecord($0, in: world.main) }
  equal(stale(ages.fill(inside, now: later)), ["day", "day"], "dated by the file inside")

  // A look that can't finish says nothing: anything partial could only make a copy look older.
  isNil(AutopilotWorktrees.lastWorked(path: edited, seconds: 0))
  isNil(AutopilotWorktrees.lastWorked(path: world.path("gone"), seconds: 10))
  let plain = world.path("not-a-copy")
  try fm.createDirectory(atPath: plain, withIntermediateDirectories: true)
  isNil(AutopilotWorktrees.lastWorked(path: plain, seconds: 10))
  let closed = nested + "/closed"
  try fm.createDirectory(atPath: closed, withIntermediateDirectories: true)
  try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: closed)
  let unreadable = AutopilotWorktrees.lastWorked(path: nested, seconds: 10)
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed)
  isNil(unreadable)
  check(AutopilotWorktrees.lastWorked(path: nested, seconds: 10) != nil, "readable again")
  // A copy Git can't date stays unknown, and isn't looked at again on every tick.
  var failed = 0
  let blind = AutopilotAges { _, _, _ in
    failed += 1
    return nil
  }
  equal(stale(blind.fill(records, now: later)), unknown, "no date, no age")
  _ = blind.fill(records, now: later)
  equal(failed, paths.count, "a look that found nothing is remembered too")

  // The check for programs using a copy sees BZ too, so a copy being burned isn't looked into,
  // and a burn that starts during a look stops it; such a look isn't remembered.
  let junk = AutopilotJunkCache()
  var looks = 0
  let shared = AutopilotAges(walks: junk.walks) { path, seconds, stop in
    looks += 1
    return AutopilotWorktrees.lastWorked(path: path, seconds: seconds, stop: stop)
  }
  let held = junk.clearing(edited) { shared.fill([records[1]], now: later) }
  isNil(held[0].lastFileChange)
  equal(looks, 0, "a copy being burned isn't looked into")
  let burned = DispatchSemaphore(value: 0)
  var interrupted = false
  let cut = AutopilotAges(walks: junk.walks) { path, _, stop in
    guard !interrupted else { return later }
    interrupted = true
    Thread.detachNewThread { junk.clearing(path) { burned.signal() } }
    let limit = Date().addingTimeInterval(5)
    while !stop() && Date() < limit { usleep(1000) }
    return later
  }
  isNil(cut.fill([records[1]], now: later)[0].lastFileChange)
  equal(burned.wait(timeout: .now() + 10), .success, "the burn went ahead once the look left")
  equal(cut.fill([records[1]], now: later)[0].lastFileChange, later, "the copy is looked at again")
  check(shared.fill([records[1]], now: later)[0].lastFileChange != nil, "so is a burned-past one")
}

// MARK: Restarts

/// Sizes and ages were kept only in memory, so after every restart, an install included, a copy
/// the inventory never measured counted as 0 bytes and left the catalog until it was sized again,
/// and its age, lessons and questions waited behind that. A restarted Autopilot reads them back.
private func apRestartProof(_ world: APWorld) async throws {
  let fm = FileManager.default
  // The inventory's walk stops at a hard-linked file, so it neither sizes nor dates the copy.
  let copy = try world.addWorktree("restarted", branch: "feature-restarted")
  try apWrite(world.path("restarted-store.txt"), "shared\n")
  try fm.linkItem(atPath: world.path("restarted-store.txt"), toPath: copy + "/linked.txt")
  try Data(count: 120 << 20).write(to: URL(fileURLWithPath: copy + "/big.bin"))
  let record = try apRecord(copy, in: world.main)
  equal(record.allocated, 0, "the inventory never measured it")
  isNil(record.lastFileChange)

  let state = URL(fileURLWithPath: world.path("restart-state"), isDirectory: true)
  let home = world.path("restart-home")
  try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: state, accessCheck: fixtureAccess)
  let before = AutopilotSources.live(monitor: monitor, root: state, home: home)
  let first = before.worktrees([record], [], [:]).0
  let bytes = first.first?.bytes ?? 0
  check(first.count == 1 && bytes >= 120 << 20, "the copy is sized: \(first.map(\.bytes))")
  equal(first.first?.facts["stale"], "today", "and dated")

  // Measuring it again would now find it small, and looking again would find no date.
  try fm.removeItem(atPath: copy + "/big.bin")
  let closed = copy + "/closed"
  try fm.createDirectory(atPath: closed, withIntermediateDirectories: true)
  try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: closed)
  defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed) }
  let after = AutopilotSources.live(monitor: monitor, root: state, home: home)
  let listed = after.worktrees([record], [], [:]).0
  equal(listed.map(\.bytes), [bytes], "a restarted Autopilot lists the copy at its measured size")
  equal(listed.first?.facts["stale"], "today", "and knows its age without looking again")
  await monitor.shutdownWorktrees()

  // A look keeps the rest of its hour across a restart, one that found no date too; a copy whose
  // HEAD or changes moved is looked at again, and a look past its hour isn't kept.
  let root = URL(fileURLWithPath: world.path("ages-state"), isDirectory: true)
  let now = Date()
  let found = now.addingTimeInterval(-3.5 * 86_400)
  var looked: [String] = []
  func restarted() throws -> AutopilotAges {
    AutopilotAges(store: try AutopilotStore(root: root)) { path, _, _ in
      looked.append(path)
      return path.hasSuffix("blind") ? nil : found
    }
  }
  func unwalked(_ name: String) -> WorktreeRecord {
    var record = WorktreeRecord(
      id: "id-" + name, path: world.path(name), repository: world.main + "/.git")
    record.head = "head-" + name
    record.status = "status-" + name
    return record
  }
  var records = [unwalked("dated"), unwalked("blind")]
  _ = try restarted().fill(records + [unwalked("gone")], now: now.addingTimeInterval(-3000))
  equal(looked.count, 3, "each copy is looked at")
  let back = try restarted().fill(records, now: now)
  equal(back.map(\.lastFileChange), [found, nil], "a restart keeps each look for its hour")
  equal(looked.count, 3, "no copy is looked at again, not even one with no date")
  records[0].head = "moved"
  records[1].status = "changed"
  _ = try restarted().fill(records, now: now)
  equal(looked.count, 5, "a copy whose HEAD or changes moved is looked at again")
  _ = try restarted().fill(records, now: now.addingTimeInterval(3601))
  equal(looked.count, 7, "an hour after its look a copy is looked at again")
  equal(try AutopilotStore(root: root).ages().keys.sorted(), ["id-blind", "id-dated"])
}

func autopilotWorktreeProof() async throws {
  apDirectProof()
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent(
    "bz-ap-worktrees-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = WorkspaceSafety.canonical(temporary.path)
  defer { try? fm.removeItem(atPath: base) }
  let world = APWorld(
    base: base, main: base + "/project",
    state: URL(fileURLWithPath: base + "/state", isDirectory: true))
  try apBuild(world)

  var cache: [String: AutopilotDelivery] = [:]
  var items: [String: AutopilotItem] = [:]
  for name in ["merged", "pushed", "localwork", "dirty", "busy", "racing", "lockme"] {
    items[name] = try apItem(world.path(name), world, cache: &cache)
  }
  items["main"] = try apItem(world.main, world, cache: &cache)

  try apFactsProof(world, items)
  try apDeliveryProof(world)
  try apRefusalProof(world, items)
  try apCleanRetire(world, items["merged"]!)
  try apUncheckedRetire(world, items["pushed"]!)
  try apDirtyRetire(world, items["dirty"]!)
  try apBrowserProfileRetire(world)
  try apBigFilesRetire(world)
  try apUnwalkedAgeProof(world)
  try apSubmoduleProof(world)
  try await apRestartProof(world)

  let leftovers = (try? fm.contentsOfDirectory(atPath: world.state.path)) ?? []
  check(leftovers.isEmpty, "scratch space was left behind: \(leftovers)")
}
