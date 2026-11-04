import Foundation

public enum Demo {
  public static func state(now: Date = Date(), calendar: Calendar = .current) -> ViewState {
    var state = ViewState()
    state.processCount = 128
    let today = calendar.startOfDay(for: now)
    addBurn(in: &state.catalog, count: 512, memory: 24_000_000_000, cpu: 15 * 3600,
      date: calendar.date(byAdding: .day, value: -12, to: today)!)
    addBurn(in: &state.catalog, count: 240, memory: 12_000_000_000, cpu: 7.5 * 3600,
      date: calendar.date(byAdding: .day, value: -3, to: today)!)
    addBurn(in: &state.catalog, count: 110, memory: 5_200_000_000, cpu: 3.8 * 3600 - 60,
      date: today)
    recordBurn(in: &state.catalog, now: max(today, now.addingTimeInterval(-120)))
    addWorkspaces(in: &state.catalog, count: 4, disk: 2_100_000_000, date: today)
    addWorkspaces(in: &state.catalog, count: 8, disk: 4_700_000_000, date: calendar.date(byAdding: .day, value: -3, to: today)!)
    addWorkspaces(in: &state.catalog, count: 6, disk: 3_200_000_000, date: calendar.date(byAdding: .day, value: -12, to: today)!)
    let owner = ProcessIdentity(pid: 90000, seconds: 1)
    let o = Observation(
      identity: ProcessIdentity(pid: 90001, seconds: 2), executable: "/example/disposable-helper",
      rss: 48 * 1024 * 1024, time: now, monotonic: 200)
    state.catalog.records[o.identity.key] = Record(o)
    let lease = Lease(
      label: "Finished helper job", owner: owner, members: [Member(o)], allowCleanup: true)
    state.findings = [
      Finding(
        id: lease.id.uuidString, title: lease.label, disposition: .eligible,
        reason: "These helpers remained after their session ended.",
        evidence: [
          "Explicit disposable-helper permission", "Owning session ended four minutes ago",
          "Repeated idle observations; no recent disk activity",
        ],
        uncertainty:
          "Demo data. This preview cannot signal any process. Detached children may escape observation in real workloads.",
        members: [o.identity.key], leaseID: lease.id, rss: o.rss),
      Finding(
        id: "growth", title: "Analysis worker", disposition: .investigate,
        reason: "Memory has kept growing across repeated observations.",
        evidence: ["Resident footprint grew by 320 MiB across six observations"],
        uncertainty:
          "Session ownership is unknown. Growth can be legitimate work; no stop action is available.",
        members: [], leaseID: nil, rss: 768 * 1024 * 1024),
      Finding(
        id: "active", title: "Overnight evaluation", disposition: .protected,
        reason: "The owning session is still running. Its helpers are protected.",
        evidence: ["Launch wrapper is alive", "Exact process identities match"],
        uncertainty: "A long runtime alone does not establish abandonment.", members: [],
        leaseID: nil, rss: 128 * 1024 * 1024),
    ]
    return state
  }

  /// Preview receipts stay in memory and use the same period accounting as real receipts.
  public static func recordBurn(in catalog: inout Catalog, now: Date = Date()) {
    addBurn(in: &catalog, count: 18, memory: 1_200_000_000, cpu: 60, date: now)
  }

  private static func addWorkspaces(in catalog: inout Catalog, count: Int, disk: UInt64, date: Date) {
    for _ in 0..<count {
      let receipt = WorkspaceReceipt(id: UUID(), workspaceID: UUID().uuidString,
        identity: .init(path: "/example/disposable-worktree", common: "/example/repo/.git", gitDirectory: "/example/repo/.git/worktrees/example", device: 0, inode: 0),
        label: "Completed task worktree", head: String(repeating: "0", count: 40), recoveryRef: "refs/burnzombies/worktrees/example",
        date: date, verifiedAt: date, outcome: "verified", diskReclaimedBytes: disk / UInt64(count), detail: "In-memory preview receipt.")
      catalog.workspaceReceipts = (catalog.workspaceReceipts ?? []) + [receipt]
    }
    catalog.lifetimeWorktreesCleaned = (catalog.lifetimeWorktreesCleaned ?? 0) + count
    catalog.lifetimeDiskReclaimedBytes = (catalog.lifetimeDiskReclaimedBytes ?? 0) + disk
  }

  private static func addBurn(in catalog: inout Catalog, count: Int, memory: UInt64, cpu: Double, date: Date) {
    var event = CleanupEvent(leaseID: UUID(), label: "Disposable helpers", date: date,
      targets: [], residentBefore: memory, outcome: "verified", detail: "In-memory preview receipt.")
    event.verifiedCount = count
    event.verificationDate = date
    event.cpuSecondsSavedEstimate = cpu
    event.responseBeforeMS = 2100
    event.responseAfterMS = 1700
    event.responseBeforeSamples = Array(repeating: 2100, count: 7)
    event.responseAfterSamples = Array(repeating: 1700, count: 7)
    catalog.events.append(event)
    catalog.lifetimeActions += 1
    catalog.lifetimeVerified += count
    catalog.lifetimeResidentReleased = (catalog.lifetimeResidentReleased ?? 0) + memory
    catalog.lifetimeCPUSecondsSaved = (catalog.lifetimeCPUSecondsSaved ?? 0) + cpu
  }


  /// Invented Autopilot data for previews and offscreen proofs. Every name, path and number is
  /// made up; nothing here describes a real machine. Counts and bytes are tallied from the entries.
  /// The lessons and the "How I'm doing" lines are not written by hand: the functions the engine
  /// uses work them out from a made-up history of the owner's answers (`learning`), so they read the
  /// way real ones do and agree with each other.
  public static func autopilot(now: Date = Date(), calendar: Calendar = .current)
    -> AutopilotSnapshot
  {
    let today: Date = calendar.startOfDay(for: now)
    /// `hour` o'clock on the day `days` ago, on the calendar's clock.
    func moment(_ days: Int, _ hour: Int) -> Date {
      let day: Date = calendar.date(byAdding: .day, value: -days, to: today) ?? today
      return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    }
    func make(
      _ kind: AutopilotKind, _ key: String, _ name: String, detail: String, path: String? = nil,
      bytes: UInt64, facts: [String: String], pid: Int32? = nil, protectedReason: String? = nil,
      used: Date? = nil, title: String? = nil
    ) -> AutopilotItem {
      let id: String
      switch kind {
      case .process: id = "process:demo-" + key
      case .worktree: id = "worktree:demo-" + key
      case .disk: id = "disk:" + AutopilotItem.hash(path ?? key)
      }
      return AutopilotItem(
        id: id, kind: kind, name: name, detail: detail, path: path, bytes: bytes, facts: facts,
        protectedReason: protectedReason, observedAt: now, pid: pid,
        processKey: kind == .process ? "demo-" + key : nil, lastUsed: used, title: title)
    }
    func entry(
      _ item: AutopilotItem, _ status: AutopilotStatus, _ authority: String?, label: String,
      why: String, receipt: AutopilotReceipt? = nil
    ) -> AutopilotEntry {
      AutopilotEntry(
        item: item, status: status, authority: authority, label: label, why: why,
        consequence: AutopilotPolicy.consequence(item), receipt: receipt)
    }
    /// A spare copy of a project: saved on GitHub with nothing unsaved, named for its task.
    func spareCopy(
      _ key: String, _ repo: String, task: String, bytes: UInt64, saved: String = "pushed",
      stale: String = "day", used: Date
    ) -> AutopilotItem {
      let name: String = repo + "-" + key
      let facts: [String: String] = [
        "place": "patrol6", "repo": repo, "saved": saved, "changes": "none", "stale": stale,
        "thread": "none", "inUse": "no", "size": "medium",
      ]
      return make(
        .worktree, name, name, detail: "A spare copy of \(repo) called \(key).",
        path: "/example/work/" + name, bytes: bytes, facts: facts, used: used, title: task)
    }

    // Leftover programs. Sizes are memory.
    let preview = make(
      .process, "api-preview", "python (api preview server)",
      detail: "A Python program running by itself in the background.", bytes: 412_000_000,
      facts: [
        "program": "python", "family": "python", "orphaned": "yes", "thread": "ended",
        "agent": "claude", "idle": "1d", "listening": "no", "memory": "medium", "repo": "api",
      ], pid: 48211, used: now.addingTimeInterval(-26 * 3600))
    let shots = make(
      .process, "screenshot-browser", "chromium (screenshot job)",
      detail: "A web browser a script opened and never closed.", bytes: 1_200_000_000,
      facts: [
        "program": "chromium", "family": "browser", "orphaned": "yes", "thread": "ended",
        "agent": "codex", "idle": "1h", "listening": "no", "memory": "large",
        "repo": "web-app",
      ], pid: 51840, used: now.addingTimeInterval(-70 * 60))
    let login = make(
      .process, "login-browser", "chromium (login test)",
      detail: "Another web browser left open by a test.", bytes: 940_000_000,
      facts: [
        "program": "chromium", "family": "browser", "orphaned": "yes", "thread": "ended",
        "agent": "codex", "idle": "10m", "listening": "no", "memory": "large", "repo": "api",
      ], pid: 52077, used: now.addingTimeInterval(-14 * 60))
    let helper = make(
      .process, "open-chat-helper", "node (web-app helper)",
      detail: "A program your current Claude chat is using right now.", bytes: 210_000_000,
      facts: [
        "program": "node", "family": "node", "orphaned": "no", "thread": "live",
        "agent": "claude", "idle": "active", "listening": "yes", "memory": "medium",
        "repo": "web-app"
      ], pid: 49902, protectedReason: "A chat you still have open started it.")
    let gradle = make(
      .process, "gradle-helper", "java (Gradle helper)",
      detail: "A Java helper from a build that already finished.", bytes: 780_000_000,
      facts: [
        "program": "java", "family": "java", "orphaned": "yes", "thread": "ended",
        "agent": "none", "idle": "1d", "listening": "no", "memory": "large", "repo": "none",
      ], pid: 47120, used: now.addingTimeInterval(-27 * 3600))

    // Old project copies (worktrees). Sizes are disk. Five were used yesterday; BZ asks about them.
    // Their work is pushed, not merged: the owner's project lessons cover merged copies at any age.
    let loginFix = spareCopy(
      "fix-login-selector", "api", task: "fix login selector", bytes: 1_000_000_000,
      used: moment(1, 17))
    let darkMode = spareCopy(
      "dark-mode-toggle", "web-app", task: "add dark mode toggle", bytes: 700_000_000,
      used: moment(1, 13))
    let footer = spareCopy(
      "tidy-footer", "web-app", task: "tidy the footer", bytes: 500_000_000, used: moment(1, 19))
    let renameSettings = spareCopy(
      "rename-settings", "api", task: "rename settings", bytes: 300_000_000, used: moment(2, 10))
    let searchSpike = spareCopy(
      "search-spike", "web-app", task: "try a faster search", bytes: 253_368_064,
      used: moment(3, 16))
    let askedCopies: [AutopilotItem] = [loginFix, darkMode, footer, renameSettings, searchSpike]
    // Three more BZ burned on its own, a little while ago, because the owner said yes to the like.
    let billing = spareCopy(
      "migrate-billing", "api", task: "migrate billing tables", bytes: 1_200_000_000,
      stale: "week", used: moment(9, 15))
    let onboarding = spareCopy(
      "onboarding-copy", "web-app", task: "update onboarding copy", bytes: 800_000_000,
      stale: "week", used: moment(11, 11))
    let buildTools = spareCopy(
      "bump-build-tools", "api", task: "bump build tools", bytes: 400_000_000, stale: "week",
      used: moment(14, 9))
    let actedCopies: [AutopilotItem] = [billing, onboarding, buildTools]
    let finished = make(
      .worktree, "api-fix-login", "api-fix-login",
      detail: "A spare copy of api called fix-login.", path: "/example/work/api-fix-login",
      bytes: 3_400_000_000,
      facts: [
        "place": "patrol6", "repo": "api", "saved": "merged", "changes": "none",
        "stale": "older", "thread": "none", "inUse": "no", "size": "large",
      ])
    let payments = make(
      .worktree, "web-app-payments", "web-app-payments",
      detail: "A spare copy of web-app with unfinished work.",
      path: "/example/work/web-app-payments", bytes: 1_900_000_000,
      facts: [
        "place": "sibling", "repo": "web-app", "saved": "local", "changes": "large",
        "stale": "week", "thread": "none", "inUse": "no", "size": "large",
      ])
    let oldCopy = make(
      .worktree, "web-app-old-experiment", "web-app-old-experiment",
      detail: "A spare copy of web-app from an old experiment.",
      path: "/example/work/web-app-old-experiment", bytes: 4_100_000_000,
      facts: [
        "place": "sibling", "repo": "web-app", "saved": "merged", "changes": "none",
        "stale": "older", "thread": "none", "inUse": "no", "size": "large",
      ])

    // Junk folders. Sizes are disk.
    let packages = make(
      .disk, "packages", "node_modules",
      detail: "Packages downloaded for a project. They download again when needed.",
      path: "/example/work/api-fix-login/node_modules", bytes: 1_800_000_000,
      facts: ["folder": "node_modules", "home": "stale-worktree", "stale": "older", "size": "large"])
    let orbitBuild = make(
      .disk, "orbit-derived", "Orbit-DerivedData",
      detail: "Files Xcode made while building the Orbit app.",
      path: "/example/Library/Developer/Xcode/DerivedData/Orbit-demo", bytes: 14_600_000_000,
      facts: ["folder": "xcode-derived", "home": "global-cache", "stale": "month", "size": "huge"],
      used: moment(40, 10))
    let atlasBuild = make(
      .disk, "atlas-derived", "Atlas-DerivedData",
      detail: "Files Xcode made while building the Atlas app.",
      path: "/example/Library/Developer/Xcode/DerivedData/Atlas-demo", bytes: 7_200_000_000,
      facts: [
        "folder": "xcode-derived", "home": "global-cache", "stale": "older", "size": "large",
      ],
      used: moment(120, 10))
    let python = make(
      .disk, "python", ".venv",
      detail: "The Python tools the api project runs with.",
      path: "/example/work/api/.venv", bytes: 640_000_000,
      facts: ["folder": "python-env", "home": "repo", "stale": "month", "size": "medium"])
    let leftovers = make(
      .disk, "build-output", "build",
      detail: "Files made while building an old copy.",
      path: "/example/work/api-search-ui/build", bytes: 380_000_000,
      facts: [
        "folder": "build-output", "home": "stale-worktree", "stale": "older", "size": "medium",
      ])

    // The questions BZ asks now: each is about several things, and its card names three of them.
    let questions: [AutopilotQuestion] = [
      AutopilotPolicy.question(
        .worktree, match: ["stale": ["day"]], covering: askedCopies, now: now),
      AutopilotPolicy.question(
        .process, match: ["family": ["browser"], "idle": ["10m"]], covering: [shots, login],
        now: now),
      AutopilotPolicy.question(
        .disk, match: ["folder": ["xcode-derived"], "stale": ["month"]],
        covering: [orbitBuild, atlasBuild], now: now),
    ]

    // What the owner taught earlier and what BZ did on its own since.
    let learned: DemoLearning = learning(
      now: now, calendar: calendar, acted: actedCopies, asking: questions)
    let ruleAuthority: String = "rule:" + learned.actRuleID

    // Receipts for what was already burned. Old copies can be restored; the failed one cannot.
    let gradleReceipt = AutopilotReceipt(
      itemID: gradle.id, kind: .process, name: gradle.name,
      authority: "starter:starter-leftover-programs", outcome: "burned",
      detail: "Stopped it and checked: it's gone.", bytes: gradle.bytes,
      date: now.addingTimeInterval(-25 * 60))
    let oldCopyReceipt = AutopilotReceipt(
      itemID: oldCopy.id, kind: .worktree, name: oldCopy.name,
      authority: "starter:starter-finished-copies", outcome: "burned",
      detail: "Saved a backup, removed the folder and checked it's gone.", bytes: oldCopy.bytes,
      date: now.addingTimeInterval(-2 * 3600),
      restore: AutopilotRestore(
        repository: "/example/work/web-app/.git",
        path: "/example/work/web-app-old-experiment",
        ref: "refs/burnzombies/retired/demo-old-experiment",
        head: "3f2a9c1d7b5e4a60918c2d4f6e8b0a1c3d5e7f90", branch: "old-experiment",
        snapshot: false))
    let leftoversReceipt = AutopilotReceipt(
      itemID: leftovers.id, kind: .disk, name: leftovers.name,
      authority: "rule:" + learned.buildsRuleID, outcome: "failed",
      detail: "Something was still using it, so I left it alone.",
      date: now.addingTimeInterval(-9 * 60))
    let heads: [String] = [
      "7d1e5c3a9b2f4086d1c7e3a5b9f20486c1d3e5a7", "a4c6e8021b3d5f7a9c0e2468ace0b1d3f5a79c2e",
      "5b9d1f3a7c2e4086a1c3e5b7d9f02468ace4b6d8",
    ]
    func actedReceipt(_ item: AutopilotItem, _ index: Int) -> AutopilotReceipt {
      let repo: String = item.facts["repo"] ?? "api"
      let git: String = "/example/work/" + repo + "/.git"
      let path: String = item.path ?? "/example/work/" + item.name
      let ref: String = "refs/burnzombies/retired/demo-" + item.name
      let at: Date = learned.tell.date.addingTimeInterval(Double(index + 2) * 60)
      let restore = AutopilotRestore(
        repository: git, path: path, ref: ref, head: heads[index], branch: item.title,
        snapshot: false)
      return AutopilotReceipt(
        itemID: item.id, kind: .worktree, name: item.name, authority: ruleAuthority,
        outcome: "burned", detail: "Saved a backup, removed the folder and checked it's gone.",
        bytes: item.bytes, date: at, restore: restore)
    }
    var actedReceipts: [AutopilotReceipt] = []
    for (index, item) in actedCopies.enumerated() {
      actedReceipts.append(actedReceipt(item, index))
    }

    let entries: [AutopilotEntry] = [
      entry(
        preview, .burn, "starter:starter-leftover-programs", label: "Forgotten preview server",
        why: "Its chat ended over a day ago and it hasn't done anything since."),
      entry(
        shots, .unsure, nil, label: "Robot browser from a screenshot job",
        why:
          "The script that opened it is finished, but it only sat idle for about an hour, so I want to double-check."
      ),
      entry(
        login, .unsure, nil, label: "Robot browser from a login test",
        why: "The test is finished and nobody is using it, but it's quite new so I'm not sure yet."),
      entry(
        helper, .protected, nil, label: "Helper for your open chat",
        why: "A chat you still have open started it. I never touch those."),
      entry(
        gradle, .burned, "starter:starter-leftover-programs", label: "Leftover Java helper",
        why: "Its build finished long ago and it sat idle for a day, so I burned it.",
        receipt: gradleReceipt),
      entry(
        finished, .burn, "rule:" + learned.copiesRuleID, label: "Finished copy of api",
        why:
          "You told me to burn copies like this: everything in it is saved and nobody touched it for months."
      ),
      entry(
        loginFix, .unsure, nil, label: "Old copy of api (fix login selector)",
        why:
          "Its work is on GitHub and nothing is unsaved, but you used it yesterday, so I'm asking."
      ),
      entry(
        darkMode, .unsure, nil, label: "Old copy of web-app (add dark mode toggle)",
        why:
          "Its work is on GitHub and nothing is unsaved, but you used it yesterday, so I'm asking."
      ),
      entry(
        footer, .unsure, nil, label: "Old copy of web-app (tidy the footer)",
        why:
          "Its work is on GitHub and nothing is unsaved, but you used it yesterday, so I'm asking."
      ),
      entry(
        renameSettings, .unsure, nil, label: "Old copy of api (rename settings)",
        why:
          "Its work is on GitHub and nothing is unsaved, but you used it two days ago, so I'm asking."
      ),
      entry(
        searchSpike, .unsure, nil, label: "Old copy of web-app (try a faster search)",
        why:
          "Its work is on GitHub and nothing is unsaved, but you used it a few days ago, so I'm asking."
      ),
      entry(
        payments, .keep, "operator", label: "Payments experiment",
        why: "You asked me to keep this one."),
      entry(
        oldCopy, .burned, "starter:starter-finished-copies", label: "Old experiment of web-app",
        why: "Everything in it was already merged and it hadn't changed for months.",
        receipt: oldCopyReceipt),
      entry(
        billing, .burned, ruleAuthority, label: "Old copy of api (migrate billing tables)",
        why: "I burned this on my own, because you said yes to copies like it.",
        receipt: actedReceipts[0]),
      entry(
        onboarding, .burned, ruleAuthority, label: "Old copy of web-app (update onboarding copy)",
        why: "I burned this on my own, because you said yes to copies like it.",
        receipt: actedReceipts[1]),
      entry(
        buildTools, .burned, ruleAuthority, label: "Old copy of api (bump build tools)",
        why: "I burned this on my own, because you said yes to copies like it.",
        receipt: actedReceipts[2]),
      entry(
        packages, .burn, "rule:" + learned.modulesRuleID,
        label: "Downloaded packages in api-fix-login",
        why: "You told me to delete downloaded packages like these, and tools rebuild them."),
      entry(
        orbitBuild, .unsure, nil, label: "Xcode build leftovers (Orbit)",
        why: "Xcode rebuilds these on its own, but they're shared across your Mac, so I want to ask first."
      ),
      entry(
        atlasBuild, .unsure, nil, label: "Xcode build leftovers (Atlas)",
        why: "Nobody has used these in over a month, but they're shared across your Mac."),
      entry(
        python, .keep, "operator", label: "Python tools for api",
        why: "You asked me to keep this one."),
      entry(
        leftovers, .failed, "rule:" + learned.buildsRuleID,
        label: "Build leftovers in api-search-ui",
        why: "You told me to delete build leftovers like these, but something was still using it.",
        receipt: leftoversReceipt),
    ]

    var sweep = AutopilotSweepState()
    sweep.enabled = true
    sweep.intervalMinutes = 15
    sweep.lastTick = now.addingTimeInterval(-3 * 60)
    sweep.lastAISweep = now.addingTimeInterval(-47 * 60)
    sweep.append("Burned 3 old project copies on my own.", date: learned.tell.date)
    sweep.append("Burned 1 leftover program.", date: now.addingTimeInterval(-25 * 60))
    sweep.append("Could not burn 1 junk folder; something was using it.", date: now.addingTimeInterval(-9 * 60))

    // Newest first, the way the engine hands them over.
    var receipts: [AutopilotReceipt] = [leftoversReceipt, gradleReceipt]
    receipts.append(contentsOf: actedReceipts.reversed())
    receipts.append(oldCopyReceipt)
    // Copies burned over the app's life: what each lesson made, plus a few starter and manual burns.
    var impact = AutopilotImpact()
    impact.worktrees = learned.copiesBurned + 5

    var snapshot = AutopilotSnapshot()
    snapshot.entries = entries
    snapshot.questions = questions
    snapshot.rules = learned.memory.rules + AutopilotPolicy.starterRules
    snapshot.lessons = AutopilotPolicy.lessonGroups(learned.memory)
    snapshot.progress = AutopilotPolicy.progress(
      learned.memory, receipts: receipts, impact: impact, now: now)
    snapshot.tells = learned.memory.tells.filter { !$0.isClosed }
    snapshot.actsOnItsOwn = learned.memory.actsOnItsOwn
    snapshot.answers = learned.memory.answers
    snapshot.trainingProgress = AutopilotPolicy.trainingProgress(learned.memory)
    snapshot.coverage = AutopilotPolicy.coverage(entries)
    for entry in entries {
      snapshot.counts[entry.status.rawValue, default: 0] += 1
      snapshot.bytes[entry.status.rawValue, default: 0] += entry.item.bytes
    }
    snapshot.sweep = sweep
    snapshot.receipts = receipts
    snapshot.observedAt = now
    return snapshot
  }

  /// What the made-up owner taught, and what BZ did on its own since.
  private struct DemoLearning {
    var memory: AutopilotMemory
    /// The tell BZ made when it acted, and the lesson that act taught.
    var tell: AutopilotTell
    var actRuleID: String
    /// The lessons some of the demo's things are decided by.
    var copiesRuleID: String
    var modulesRuleID: String
    var buildsRuleID: String
    /// Copies every lesson burned, together.
    var copiesBurned: Int
  }

  /// A made-up history, run through the engine's own answer path (`lesson(for:)` and `learn`), so
  /// the lessons merge and read as they do for a real owner: 13 answers over the last weeks, then
  /// one call BZ made on its own that the owner hasn't judged yet. Each lesson has burned things,
  /// as a tally.
  private static func learning(
    now: Date, calendar: Calendar, acted: [AutopilotItem], asking: [AutopilotQuestion]
  ) -> DemoLearning {
    var memory = AutopilotMemory()
    let today: Date = calendar.startOfDay(for: now)

    /// An answer from `days` ago, and the lesson it taught.
    func answered(
      _ kind: AutopilotKind, _ match: [String: [String]], _ answer: AutopilotAnswer, _ days: Int
    ) -> AutopilotQuestion {
      let day: Date = calendar.date(byAdding: .day, value: -days, to: today) ?? today
      let at: Date = day.addingTimeInterval(14 * 3600)
      var question = AutopilotQuestion(
        kind: kind, match: match, question: AutopilotPolicy.wording(kind: kind, match: match),
        why: "", examples: [], count: 4, bytes: 3_000_000_000, asked: at.addingTimeInterval(-90))
      question.answer = answer
      question.answered = at
      memory.questions.append(question)
      let verdict: AutopilotVerdict = answer == .yes ? .burn : .keep
      let lesson: AutopilotRule = AutopilotPolicy.lesson(
        for: question, verdict: verdict, created: at)
      AutopilotPolicy.learn(lesson, into: &memory.rules)
      return question
    }
    /// What the lesson that holds this answer has burned.
    func burned(_ question: AutopilotQuestion, _ count: Int, _ bytes: UInt64) -> String {
      let rule: AutopilotRule? = memory.rules.first {
        AutopilotPolicy.questionIDs($0).contains(question.id)
      }
      let id: String = rule?.id ?? question.id
      memory.tallies[id] = AutopilotTally(count: count, bytes: bytes)
      return id
    }

    // Copies untouched for a month are done once their work is on GitHub and nothing is unsaved.
    _ = answered(
      .worktree, ["saved": ["merged"], "changes": ["none"], "stale": ["month"]], .yes, 41)
    let month = answered(
      .worktree, ["saved": ["pushed"], "changes": ["none"], "stale": ["month"]], .yes, 36)
    _ = answered(
      .worktree, ["saved": ["merged"], "changes": ["none"], "stale": ["older"]], .yes, 33)
    _ = answered(
      .worktree, ["saved": ["pushed"], "changes": ["none"], "stale": ["older"]], .yes, 30)
    // Rebuildable folders untouched since yesterday can go.
    let caches = answered(.disk, ["folder": ["package-cache"], "stale": ["day"]], .yes, 28)
    let modules = answered(.disk, ["folder": ["node_modules"], "stale": ["day"]], .yes, 27)
    let builds = answered(.disk, ["folder": ["build-output"], "stale": ["day"]], .yes, 26)
    // Merged copies of some projects are done at any age once no chat uses them. Two answers name
    // four projects between them, api and web-app twice, so those two come first in the sentence.
    let withDocs: [String] = ["api", "web-app", "docs"]
    let withMobile: [String] = ["api", "web-app", "mobile"]
    let projectA = answered(
      .worktree, ["repo": withDocs, "saved": ["merged"], "thread": ["ended"]], .yes, 22)
    let projectB = answered(
      .worktree, ["repo": withMobile, "saved": ["merged"], "thread": ["none"]], .yes, 21)
    // Leftover programs can stop once idle, and busy Java helpers serving a port stay.
    let node = answered(.process, ["family": ["node"], "idle": ["10m"]], .yes, 19)
    let java = answered(.process, ["family": ["java"], "idle": ["1h"]], .yes, 18)
    _ = answered(
      .process, ["family": ["node"], "idle": ["1h"], "orphaned": ["yes"]], .yes, 17)
    _ = answered(
      .process, ["family": ["java"], "idle": ["10m"], "listening": ["yes"]], .no, 15)

    // What each lesson has burned.
    let copiesID: String = burned(month, 17, 38_600_000_000)
    _ = burned(projectA, 2, 3_900_000_000)
    _ = burned(projectB, 2, 4_000_000_000)
    _ = burned(caches, 14, 21_600_000_000)
    let modulesID: String = burned(modules, 22, 18_900_000_000)
    let buildsID: String = burned(builds, 12, 6_200_000_000)
    _ = burned(node, 21, 5_200_000_000)
    _ = burned(java, 11, 9_800_000_000)

    // BZ guessed nine of the owner's last ten answers right.
    let latest: [AutopilotQuestion] = Array(memory.questions.suffix(10))
    for (index, question) in latest.enumerated() {
      let said: AutopilotAnswer = question.answer ?? .yes
      let missed: Bool = index == 3
      let miss: AutopilotAnswer = said == .yes ? .no : .yes
      memory.scores.append(
        AutopilotScore(
          questionID: question.id, subject: AutopilotPolicy.subject(question.kind, question.match),
          guess: missed ? miss : said, answer: said, right: !missed,
          date: question.answered ?? now))
    }

    // BZ was sure of copies untouched for a week, so it burned three on its own and told the owner.
    let tellDate: Date = now.addingTimeInterval(-40 * 60)
    let tellID: String = "demo-tell"
    let owned: Int = memory.questions.filter { $0.kind == .worktree && $0.answer == .yes }.count
    let guess = AutopilotGuess(
      answer: .yes, sure: true, why: AutopilotPolicy.reason(saidYes: owned, risks: []),
      source: "native")
    let bytes: UInt64 = acted.reduce(UInt64(0)) { $0 + $1.bytes }
    var call = AutopilotQuestion(
      kind: .worktree, match: ["stale": ["week"]], question: "", why: "", examples: [],
      count: acted.count, bytes: bytes, asked: tellDate)
    call.id += ":" + tellID
    call.rows = AutopilotPolicy.rows(of: acted)
    call.guess = guess
    call.answer = .yes
    call.answered = tellDate
    call.answeredBy = "bz"
    memory.questions.append(call)
    let approved: Set<String> = AutopilotPolicy.approvedRisks(
      "worktree:", memory, besides: call.id)
    let taught: AutopilotRule = AutopilotPolicy.actLesson(
      for: call, approved: approved, created: tellDate, tellID: tellID)
    AutopilotPolicy.learn(taught, into: &memory.rules)
    memory.tallies[taught.id] = AutopilotTally(count: acted.count, bytes: bytes)
    let tell = AutopilotTell(
      id: tellID, questionID: call.id, ruleID: taught.id, kind: .worktree, count: acted.count,
      bytes: bytes, rows: call.rows ?? [], why: guess.why, date: tellDate)
    memory.tells.append(tell)
    // The questions BZ is asking now were shown this week.
    memory.questions.append(contentsOf: asking)

    var copiesBurned: Int = 0
    for rule in memory.rules where rule.kind == .worktree {
      copiesBurned += memory.tallies[rule.id]?.count ?? 0
    }
    return DemoLearning(
      memory: memory, tell: tell, actRuleID: taught.id, copiesRuleID: copiesID,
      modulesRuleID: modulesID, buildsRuleID: buildsID, copiesBurned: copiesBurned)
  }
}
