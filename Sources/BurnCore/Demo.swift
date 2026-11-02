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
  public static func autopilot(now: Date = Date()) -> AutopilotSnapshot {
    func make(
      _ kind: AutopilotKind, _ key: String, _ name: String, detail: String, path: String? = nil,
      bytes: UInt64, facts: [String: String], pid: Int32? = nil, protectedReason: String? = nil
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
        processKey: kind == .process ? "demo-" + key : nil)
    }
    func entry(
      _ item: AutopilotItem, _ status: AutopilotStatus, _ authority: String?, label: String,
      why: String, receipt: AutopilotReceipt? = nil
    ) -> AutopilotEntry {
      AutopilotEntry(
        item: item, status: status, authority: authority, label: label, why: why,
        consequence: AutopilotPolicy.consequence(item), receipt: receipt)
    }

    // Two things the operator taught earlier.
    let keepLocal = AutopilotRule(
      kind: .worktree, match: ["saved": ["local"]], verdict: .keep, source: .`operator`,
      title: "Keep: Old copies with work that only lives on this Mac",
      created: now.addingTimeInterval(-3 * 86400))
    let burnBuild = AutopilotRule(
      kind: .disk, match: ["folder": ["build-output"], "home": ["stale-worktree"]],
      verdict: .burn, source: .`operator`,
      title: "Burn: Build leftovers inside old copies of your projects",
      created: now.addingTimeInterval(-2 * 86400))

    // Leftover programs. Sizes are memory.
    let preview = make(
      .process, "atlas-preview", "node (atlas preview server)",
      detail: "A Node program running by itself in the background.", bytes: 412_000_000,
      facts: [
        "program": "node", "family": "node", "orphaned": "yes", "thread": "ended",
        "agent": "claude", "idle": "1d", "listening": "no", "memory": "medium", "repo": "atlas",
      ], pid: 48211)
    let shots = make(
      .process, "screenshot-browser", "chromium (screenshot job)",
      detail: "A web browser a script opened and never closed.", bytes: 1_200_000_000,
      facts: [
        "program": "chromium", "family": "browser", "orphaned": "yes", "thread": "ended",
        "agent": "codex", "idle": "1h", "listening": "no", "memory": "large",
        "repo": "orbit-web",
      ], pid: 51840)
    let login = make(
      .process, "login-browser", "chromium (login test)",
      detail: "Another web browser left open by a test.", bytes: 940_000_000,
      facts: [
        "program": "chromium", "family": "browser", "orphaned": "yes", "thread": "ended",
        "agent": "codex", "idle": "10m", "listening": "no", "memory": "large", "repo": "atlas",
      ], pid: 52077)
    let helper = make(
      .process, "open-chat-helper", "node (orbit-web helper)",
      detail: "A program your current Claude chat is using right now.", bytes: 210_000_000,
      facts: [
        "program": "node", "family": "node", "orphaned": "no", "thread": "live",
        "agent": "claude", "idle": "active", "listening": "yes", "memory": "medium",
        "repo": "orbit-web",
      ], pid: 49902, protectedReason: "A chat you still have open started it.")
    let gradle = make(
      .process, "gradle-helper", "java (Gradle helper)",
      detail: "A Java helper from a build that already finished.", bytes: 780_000_000,
      facts: [
        "program": "java", "family": "java", "orphaned": "yes", "thread": "ended",
        "agent": "none", "idle": "1d", "listening": "no", "memory": "large", "repo": "none",
      ], pid: 47120)

    // Old project copies (worktrees). Sizes are disk.
    let finished = make(
      .worktree, "atlas-fix-login", "atlas-fix-login",
      detail: "A spare copy of atlas called fix-login.", path: "/example/work/atlas-fix-login",
      bytes: 3_400_000_000,
      facts: [
        "place": "patrol6", "repo": "atlas", "saved": "merged", "changes": "none",
        "stale": "older", "thread": "none", "inUse": "no", "size": "large",
      ])
    let redesign = make(
      .worktree, "orbit-web-redesign", "orbit-web-redesign",
      detail: "A spare copy of orbit-web called redesign.",
      path: "/example/work/orbit-web-redesign", bytes: 5_800_000_000,
      facts: [
        "place": "sibling", "repo": "orbit-web", "saved": "pushed", "changes": "small",
        "stale": "month", "thread": "none", "inUse": "no", "size": "large",
      ])
    let search = make(
      .worktree, "atlas-search-ui", "atlas-search-ui",
      detail: "A spare copy of atlas called search-ui.", path: "/example/work/atlas-search-ui",
      bytes: 3_100_000_000,
      facts: [
        "place": "other", "repo": "atlas", "saved": "pushed", "changes": "none",
        "stale": "month", "thread": "ended", "inUse": "no", "size": "medium",
      ])
    let payments = make(
      .worktree, "orbit-web-payments", "orbit-web-payments",
      detail: "A spare copy of orbit-web with unfinished work.",
      path: "/example/work/orbit-web-payments", bytes: 1_900_000_000,
      facts: [
        "place": "sibling", "repo": "orbit-web", "saved": "local", "changes": "large",
        "stale": "week", "thread": "none", "inUse": "no", "size": "large",
      ])
    let oldCopy = make(
      .worktree, "orbit-web-old-experiment", "orbit-web-old-experiment",
      detail: "A spare copy of orbit-web from an old experiment.",
      path: "/example/work/orbit-web-old-experiment", bytes: 4_100_000_000,
      facts: [
        "place": "sibling", "repo": "orbit-web", "saved": "merged", "changes": "none",
        "stale": "older", "thread": "none", "inUse": "no", "size": "large",
      ])

    // Junk folders. Sizes are disk.
    let packages = make(
      .disk, "packages", "node_modules",
      detail: "Packages downloaded for a project. They download again when needed.",
      path: "/example/work/atlas-fix-login/node_modules", bytes: 1_800_000_000,
      facts: ["folder": "node_modules", "home": "stale-worktree", "stale": "older", "size": "large"])
    let orbitBuild = make(
      .disk, "orbit-derived", "Orbit-DerivedData",
      detail: "Files Xcode made while building the Orbit app.",
      path: "/example/Library/Developer/Xcode/DerivedData/Orbit-demo", bytes: 14_600_000_000,
      facts: ["folder": "xcode-derived", "home": "global-cache", "stale": "month", "size": "huge"])
    let atlasBuild = make(
      .disk, "atlas-derived", "Atlas-DerivedData",
      detail: "Files Xcode made while building the Atlas app.",
      path: "/example/Library/Developer/Xcode/DerivedData/Atlas-demo", bytes: 7_200_000_000,
      facts: ["folder": "xcode-derived", "home": "global-cache", "stale": "older", "size": "large"])
    let python = make(
      .disk, "python", ".venv",
      detail: "The Python tools the atlas project runs with.",
      path: "/example/work/atlas/.venv", bytes: 640_000_000,
      facts: ["folder": "python-env", "home": "repo", "stale": "month", "size": "medium"])
    let leftovers = make(
      .disk, "build-output", "build",
      detail: "Files made while building an old copy.",
      path: "/example/work/atlas-search-ui/build", bytes: 380_000_000,
      facts: [
        "folder": "build-output", "home": "stale-worktree", "stale": "older", "size": "medium",
      ])

    // Receipts for the two things already burned. The old copy can be restored.
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
        repository: "/example/work/orbit-web/.git",
        path: "/example/work/orbit-web-old-experiment",
        ref: "refs/burnzombies/retired/demo-old-experiment",
        head: "3f2a9c1d7b5e4a60918c2d4f6e8b0a1c3d5e7f90", branch: "old-experiment",
        snapshot: false))
    let leftoversReceipt = AutopilotReceipt(
      itemID: leftovers.id, kind: .disk, name: leftovers.name,
      authority: "rule:" + burnBuild.id, outcome: "failed",
      detail: "Something was still using it, so I left it alone.",
      date: now.addingTimeInterval(-9 * 60))

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
        finished, .burn, "starter:starter-finished-copies", label: "Finished copy of atlas",
        why:
          "Everything in it is already saved in the main project and nobody touched it for months."
      ),
      entry(
        redesign, .unsure, nil, label: "Old copy of orbit-web",
        why: "Its work is saved on GitHub, but a few small edits only exist here."),
      entry(
        search, .unsure, nil, label: "Old copy of atlas",
        why: "Its work is saved on GitHub and it hasn't changed in a month, but its chat only just ended."
      ),
      entry(
        payments, .keep, "rule:" + keepLocal.id, label: "Payments experiment",
        why: "You told me to keep copies that have work only on this Mac."),
      entry(
        oldCopy, .burned, "starter:starter-finished-copies", label: "Old experiment of orbit-web",
        why: "Everything in it was already merged and it hadn't changed for months.",
        receipt: oldCopyReceipt),
      entry(
        packages, .burn, "starter:starter-rebuildable-junk",
        label: "Downloaded packages in atlas-fix-login",
        why: "It sits inside an old copy nobody uses, and tools rebuild it on their own."),
      entry(
        orbitBuild, .unsure, nil, label: "Xcode build leftovers (Orbit)",
        why: "Xcode rebuilds these on its own, but they're shared across your Mac, so I want to ask first."
      ),
      entry(
        atlasBuild, .unsure, nil, label: "Xcode build leftovers (Atlas)",
        why: "Nobody has used these in over a month, but they're shared across your Mac."),
      entry(
        python, .keep, "operator", label: "Python tools for atlas",
        why: "You asked me to keep this one."),
      entry(
        leftovers, .failed, "rule:" + burnBuild.id, label: "Build leftovers in atlas-search-ui",
        why: "You told me to burn build leftovers inside old copies, but something was still using it.",
        receipt: leftoversReceipt),
    ]

    func question(
      _ kind: AutopilotKind, _ match: [String: [String]], _ items: [AutopilotItem]
    ) -> AutopilotQuestion {
      let bytes = items.reduce(UInt64(0)) { $0 + $1.bytes }
      return AutopilotQuestion(
        kind: kind, match: match, question: AutopilotPolicy.wording(kind: kind, match: match),
        why: "I found \(items.count) like this, using \(AutopilotPolicy.format(bytes)).",
        examples: Array(items.sorted { $0.bytes > $1.bytes }.prefix(3).map(\.name)),
        count: items.count, bytes: bytes, asked: now)
    }
    let questions = [
      question(.worktree, ["saved": ["pushed"]], [redesign, search]),
      question(.process, ["family": ["browser"], "thread": ["ended"]], [shots, login]),
      question(
        .disk, ["folder": ["xcode-derived"], "home": ["global-cache"]], [orbitBuild, atlasBuild]),
    ]

    var sweep = AutopilotSweepState()
    sweep.enabled = true
    sweep.intervalMinutes = 15
    sweep.lastTick = now.addingTimeInterval(-3 * 60)
    sweep.lastAISweep = now.addingTimeInterval(-47 * 60)
    sweep.append("Burned 1 leftover program.", date: now.addingTimeInterval(-25 * 60))
    sweep.append("Could not burn 1 junk folder; something was using it.", date: now.addingTimeInterval(-9 * 60))

    var snapshot = AutopilotSnapshot()
    snapshot.entries = entries
    snapshot.questions = questions
    snapshot.rules = [keepLocal, burnBuild] + AutopilotPolicy.starterRules
    snapshot.trainingProgress = 0.42
    snapshot.answers = 5
    snapshot.coverage = AutopilotPolicy.coverage(entries)
    for entry in entries {
      snapshot.counts[entry.status.rawValue, default: 0] += 1
      snapshot.bytes[entry.status.rawValue, default: 0] += entry.item.bytes
    }
    snapshot.sweep = sweep
    snapshot.receipts = [oldCopyReceipt, leftoversReceipt, gradleReceipt]
    snapshot.observedAt = now
    return snapshot
  }
}
