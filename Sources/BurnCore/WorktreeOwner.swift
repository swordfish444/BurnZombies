import CBurn
import Darwin
import Foundation

public struct WorktreePullRequest: Codable, Sendable {
  public var number: Int
  public var state: String
  public var merged: Bool
  public var headMatches: Bool
  public var mergeCommit: String?
  public var url: String
}
public struct WorktreeDeliveryEvidence: Codable, Sendable {
  public var id: String
  public var head: String
  public var repository: String
  public var defaultBranch: String?
  public var observedAt: Date
  public var requests: [WorktreePullRequest] = []
  public var complete = false
  public var detail: String
}

/// Metadata is advisory. This adapter never fetches refs, changes auth or retires
/// another application's checkout. Network access happens only on explicit refresh.
public enum WorktreeOwner {
  public static func githubRepository(_ remote: String) -> (String, String)? {
    var path: String
    if remote.hasPrefix("git@github.com:") {
      path = String(remote.dropFirst(15))
    } else if let url = URLComponents(string: remote), url.scheme == "https",
      url.host == "github.com", url.user == nil, url.password == nil, url.query == nil,
      url.fragment == nil
    {
      path = String(url.path.dropFirst())
    } else {
      return nil
    }
    if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard parts.count == 2,
      parts.allSatisfy({
        !$0.isEmpty && $0.count <= 100 && $0 != "." && $0 != ".."
          && $0.unicodeScalars.allSatisfy(allowed.contains)
      })
    else { return nil }
    return (String(parts[0]), String(parts[1]))
  }
  public static func parse(_ data: Data, id: String, head: String, repository: String) throws
    -> WorktreeDeliveryEvidence
  {
    guard data.count <= 1_048_576,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["errors"] == nil,
      let body = object["data"] as? [String: Any], let repo = body["repository"] as? [String: Any],
      let commit = repo["object"] as? [String: Any], commit["oid"] as? String == head,
      let connection = commit["associatedPullRequests"] as? [String: Any],
      let nodes = connection["nodes"] as? [[String: Any]], nodes.count <= 10
    else {
      throw StoreError.message(
        "GitHub commit metadata unavailable or mismatched; completion remains unknown.")
    }
    var result = WorktreeDeliveryEvidence(
      id: id, head: head, repository: repository,
      defaultBranch: (repo["defaultBranchRef"] as? [String: Any])?["name"] as? String,
      observedAt: Date(),
      detail:
        "Associated PR metadata for this exact commit; this does not establish completion, preservation or retirement authority."
    )
    for node in nodes {
      guard let number = node["number"] as? Int, number > 0, let state = node["state"] as? String,
        ["OPEN", "CLOSED", "MERGED"].contains(state), let merged = node["merged"] as? Bool,
        let url = node["url"] as? String, url.hasPrefix("https://github.com/"), url.count < 2048
      else { throw StoreError.message("Unsupported PR metadata; preserve uncertainty.") }
      result.requests.append(
        .init(
          number: number, state: state, merged: merged,
          headMatches: node["headRefOid"] as? String == head,
          mergeCommit: (node["mergeCommit"] as? [String: Any])?["oid"] as? String, url: url))
    }
    result.complete = (connection["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool == false
    if !result.complete { result.detail += " Results are truncated." }
    return result
  }
  public static func fetch(_ row: WorktreeRecord) -> WorktreeDeliveryEvidence {
    var unknown = WorktreeDeliveryEvidence(
      id: row.id, head: row.head ?? "", repository: "unknown", observedAt: Date(),
      detail: "GitHub metadata unavailable. Local inspection and recovery remain independent.")
    do {
      guard let head = row.head, head.count == 40 || head.count == 64,
        let remote = try? WorktreeGit.line(
          row.repository, ["config", "--get", "remote.origin.url"]),
        let (owner, name) = githubRepository(remote),
        let executable = MachineReviewConfiguration.detect("gh")
      else { return unknown }
      unknown.repository = owner + "/" + name
      let query =
        "query($owner:String!,$name:String!,$oid:GitObjectID!){repository(owner:$owner,name:$name){defaultBranchRef{name} object(oid:$oid){... on Commit{oid associatedPullRequests(first:10){nodes{number state merged headRefOid mergeCommit{oid} url} pageInfo{hasNextPage}}}}}}"
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "bz-pr-" + UUID().uuidString)
      let fd = open(file.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { return unknown }
      defer {
        close(fd)
        unlink(file.path)
      }
      var argv =
        [
          executable, "api", "graphql", "--hostname", "github.com", "--raw-field", "query=" + query,
          "--raw-field", "owner=" + owner, "--raw-field", "name=" + name, "--raw-field",
          "oid=" + head,
        ].map { (value: String) in value.withCString { strdup($0) } } + [nil]
      var env =
        ["PATH=/usr/bin:/bin", "HOME=" + NSHomeDirectory(), "GH_PROMPT_DISABLED=1"].map {
          (value: String) in value.withCString { strdup($0) }
        } + [nil]
      defer {
        argv.forEach { free($0) }
        env.forEach { free($0) }
      }
      let result = bz_capture_tool(&argv, &env, fd, 8000, 1_048_576)
      guard result == 0 else {
        unknown.detail =
          "GitHub refresh failed or exceeded its bound; no auth changes or retries. Completion remains unknown."
        return unknown
      }
      _ = lseek(fd, 0, SEEK_SET)
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      return try parse(
        handle.read(upToCount: 1_048_577) ?? Data(), id: row.id, head: head,
        repository: owner + "/" + name)
    } catch { return unknown }
  }
}
