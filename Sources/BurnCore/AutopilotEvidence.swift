import Foundation

/// File access is bound to a current catalog item. Harnesses receive the same useful project
/// evidence through this boundary instead of general-purpose file-reading tools.
public enum AutopilotEvidence {
  private static let manifests: Set<String> = [
    "package.json", "package-lock.json", "pnpm-lock.yaml",
    "yarn.lock", "Package.swift", "Cargo.toml", "pyproject.toml", "requirements.txt",
    "build.gradle",
    "build.gradle.kts", "CMakeLists.txt", "Podfile", "Gemfile", "tsconfig.json", "manifest.json",
  ]
  static func root(_ item: AutopilotItem, protected: ProtectedLocations) -> String? {
    let path: String?
    if item.kind == .process {
      let native = Native()
      guard let pid = item.pid, case .found(let process) = native.probe(pid),
        process.identity.key == item.processKey
      else { return nil }
      path = native.currentDirectory(pid)
    } else {
      path = item.path.map { item.kind == .disk ? ($0 as NSString).deletingLastPathComponent : $0 }
    }
    guard let path, protected.resolution(path).place == nil, path != "/", path != NSHomeDirectory(),
      path == WorkspaceSafety.canonical(path)
    else { return nil }
    return path
  }
  public static func read(
    _ item: AutopilotItem, relativePath: String, protected: ProtectedLocations = .limited()
  ) -> [String: String] {
    let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    let name = parts.last.map(String.init) ?? ""
    guard !relativePath.isEmpty, relativePath.utf8.count <= 512,
      !relativePath.contains("\0"), !relativePath.contains("\\"),
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }),
      manifests.contains(name) || name.lowercased() == "readme.md" || name.lowercased() == "readme",
      let root = root(item, protected: protected)
    else { return ["error": "Use a project manifest or README inside this exact item's project."] }
    let path = root + "/" + relativePath
    guard protected.resolution(path).place == nil else {
      return ["error": "macOS protects this location."]
    }
    guard WorkspaceSafety.contains(root, path), path == WorkspaceSafety.canonical(path),
      let text = DiskDiscovery.manifest(path)
    else {
      return ["error": "Evidence is unavailable, private, linked or oversized."]
    }
    return [relativePath: text]
  }
  static func overview(_ item: AutopilotItem, protected: ProtectedLocations) -> String {
    var parts: [String] = []
    for name in [
      "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "build.gradle.kts",
      "README.md",
    ] {
      let value = read(item, relativePath: name, protected: protected)
      if let text = value[name] { parts.append(name + ":\n" + text) }
      if parts.count == 3 { break }
    }
    return parts.joined(separator: "\n")
  }
}
