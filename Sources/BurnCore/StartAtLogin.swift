import Foundation

/// Start at login. A fresh install turns it on so Autopilot keeps running after a restart; from
/// then on only the person changes it. The decision is a small file beside BZ's other state, so
/// updates keep it and deleting BZ's folder forgets it.
public enum StartAtLogin {
  public enum Outcome: Equatable, Sendable {
    /// A fresh install: BZ now starts at login.
    case registered
    /// A fresh install macOS refused to register. Settings can try again.
    case refused(String)
    /// Decided before, or an update from a version that never asked: nothing changed.
    case unchanged
  }
  struct Choice: Codable { var enabled: Bool }
  static func url(_ root: URL) -> URL { root.appendingPathComponent("start-at-login.json") }

  /// The recorded choice; nil until a launch has decided.
  public static func recorded(root: URL) -> Bool? {
    let url = url(root)
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Store(root: root).read(url, limit: 4096)
    else { return nil }
    return (try? JSONDecoder().decode(Choice.self, from: data))?.enabled
  }

  /// Decides once per install, on its first launch. Call it before the observer saves its first
  /// catalog: a catalog with no recorded choice is an install from before this setting existed.
  /// Nothing says whether that person switched it off, so the Mac's current setting stays.
  public static func decideAtLaunch(
    root: URL, isEnabled: () -> Bool, register: () throws -> Void
  ) -> Outcome {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: url(root).path) else { return .unchanged }
    let catalog = root.appendingPathComponent("catalog.bzcat")
    // A reinstall can find the login item still there from before.
    let already = isEnabled()
    if fm.fileExists(atPath: catalog.path) || already {
      try? record(already, root: root)
      return .unchanged
    }
    do {
      try register()
    } catch {
      try? record(false, root: root)
      return .refused(error.localizedDescription)
    }
    try? record(true, root: root)
    return .registered
  }

  /// The switch in Settings. The choice is recorded only after macOS made the change.
  public static func choose(
    _ enabled: Bool, root: URL, register: () throws -> Void, unregister: () throws -> Void
  ) throws {
    if enabled {
      try register()
    } else {
      try unregister()
    }
    try? record(enabled, root: root)
  }

  /// Only the installed app changes this Mac's login items: a debug build has no app to start,
  /// and an isolated BZ home belongs to a test.
  public static func applies(bundle: URL, environment: [String: String]) -> Bool {
    bundle.pathExtension == "app" && environment["BURNZOMBIES_HOME"] == nil
  }

  static func record(_ enabled: Bool, root: URL) throws {
    let data = try JSONEncoder().encode(Choice(enabled: enabled))
    try Store(root: root).write(data, to: url(root), limit: 4096)
  }
}
