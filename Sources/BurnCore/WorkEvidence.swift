import CryptoKit
import Foundation

/// Owner assertions captured while a helper was in use. Neither age nor owner exit releases work.
public struct WorkEvidence: Codable, Sendable {
  public var id: String
  public var tokenHash: String
  public var members: [Member]
  public var anchors: [Member]
  public var label: String
  public var purpose: String
  public var completionCondition: String
  public var created: Date
  public var updated: Date
  public var state: String
  public var evidence: String
  public static func hash(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public static func blocking(_ claims: [WorkEvidence], identity: String) -> Bool {
    claims.contains { $0.state != "released" && $0.members.contains { $0.identity.key == identity } }
  }
  public static func blockingTree(_ claims: [WorkEvidence], record: Record, records: [String: Record]) -> Bool {
    var current = record
    var seen = Set<String>()
    for _ in 0..<128 {
      guard seen.insert(current.id).inserted else { return true }
      if blocking(claims, identity: current.id) { return true }
      guard current.latest.parent > 1,
        let parent = records.values.first(where: { $0.missingSince == nil && $0.latest.identity.pid == current.latest.parent })
      else { return false }
      current = parent
    }
    return true
  }

}

/// Safe to show to a different reviewer: no update capability, transcripts or command arguments.
public struct WorkSummary: Codable, Sendable {
  public var id: String
  public var processIDs: [String]
  public var livePIDs: [Int32]
  public var label: String
  public var purpose: String
  public var completionCondition: String
  public var state: String
  public var evidence: String
  public var created: Date
  public var updated: Date
  public var ownershipAnchors: [Member]
  public var blockedByActiveClaim: Bool
}
