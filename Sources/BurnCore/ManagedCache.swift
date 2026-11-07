import CBurn
import Darwin
import Foundation

/// Owner-mediated BuildKit GC. This never removes host paths, worktrees, images,
/// containers or volumes. An engine reference check replaces no filesystem guard.
/// Two callers, each with its own permission: the old disk cleaner under `DiskPolicy` (off since
/// v0.17.0), which must persist a prepared receipt and consume its plan token BEFORE clean(), and
/// Autopilot under the owner's answer (`AutopilotDockerCache`), whose burns pass `Autopilot.execute`.
/// Neither automatically retries an uncertain attempt on stale evidence.
public struct BuildKitCache {
  /// What stays, whoever asks: the most recently used records, and everything used too recently.
  public struct Retention: Codable, Equatable, Sendable {
    public var keepNewest: Int
    public var minimumAgeDays: Int
    public init(keepNewest: Int, minimumAgeDays: Int) {
      self.keepNewest = keepNewest
      self.minimumAgeDays = minimumAgeDays
    }
    public init(_ policy: DiskPolicy) {
      self.init(keepNewest: policy.keepNewest, minimumAgeDays: policy.minimumAgeDays)
    }
    /// Autopilot's: the old cleaner's defaults, built in. There's nothing to set.
    public static let standard = Retention(keepNewest: 3, minimumAgeDays: 14)
    var revision: String { "retention:\(keepNewest):\(minimumAgeDays)" }
  }
  public struct Target: Codable, Equatable, Sendable {
    public var context: String
    public var builder: String
    public init(context: String, builder: String) {
      self.context = context
      self.builder = builder
    }
  }
  public struct Owner: Codable, Equatable, Sendable {
    public var target: Target
    public var endpoint: String
    public var socketIdentity: String
    public var executableIdentity: String
    public var daemonID: String
    public var node: String
    public var buildkitVersion: String
  }
  public struct Record: Codable, Equatable, Sendable {
    public var id: String
    public var bytes: UInt64
    public var created: Date
    public var lastUsed: Date?
    public var mutable: Bool
    public var reclaimable: Bool
    public var shared: Bool
    public var type: String
    /// What it is built on, when Buildx says. The engine holds a record while another is built on it.
    public var parents: [String]?
  }
  public struct Inventory: Codable, Sendable {
    public var owner: Owner
    public var date: Date
    public var policyRevision: String
    public var records: [Record]
    public var eligibleIDs: [String]
    public var eligibleBytes: UInt64
    public var revision: String {
      let e = JSONEncoder()
      e.outputFormatting = [.sortedKeys]
      // A new unrelated build, shared image cache or scan time is not a new
      // cleanup opportunity. Execution still compares fresh full selected records.
      var stable = self
      stable.date = .distantPast
      let selected = Set(eligibleIDs)
      stable.records = records.filter { selected.contains($0.id) }.sorted { $0.id < $1.id }
      stable.eligibleIDs.sort()
      return WorkEvidence.hash(String(decoding: (try? e.encode(stable)) ?? Data(), as: UTF8.self))
    }
  }
  public struct Plan: Codable, Sendable {
    public var id: UUID
    public var inventory: Inventory
    public var recordIDs: [String]
    public var cacheBytes: UInt64
    public var created: Date
    public var expires: Date
  }
  public struct Receipt: Codable, Sendable {
    public var planID: UUID
    public var date: Date
    public var owner: Owner
    public var requestedIDs: [String]
    public var removedIDs: [String]
    public var outcome: String
    /// Owner cache accounting, NOT physical disk space returned to macOS.
    public var cacheReleasedBytes: UInt64
    /// Deliberately nil: Docker VM allocation/trim requires separate observation.
    public var hostDiskReclaimedBytes: UInt64?
    public var controlsPreserved: Bool?
    public var detail: String
  }
  /// Explicit developer proof only; not exposed as a harness cleanup tool.
  public struct NoMatchContract: Codable, Sendable {
    public var date: Date
    public var context: String
    public var daemonIdentityHash: String
    public var generatedAbsentID: String
    public var beforeRecords: Int
    public var afterRecords: Int?
    public var existingRecordsPreserved: Bool?
    public var controlsPreserved: Bool?
    public var ownerPreserved: Bool?
    public var reportedRemovedIDs: [String]
    public var pruneAttempts = 1
    public var existingRecordsSelected = 0
    public var cacheReleasedBytes: UInt64 = 0
    public var hostDiskReclaimedBytes: UInt64 = 0
    public var outcome: String
    public var detail: String
  }
  public struct Command: Sendable {
    public enum Transport: Sendable { case dockerCLI, localEngineCacheUsage }
    public var arguments: [String]
    public var milliseconds: Int32 = 8000
    public var transport: Transport = .dockerCLI
  }
  public typealias Runner = (Command) throws -> Data
  private let run: Runner
  private let socketIdentity: (String) throws -> String
  private let executableIdentity: () throws -> String

  /// Injection supports isolated engine fixtures; production should use live(store:).
  public init(
    runner: @escaping Runner, socketIdentity: @escaping (String) throws -> String,
    executableIdentity: @escaping () throws -> String
  ) {
    run = runner
    self.socketIdentity = socketIdentity
    self.executableIdentity = executableIdentity
  }
  /// The context the owner's own `docker` uses, and its embedded builder. Decodes only routing
  /// metadata; never copies credentials to a tool or model.
  public static func currentTarget(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> Target {
    struct Config: Decodable { var currentContext: String? }
    let url = home.appendingPathComponent(".docker/config.json")
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= 262144 else {
      throw StoreError.message("Docker context metadata exceeds bound.")
    }
    let context = try JSONDecoder().decode(Config.self, from: data).currentContext ?? "default"
    return .init(context: context, builder: context)
  }
  private static func fail(_ message: String) -> StoreError { .message(message) }
  private static func name(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
      && value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
  }
  private static func recordID(_ value: String) -> Bool {
    (8...128).contains(value.count)
      && value.range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil
  }
  private func command(
    _ target: Target, _ args: [String], milliseconds: Int32 = 8000,
    transport: Command.Transport = .dockerCLI
  ) throws -> Data {
    let data = try run(
      .init(
        arguments: ["--context", target.context] + args, milliseconds: milliseconds,
        transport: transport))
    guard data.count <= 1_048_576 else {
      throw Self.fail("BuildKit evidence exceeded its output bound.")
    }
    return data
  }
  private func owner(_ target: Target) throws -> Owner {
    // Embedded Docker builders inherit exactly one context endpoint. Custom
    // docker-container, multi-node and remote builders are intentionally unsupported.
    guard Self.name(target.context), target.context == target.builder else {
      throw Self.fail("Choose an explicit local Docker context and its matching embedded builder.")
    }
    struct Context: Decodable {
      struct Endpoint: Decodable { var Host: String }
      var Name: String
      var Endpoints: [String: Endpoint]
    }
    let contexts = try JSONDecoder().decode(
      [Context].self, from: command(target, ["context", "inspect", target.context]))
    guard contexts.count == 1, contexts[0].Name == target.context,
      let endpoint = contexts[0].Endpoints["docker"]?.Host, endpoint.hasPrefix("unix:///"),
      !endpoint.contains("\n"), !endpoint.contains("\0")
    else {
      throw Self.fail("Only an existing local Unix-socket Docker owner is supported.")
    }
    let socket = String(endpoint.dropFirst("unix://".count))
    let socketID = try socketIdentity(socket)
    let executableID = try executableIdentity()
    let inspect = String(
      decoding: try command(target, ["buildx", "inspect", target.builder, "--timeout", "5s"]),
      as: UTF8.self)
    func values(_ key: String) -> [String] {
      inspect.split(separator: "\n").compactMap { line in
        // Buildx also prints indented device labels named "Name". Those are
        // not builder nodes and must not change the single-node proof.
        guard line.first?.isWhitespace == false else { return nil }
        let s = line.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix(key + ":")
          ? String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) : nil
      }
    }
    let names = values("Name")
    let endpoints = values("Endpoint")
    let versions = values("BuildKit") + values("BuildKit version")
    let endpointMatches =
      endpoints.count == 1
      && (endpoints[0] == target.context || endpoints[0] == endpoint
        || (endpoints[0].hasPrefix("unix:///")
          && WorkspaceSafety.canonical(String(endpoints[0].dropFirst("unix://".count)))
            == WorkspaceSafety.canonical(socket)))
    guard names.count == 2, names.first == target.builder, Self.name(names[1]),
      values("Driver") == ["docker"], endpointMatches,
      values("Status") == ["running"], versions.count == 1,
      versions[0].range(
        of: "^v?0\\.[0-9]+\\.[0-9]+([-.+][A-Za-z0-9.-]+)?$", options: .regularExpression) != nil,
      values("Error").isEmpty
    else {
      throw Self.fail("Builder must be one running local embedded Docker node with known status.")
    }
    let daemon = try JSONDecoder().decode(
      String.self, from: command(target, ["info", "--format", "{{json .ID}}"])
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !daemon.isEmpty, daemon.count <= 200, !daemon.contains("\n"),
      try socketIdentity(socket) == socketID
    else {
      throw Self.fail("Docker owner identity is unavailable or changed during inspection.")
    }
    return .init(
      target: target, endpoint: endpoint, socketIdentity: socketID,
      executableIdentity: executableID,
      daemonID: daemon, node: names[1], buildkitVersion: versions[0])
  }
  public static func decodeRecords(_ data: Data, exactUsage: Data) throws -> [Record] {
    // Buildx JSON uses humanized sizes/ages in current releases. Only its state
    // flags are authoritative here; Engine API v1.51 provides exact bytes/dates.
    struct Flags: Decodable {
      var ID: String
      var Mutable: Bool
      var Reclaimable: Bool
      var Shared: Bool
      var `Type`: String
      var Parents: [String]?
    }
    struct Usage: Decodable {
      var ID: String
      var Size: UInt64
      var CreatedAt: Date
      var LastUsedAt: Date?
      var InUse: Bool
      var Shared: Bool
      var `Type`: String
    }
    struct Response: Decodable { var BuildCache: [Usage]? }
    guard data.count <= 1_048_576, exactUsage.count <= 1_048_576 else {
      throw fail("BuildKit inventory exceeded its bound.")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = f.date(from: value) { return date }
      f.formatOptions = [.withInternetDateTime]
      guard let date = f.date(from: value) else {
        throw fail("BuildKit returned an invalid timestamp.")
      }
      return date
    }
    let lines = data.split(separator: 10).filter {
      !$0.allSatisfy { $0 == 13 || $0 == 32 || $0 == 9 }
    }
    let usages = try decoder.decode(Response.self, from: exactUsage).BuildCache ?? []
    guard lines.count <= 5000, usages.count <= 5000, lines.count == usages.count else {
      throw fail("BuildKit inventory changed or is incomplete at its record bound.")
    }
    var flags: [String: Flags] = [:]
    for line in lines {
      let r = try decoder.decode(Flags.self, from: Data(line))
      guard recordID(r.ID), flags[r.ID] == nil else {
        throw fail("BuildKit returned an ambiguous cache identity.")
      }
      flags[r.ID] = r
    }
    var seen = Set<String>()
    return try usages.map { r in
      guard recordID(r.ID), seen.insert(r.ID).inserted, r.Size <= 1_000_000_000_000_000,
        r.`Type`.count <= 80, let state = flags[r.ID], state.Reclaimable == !r.InUse,
        state.Shared == r.Shared, state.`Type` == r.`Type`
      else {
        throw fail("BuildKit cache state changed or its exact inventory is ambiguous.")
      }
      return Record(
        id: r.ID, bytes: r.Size, created: r.CreatedAt, lastUsed: r.LastUsedAt,
        mutable: state.Mutable, reclaimable: state.Reclaimable, shared: r.Shared, type: r.`Type`,
        parents: state.Parents)
    }
  }
  private static func eligible(_ records: [Record], retention: Retention, now: Date) -> [Record] {
    let ordered = records.filter { $0.type == "regular" }.sorted {
      let l = $0.lastUsed ?? $0.created
      let r = $1.lastUsed ?? $1.created
      return l == r ? $0.id < $1.id : l > r
    }
    let retained = Set(ordered.prefix(retention.keepNewest).map(\.id))
    let cutoff = now.addingTimeInterval(-Double(retention.minimumAgeDays) * 86400)
    var chosen = Set(
      records.filter {
        guard let used = $0.lastUsed else { return false }
        return !retained.contains($0.id) && $0.type == "regular" && !$0.mutable && !$0.shared
          && $0.reclaimable
          && $0.bytes > 0 && $0.created <= used && used <= cutoff
      }.map(\.id))
    // The engine won't remove a record while another is built on it, so whatever stays keeps what
    // it is built on, all the way down, and those bytes are never promised.
    let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var staying = records.filter { !chosen.contains($0.id) }
    while let record = staying.popLast() {
      for parent in record.parents ?? [] where chosen.remove(parent) != nil {
        if let held = byID[parent] { staying.append(held) }
      }
    }
    return records.filter { chosen.contains($0.id) }.sorted { $0.id < $1.id }
  }
  /// The eligible records in the order the engine can remove them: each before what it is built on,
  /// the biggest first among those that are ready.
  public static func removalOrder(_ inventory: Inventory) -> [String] {
    let eligible = Set(inventory.eligibleIDs)
    let records = inventory.records.filter { eligible.contains($0.id) }
    let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var above = [String: Int]()
    for record in records {
      for parent in Set(record.parents ?? []) where eligible.contains(parent) {
        above[parent, default: 0] += 1
      }
    }
    var order = [String]()
    var ready = records.filter { above[$0.id, default: 0] == 0 }
    while !ready.isEmpty {
      ready.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
      order += ready.map(\.id)
      var next = [Record]()
      for record in ready {
        for parent in Set(record.parents ?? []) where eligible.contains(parent) {
          above[parent, default: 0] -= 1
          if above[parent] == 0, let held = byID[parent] { next.append(held) }
        }
      }
      ready = next
    }
    return order
  }
  public func inspect(target: Target, policy: DiskPolicy, now: Date = Date()) throws -> Inventory {
    try policy.validate()
    guard policy.mode != "off" else { throw Self.fail("Disk cleanup is off.") }
    return try inventory(target, retention: Retention(policy), revision: policy.revision, now: now)
  }
  /// Autopilot's way in. The owner's answer is its permission, so no mode, goal or cap applies; every
  /// check on the owner and on each record does.
  public func inspect(target: Target, retention: Retention, now: Date = Date()) throws -> Inventory {
    try inventory(target, retention: retention, revision: retention.revision, now: now)
  }
  private func inventory(_ target: Target, retention: Retention, revision: String, now: Date) throws
    -> Inventory
  {
    let identity = try owner(target)
    let data = try command(
      target, ["buildx", "--builder", target.builder, "du", "--format=json", "--timeout", "5s"])
    let exactUsage = try command(target, [], transport: .localEngineCacheUsage)
    let records = try Self.decodeRecords(data, exactUsage: exactUsage)
    let allowed = Self.eligible(records, retention: retention, now: now)
    return .init(
      owner: identity, date: now, policyRevision: revision, records: records,
      eligibleIDs: allowed.map(\.id), eligibleBytes: allowed.reduce(0) { $0 + $1.bytes })
  }
  public static func preview(
    inventory: Inventory, recordIDs: [String], policy: DiskPolicy,
    usedTodayBytes: UInt64, now: Date = Date()
  ) throws -> Plan {
    try policy.validate()
    guard policy.mode == "automatic", inventory.policyRevision == policy.revision,
      (0...600).contains(now.timeIntervalSince(inventory.date)), (1...32).contains(recordIDs.count),
      Set(recordIDs).count == recordIDs.count
    else { throw fail("Cache preview requires fresh evidence and automatic cleanup policy.") }
    let eligible = eligible(inventory.records, retention: Retention(policy), now: now)
    let ids = Set(recordIDs)
    let selected = eligible.filter { ids.contains($0.id) }
    let bytes = selected.reduce(UInt64(0)) { $0 + $1.bytes }
    let limit = UInt64(policy.maximumGBPerDay) * 1_000_000_000
    guard selected.count == ids.count, bytes >= DiskCandidate.minimumAutomaticCacheBytes,
      usedTodayBytes <= limit, bytes <= limit - usedTodayBytes
    else {
      throw fail(
        "Selected cache records must be old, unused, unshared, outside newest retention and within the daily cleanup allowance."
      )
    }
    return .init(
      id: UUID(), inventory: inventory, recordIDs: recordIDs.sorted(), cacheBytes: bytes,
      created: now, expires: now.addingTimeInterval(120))
  }
  /// Autopilot's preview: fresh evidence and exact, eligible records, with no goal or daily cap.
  public static func preview(
    inventory: Inventory, recordIDs: [String], retention: Retention, now: Date = Date()
  ) throws -> Plan {
    guard inventory.policyRevision == retention.revision,
      (0...600).contains(now.timeIntervalSince(inventory.date)), (1...32).contains(recordIDs.count),
      Set(recordIDs).count == recordIDs.count
    else { throw fail("Cache preview requires fresh evidence.") }
    let ids = Set(recordIDs)
    let selected = eligible(inventory.records, retention: retention, now: now).filter {
      ids.contains($0.id)
    }
    guard selected.count == ids.count else {
      throw fail("Selected cache records must be old, unused, unshared and outside newest retention.")
    }
    return .init(
      id: UUID(), inventory: inventory, recordIDs: recordIDs.sorted(),
      cacheBytes: selected.reduce(UInt64(0)) { $0 + $1.bytes }, created: now,
      expires: now.addingTimeInterval(120))
  }
  private struct Controls {
    var containers: [String: String]
    var images: Set<String>
    var volumes: Set<String>
    func preserves(_ before: Controls) -> Bool {
      before.containers.allSatisfy { containers[$0.key] == $0.value }
        && before.images.isSubset(of: images) && before.volumes.isSubset(of: volumes)
    }
  }
  private func controls(_ target: Target) throws -> Controls {
    struct Container: Decodable {
      var id: String
      var state: String
    }
    func lines(_ data: Data) throws -> [Data] {
      let result: [Data] = data.split(separator: UInt8(10))
      guard result.count <= 5000 else { throw Self.fail("Docker control inventory is incomplete.") }
      return result
    }
    let decoder = JSONDecoder()
    let rows = try lines(
      command(
        target,
        [
          "container", "ls", "--all", "--no-trunc", "--format",
          "{\"id\":{{json .ID}},\"state\":{{json .State}}}",
        ]))
    var containers: [String: String] = [:]
    for data in rows {
      let row = try decoder.decode(Container.self, from: data)
      guard !row.id.isEmpty, containers[row.id] == nil, !row.state.isEmpty else {
        throw Self.fail("Ambiguous container control inventory.")
      }
      containers[row.id] = row.state
    }
    func ids(_ args: [String]) throws -> Set<String> {
      Set(try lines(command(target, args)).map { try decoder.decode(String.self, from: $0) })
    }
    return .init(
      containers: containers,
      images: try ids(["image", "ls", "--all", "--no-trunc", "--format", "{{json .ID}}"]),
      volumes: try ids(["volume", "ls", "--format", "{{json .Name}}"]))
  }
  /// How long a prune may take. A layer of 100,000 files took 0.74 s (Docker 29.7.2), so a whole
  /// batch of such layers fits. `--timeout` bounds only loading the builder.
  private static let pruneMilliseconds: Int32 = 60_000
  /// What a prune is told, by exact id. BuildKit's `private` and `immutable` are there or not, so
  /// they take an empty value: `shared=false`, `mutable=false` and `inuse=false` compare with text
  /// that isn't there and match nothing, which is how the real engine answered on Docker 29.7.2,
  /// Buildx 0.36.1 and BuildKit 0.32.2. Use needs no filter: without `--all` the engine never removes
  /// what something holds, what another record is built on, or what an image shares.
  public static func pruneArguments(_ target: Target, ids: [String], retention: Retention)
    -> [String]
  {
    [
      "buildx", "--builder", target.builder, "prune",
      "--filter", "id=^(" + ids.joined(separator: "|") + ")$", "--filter",
      "until=\(retention.minimumAgeDays * 24)h",
      "--filter", "type=regular", "--filter", "private=\"\"", "--filter", "immutable=\"\"",
      "--force", "--timeout", "5s",
    ]
  }
  private static func removedIDs(_ output: Data) -> Set<String> {
    Set(
      String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
        guard let first = line.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let id = String(first)
        return recordID(id) ? id : nil
      })
  }

  /// One explicitly invoked no-match actuator contract. It generates its own ID,
  /// proves that ID absent, and can never accept a caller-supplied existing record.
  /// All real cleanup filters and the pinned local transport remain unchanged.
  public func proveNoMatchContract(target: Target, policy: DiskPolicy) throws -> NoMatchContract {
    let initial = try inspect(target: target, policy: policy)
    let beforeControls = try controls(target)
    let id =
      "bz" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    guard Self.recordID(id), !initial.records.contains(where: { $0.id == id }) else {
      throw Self.fail("No-match proof could not establish an absent ID; no actuator call made.")
    }
    let before = try inspect(target: target, policy: policy)
    guard before.owner == initial.owner, !before.records.contains(where: { $0.id == id }) else {
      throw Self.fail("No-match owner or absence proof changed; no actuator call made.")
    }
    var result = NoMatchContract(
      date: Date(), context: target.context,
      daemonIdentityHash: WorkEvidence.hash(before.owner.daemonID), generatedAbsentID: id,
      beforeRecords: before.records.count, reportedRemovedIDs: [], outcome: "inconclusive",
      detail:
        "One exact absent-ID actuator request; zero existing records selected or cleanup credited.")
    var dispatchError: String?
    do {
      let output = try command(
        target, Self.pruneArguments(target, ids: [id], retention: Retention(policy)),
        milliseconds: Self.pruneMilliseconds)
      result.reportedRemovedIDs = Self.removedIDs(output).sorted()
      let text = String(decoding: output, as: UTF8.self)
      if !result.reportedRemovedIDs.isEmpty
        || text.range(of: #"(?m)^Total:\s*0B\s*$"#, options: .regularExpression) == nil
      {
        dispatchError = "The owner did not return an unambiguous zero-byte no-match result."
      }
    } catch { dispatchError = String(error.localizedDescription.prefix(240)) }
    do {
      let after = try inspect(target: target, policy: policy)
      result.afterRecords = after.records.count
      result.ownerPreserved = after.owner == before.owner
      result.existingRecordsPreserved = Set(before.records.map(\.id)).isSubset(
        of: Set(after.records.map(\.id)))
      result.controlsPreserved = try controls(target).preserves(beforeControls)
      if dispatchError == nil && result.ownerPreserved == true
        && result.existingRecordsPreserved == true && result.controlsPreserved == true
      {
        result.outcome = "verifiedZeroCleanup"
        result.detail =
          "Exact anchored filters accepted. The absent ID matched nothing; all prior cache IDs, container states, images and volumes remain. Zero cleanup."
      } else {
        result.detail =
          dispatchError
          ?? "Owner/cache/control state changed; contract result is inconclusive. No cleanup credit or retry."
      }
    } catch {
      result.detail =
        "No-match reconciliation unavailable: " + error.localizedDescription.prefix(240)
    }
    return result
  }
  /// Throws before mutation; once a prune is attempted, always returns a receipt.
  /// --force here skips the CLI confirmation only; it does not bypass engine locks.
  public func clean(
    plan: Plan, policy: DiskPolicy, usedTodayBytes: UInt64,
    now: Date = Date(), authorize: () throws -> Void = {}
  ) throws -> Receipt {
    guard plan.inventory.policyRevision == policy.revision else {
      throw Self.fail("Cache plan expired or its policy changed.")
    }
    return try clean(
      plan, retention: Retention(policy), now: now, authorize: authorize,
      inspect: { try inspect(target: $0, policy: policy, now: $1) },
      validate: {
        try Self.preview(
          inventory: $0, recordIDs: plan.recordIDs, policy: policy, usedTodayBytes: usedTodayBytes,
          now: now)
      })
  }
  /// Autopilot's: the same steps and checks, with no goal or daily cap in them.
  public func clean(
    plan: Plan, retention: Retention, now: Date = Date(), authorize: () throws -> Void = {}
  ) throws -> Receipt {
    guard plan.inventory.policyRevision == retention.revision else {
      throw Self.fail("Cache plan expired or its policy changed.")
    }
    return try clean(
      plan, retention: retention, now: now, authorize: authorize,
      inspect: { try inspect(target: $0, retention: retention, now: $1) },
      validate: {
        try Self.preview(inventory: $0, recordIDs: plan.recordIDs, retention: retention, now: now)
      })
  }
  private func clean(
    _ plan: Plan, retention: Retention, now: Date, authorize: () throws -> Void,
    inspect look: (Target, Date) throws -> Inventory, validate: (Inventory) throws -> Plan
  ) throws -> Receipt {
    guard plan.created <= now, now <= plan.expires,
      plan.expires.timeIntervalSince(plan.created) <= 120
    else { throw Self.fail("Cache plan expired or its policy changed.") }
    let target = plan.inventory.owner.target
    let fresh = try look(target, now)
    guard fresh.owner == plan.inventory.owner else {
      throw Self.fail("Docker owner changed; cache plan refused.")
    }
    let validated = try validate(fresh)
    let selected = Set(plan.recordIDs)
    guard validated.cacheBytes == plan.cacheBytes,
      fresh.records.filter({ selected.contains($0.id) }).sorted(by: { $0.id < $1.id })
        == plan.inventory.records.filter({ selected.contains($0.id) }).sorted(by: { $0.id < $1.id })
    else { throw Self.fail("Selected cache evidence changed; build a new plan.") }
    let before = try controls(target)
    guard try owner(target) == fresh.owner else {
      throw Self.fail("Docker owner changed before cleanup.")
    }
    // The Monitor reloads live policy, remaining allowance and disk target here, and Autopilot its
    // decision to burn: those can change during the bounded owner/controls inspection above.
    try authorize()
    guard Date() <= plan.expires else {
      throw Self.fail("Cache plan expired during owner verification; preserved.")
    }
    var receipt = Receipt(
      planID: plan.id, date: now, owner: fresh.owner, requestedIDs: plan.recordIDs,
      removedIDs: [], outcome: "uncertain", cacheReleasedBytes: 0, hostDiskReclaimedBytes: nil,
      controlsPreserved: nil,
      detail: "Prune attempted; fresh owner reconciliation is required before any retry.")
    do {
      // Buildx's id= filter is a regex. Validated alphanumeric IDs plus anchors
      // prevent prefix/substring matches. One bounded set avoids partial batches.
      let output = try command(
        target, Self.pruneArguments(target, ids: plan.recordIDs, retention: retention),
        milliseconds: Self.pruneMilliseconds)
      let reported = Self.removedIDs(output)
      guard reported.isSubset(of: selected) else {
        throw Self.fail("Owner reported an unexpected cache record; reconciliation required.")
      }
      let after = try look(target, Date())
      guard after.owner == fresh.owner else {
        throw Self.fail("Owner changed during cleanup; reconciliation required.")
      }
      let controlsOK = try controls(target).preserves(before)
      receipt.controlsPreserved = controlsOK
      guard controlsOK else {
        throw Self.fail("Docker control inventory changed during cleanup; reconciliation required.")
      }
      let remaining = Set(after.records.map(\.id))
      receipt.removedIDs = plan.recordIDs.filter {
        reported.contains($0) && !remaining.contains($0)
      }
      receipt.cacheReleasedBytes = fresh.records.filter { receipt.removedIDs.contains($0.id) }
        .reduce(0) { $0 + $1.bytes }
      receipt.outcome =
        receipt.removedIDs.count == plan.recordIDs.count
        ? "verified" : receipt.removedIDs.isEmpty ? "noChange" : "partial"
      receipt.detail =
        receipt.removedIDs.isEmpty
        ? "No selected cache removal was verified. Active or retained records were preserved."
        : "Exact owner cache records disappeared; container states, images and volumes were preserved. Host disk recovery is not yet measured."
    } catch {
      // An RPC can continue after its CLI exits. Never retry or claim success here.
      receipt.detail =
        "Cleanup outcome requires reconciliation: " + String(describing: error).prefix(240)
    }
    return receipt
  }

  public static func live(store: Store) throws -> Self {
    let binaries = [
      "/Applications/Docker.app/Contents/Resources/bin/docker", "/opt/homebrew/bin/docker",
      "/usr/local/bin/docker",
    ]
    guard let binary = binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
      throw fail("Docker CLI is not installed in a supported location.")
    }
    func identity(_ path: String, socket: Bool) throws -> String {
      let canonical = WorkspaceSafety.canonical(path)
      var s = stat()
      guard stat(canonical, &s) == 0, [getuid(), 0].contains(s.st_uid),
        s.st_mode & S_IFMT == (socket ? S_IFSOCK : S_IFREG), socket || s.st_mode & 0o022 == 0
      else {
        throw fail("Docker executable or local socket identity is unsafe or unavailable.")
      }
      return
        "\(canonical)|\(s.st_dev):\(s.st_ino):\(socket ? 0 : s.st_size):\(socket ? 0 : s.st_mtimespec.tv_sec)"
    }
    let plugins = [
      "/Applications/Docker.app/Contents/Resources/cli-plugins/docker-buildx",
      "/opt/homebrew/lib/docker/cli-plugins/docker-buildx",
      "/usr/local/lib/docker/cli-plugins/docker-buildx",
    ]
    guard let plugin = plugins.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else {
      throw fail("Buildx is not installed in a supported fixed location.")
    }
    let original = try identity(binary, socket: false)
    let originalPlugin = try identity(plugin, socket: false)
    let originalCurl = try identity("/usr/bin/curl", socket: false)
    let capture = ManagedCacheCapture(store: store, binary: binary, plugin: plugin)
    return .init(
      runner: { command in
        guard try identity(binary, socket: false) == original,
          try identity(plugin, socket: false) == originalPlugin,
          try identity("/usr/bin/curl", socket: false) == originalCurl
        else {
          throw fail("Docker executable or fixed Buildx plugin changed.")
        }
        return try capture.run(command)
      }, socketIdentity: { try identity($0, socket: true) },
      executableIdentity: {
        try identity(binary, socket: false) + "|" + identity(plugin, socket: false) + "|"
          + identity("/usr/bin/curl", socket: false)
      })
  }
}

/// Keep routing configuration private and immutable for this owner operation.
/// Context inspection alone reads user configuration; every engine-facing command
/// receives our local-only snapshot and fixed plugin, never a mutable context name
/// resolved through the user's live configuration. No credentials are copied.
private final class ManagedCacheCapture {
  let store: Store
  let binary: String
  let plugin: String
  var pinned: [String: (directory: URL, endpoint: String)] = [:]
  let lock = NSLock()
  init(store: Store, binary: String, plugin: String) {
    self.store = store
    self.binary = binary
    self.plugin = plugin
  }
  deinit { for value in pinned.values { try? FileManager.default.removeItem(at: value.directory) } }

  func run(_ command: BuildKitCache.Command) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    let args = command.arguments
    guard args.count >= 2, args[0] == "--context" else {
      throw StoreError.message("Missing explicit Docker owner.")
    }
    let context = args[1]
    let inspection =
      command.transport == .dockerCLI
      && Array(args.dropFirst(2)) == ["context", "inspect", context]
    var routed = args
    var executable = binary
    if command.transport == .localEngineCacheUsage {
      guard args.count == 2, let binding = pinned[context] else {
        throw StoreError.message("Local Docker API transport was not pinned.")
      }
      executable = "/usr/bin/curl"
      // Fixed read-only API and version; no URL, query, proxy, curlrc, credentials
      // or remote endpoint can be supplied by the model or user context.
      routed = [
        "--disable", "--silent", "--show-error", "--fail", "--max-time", "6", "--noproxy", "*",
        "--proto", "=http", "--unix-socket", String(binding.endpoint.dropFirst("unix://".count)),
        "http://localhost/v1.51/system/df?type=build-cache",
      ]
    } else if !inspection {
      guard let binding = pinned[context] else {
        throw StoreError.message("Local Docker transport was not pinned.")
      }
      routed =
        ["--config", binding.directory.path]
        + (context == "default" ? ["--host", binding.endpoint] : ["--context", context])
        + Array(args.dropFirst(2))
    }
    let output = store.root.appendingPathComponent("managed-cache-output-" + UUID().uuidString)
    let fd = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Cannot create private owner-tool capture.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: output)
    }
    var argv =
      ([executable] + routed).map { (value: String) in value.withCString { strdup($0) } } + [nil]
    var env =
      [
        "HOME=" + NSHomeDirectory(), "PATH=/usr/bin:/bin", "LC_ALL=C", "NO_COLOR=1",
        "DOCKER_CLI_HINTS=false",
      ]
      .map { (value: String) in value.withCString { strdup($0) } } + [nil]
    defer {
      argv.forEach { free($0) }
      env.forEach { free($0) }
    }
    let result =
      command.milliseconds > 8000
      ? bz_capture_prune_tool(&argv, &env, fd, command.milliseconds, 1_048_576)
      : bz_capture_tool(&argv, &env, fd, command.milliseconds, 1_048_576)
    guard result == 0 else {
      let operation =
        command.transport == .localEngineCacheUsage
        ? "exact cache inventory"
        : args.contains("prune")
          ? "prune"
          : args.contains("du")
            ? "disk inventory"
            : inspection
              ? "context inspection"
              : args.contains("inspect")
                ? "builder inspection"
                : args.contains("info") ? "daemon identity" : "control inventory"
      throw StoreError.message(
        "Docker \(operation) did not complete (exit \(result)); no automatic retry.")
    }
    try handle.seek(toOffset: 0)
    let data = try handle.read(upToCount: 1_048_577) ?? Data()
    if inspection && pinned[context] == nil {
      guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        rows.count == 1,
        rows[0]["Name"] as? String == context,
        let endpoints = rows[0]["Endpoints"] as? [String: [String: Any]],
        let endpoint = endpoints["docker"]?["Host"] as? String, endpoint.hasPrefix("unix:///"),
        !endpoint.contains("\n"), !endpoint.contains("\0")
      else { throw StoreError.message("A remote or ambiguous Docker context cannot be pinned.") }
      let fixedEndpoint =
        "unix://" + WorkspaceSafety.canonical(String(endpoint.dropFirst("unix://".count)))
      let directory = store.root.appendingPathComponent("owner-context-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      do {
        let config: [String: Any] = [
          "currentContext": context,
          "cliPluginsExtraDirs": [(plugin as NSString).deletingLastPathComponent],
        ]
        try JSONSerialization.data(withJSONObject: config).write(
          to: directory.appendingPathComponent("config.json"), options: .atomic)
        if context != "default" {
          let meta = directory.appendingPathComponent("contexts/meta/" + WorkEvidence.hash(context))
          try FileManager.default.createDirectory(
            at: meta, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
          let value: [String: Any] = [
            "Name": context, "Metadata": [:],
            "Endpoints": ["docker": ["Host": fixedEndpoint, "SkipTLSVerify": false]],
          ]
          try JSONSerialization.data(withJSONObject: value).write(
            to: meta.appendingPathComponent("meta.json"), options: .atomic)
        }
        pinned[context] = (directory, fixedEndpoint)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
    }
    return data
  }
}
