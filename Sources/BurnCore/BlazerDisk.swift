import CBurn
import Darwin
import Foundation

/// Low-disk velocity tracker and Overdrive trigger. Monitors APFS free bytes and hourly burn rate
/// so BurnZombies automatically drops into high-frequency sweeps before agent swarms brick the Mac.
public enum BlazerOverdrive {
  public static let lowDiskThreshold: UInt64 = 50_000_000_000
  public static let exhaustVelocityThreshold: UInt64 = 5_000_000_000
  public static let overdriveIntervalSeconds: TimeInterval = 120
  private static let fileName = "blazer-exhaust.json"
  private static let maxSamples = 96
  private static let minSampleSpacing: TimeInterval = 60
  private static let retentionWindow: TimeInterval = 24 * 3600
  private static let velocityWindow: TimeInterval = 3 * 3600

  public struct ExhaustSample: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    public init(timestamp: Date, freeBytes: UInt64, totalBytes: UInt64) {
      self.timestamp = timestamp
      self.freeBytes = freeBytes
      self.totalBytes = totalBytes
    }
  }

  public struct VolumeTelemetry: Codable, Sendable, Equatable {
    public var freeBytes: UInt64
    public var totalBytes: UInt64
    public var usedPercent: Double
    public var exhaustBytesPerHour: UInt64
    public var overdriveActive: Bool
    public var overdriveReason: String?

    public init(
      freeBytes: UInt64, totalBytes: UInt64, usedPercent: Double, exhaustBytesPerHour: UInt64,
      overdriveActive: Bool, overdriveReason: String?
    ) {
      self.freeBytes = freeBytes
      self.totalBytes = totalBytes
      self.usedPercent = usedPercent
      self.exhaustBytesPerHour = exhaustBytesPerHour
      self.overdriveActive = overdriveActive
      self.overdriveReason = overdriveReason
    }
  }

  public static func volumeSpace(at path: String = NSHomeDirectory()) -> (
    free: UInt64, total: UInt64
  )? {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return nil }
    let block = UInt64(fs.f_bsize)
    return (free: UInt64(fs.f_bavail) * block, total: UInt64(fs.f_blocks) * block)
  }

  /// Records a volume sample (at most once per minute) and computes current Overdrive state.
  public static func sample(
    root: URL = Store.defaultRoot, volumePath: String = NSHomeDirectory(), now: Date = Date(),
    statVolume: ((String) -> (free: UInt64, total: UInt64)?)? = nil
  ) -> VolumeTelemetry {
    evaluate(
      root: root, volumePath: volumePath, now: now, persist: true, statVolume: statVolume)
  }

  /// Pure read of volume telemetry + historical velocity without mutating state on disk.
  public static func readOnlyTelemetry(
    root: URL = Store.defaultRoot, volumePath: String = NSHomeDirectory(), now: Date = Date(),
    statVolume: ((String) -> (free: UInt64, total: UInt64)?)? = nil
  ) -> VolumeTelemetry {
    evaluate(
      root: root, volumePath: volumePath, now: now, persist: false, statVolume: statVolume)
  }

  private static func evaluate(
    root: URL, volumePath: String, now: Date, persist: Bool,
    statVolume: ((String) -> (free: UInt64, total: UInt64)?)?
  ) -> VolumeTelemetry {
    let reader = statVolume ?? { volumeSpace(at: $0) }
    guard let space = reader(volumePath), space.total > 0 else {
      return VolumeTelemetry(
        freeBytes: 0, totalBytes: 0, usedPercent: 0, exhaustBytesPerHour: 0,
        overdriveActive: false, overdriveReason: nil)
    }
    let url = root.appendingPathComponent(fileName)
    let store = try? Store(root: root)
    var samples: [ExhaustSample] =
      (try? store?.read(url, limit: 65_536)).flatMap {
        try? JSONDecoder().decode([ExhaustSample].self, from: $0)
      } ?? []
    samples = samples.filter {
      $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= retentionWindow
    }.sorted { $0.timestamp < $1.timestamp }

    if persist {
      if samples.last.map({ now.timeIntervalSince($0.timestamp) >= minSampleSpacing }) ?? true {
        samples.append(
          ExhaustSample(timestamp: now, freeBytes: space.free, totalBytes: space.total))
        if samples.count > maxSamples {
          samples.removeFirst(samples.count - maxSamples)
        }
        if let encoded = try? JSONEncoder().encode(samples) {
          try? store?.write(encoded, to: url, limit: 65_536)
        }
      }
    }

    let velocity = computeVelocity(samples: samples, currentFree: space.free, now: now)
    let used =
      space.total > space.free
      ? Double(space.total - space.free) / Double(space.total) * 100.0 : 0.0
    let lowDisk = space.free < lowDiskThreshold
    let highExhaust = velocity >= exhaustVelocityThreshold
    let active = lowDisk || highExhaust
    var reasons: [String] = []
    if lowDisk {
      let gb = String(format: "%.1f GB", Double(space.free) / 1_000_000_000)
      reasons.append("free space at \(gb)")
    }
    if highExhaust {
      let rate = String(format: "%.1f GB/hr", Double(velocity) / 1_000_000_000)
      reasons.append("exhaust burning \(rate)")
    }
    return VolumeTelemetry(
      freeBytes: space.free, totalBytes: space.total, usedPercent: used,
      exhaustBytesPerHour: velocity, overdriveActive: active,
      overdriveReason: reasons.isEmpty ? nil : reasons.joined(separator: " + "))
  }

  private static func computeVelocity(
    samples: [ExhaustSample], currentFree: UInt64, now: Date
  ) -> UInt64 {
    let window = samples.filter {
      let dt = now.timeIntervalSince($0.timestamp)
      return dt >= minSampleSpacing && dt <= velocityWindow
    }
    var peakRate: Double = 0
    for anchor in window where anchor.freeBytes > currentFree {
      let dt = now.timeIntervalSince(anchor.timestamp)
      guard dt >= minSampleSpacing else { continue }
      let dropped = Double(anchor.freeBytes - currentFree)
      let perHour = dropped / (dt / 3600.0)
      if perHour > peakRate { peakRate = perHour }
    }
    guard peakRate.isFinite, peakRate > 0 else { return 0 }
    return UInt64(min(Double(UInt64.max / 2), peakRate))
  }
}

/// Content-signature scanner ("Anatomical X-Ray") that discovers disguised Xcode DerivedData,
/// isolated Gradle caches, older local Android SDK build trees, dead-chat scratch directories,
/// shut-down ephemeral Simulator data, unlocked offline Android AVDs, and expired recovery archives.
public enum BlazerAnatomy {
  public enum SignatureKind: String, Codable, Sendable, CaseIterable {
    case disguisedDerivedData = "disguised-derived-data"
    case isolatedGradleCache = "isolated-gradle-cache"
    case androidSdkTree = "android-sdk-tree"
    case deadAgentScratch = "dead-scratch"
    case shutdownSimulatorData = "simulator-data"
    case offlineAndroidAvd = "android-avd"
    case orphanedRecovery = "orphaned-recovery"

    public var folderFact: String {
      switch self {
      case .disguisedDerivedData, .shutdownSimulatorData: return "xcode-derived"
      case .isolatedGradleCache: return "package-cache"
      case .androidSdkTree, .deadAgentScratch, .offlineAndroidAvd, .orphanedRecovery:
        return "build-output"
      }
    }

    public var categoryLabel: String {
      switch self {
      case .disguisedDerivedData: return "Disguised Xcode DerivedData"
      case .isolatedGradleCache: return "Isolated Gradle cache"
      case .androidSdkTree: return "Old local Android SDK tree"
      case .deadAgentScratch: return "Finished agent scratch folder"
      case .shutdownSimulatorData: return "Shut-down Simulator device data"
      case .offlineAndroidAvd: return "Offline Android emulator image"
      case .orphanedRecovery: return "Expired recovery archive"
      }
    }
  }

  public static let minimumBytes: UInt64 = 100_000_000
  public static let keepNewestAndroidTrees = 3
  private static let scratchMinAge: TimeInterval = 2 * 3600
  private static let simulatorMinAge: TimeInterval = 24 * 3600
  private static let avdMinAge: TimeInterval = 7 * 86_400
  private static let recoveryMaxAge: TimeInterval = 30 * 86_400
  private static let excluded = [
    "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Pictures", ".ssh", ".gnupg",
    "Library/Keychains",
  ]

  public static func isAnatomical(_ item: AutopilotItem) -> Bool {
    item.kind == .disk && item.facts["anatomical"] != nil
  }

  /// Resolves the temp folders safe to inspect for `home`. Stand-in test homes stay strictly inside
  /// their own directory unless explicit `tempRoots` are provided.
  public static func defaultTempRoots(for home: String) -> [String] {
    let base = WorkspaceSafety.canonical(home)
    let realHome = WorkspaceSafety.canonical(NSHomeDirectory())
    if base == realHome {
      var roots = ["/private/tmp"]
      let userTmp = WorkspaceSafety.canonical(NSTemporaryDirectory())
      if userTmp.hasPrefix("/"), !roots.contains(userTmp) { roots.append(userTmp) }
      return roots
    }
    let localTmp = base + "/tmp"
    return isOwnedDirectory(localTmp) ? [WorkspaceSafety.canonical(localTmp)] : []
  }

  /// Inspects a directory's contents (without following symlinks) to check for disguised build
  /// cache anatomy.
  public static func inspectSignature(at path: String, home: String) -> SignatureKind? {
    guard isOwnedDirectory(path), !exists(path + "/.git") else { return nil }
    let base = WorkspaceSafety.canonical(home)
    let standardDD = base + "/Library/Developer/Xcode/DerivedData"
    if path == standardDD || path.hasPrefix(standardDD + "/") { return nil }
    let standardGradle = base + "/.gradle"
    if path == standardGradle || path.hasPrefix(standardGradle + "/") { return nil }

    // 1. Disguised Xcode DerivedData (`info.plist`/`Info.plist`/`ModuleCache.noindex` + `Build/Intermediates.noindex` or `Build/Products`)
    let hasBuildTree =
      isOwnedDirectory(path + "/Build/Intermediates.noindex")
      || isOwnedDirectory(path + "/Build/Products")
    let hasXcodeMarker =
      isRegularFile(path + "/info.plist") || isRegularFile(path + "/Info.plist")
      || isOwnedDirectory(path + "/ModuleCache.noindex")
      || isOwnedDirectory(path + "/Logs/Build")
    if hasBuildTree && hasXcodeMarker {
      return .disguisedDerivedData
    }
    // Also check if a parent directory holds multiple disguised DerivedData targets (`*/Build/Intermediates.noindex` + `*/info.plist`)
    if let children = try? FileManager.default.contentsOfDirectory(atPath: path),
      children.count <= 64,
      children.contains(where: { child in
        let sub = path + "/" + child
        return isOwnedDirectory(sub)
          && (isOwnedDirectory(sub + "/Build/Intermediates.noindex")
            || isOwnedDirectory(sub + "/Build/Products"))
          && (isRegularFile(sub + "/info.plist") || isRegularFile(sub + "/Info.plist"))
      }),
      ["dd", "deriveddata", "derived-data", "ios-derived", "xcode-derived"].contains(where: {
        leaf(path).lowercased().contains($0)
      })
    {
      return .disguisedDerivedData
    }

    // 2. Isolated Gradle user home / cache (`caches/modules-2` + `wrapper/dists` or `daemon`)
    if isOwnedDirectory(path + "/caches/modules-2")
      && (isOwnedDirectory(path + "/wrapper/dists") || isOwnedDirectory(path + "/daemon"))
    {
      return .isolatedGradleCache
    }
    return nil
  }

  /// Scans user-owned artifact, scratch, SDK, Simulator, AVD, and recovery locations for disguised
  /// rebuildable waste.
  public static func scan(
    home: String = NSHomeDirectory(), root: URL = Store.defaultRoot,
    threads: [AgentThread] = [], tempRoots: [String]? = nil, overdrive: Bool = false,
    minimumBytes: UInt64 = minimumBytes, now: Date = Date(),
    sizer: (String) -> UInt64? = { AutopilotDisk.allocatedSize($0) },
    protected: ProtectedLocations? = nil
  ) -> [AutopilotItem] {
    let base = WorkspaceSafety.canonical(home)
    guard base.hasPrefix("/"), base != "/" else { return [] }
    let scope = protected ?? .limited(homes: [base])
    let temps = (tempRoots ?? defaultTempRoots(for: base)).map(WorkspaceSafety.canonical)
    var found: [String: AutopilotItem] = [:]

    func record(
      path: String, kind: SignatureKind, name: String, detail: String, touched: Date
    ) {
      let real = WorkspaceSafety.canonical(path)
      guard real == path, !found.keys.contains("disk:" + AutopilotItem.hash(real)),
        allowedLocation(real, home: base, tempRoots: temps, recoveryRoot: root, protected: scope),
        isOwnedDirectory(real), !exists(real + "/.git"),
        let bytes = sizer(real), bytes >= minimumBytes
      else { return }
      var facts: [String: String] = [
        "folder": kind.folderFact,
        "home": "global-cache",
        "anatomical": kind.rawValue,
        "stale": staleBucket(since: touched, now: now),
        "size": byteScale(bytes),
      ]
      if overdrive { facts["overdrive"] = "yes" }
      let item = AutopilotItem(
        id: "disk:" + AutopilotItem.hash(real), kind: .disk, name: name, detail: detail,
        path: real, bytes: bytes, facts: facts, observedAt: now, lastUsed: touched)
      found[item.id] = item
    }

    // 1. Disguised DerivedData & Isolated Gradle Caches inside agent/temp roots (up to depth 2)
    let searchRoots =
      [
        base + "/.codex/artifacts",
        base + "/.codex/outputs",
        base + "/.claude",
        base + "/.gemini/antigravity/brain",
      ] + temps
    var visited = Set<String>()
    for rawRoot in searchRoots {
      let searchRoot = WorkspaceSafety.canonical(rawRoot)
      guard isOwnedDirectory(searchRoot) || temps.contains(searchRoot) else { continue }
      scanSignatures(
        under: searchRoot, maxDepth: 2, home: base, visited: &visited
      ) { candidate, sig, touched in
        let title = "\(leaf(candidate)) (\(sig.categoryLabel))"
        let detail =
          sig == .disguisedDerivedData
          ? "Disguised Xcode DerivedData at \(abbreviate(candidate, home: base)). Xcode rebuilds it when needed."
          : "Isolated Gradle cache at \(abbreviate(candidate, home: base)). Gradle re-downloads packages when needed."
        record(path: candidate, kind: sig, name: title, detail: detail, touched: touched)
      }
    }

    // 2. Local Android SDK build trees (`~/.patrol6/android-sdk-local`), keeping newest 3
    let sdkRoot = base + "/.patrol6/android-sdk-local"
    if isOwnedDirectory(sdkRoot) {
      let candidates = collectAndroidSdkTrees(under: sdkRoot)
      let sorted = candidates.sorted {
        $0.touched != $1.touched ? $0.touched > $1.touched : $0.path > $1.path
      }
      for tree in sorted.dropFirst(keepNewestAndroidTrees) {
        let label = relativeLabel(tree.path, under: sdkRoot)
        record(
          path: tree.path, kind: .androidSdkTree,
          name: "Android SDK build \(label)",
          detail:
            "Older local Android SDK build tree (newest \(keepNewestAndroidTrees) trees are kept safe).",
          touched: tree.touched)
      }
    }

    // 3. Dead-chat scratch directories (`/tmp/claude-*`, `~/.codex/artifacts/*`, `~/.gemini/antigravity/brain/*/scratch`)
    let liveIDs = Set(
      threads.filter(\.live).map { thread -> String in
        if let colon = thread.id.firstIndex(of: ":") {
          return String(thread.id[thread.id.index(after: colon)...])
        }
        return thread.id
      })
    for temp in temps {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []
      for entry in entries.sorted().prefix(512) where entry.hasPrefix("claude-") {
        let candidate = temp + "/" + entry
        guard isOwnedDirectory(candidate), let touched = modifiedDate(candidate),
          now.timeIntervalSince(touched) >= scratchMinAge,
          !matchesLiveSession(name: entry, path: candidate, threads: threads, liveIDs: liveIDs),
          inspectSignature(at: candidate, home: base) == nil
        else { continue }
        record(
          path: candidate, kind: .deadAgentScratch,
          name: "\(entry) in temp scratch",
          detail: "Scratch files from a finished Claude session in \(temp).",
          touched: touched)
      }
    }
    let codexArtifacts = base + "/.codex/artifacts"
    if isOwnedDirectory(codexArtifacts) {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: codexArtifacts)) ?? []
      for entry in entries.sorted().prefix(512) {
        let candidate = codexArtifacts + "/" + entry
        guard isOwnedDirectory(candidate), let touched = modifiedDate(candidate),
          now.timeIntervalSince(touched) >= scratchMinAge,
          !matchesLiveSession(name: entry, path: candidate, threads: threads, liveIDs: liveIDs),
          inspectSignature(at: candidate, home: base) == nil
        else { continue }
        record(
          path: candidate, kind: .deadAgentScratch,
          name: "\(entry) in Codex artifacts",
          detail: "Scratch artifacts from a finished Codex run.",
          touched: touched)
      }
    }
    let agyBrain = base + "/.gemini/antigravity/brain"
    if isOwnedDirectory(agyBrain) {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: agyBrain)) ?? []
      for entry in entries.sorted().prefix(512) {
        let candidate = agyBrain + "/" + entry + "/scratch"
        guard isOwnedDirectory(candidate), let touched = modifiedDate(candidate),
          now.timeIntervalSince(touched) >= scratchMinAge, !liveIDs.contains(entry),
          inspectSignature(at: candidate, home: base) == nil
        else { continue }
        record(
          path: candidate, kind: .deadAgentScratch,
          name: "scratch in Antigravity \(entry.prefix(8))",
          detail: "Temporary scratch folder from a finished Antigravity session.",
          touched: touched)
      }
    }

    // 4. Shut-down iOS Simulator ephemeral device data (`state == 1` in `device.plist`, untouched >= 24h)
    let simDevices = base + "/Library/Developer/CoreSimulator/Devices"
    if isOwnedDirectory(simDevices) {
      let uuids = (try? FileManager.default.contentsOfDirectory(atPath: simDevices)) ?? []
      for uuid in uuids.sorted().prefix(256) {
        let deviceDir = simDevices + "/" + uuid
        let dataDir = deviceDir + "/data"
        guard isOwnedDirectory(deviceDir), isOwnedDirectory(dataDir),
          let sim = shutdownSimulatorInfo(deviceDir: deviceDir),
          let touched = modifiedDate(dataDir),
          now.timeIntervalSince(touched) >= simulatorMinAge
        else { continue }
        record(
          path: dataDir, kind: .shutdownSimulatorData,
          name: "\(sim.name) Simulator data",
          detail:
            "Shut-down iOS Simulator data (\(uuid.prefix(8))). Simulator recreates clean device storage on next boot.",
          touched: touched)
      }
    }

    // 5. Unlocked offline Android AVDs (`~/.android/avd/*.avd`, no `.lock` files, untouched >= 7d)
    let avdRoot = base + "/.android/avd"
    if isOwnedDirectory(avdRoot) {
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: avdRoot)) ?? []
      for entry in entries.sorted().prefix(128) where entry.hasSuffix(".avd") {
        let candidate = avdRoot + "/" + entry
        guard isOwnedDirectory(candidate), !hasAvdLock(candidate),
          let touched = modifiedDate(candidate),
          now.timeIntervalSince(touched) >= avdMinAge
        else { continue }
        let title = String(entry.dropLast(4))
        record(
          path: candidate, kind: .offlineAndroidAvd,
          name: "\(title) Android AVD",
          detail: "Offline Android emulator system data untouched for over a week.",
          touched: touched)
      }
    }

    // 6. Expired/orphaned PrivateRecovery archives (> 30 days old with no receipt pointing to them)
    let recoveryDir = WorkspaceSafety.canonical(root.appendingPathComponent("recovery").path)
    if isOwnedDirectory(recoveryDir) {
      let referenced = referencedRecoveryDirectories(root: root)
      let entries = (try? FileManager.default.contentsOfDirectory(atPath: recoveryDir)) ?? []
      for entry in entries.sorted().prefix(256) {
        let candidate = recoveryDir + "/" + entry
        guard isOwnedDirectory(candidate), !referenced.contains(candidate),
          let touched = modifiedDate(candidate),
          now.timeIntervalSince(touched) >= recoveryMaxAge
        else { continue }
        record(
          path: candidate, kind: .orphanedRecovery,
          name: "Expired recovery snapshot \(entry.prefix(8))",
          detail: "Unreferenced recovery archive older than 30 days.",
          touched: touched)
      }
    }

    return found.values.sorted {
      $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id
    }
  }

  /// Reclaims an anatomical item after re-checking ownership, symlinks, live locks, and signatures.
  public static func reclaim(
    _ item: AutopilotItem, authority: String, home: String = NSHomeDirectory(),
    tempRoots: [String]? = nil, inUse: (String) -> Int32 = { bz_path_in_use($0) },
    protected: ProtectedLocations? = nil, root: URL = Store.defaultRoot,
    authorize: () -> Bool = { true }
  ) -> AutopilotReceipt {
    func refuse(_ reason: String) -> AutopilotReceipt {
      .refused(item, authority: authority, reason)
    }
    guard item.kind == .disk, let path = item.path,
      let rawKind = item.facts["anatomical"], let kind = SignatureKind(rawValue: rawKind)
    else {
      return refuse("That folder doesn't carry a verified anatomical signature, so I left it alone.")
    }
    let base = WorkspaceSafety.canonical(home)
    guard base.hasPrefix("/"), base != "/" else {
      return refuse("I can't find your home folder, so I left this alone.")
    }
    let scope = protected ?? .limited(homes: [base])
    let temps = (tempRoots ?? defaultTempRoots(for: base)).map(WorkspaceSafety.canonical)
    if let place = scope.resolution(path).place {
      return refuse(AutopilotDisk.protectedRefusal(place))
    }
    var original = stat()
    guard lstat(path, &original) == 0 else {
      return refuse("That folder is already gone.")
    }
    guard original.st_mode & S_IFMT != S_IFLNK else {
      return refuse("That folder is a shortcut to somewhere else, so I left it alone.")
    }
    guard original.st_mode & S_IFMT == S_IFDIR else {
      return refuse("That isn't a folder, so I left it alone.")
    }
    guard original.st_uid == getuid() else {
      return refuse("That folder belongs to someone else, so I left it alone.")
    }
    let real = WorkspaceSafety.canonical(path)
    guard real == path,
      allowedLocation(real, home: base, tempRoots: temps, recoveryRoot: root, protected: scope)
    else {
      return refuse("That folder isn't in a safe user-owned location, so I left it alone.")
    }
    guard !exists(real + "/.git") else {
      return refuse("There's a Git repository inside that folder, so I left it alone.")
    }

    // Live anatomical re-verification before deleting a single byte:
    switch kind {
    case .disguisedDerivedData, .isolatedGradleCache:
      guard inspectSignature(at: real, home: base) == kind else {
        return refuse("That folder's build-cache signature changed, so I left it alone.")
      }
    case .androidSdkTree:
      let sdkRoot = base + "/.patrol6/android-sdk-local"
      let newest = Set(
        collectAndroidSdkTrees(under: sdkRoot)
          .sorted { $0.touched != $1.touched ? $0.touched > $1.touched : $0.path > $1.path }
          .prefix(keepNewestAndroidTrees)
          .map(\.path))
      guard real.hasPrefix(sdkRoot + "/"), !newest.contains(real) else {
        return refuse(
          "That Android SDK tree is now one of the \(keepNewestAndroidTrees) newest builds, so I kept it."
        )
      }
    case .shutdownSimulatorData:
      let deviceDir = parentPath(real)
      guard leaf(real) == "data", shutdownSimulatorInfo(deviceDir: deviceDir) != nil else {
        return refuse("That Simulator booted up or changed state, so I left it alone.")
      }
    case .offlineAndroidAvd:
      guard real.hasSuffix(".avd"), !hasAvdLock(real) else {
        return refuse("That Android emulator is locked by a running instance, so I left it alone.")
      }
    case .deadAgentScratch:
      let threads = AgentThreads.index(home: base)
      let liveIDs = Set(
        threads.filter(\.live).map { t -> String in
          if let colon = t.id.firstIndex(of: ":") {
            return String(t.id[t.id.index(after: colon)...])
          }
          return t.id
        })
      guard !matchesLiveSession(name: leaf(real), path: real, threads: threads, liveIDs: liveIDs)
      else {
        return refuse("An active agent session is using that scratch folder, so I left it alone.")
      }
    case .orphanedRecovery:
      let referenced = referencedRecoveryDirectories(root: root)
      guard !referenced.contains(real) else {
        return refuse("A recovery receipt references that snapshot, so I left it alone.")
      }
    }

    switch inUse(real) {
    case 0: break
    case 1: return refuse("Something is using that folder right now, so I left it alone.")
    default: return refuse("I couldn't tell if something is using that folder, so I left it alone.")
    }
    guard authorize() else {
      return refuse("Permissions changed before cleanup, so I left it alone.")
    }
    var verify = stat()
    guard lstat(real, &verify) == 0, verify.st_ino == original.st_ino,
      verify.st_dev == original.st_dev
    else {
      return refuse("That folder changed while checking it, so I left it alone.")
    }

    let bytes = AutopilotDisk.allocatedSize(real) ?? item.bytes
    do {
      try keepingParentTime(of: real) {
        try FileManager.default.removeItem(atPath: real)
      }
    } catch {
      return AutopilotReceipt(
        itemID: item.id, kind: item.kind, name: item.name, authority: authority, outcome: "failed",
        detail: "I couldn't remove all of \(item.name), so some of it is still there.")
    }
    guard !exists(real) else {
      return AutopilotReceipt(
        itemID: item.id, kind: item.kind, name: item.name, authority: authority, outcome: "failed",
        detail: "\(item.name) is still there, so I'm not counting it as burned.")
    }
    return AutopilotReceipt(
      itemID: item.id, kind: item.kind, name: item.name, authority: authority, outcome: "burned",
      detail: "Cleared \(item.name). Your tools will rebuild it when they need it.",
      bytes: bytes)
  }

  // MARK: - Helpers

  private static func scanSignatures(
    under root: String, maxDepth: Int, home: String, visited: inout Set<String>,
    yield: (String, SignatureKind, Date) -> Void
  ) {
    var queue: [(path: String, depth: Int)] = [(root, 0)]
    var inspected = 0
    while !queue.isEmpty, inspected < 600 {
      let (dir, depth) = queue.removeFirst()
      guard visited.insert(dir).inserted else { continue }
      inspected += 1
      if depth > 0, let sig = inspectSignature(at: dir, home: home), let touched = modifiedDate(dir)
      {
        yield(dir, sig, touched)
        continue
      }
      guard depth < maxDepth,
        let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
      else { continue }
      for name in names.sorted().prefix(128) where name != ".git" && !name.hasPrefix(".Trash") {
        let child = dir + "/" + name
        guard isOwnedDirectory(child), !exists(child + "/.git") else { continue }
        queue.append((child, depth + 1))
      }
    }
  }

  private static func collectAndroidSdkTrees(under sdkRoot: String) -> [(
    path: String, touched: Date
  )] {
    var results: [(path: String, touched: Date)] = []
    let level1 = (try? FileManager.default.contentsOfDirectory(atPath: sdkRoot)) ?? []
    for name1 in level1.sorted().prefix(64) {
      let p1 = sdkRoot + "/" + name1
      guard isOwnedDirectory(p1) else { continue }
      if isAndroidSdkDirectory(p1), let touched = modifiedDate(p1) {
        results.append((p1, touched))
        continue
      }
      let level2 = (try? FileManager.default.contentsOfDirectory(atPath: p1)) ?? []
      for name2 in level2.sorted().prefix(64) {
        let p2 = p1 + "/" + name2
        guard isOwnedDirectory(p2), isAndroidSdkDirectory(p2), let touched = modifiedDate(p2) else {
          continue
        }
        results.append((p2, touched))
      }
    }
    return results
  }

  private static func isAndroidSdkDirectory(_ path: String) -> Bool {
    (isOwnedDirectory(path + "/platforms") && isOwnedDirectory(path + "/build-tools"))
      || (isOwnedDirectory(path + "/platform-tools") && isOwnedDirectory(path + "/build-tools"))
  }

  private static func shutdownSimulatorInfo(deviceDir: String) -> (name: String, state: Int)? {
    let plistPath = deviceDir + "/device.plist"
    guard isRegularFile(plistPath),
      let data = FileManager.default.contents(atPath: plistPath), data.count <= 65_536,
      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil))
        as? [String: Any],
      let state = plist["state"] as? Int, state == 1
    else { return nil }
    let name = (plist["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (name: (name?.isEmpty == false ? name! : leaf(deviceDir)), state: state)
  }

  private static func hasAvdLock(_ path: String) -> Bool {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
      return true
    }
    return names.contains { $0.hasSuffix(".lock") }
  }

  private static func referencedRecoveryDirectories(root: URL) -> Set<String> {
    let receiptsURL = root.appendingPathComponent("autopilot/receipts.json")
    guard let data = try? Store(root: root).read(receiptsURL, limit: 4 * 1_048_576),
      let receipts = try? JSONDecoder().decode([AutopilotReceipt].self, from: data)
    else { return [] }
    return Set(
      receipts.compactMap { $0.restore?.recovery?.directory }.map(WorkspaceSafety.canonical))
  }

  private static func matchesLiveSession(
    name: String, path: String, threads: [AgentThread], liveIDs: Set<String>
  ) -> Bool {
    if liveIDs.contains(name) { return true }
    let stripped = name.hasPrefix("claude-") ? String(name.dropFirst(7)) : name
    if !stripped.isEmpty, liveIDs.contains(stripped) { return true }
    if liveIDs.contains(where: { !$0.isEmpty && name.contains($0) }) { return true }
    return AgentThreads.state(for: path, threads: threads).thread == "live"
  }

  private static func allowedLocation(
    _ real: String, home: String, tempRoots: [String], recoveryRoot: URL,
    protected: ProtectedLocations
  ) -> Bool {
    if protected.resolution(real).place != nil { return false }
    let recoveryDir = WorkspaceSafety.canonical(recoveryRoot.appendingPathComponent("recovery").path)
    if real.hasPrefix(recoveryDir + "/") { return true }
    if tempRoots.contains(where: { !$0.isEmpty && $0 != "/" && real.hasPrefix($0 + "/") }) {
      return true
    }
    guard real.hasPrefix(home + "/") else { return false }
    let relative = String(real.dropFirst(home.count + 1)).lowercased()
    return !excluded.contains {
      relative == $0.lowercased() || relative.hasPrefix($0.lowercased() + "/")
    }
  }

  private static func keepingParentTime(of path: String, _ remove: () throws -> Void) rethrows {
    let parent = parentPath(path)
    var before = stat()
    let directory = lstat(parent, &before) == 0 && before.st_mode & S_IFMT == S_IFDIR
    defer {
      if directory {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), before.st_mtimespec]
        _ = utimensat(AT_FDCWD, parent, &times, AT_SYMLINK_NOFOLLOW)
      }
    }
    try remove()
  }

  private static func isOwnedDirectory(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
  }

  private static func isRegularFile(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
  }

  private static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private static func modifiedDate(_ path: String) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return AutopilotDisk.changed(info)
  }

  private static func parentPath(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return slash == path.startIndex ? "/" : String(path[..<slash])
  }

  private static func leaf(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  private static func relativeLabel(_ path: String, under root: String) -> String {
    path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : leaf(path)
  }

  private static func abbreviate(_ path: String, home: String) -> String {
    path.hasPrefix(home + "/") ? "~/" + String(path.dropFirst(home.count + 1)) : path
  }

  private static func staleBucket(since date: Date, now: Date) -> String {
    switch now.timeIntervalSince(date) / 86_400 {
    case ..<1: return "today"
    case ..<7: return "day"
    case ..<30: return "week"
    case ..<90: return "month"
    default: return "older"
    }
  }

  private static func byteScale(_ bytes: UInt64) -> String {
    bytes < 1_000_000_000 ? "medium" : bytes < 10_000_000_000 ? "large" : "huge"
  }
}
