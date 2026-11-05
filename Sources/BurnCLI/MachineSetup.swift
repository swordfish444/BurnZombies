import BurnCore
import Foundation

enum MachineSetup {
  static let lookOnlyLine =
    "Look-only is on: BurnZombies finds and asks but burns nothing until you choose Start burning in its menu."

  static func run(_ args: [String]) throws {
    let root = try value("--root", in: args).map { URL(fileURLWithPath: $0) } ?? Store.defaultRoot
    try setUpAI(args, root: root)
    // Look-only belongs to Autopilot, not the AI: it holds every burn with or without AI judging,
    // and only once the AI step went through, so a failed setup changes nothing.
    guard args.contains("--look-only") else { return }
    try Autopilot.setLookOnly(true, root: root)
    print(lookOnlyLine)
  }

  static func value(_ flag: String, in args: [String]) throws -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { throw StoreError.message("Missing \(flag) value.") }
    return args[i + 1]
  }

  /// Chooses the AI that judges what BZ isn't sure about, or turns AI judging off.
  static func setUpAI(_ args: [String], root: URL) throws {
    func value(_ flag: String) throws -> String? { try MachineSetup.value(flag, in: args) }
    let selected = try value("--harness") ?? "auto"
    guard
      ["auto", "all", "none"].contains(selected)
        || MachineReviewConfiguration.harnesses.contains(selected)
    else {
      throw StoreError.message("Choose auto, codex, claude, cursor, copilot or gemini.")
    }
    let cleansAnyway =
      args.contains("--look-only")
      ? "BurnZombies still finds what its rules cover and asks you about the rest."
      : "BurnZombies still burns what's clearly safe and asks you about the rest."
    if selected == "none" {
      if var config = try MachineReviewConfiguration.load(root: root) {
        config.enabled = false
        try config.save(root: root)
      }
      print("AI judging is off. " + cleansAnyway)
      return
    }
    let old = try MachineReviewConfiguration.load(root: root)
    // A reinstall never switches a previously selected provider, including when it is unavailable.
    let choices =
      selected == "auto" || selected == "all"
      ? old.map { [$0.harness] } ?? ["claude", "codex"] : [selected]
    let launcher = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      .resolvingSymlinksInPath()
    guard let harness = choices.first(where: { MachineReviewConfiguration.detect($0) != nil }),
      let executable = MachineReviewConfiguration.detect(harness)
    else {
      // A Mac without an AI command-line tool still gets BurnZombies; only a named one is required.
      guard old == nil, selected == "auto" || selected == "all" else {
        throw StoreError.message(
          "\(old.map(\.harnessName) ?? selected) isn't installed or isn't on PATH. Install it and sign in, then run setup again. Nothing changed."
        )
      }
      print(
        "No Claude Code or Codex found, so AI judging is off. \(cleansAnyway) To add AI later, install one and run: \(launcher.path) setup"
      )
      return
    }
    // Establish migration only after read-only prerequisites pass.
    _ = try IntentLedger.migrate(root: root)
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
    // A reinstall keeps AI judging as it was; only these flags change it.
    if args.contains("--observe-only") {
      config.enabled = false
    } else if args.contains("--with-ai") {
      config.enabled = true
    }
    try config.save(root: root)
    print(
      config.enabled
        ? "\(config.harnessName) judges what BurnZombies isn't sure about, with your existing login. Change the model in Settings → Review intelligence."
        : "AI judging is off. \(cleansAnyway) To turn it on: \(launcher.path) setup --with-ai"
    )
  }
}
