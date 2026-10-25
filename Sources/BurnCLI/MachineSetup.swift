import BurnCore
import Foundation

enum MachineSetup {
  static func run(_ args: [String]) throws {
    func value(_ flag: String) throws -> String? {
      guard let i = args.firstIndex(of: flag) else { return nil }
      guard i + 1 < args.count else { throw StoreError.message("Missing \(flag) value.") }
      return args[i + 1]
    }
    let selected = try value("--harness") ?? "auto"
    guard ["auto", "all", "none"].contains(selected) || MachineReviewConfiguration.harnesses.contains(selected) else {
      throw StoreError.message("Choose auto, codex, claude, cursor, copilot or gemini.")
    }
    let root = try value("--root").map { URL(fileURLWithPath: $0) } ?? Store.defaultRoot
    if selected == "none" {
      if var config = try MachineReviewConfiguration.load(root: root) { config.enabled = false; try config.save(root: root) }
      print("Background reviews off. The app can still observe this Mac."); return
    }
    let old = try MachineReviewConfiguration.load(root: root)
    // A reinstall never switches a previously selected provider, including when it is unavailable.
    let choices = selected == "auto" || selected == "all" ? old.map { [$0.harness] } ?? MachineReviewConfiguration.harnesses : [selected]
    guard let harness = choices.first(where: { MachineReviewConfiguration.detect($0) != nil }),
      let executable = MachineReviewConfiguration.detect(harness) else {
      throw StoreError.message("No selected harness CLI is available. Install/sign in to Codex, Claude Code, Cursor CLI, Copilot CLI or Gemini CLI, then run setup again. Nothing changed.")
    }
    let launcher = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    var config = MachineReviewConfiguration(harness: harness, executable: executable, launcher: launcher.path,
      server: launcher.deletingLastPathComponent().appendingPathComponent("burnzombies-mcp").path)
    if let old { config.enabled = old.enabled }
    try config.save(root: root)
    print("BurnZombies will watch this Mac across all projects and sessions, using \(harness) for bounded background reviews.")
    print("No active chat, chat hooks, computer restart or edits to harness configuration required.")
    print("Reviews use your existing harness login and usage allowance. One provider; no automatic fallback.")
  }
}
