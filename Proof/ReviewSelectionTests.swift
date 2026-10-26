import BurnCore
import Foundation

func reviewSelectionProof() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("bz-selection-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try Store(root: root)
  let legacy = Data(#"{"harness":"codex","executable":"/usr/bin/true","launcher":"/bin/true","server":"/bin/true","enabled":false}"#.utf8)
  try store.write(legacy, to: root.appendingPathComponent("machine-review.json"), limit: 8192)
  let original = try MachineReviewConfiguration.load(root: root)!
  isNil(original.model); isNil(original.reasoningEffort)
  let saved = try MachineReviewConfiguration.saveSelection(root: root, expectedHarness: "codex", model: " example-model ", thinking: "high")
  equal(saved.model, "example-model"); equal(saved.reasoningEffort, "high")
  checkFalse(saved.enabled, "Saving a model must not enable paused/disabled reviews")
  equal(try MachineReviewConfiguration.load(root: root)?.model, "example-model")
  throwsError(try MachineReviewConfiguration.saveSelection(root: root, expectedHarness: "claude", model: "other", thinking: "low"))
  equal(try MachineReviewConfiguration.load(root: root)?.model, "example-model", "Stale settings must not overwrite another provider")
  for harness in MachineReviewConfiguration.harnesses {
    var c = original; c.harness = harness; c.model = "vendor/model-v1"
    let canThink = !c.thinkingLevels.isEmpty
    c.reasoningEffort = canThink ? "high" : nil
    let args = try MachineReviewer.arguments(c, directory: root, root: root, prompt: "Bounded proof")
    let i = args.firstIndex(of: "--model")!
    equal(args[i+1], "vendor/model-v1")
    if harness == "codex" { check(args.contains("model_reasoning_effort=\"high\"")) }
    if harness == "claude" { equal(args[args.firstIndex(of: "--effort")!+1], "high") }
    if harness == "copilot" { equal(args[args.firstIndex(of: "--reasoning-effort")!+1], "high") }
    c.reasoningEffort = "unsupported"
    throwsError(try MachineReviewer.arguments(c, directory: root, root: root, prompt: "Bounded proof"))
    c.reasoningEffort = nil; c.model = nil
    let defaults = try MachineReviewer.arguments(c, directory: root, root: root, prompt: "Bounded proof")
    checkFalse(defaults.contains("--model")); checkFalse(defaults.contains("--effort"))
  }
  for invalid in ["--bypass", "model\nother", "name with spaces", "\"bad\"", String(repeating: "a", count: 161)] {
    var c = original; c.model = invalid; throwsError(try c.save(root: root))
  }
  let reset = try MachineReviewConfiguration.saveSelection(root: root, expectedHarness: "codex", model: "", thinking: "default")
  isNil(reset.model); isNil(reset.reasoningEffort); checkFalse(reset.enabled)
  let catalog = try ReviewModelOption.decode(Data(#"{"models":[{"slug":"b","display_name":"B","priority":2,"visibility":"list","supported_reasoning_levels":[{"effort":"low"}]},{"slug":"a","display_name":"A","priority":1,"visibility":"list"},{"slug":"hidden","priority":0,"visibility":"hide"},{"slug":"a","priority":3}]}"#.utf8))
  equal(catalog.map(\.id), ["a", "b"]); equal(catalog.last?.efforts, ["low"])
  throwsError(try ReviewModelOption.decode(Data("broken".utf8)))
}
