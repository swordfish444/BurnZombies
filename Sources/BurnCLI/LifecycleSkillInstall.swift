import BurnCore
import CryptoKit
import Foundation

/// Instruction-only installation: never changes hooks, MCP settings, permissions or account configuration.
enum LifecycleSkillInstall {
  /// Retire only byte-verified installer-owned instructions. Customized files and
  /// symlinks are preserved. New installations never add a globally triggered skill.
  static func retire(_ args: [String]) throws {
    let home: URL
    if let i = args.firstIndex(of: "--home"), i + 1 < args.count { home = URL(fileURLWithPath: args[i + 1]) }
    else { home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURNZOMBIES_SKILL_HOME"] ?? NSHomeDirectory()) }
    let fm = FileManager.default
    var removals: [(URL, URL, Data)] = []
    for base in [".agents", ".claude", ".cursor", ".copilot", ".gemini"] {
      let directory = home.appendingPathComponent(base + "/skills/burnzombies")
      let file = directory.appendingPathComponent("SKILL.md"), marker = directory.appendingPathComponent(".burnzombies-sha256")
      guard fm.fileExists(atPath: file.path) else { continue }
      for path in [home.appendingPathComponent(base), home.appendingPathComponent(base + "/skills"), directory, file, marker] {
        guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
          throw StoreError.message("Customized skill symlink preserved: \(path.path)")
        }
      }
      let data = try Data(contentsOf: file)
      let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard data.count <= 65536, (try? String(contentsOf: marker, encoding: .utf8)) == hash else {
        throw StoreError.message("Customized skill preserved: \(file.path). Remove its automatic trigger manually to eliminate per-chat overhead.")
      }
      removals.append((file, marker, data))
    }
    if args.contains("--check") { return }
    for (file, marker, data) in removals {
      guard try Data(contentsOf: file) == data else { throw StoreError.message("Skill changed during retirement; preserved.") }
      // Keep an inert recovery copy outside skill discovery. Never delete extra user files.
      try data.write(to: file.deletingLastPathComponent().appendingPathComponent("retired-instructions.txt"), options: .atomic)
      try fm.removeItem(at: file); try fm.removeItem(at: marker)
    }
    print("Passive observation configured. No automatic BurnZombies instructions in working chats.")
  }
  static func run(_ args: [String]) throws {
    func option(_ flag: String) throws -> String? {
      guard let i = args.firstIndex(of: flag) else { return nil }
      guard i + 1 < args.count else { throw StoreError.message("Missing \(flag).") }
      return args[i + 1]
    }
    let home = URL(fileURLWithPath: try option("--home") ?? ProcessInfo.processInfo.environment["BURNZOMBIES_SKILL_HOME"] ?? NSHomeDirectory())
    let cli = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let bundled = cli.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/burnzombies/SKILL.md")
    let source = try String(contentsOfFile: option("--skill-file") ?? bundled.path, encoding: .utf8)
    let prefix = ProcessInfo.processInfo.environment["BURNZOMBIES_HOME"].map { "BURNZOMBIES_HOME=" + HarnessInstall.quoted($0) + " " } ?? ""
    let command = prefix + HarnessInstall.quoted(cli.path)
    let text = source + "\n## Installed native command\n\n```sh\n" + command + " workspace <<'BZ_WORKSPACE_JSON'\n{\"action\":\"create\",\"repository\":\"/absolute/repository\",\"label\":\"Task workspace\",\"evidence\":\"This task needs an isolated disposable workspace.\",\"completion_condition\":\"Work is finished, preserved and has no remaining consumers.\"}\nBZ_WORKSPACE_JSON\n" + command + " evidence PID\n" + command + " lifecycle <<'BZ_LIFECYCLE_JSON'\n{\"action\":\"release\",\"work_token\":\"your returned token\",\"evidence\":\"Your observed completion facts.\"}\nBZ_LIFECYCLE_JSON\n```\n"
    let data = Data(text.utf8), fm = FileManager.default
    let legacy: Set<String> = ["7770618dbd9bfa68af922bcae491aa7e8ae6365640920ca94a17ce183c61dd83", "a430105c72b745b391e911b7e113c8f0418e7d6cb30eecdbcbea0660fc280259"]
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var roots = [".agents", ".claude"]
    // Refresh historical copies only if present; shared .agents covers Cursor, Copilot and Gemini.
    roots += [".cursor", ".copilot", ".gemini"].filter { fm.fileExists(atPath: home.appendingPathComponent($0 + "/skills/burnzombies/SKILL.md").path) }
    var edits: [(URL, Data?)] = []
    for root in roots {
      let directory = home.appendingPathComponent(root + "/skills/burnzombies")
      for part in [home.appendingPathComponent(root), home.appendingPathComponent(root + "/skills"), directory] {
        if (try? part.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw StoreError.message("Skill symlink preserved: \(part.path)") }
      }
      let file = directory.appendingPathComponent("SKILL.md"), marker = directory.appendingPathComponent(".burnzombies-sha256")
      for item in [file, marker] {
        if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw StoreError.message("Skill symlink preserved: \(item.path)") }
      }
      let old = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
      if let old, old != data {
        let hash = digest(old)
        let managed = try? String(contentsOf: marker, encoding: .utf8)
        guard old.count <= 65536, legacy.contains(hash) || managed == hash else {
          throw StoreError.message("Customized BurnZombies skill preserved at \(file.path). Merge its changes before installing the lifecycle skill.")
        }
      }
      edits.append((file, old))
    }
    if args.contains("--check") { print("Lifecycle skill installation preflight passed."); return }
    var changed: [(URL, Data?, Data?)] = []
    do {
      for (file, old) in edits {
        let marker = file.deletingLastPathComponent().appendingPathComponent(".burnzombies-sha256")
        let oldMarker = try? Data(contentsOf: marker)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Re-read just before writing; do not overwrite an intervening user edit.
        let now = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard now == old else { throw StoreError.message("Skill changed during install; preserved.") }
        changed.append((file, old, oldMarker))
        try data.write(to: file, options: .atomic)
        try Data(digest(data).utf8).write(to: marker, options: .atomic)
        for path in [file, marker] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
      }
    } catch {
      for (file, old, marker) in changed.reversed() {
        if let old { try? old.write(to: file, options: .atomic) } else { try? fm.removeItem(at: file) }
        let path = file.deletingLastPathComponent().appendingPathComponent(".burnzombies-sha256")
        if let marker { try? marker.write(to: path, options: .atomic) } else { try? fm.removeItem(at: path) }
      }
      throw error
    }
    print("Lifecycle skill installed for local Codex, Claude Code, Cursor, Copilot and Gemini discovery. No hooks or harness config edits. Existing chats use their normal skill refresh; invocation and permissions remain with the harness.")
  }
}
