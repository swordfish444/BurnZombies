import Darwin
import Foundation

/// Local SDK build snapshot rings and isolated shared Gradle caches under developer dot-stores
/// (`~/.*/*-local`). Keeps the newest 3 snapshots per artifact (and anything under 7 days old),
/// plus the newest Gradle version directory per consumer, while surfacing older multi-hundred-MB
/// leftovers under existing `build-output` and `package-cache` subjects.
public enum AutopilotBuildRings {
  public static let keepSnapshots = 3
  public static let minimumAge: TimeInterval = 7 * 86_400
  private static let entryLimit = 500

  private static let excludedDots: Set<String> = [
    ".trash", ".ssh", ".gnupg", ".local", ".claude", ".codex", ".gemini", ".git", ".npm",
    ".cache", ".gradle", ".config", ".cups",
  ]

  public struct Target: Sendable, Equatable {
    public var path: String
    public var folder: String
    public var name: String
    public var subject: String
    public var modified: Date
  }

  /// Eligible snapshot and Gradle cache directories across `~/.*/*-local`, plus sibling paths
  /// intentionally retained so previously cached observations are discarded if they become active.
  public static func discover(
    home: String, now: Date = Date(), protected: ProtectedLocations = .limited()
  ) -> (targets: [Target], discarded: Set<String>) {
    let base = WorkspaceSafety.canonical(home)
    guard base.hasPrefix("/"), base != "/",
      let homeEntries = try? FileManager.default.contentsOfDirectory(atPath: base)
    else { return ([], []) }

    var targets: [Target] = []
    var discarded = Set<String>()

    for dot in homeEntries.sorted().prefix(entryLimit)
    where dot.hasPrefix(".") && dot.count > 1 && !excludedDots.contains(dot.lowercased()) {
      let dotPath = base + "/" + dot
      guard validDirectory(dotPath, home: base, protected: protected),
        let dotChildren = try? FileManager.default.contentsOfDirectory(atPath: dotPath)
      else { continue }

      for ring in dotChildren.sorted().prefix(entryLimit) where ring.hasSuffix("-local") {
        let ringPath = dotPath + "/" + ring
        guard validDirectory(ringPath, home: base, protected: protected),
          !exists(ringPath + "/.git"),
          let ringEntries = try? FileManager.default.contentsOfDirectory(atPath: ringPath)
        else { continue }

        for entry in ringEntries.sorted().prefix(entryLimit) where !entry.hasPrefix(".") {
          let entryPath = ringPath + "/" + entry
          guard validDirectory(entryPath, home: base, protected: protected),
            !exists(entryPath + "/.git")
          else { continue }

          if entry == "_shared-cache" {
            let found = gradleTargets(
              sharedCache: entryPath, ringName: ring, home: base, now: now, protected: protected)
            targets += found.targets
            discarded.formUnion(found.discarded)
          } else {
            let found = snapshotTargets(
              artifactPath: entryPath, artifact: entry, ringName: ring, home: base, now: now,
              protected: protected)
            targets += found.targets
            discarded.formUnion(found.discarded)
          }
        }
      }
    }
    return (targets, discarded)
  }

  /// Recognized `folder` fact (`build-output` or `package-cache`) for a live path inside a build
  /// ring, or nil when `path` is not a verified snapshot or shared Gradle cache directory.
  public static func recognized(_ path: String, home: String) -> String? {
    let base = WorkspaceSafety.canonical(home)
    guard let parsed = parseRingPath(path, home: base) else { return nil }
    switch parsed {
    case .snapshot(let snapshotPath, _, _):
      return isSnapshot(snapshotPath) ? "build-output" : nil
    case .gradle(let entryPath, _, let entry):
      guard validPlainDirectory(entryPath, home: base),
        AutopilotGradleCaches.isCacheDirectory(entry) || entry == "build-cache"
      else { return nil }
      return "package-cache"
    }
  }

  public static func regenerable(_ path: String, home: String) -> Bool {
    recognized(path, home: home) != nil
  }

  /// Live safety rail checked again right before removal in `AutopilotDisk.reclaim`.
  /// Returns nil if `path` is not inside a build ring or still passes retention rules; returns a
  /// plain-English refusal if retention now protects it.
  public static func refusal(
    _ path: String, home: String, now: Date = Date(), protected: ProtectedLocations = .limited()
  ) -> String? {
    let base = WorkspaceSafety.canonical(home)
    guard path.hasPrefix(base + "/") else { return nil }
    let parts = String(path.dropFirst(base.count + 1)).split(
      separator: "/", omittingEmptySubsequences: false
    ).map(String.init)
    guard parts.count >= 2, parts[0].hasPrefix("."), !excludedDots.contains(parts[0].lowercased()),
      parts[1].hasSuffix("-local")
    else { return nil }

    guard let parsed = parseRingPath(path, home: base) else {
      return "That folder isn't a recognized build snapshot or cache, so I left it alone."
    }

    switch parsed {
    case .snapshot(let snapshotPath, let artifactPath, _):
      guard validDirectory(snapshotPath, home: base, protected: protected),
        isSnapshot(snapshotPath), let touched = snapshotModified(snapshotPath)
      else {
        return "That folder doesn't look like a complete local SDK snapshot, so I left it alone."
      }
      if now.timeIntervalSince(touched) < minimumAge {
        return "That local SDK build was used in the last week, so I left it alone."
      }
      let siblings = rankedSnapshots(in: artifactPath, home: base, protected: protected)
      guard let index = siblings.firstIndex(where: { $0.path == snapshotPath }) else {
        return "I couldn't check the newer local SDK builds next to it, so I left it alone."
      }
      if index < keepSnapshots {
        return
          "That's one of the \(keepSnapshots) newest local SDK builds, so I left it alone."
      }
      return nil

    case .gradle(let entryPath, let consumerPath, let entry):
      guard validDirectory(entryPath, home: base, protected: protected),
        AutopilotGradleCaches.isCacheDirectory(entry) || entry == "build-cache",
        let touched = modified(entryPath)
      else {
        return "That doesn't look like a recognized Gradle cache folder, so I left it alone."
      }
      if isVersionDirectory(entry) {
        let versions = rankedGradleVersions(in: consumerPath, home: base, protected: protected)
        guard let index = versions.firstIndex(where: { $0.path == entryPath }) else {
          return "I couldn't check which Gradle version is newest there, so I left it alone."
        }
        if index == 0 {
          return "That's the newest Gradle cache in that build store, so I left it alone."
        }
        if now.timeIntervalSince(touched) < 86_400 {
          return "That Gradle cache was used today, so I left it alone."
        }
        return nil
      }
      if now.timeIntervalSince(touched) < minimumAge {
        return "That shared Gradle cache was used in the last week, so I left it alone."
      }
      return nil
    }
  }

  // MARK: - Ring Layout

  private enum RingEntry {
    case snapshot(path: String, artifactPath: String, artifact: String)
    case gradle(path: String, consumerPath: String, entry: String)
  }

  private static func parseRingPath(_ path: String, home: String) -> RingEntry? {
    guard path.hasPrefix(home + "/") else { return nil }
    let parts = String(path.dropFirst(home.count + 1)).split(
      separator: "/", omittingEmptySubsequences: false
    ).map(String.init)
    guard parts.count >= 4, parts[0].hasPrefix("."), parts[0].count > 1,
      !excludedDots.contains(parts[0].lowercased()), parts[1].hasSuffix("-local")
    else { return nil }

    let ringPath = home + "/" + parts[0] + "/" + parts[1]
    guard !exists(ringPath + "/.git") else { return nil }

    if parts[2] == "_shared-cache" {
      guard parts.count == 6, parts[3] == "gradle", !parts[4].isEmpty, !parts[5].isEmpty else {
        return nil
      }
      let consumerPath = ringPath + "/_shared-cache/gradle/" + parts[4]
      return .gradle(path: path, consumerPath: consumerPath, entry: parts[5])
    }

    guard parts.count == 4, !parts[2].hasPrefix("."), !parts[3].hasPrefix(".") else {
      return nil
    }
    let artifactPath = ringPath + "/" + parts[2]
    return .snapshot(path: path, artifactPath: artifactPath, artifact: parts[2])
  }

  private static func snapshotTargets(
    artifactPath: String, artifact: String, ringName: String, home: String, now: Date,
    protected: ProtectedLocations
  ) -> (targets: [Target], discarded: Set<String>) {
    let ranked = rankedSnapshots(in: artifactPath, home: home, protected: protected)
    var targets: [Target] = []
    var discarded = Set<String>()
    for (index, snapshot) in ranked.enumerated() {
      if index < keepSnapshots || now.timeIntervalSince(snapshot.modified) < minimumAge {
        discarded.insert(snapshot.path)
        continue
      }
      let label = shortLabel(snapshot.name)
      targets.append(
        Target(
          path: snapshot.path, folder: "build-output",
          name: "\(artifact) snapshot \(label) in \(ringName)", subject: artifact,
          modified: snapshot.modified))
    }
    return (targets, discarded)
  }

  private static func rankedSnapshots(
    in artifactPath: String, home: String, protected: ProtectedLocations
  ) -> [(path: String, name: String, modified: Date)] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: artifactPath) else {
      return []
    }
    var snapshots: [(path: String, name: String, modified: Date)] = []
    for name in names.sorted().prefix(entryLimit) where !name.hasPrefix(".") {
      let path = artifactPath + "/" + name
      guard validDirectory(path, home: home, protected: protected), !exists(path + "/.git"),
        isSnapshot(path), let touched = snapshotModified(path)
      else { continue }
      snapshots.append((path: path, name: name, modified: touched))
    }
    return snapshots.sorted {
      $0.modified != $1.modified ? $0.modified > $1.modified : $0.name > $1.name
    }
  }

  private static func gradleTargets(
    sharedCache: String, ringName: String, home: String, now: Date, protected: ProtectedLocations
  ) -> (targets: [Target], discarded: Set<String>) {
    let gradleRoot = sharedCache + "/gradle"
    guard validDirectory(gradleRoot, home: home, protected: protected),
      let consumers = try? FileManager.default.contentsOfDirectory(atPath: gradleRoot)
    else { return ([], []) }

    var targets: [Target] = []
    var discarded = Set<String>()

    for consumer in consumers.sorted().prefix(entryLimit) where !consumer.hasPrefix(".") {
      let consumerPath = gradleRoot + "/" + consumer
      guard validDirectory(consumerPath, home: home, protected: protected),
        let entries = try? FileManager.default.contentsOfDirectory(atPath: consumerPath)
      else { continue }

      let versions = rankedGradleVersions(in: consumerPath, home: home, protected: protected)
      let newestVersion = versions.first?.path

      for entry in entries.sorted().prefix(entryLimit) {
        let entryPath = consumerPath + "/" + entry
        guard AutopilotGradleCaches.isCacheDirectory(entry) || entry == "build-cache" else {
          continue
        }
        guard validDirectory(entryPath, home: home, protected: protected),
          let touched = modified(entryPath)
        else { continue }

        if isVersionDirectory(entry) {
          if entryPath == newestVersion || now.timeIntervalSince(touched) < 86_400 {
            discarded.insert(entryPath)
            continue
          }
        } else if now.timeIntervalSince(touched) < minimumAge {
          discarded.insert(entryPath)
          continue
        }

        let baseLabel =
          entry == "build-cache"
          ? "Gradle build cache"
          : (AutopilotGradleCaches.displayName(entry) ?? entry)
        targets.append(
          Target(
            path: entryPath, folder: "package-cache",
            name: "\(baseLabel) (\(consumer) in \(ringName))", subject: "Gradle",
            modified: touched))
      }
    }
    return (targets, discarded)
  }

  private static func rankedGradleVersions(
    in consumerPath: String, home: String, protected: ProtectedLocations
  ) -> [(path: String, entry: String, modified: Date)] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: consumerPath) else {
      return []
    }
    var versions: [(path: String, entry: String, modified: Date)] = []
    for entry in entries where isVersionDirectory(entry) {
      let path = consumerPath + "/" + entry
      guard validDirectory(path, home: home, protected: protected), let touched = modified(path)
      else { continue }
      versions.append((path: path, entry: entry, modified: touched))
    }
    return versions.sorted { a, b in
      let av = versionTuple(a.entry)
      let bv = versionTuple(b.entry)
      if a.modified != b.modified { return a.modified > b.modified }
      return av != bv ? av > bv : a.entry > b.entry
    }
  }

  // MARK: - Markers & Helpers

  private static func isSnapshot(_ path: String) -> Bool {
    guard regularFile(path + "/manifest.json") else { return false }
    if regularFile(path + "/init.gradle") || regularFile(path + "/init.gradle.kts") { return true }
    for folder in ["consumers", "repo", "m2"] where plainDirectory(path + "/" + folder) {
      return true
    }
    guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else {
      return false
    }
    for child in children.prefix(64) {
      let childPath = path + "/" + child
      if hasArtifactExtension(child) && regularFile(childPath) { return true }
      if plainDirectory(childPath),
        let nested = try? FileManager.default.contentsOfDirectory(atPath: childPath)
      {
        if nested.prefix(64).contains(where: {
          hasArtifactExtension($0) && regularFile(childPath + "/" + $0)
        }) {
          return true
        }
      }
    }
    return false
  }

  private static func hasArtifactExtension(_ name: String) -> Bool {
    name.hasSuffix(".pom") || name.hasSuffix(".aar") || name.hasSuffix(".jar")
  }

  /// Newest modification across the snapshot root, its manifest, and immediate consumer folders.
  public static func snapshotModified(_ path: String) -> Date? {
    guard var newest = modified(path) else { return nil }
    if let manifest = modified(path + "/manifest.json") { newest = max(newest, manifest) }
    let consumers = path + "/consumers"
    if plainDirectory(consumers),
      let names = try? FileManager.default.contentsOfDirectory(atPath: consumers)
    {
      for name in names.prefix(64) {
        let consumer = consumers + "/" + name
        if let touched = modified(consumer) { newest = max(newest, touched) }
        if let gradle = modified(consumer + "/gradle-home") { newest = max(newest, gradle) }
      }
    }
    return newest
  }

  private static func isVersionDirectory(_ name: String) -> Bool {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    return (2...3).contains(parts.count)
      && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
  }

  private static func versionTuple(_ name: String) -> (Int, Int, Int) {
    let nums = name.split(separator: ".").map { Int($0) ?? 0 }
    return (
      nums.count > 0 ? nums[0] : 0,
      nums.count > 1 ? nums[1] : 0,
      nums.count > 2 ? nums[2] : 0
    )
  }

  private static func shortLabel(_ name: String) -> String {
    name.count <= 20 ? name : String(name.prefix(16)) + "…"
  }

  private static func validDirectory(
    _ path: String, home: String, protected: ProtectedLocations
  ) -> Bool {
    guard protected.resolution(path).place == nil else { return false }
    return validPlainDirectory(path, home: home)
  }

  private static func validPlainDirectory(_ path: String, home: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
      return false
    }
    let real = WorkspaceSafety.canonical(path)
    return real == path && real.hasPrefix(home + "/")
  }

  private static func plainDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
      && WorkspaceSafety.canonical(path) == path
  }

  private static func regularFile(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
      && WorkspaceSafety.canonical(path) == path
  }

  private static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private static func modified(_ path: String) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return AutopilotDisk.changed(info)
  }
}
