import Foundation

/// Gradle's independently reusable caches. A daemon using one version must not hold every
/// other version's cache, and unknown folders, keyrings and root metadata must stay intact.
public enum AutopilotGradleCaches {
  public static let relativePath = ".gradle/caches"

  /// Only recognized immediate directory names qualify. The disk scanner still verifies the
  /// directory, its ownership and links, and the cleaner still checks whether anything uses it.
  public static func isCacheDirectory(_ name: String) -> Bool {
    displayName(name) != nil
  }

  public static func displayName(_ name: String) -> String? {
    let version = name.split(separator: ".", omittingEmptySubsequences: false)
    if (2...3).contains(version.count), version.allSatisfy({ digits($0) }) {
      return "Gradle " + name + " cache"
    }
    for (prefix, label) in [
      ("build-cache-", "Gradle build cache"),
      ("jars-", "Gradle processed jars"),
      ("modules-", "Gradle downloaded packages"),
      ("transforms-", "Gradle transforms"),
    ] where name.hasPrefix(prefix) {
      let number = name.dropFirst(prefix.count)
      guard digits(number), number.first != "0" else { return nil }
      return label + " " + String(number)
    }
    return nil
  }

  /// A keep on the formerly single Gradle item remains an owner instruction for its children.
  /// This does not carry an AI judgment forward, or make the whole cache root removable again.
  public static func keepParent(
    for item: AutopilotItem, home: String = NSHomeDirectory()
  ) -> String? {
    guard item.kind == .disk, item.facts["home"] == "global-cache",
      item.facts["folder"] == "package-cache", let path = item.path
    else { return nil }
    let base = WorkspaceSafety.canonical(home)
    guard base.hasPrefix("/"), base != "/" else { return nil }
    let root = base + "/" + relativePath
    guard path.hasPrefix(root + "/"),
      isCacheDirectory(String(path.dropFirst(root.count + 1)))
    else { return nil }
    return root
  }

  private static func digits(_ value: Substring) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
  }
}
