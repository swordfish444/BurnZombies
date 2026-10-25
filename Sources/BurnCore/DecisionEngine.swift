import Foundation

public struct Policy: Sendable {
  public var grace: TimeInterval = 180
  public var quietSpan: TimeInterval = 120
  public var freshness: TimeInterval = 75
  public init() {}
}

public enum DecisionEngine {
  public static func hardProtection(_ o: Observation, uid: UInt32, ownPID: Int32) -> String? {
    if o.identity.pid <= 1 || o.identity.pid == ownPID || o.uid != uid {
      return "System or different-user process"
    }
    if o.executable.isEmpty || !o.metricsValid { return "Incomplete process visibility" }
    let p = o.executable.lowercased()
    if p.contains(".app/") || p.hasPrefix("/system/") || p.hasPrefix("/usr/libexec/")
      || p.hasPrefix("/usr/sbin/")
    {
      return "Application or operating-system service"
    }
    if [
      "adb", "fastboot", "ssh", "sshd", "gpg-agent", "security", "op", "ffmpeg", "rsync", "rclone",
      "launchd", "codex", "claude", "gemini", "aider", "opencode",
    ].contains(o.name.lowercased())
      || [
        "chrome", "chromium", "firefox", "webkit", "safari", "record", "upload", "camera",
        "credential",
      ].contains(where: { p.contains($0) })
    {
      return "Agent, browser, device, transfer, recording, or credential tool"
    }
    return nil
  }
  public static func eligibility(
    _ r: Record, lease: Lease, owner: OwnerState, preferences: Preferences, uid: UInt32,
    ownPID: Int32, now: Date, policy: Policy = Policy()
  ) -> (Bool, [String]) {
    let o = r.latest
    if let reason = hardProtection(o, uid: uid, ownPID: ownPID) { return (false, [reason]) }
    guard !r.protection, !preferences.protectedExecutables.contains(o.executable),
      r.ignoreUntil.map({ $0 <= now }) ?? true
    else { return (false, ["Operator protection or snooze is active"]) }
    guard lease.allowCleanup, !lease.disarmed, lease.members.contains(Member(o)) else {
      return (false, ["No unspent, explicit disposable-helper permission for this identity"])
    }
    guard owner == .gone else {
      return (
        false,
        [owner == .alive ? "The owning session is still running" : "Owner visibility is uncertain"]
      )
    }
    guard !o.zombie else { return (false, ["OS zombie: only its parent can reap its exit status"]) }
    guard r.missingSince == nil, now.timeIntervalSince(o.time) >= 0,
      now.timeIntervalSince(o.time) <= policy.freshness
    else { return (false, ["A fresh process observation is required"]) }
    guard let since = r.orphanSince, now.timeIntervalSince(since) >= policy.grace else {
      return (false, ["Waiting for the owner-exit grace period"])
    }
    var samples = r.samples.filter { $0.time >= since }
    if let last = samples.last, o.monotonic > last.monotonic { samples.append(o) }
    guard samples.count >= 3, let first = samples.first, let last = samples.last,
      last.monotonic - first.monotonic >= policy.quietSpan
    else { return (false, ["Waiting for repeated idle observations"]) }
    for (a, b) in zip(samples, samples.dropFirst()) {
      let delta = b.monotonic - a.monotonic
      guard a.metricsValid, b.metricsValid, a.executable == o.executable,
        b.executable == o.executable,
        delta > 0, delta <= policy.freshness, b.cpuNS >= a.cpuNS,
        Double(b.cpuNS - a.cpuNS) / 1e9 / delta < 0.01,
        b.readBytes == a.readBytes, b.writeBytes == a.writeBytes
      else {
        return (
          false, ["Recent activity, identity change, or a sampling gap requires more observation"]
        )
      }
    }
    return (
      true,
      [
        "Explicit permission for these exact process start times",
        "Owning wrapper is confirmed gone",
        "At least \(Int(policy.grace)) seconds of grace and \(Int(policy.quietSpan)) seconds of idle observations",
        "No protected application, active owner, or recent disk activity",
      ]
    )
  }

  public static func findings(
    catalog: Catalog, leases: [Lease], owners: [UUID: OwnerState], uid: UInt32, ownPID: Int32,
    now: Date, policy: Policy = Policy()
  ) -> [Finding] {
    var result = [Finding]()
    var claimed = Set<String>()
    for lease in leases {
      let records = lease.members.compactMap { catalog.records[$0.identity.key] }.filter {
        $0.missingSince == nil
      }
      guard !records.isEmpty else { continue }
      claimed.formUnion(records.map(\.id))
      let decisions = records.map {
        eligibility(
          $0, lease: lease, owner: owners[lease.id] ?? .unknown, preferences: catalog.preferences,
          uid: uid, ownPID: ownPID, now: now, policy: policy)
      }
      let eligible = decisions.allSatisfy(\.0)
      let owner = owners[lease.id] ?? .unknown
      let protected = records.contains {
        $0.protection || catalog.preferences.protectedExecutables.contains($0.latest.executable)
          || hardProtection($0.latest, uid: uid, ownPID: ownPID) != nil
      }
      let reason =
        eligible
        ? "These helpers remained after their session ended."
        : owner == .alive
          ? "The owning session is still running. Its helpers are protected."
          : decisions.first(where: { !$0.0 })?.1.first ?? "Ownership needs review."
      result.append(
        Finding(
          id: lease.id.uuidString, title: lease.label,
          disposition: eligible
            ? .eligible
            : owner == .gone && !lease.disarmed && !protected ? .investigate : .protected,
          reason: reason, evidence: Array(Set(decisions.flatMap(\.1))).sorted(),
          uncertainty:
            "Ownership was observed by the launch wrapper. Unobserved detached descendants and application-level work cannot be inferred. Permission applies only to disposable helpers.",
          members: records.map(\.id), leaseID: lease.id,
          rss: records.reduce(0) { $0 + $1.latest.rss }))
    }
    let available = catalog.records.values.filter {
      $0.missingSince == nil && !claimed.contains($0.id)
        && !($0.ignoreUntil.map { $0 > now } ?? false)
    }
    for r in available {
      let o = r.latest
      var reason: String?
      var evidence = [String]()
      if o.zombie {
        reason = "An exited process is waiting for its parent to reap it."
        evidence = ["Kernel zombie state; sending signals cannot reap it."]
      }
      let s = r.samples
      if s.count >= 6, let first = s.first, o.monotonic - first.monotonic >= 240 {
        let growing = zip(s, s.dropFirst()).filter { $1.rss > $0.rss }.count
        if o.rss > first.rss + 256 * 1024 * 1024 && o.rss > first.rss + first.rss / 2
          && growing >= s.count - 2
        {
          reason = "Memory has kept growing across repeated observations."
          evidence = [
            "Resident footprint grew by more than 256 MiB and 50% over at least four minutes.",
            "This can be legitimate workload growth; it is not proof of a leak.",
          ]
        } else if o.fds > first.fds + 128
          && zip(s, s.dropFirst()).filter({ $1.fds > $0.fds }).count >= s.count - 2
        {
          reason = "Descriptor table capacity has kept growing."
          evidence = [
            "More than 128 extra allocated slots over at least four minutes.",
            "Capacity is a growth signal, not an open-handle count. Inspect descriptors for a current count.",
          ]
        }
      }
      if let reason {
        result.append(
          Finding(
            id: r.id, title: o.name,
            disposition: r.protection
              || catalog.preferences.protectedExecutables.contains(o.executable)
              ? .protected : .investigate, reason: reason, evidence: evidence,
            uncertainty: "Session ownership is unknown. No termination action is available.",
            members: [r.id], leaseID: nil, rss: o.rss))
      }
    }
    // Parent identity, rather than executable alone, distinguishes independent jobs.
    let parentKeys = Dictionary(
      catalog.records.values.filter { $0.missingSince == nil }.map {
        ($0.latest.identity.pid, $0.id)
      }, uniquingKeysWith: { a, _ in a })
    let grouped = Dictionary(grouping: available) { r in
      let parent = parentKeys[r.latest.parent] ?? "unknown:\(r.latest.parent)"
      return "\(parent)|\(r.latest.executable)"
    }
    for (key, group) in grouped where group.count >= 12 {
      result.append(
        Finding(
          id: "family:" + key, title: "\(group.count) related \(group[0].latest.name) helpers",
          disposition: group.allSatisfy {
            $0.protection || catalog.preferences.protectedExecutables.contains($0.latest.executable)
          } ? .protected : .investigate,
          reason: "One observed parent has a large helper family.",
          evidence: [
            "Same executable and observed parent identity; \(group.count) distinct process start times."
          ],
          uncertainty:
            "A pool of workers may be intentional. Shared ancestry is not proof of an abandoned session.",
          members: group.map(\.id), leaseID: nil, rss: group.reduce(0) { $0 + $1.latest.rss }))
    }
    // Churn is review-only. An absent parent is never a positive ownership assertion.
    let recent = catalog.records.values.filter {
      now.timeIntervalSince1970 - Double($0.latest.identity.seconds) < 600
        && now.timeIntervalSince1970 >= Double($0.latest.identity.seconds) && $0.latest.parent > 1
    }
    let churn = Dictionary(grouping: recent) { "\($0.latest.parent)|\($0.latest.executable)" }
    for (key, group) in churn
    where group.count >= 5 && group.filter({ $0.missingSince != nil }).count >= 3 {
      let live = group.filter { $0.missingSince == nil }
      result.append(
        Finding(
          id: "churn:" + key, title: "\(group[0].latest.name) keeps returning",
          disposition: group.allSatisfy {
            $0.protection || catalog.preferences.protectedExecutables.contains($0.latest.executable)
          } ? .protected : .investigate,
          reason: "Repeated starts and exits suggest a restart loop.",
          evidence: [
            "\(group.count) identities observed within 10 minutes; at least three exited."
          ],
          uncertainty:
            "Parent PID correlation is inferred. Short independent jobs can look similar. Inspect the creator; no repeated termination.",
          members: live.map(\.id), leaseID: nil, rss: live.reduce(0) { $0 + $1.latest.rss }))
    }
    return result.sorted { a, b in
      let rank: [Disposition: Int] = [.eligible: 0, .investigate: 1, .protected: 2, .healthy: 3]
      return rank[a.disposition] == rank[b.disposition]
        ? a.rss > b.rss : rank[a.disposition]! < rank[b.disposition]!
    }
  }
}
