import Foundation

public struct CodexReviewPlan: Codable {
  public var executable: String
  public var model: String?
  public var effort: String?
  public var prompt: String
  public var overrides: [String]
  public init(executable: String, model: String?, effort: String?, prompt: String, overrides: [String]) {
    self.executable = executable; self.model = model; self.effort = effort; self.prompt = prompt; self.overrides = overrides
  }
}
