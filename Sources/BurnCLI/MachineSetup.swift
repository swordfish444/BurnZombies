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
    guard
      ["auto", "all", "none"].contains(selected)
        || MachineReviewConfiguration.harnesses.contains(selected)
    else {
      throw StoreError.message("Choose auto, codex, claude, cursor, copilot or gemini.")
    }
    let root = try value("--root").map { URL(fileURLWithPath: $0) } ?? Store.defaultRoot
    if selected == "none" {
      if var config = try MachineReviewConfiguration.load(root: root) {
        config.enabled = false
        try config.save(root: root)
      }
      print("Background reviews off. The app can still observe this Mac.")
      return
    }
    let old = try MachineReviewConfiguration.load(root: root)
    // A reinstall never switches a previously selected provider, including when it is unavailable.
    let choices =
      selected == "auto" || selected == "all"
      ? old.map { [$0.harness] } ?? ["claude", "codex"] : [selected]
    guard let harness = choices.first(where: { MachineReviewConfiguration.detect($0) != nil }),
      let executable = MachineReviewConfiguration.detect(harness)
    else {
      throw StoreError.message(
        "No selected harness CLI is available. Install/sign in to the selected harness (Codex or Claude Code for current supported setup), then run setup again. Nothing changed."
      )
    }
    // Establish migration only after read-only prerequisites pass.
    _ = try IntentLedger.migrate(root: root)
    let launcher = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .resolvingSymlinksInPath()
    var config = MachineReviewConfiguration(
      harness: harness, executable: executable, launcher: launcher.path,
      server: launcher.deletingLastPathComponent().appendingPathComponent("burnzombies-mcp").path)
    if let old {
      config.enabled = old.enabled
      config.huntIntervalHours = old.huntIntervalHours
      if old.harness == harness {
        config.model = old.model
        config.reasoningEffort = old.reasoningEffort
      }
    }
    if let model = try value("--model") {
      config.model = MachineReviewConfiguration.selectionValue(model)
    }
    if let thinking = try value("--thinking") {
      config.reasoningEffort = MachineReviewConfiguration.selectionValue(thinking)
    }
    if args.contains("--observe-only") { config.enabled = false }
    try config.save(root: root)
    print(
      config.enabled
        ? "BurnZombies Autopilot will sweep this Mac every 15 minutes, using \(harness) to judge new leftovers."
        : "BurnZombies is configured for \(harness). AI reviews are off; native observation remains available."
    )
    print(
      "No active chat, chat hooks, computer restart or edits to harness configuration required.")
    print(
      "Reviews use your existing harness login and usage allowance. One provider; no automatic fallback."
    )
    print(
      "Autopilot burns leftovers on its own with safe starter rules and what you teach it in Teach BZ. Old copies are always restorable. Turn it off in Settings → Autopilot."
    )
    print(
      "Model: \(config.model ?? "harness default") · Thinking: \(config.reasoningEffort ?? "harness default"). Change these in Settings."
    )
    print(
      "Full Disk Access is optional: System Settings → Privacy & Security → Full Disk Access → add and enable BurnZombies.app."
    )
    print(
      "Without it BurnZombies covers everything except the places macOS protects (Desktop, Documents, Downloads, iCloud Drive, Mail, Messages, Photos, other apps' data and external drives). With it, use Allow Full Disk Access in the menu-bar banner and return to BurnZombies for an access check; it adds those places and AI hunts."
    )
  }
}
