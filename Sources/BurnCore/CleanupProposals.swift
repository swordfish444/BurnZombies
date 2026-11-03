import Foundation

extension CleanupProposal {
  public static func owner(_ value: GradleDaemonEvidence) -> Self {
    var p = Self(
      action: .ownerStop, resources: [value.member.identity.key], revision: value.revision,
      title: "Idle Gradle \(value.version) worker · PID \(value.member.identity.pid)",
      detail: value.reason
        + " Gradle will finish a raced build before stopping. Exit must be independently verified.",
      workflow: "gradle-stop-when-idle-v1:"
        + WorkEvidence.hash(value.gradleHome + "|" + value.distribution + "|" + value.version),
      recovery: "No undo. Gradle can create another worker for the next build.",
      bytes: value.residentBytes, ready: value.eligible, now: value.checkedAt)
    p.workflowDetail =
      "Only Gradle \(value.version) in home \(value.gradleHome), distribution \(value.distribution). Requires idle owner state, no active claims or children, fresh complete evidence and independent AI review. Uses StopWhenIdle; never a generic signal."
    return p
  }
  public static func worktree(_ value: WorktreeRecord, ready: Bool) -> Self {
    let scope = value.identity.map { "\($0.device):\($0.commonInode)" }
    return .init(
      action: .worktree, resources: ["worktree:" + value.id],
      revision: value.revision.isEmpty ? "pending" : value.revision,
      // A path's name is read from its spelling: a URL checks the disk, which can reach
      // into a place macOS protects.
      title: (value.path as NSString).lastPathComponent,
      detail: value.ownerManaged
        ? "Managed by its harness. Review the owning chat's worktree: preserve needed ignored files separately, then use that chat's Archive worktree action. BurnZombies cannot archive another chat's checkout."
        : ([
          value.state, "Branch: " + (value.branch ?? "detached"),
          "Last commit: " + (value.lastCommitAt.map { $0.formatted() } ?? "unknown"),
          "Last file change: " + (value.lastFileChange.map { $0.formatted() } ?? "unknown"),
          "\(value.changes) local changes; \(value.ignored) ignored files",
          "Age alone does not establish abandonment. Review branch delivery and owners below.",
        ]
          + value.blockers + value.gaps + ["Observed consumer: " + value.consumer]).joined(
            separator: ". "),
      path: value.path,
      workflow: scope.map { "clean-worktree-v1:" + WorkEvidence.hash(value.repository + "|" + $0) },
      recovery:
        "Approving adopts this exact checkout for management and retires it, including local and ignored files. Encrypted recovery must be restored and verified before removal. Requires this Mac's Keychain key; archive space reduces the net saving.",
      bytes: value.allocated, ready: ready, now: value.observedAt)
  }
  public static func processes(_ values: [Observation]) -> Self {
    .init(
      action: .process, resources: values.map { $0.identity.key },
      revision: WorkEvidence.hash(
        values.map { $0.identity.key + "|" + $0.executable }.sorted().joined(separator: "|")),
      title: values.count == 1
        ? "Completed \(values[0].name) helper · PID \(values[0].identity.pid)"
        : "\(values.count) completed helpers",
      detail:
        "Exact owner completion and no current consumers are required again immediately before a graceful stop.",
      recovery: "No undo. Only the owning workflow can recreate a process.",
      bytes: values.reduce(0) { $0 + $1.rss }, ready: true,
      now: values.map(\.time).min() ?? .distantPast)
  }
  public static func disk(_ value: DiskCandidate) -> Self {
    .init(
      action: .disk, resources: [value.id], revision: value.revision,
      title: (value.path as NSString).lastPathComponent, detail: value.guardReason,
      path: value.path, recovery: "No undo. An exact regeneration and retention rule is required.",
      bytes: value.bytes, ready: value.reviewable, now: value.observedAt ?? .distantPast)
  }
  public static func cache(_ value: BuildKitCache.Plan) -> Self {
    .init(
      action: .cache,
      resources: value.recordIDs.map {
        "cache:"
          + WorkEvidence.hash(
            value.inventory.owner.daemonID + "|" + value.inventory.owner.target.context + "|"
              + value.inventory.owner.target.builder) + ":" + $0
      },
      revision: value.inventory.revision, title: "Unused local build cache",
      detail:
        "The build engine must recheck all selected IDs and live references. Containers, images and volumes are excluded.",
      recovery: "No undo. Future builds may regenerate cache.", bytes: value.cacheBytes,
      ready: true, now: value.inventory.date)
  }
}
