import Foundation

/// Identical JSON contract for MCP and the instruction-only skill's native transport.
public enum LifecycleInput {
  public static func request(_ data: Data) throws -> AgentRequest {
    guard data.count <= 16384, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys).isSubset(of: ["action", "process_ids", "label", "evidence", "completion_condition", "work_token"]),
      let action = object["action"] as? String, ["register", "release", "retain"].contains(action),
      let evidence = object["evidence"] as? String, (20...1200).contains(evidence.count) else {
      throw StoreError.message("Use action register/release/retain and factual evidence (20–1200 characters).")
    }
    if action == "register" {
      guard object["work_token"] == nil, let ids = object["process_ids"] as? [String],
        (1...16).contains(ids.count), Set(ids).count == ids.count,
        ids.allSatisfy({ (1...100).contains($0.count) }),
        let label = object["label"] as? String, (1...80).contains(label.count),
        let condition = object["completion_condition"] as? String, (10...500).contains(condition.count) else {
        throw StoreError.message("Register requires process_ids, label, evidence and completion_condition.")
      }
      return AgentRequest("lifecycle", processIDs: ids, label: label, rationale: evidence,
        action: action, completionCondition: condition)
    }
    guard object.count == 3, let token = object["work_token"] as? String, token.count == 72 else {
      throw StoreError.message("Release/retain requires only action, work_token and evidence.")
    }
    return AgentRequest("lifecycle", rationale: evidence, action: action, workToken: token)
  }
}
