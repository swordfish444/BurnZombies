import Foundation

/// The owner's one list of what BZ never touches. Rules, the AI and Burn now all stop here.
extension AutopilotPolicy {
  /// Plain text, because `decide` runs for every item: listed paths are canonical when added.
  static func inside(_ path: String, _ folder: String) -> Bool {
    path == folder || folder == "/" || path.hasPrefix(folder + "/")
  }

  /// What's inside a listed folder stays. So does what holds one: burning an old copy would take
  /// the listed folder with it.
  public static func neverTouched(_ item: AutopilotItem, memory: AutopilotMemory) -> Bool {
    guard !memory.neverTouch.isEmpty, let path = item.path else { return false }
    return memory.neverTouch.contains { inside(path, $0) || inside($0, path) }
  }
}

extension Autopilot {
  static let neverTouchHold = "You told me never to touch this."

  /// Disk cleanup is gone: its cleaner stays off, its daily cap and goals with it, and what the
  /// owner protected there moves onto Never touches, where Autopilot obeys it.
  public static func retireDiskCleanup(root: URL = Store.defaultRoot) throws {
    let store = try Store(root: root)
    var policy = try DiskPolicy.load(store)
    guard policy.mode != "off" || !policy.protectedPaths.isEmpty || !policy.rules.isEmpty else {
      return
    }
    let kept = policy.protectedPaths + policy.rules.filter { $0.disposition == "keep" }.map(\.path)
    if !kept.isEmpty {
      try AutopilotStore(root: root).updateMemory { memory in
        memory.neverTouch = Array(Set(memory.neverTouch).union(kept)).sorted()
      }
    }
    policy.mode = "off"
    policy.protectedPaths = []
    policy.rules = []
    try policy.save(store)
  }
}
