import CBurn
import Darwin
import Foundation

/// Optional external analyzer. No Mole source is bundled and no deleting command is exposed.
public struct MoleEvidence: Codable, Sendable {
  public struct Entry: Codable, Sendable {
    public var path: String
    public var bytes: UInt64
    public var scanStatus: String
    public var cleanupHint: Bool
  }
  public var provider = "Mole analyze"
  public var scanStatus: String
  public var entries: [Entry]
  public var scope =
    "Read-only hints. cleanable is not proof of disposability or permission. Partial/unavailable results preserve uncertainty. Native APFS measurements govern recovery totals."

  public static func decode(_ data: Data, root: String, protected: [String] = []) throws -> Self {
    struct Row: Decodable {
      var path: String
      var size: Int64
      var scan_status: String
      var cleanable: Bool?
    }
    struct Output: Decodable {
      var path: String
      var scan_status: String
      var entries: [Row]
    }
    guard data.count <= 1_048_576 else {
      throw StoreError.message("Mole output exceeded its bound.")
    }
    let output = try JSONDecoder().decode(Output.self, from: data)
    let statuses: Set<String> = ["complete", "partial", "unavailable"]
    guard output.path == root, statuses.contains(output.scan_status), output.entries.count <= 10_000
    else {
      throw StoreError.message("Mole returned a different path or unsupported scan state.")
    }
    let entries = output.entries.filter { row in
      row.size >= 0 && statuses.contains(row.scan_status) && row.path != root
        && WorkspaceSafety.contains(root, row.path)
        && row.path == WorkspaceSafety.canonical(row.path)
        && !protected.contains(where: { p in
          WorkspaceSafety.contains(p, row.path) || WorkspaceSafety.contains(row.path, p)
        })
    }.sorted { $0.size > $1.size }.prefix(12).map {
      Entry(
        path: $0.path, bytes: UInt64($0.size), scanStatus: $0.scan_status,
        cleanupHint: $0.cleanable == true && output.scan_status == "complete"
          && $0.scan_status == "complete")
    }
    return .init(scanStatus: output.scan_status, entries: entries)
  }
  public static func analyze(_ path: String, store: Store, protected: [String]) -> Self? {
    // The external analyzer has no exclusion-list contract. If any protected
    // location intersects the branch, keep the whole invocation native-only.
    guard path == WorkspaceSafety.canonical(path),
      !protected.contains(where: {
        WorkspaceSafety.contains($0, path) || WorkspaceSafety.contains(path, $0)
      }),
      let identity = try? WorkspaceSafety.statAt(path), identity.st_mode & S_IFMT == S_IFDIR,
      identity.st_flags & UInt32(SF_DATALESS) == 0
    else { return nil }
    // Fixed Homebrew locations avoid PATH/repository command substitution. The bundled
    // Go analyzer runs directly; its own du/Spotlight helpers share our bounded group.
    let binaries = [
      "/opt/homebrew/opt/mole/libexec/bin/analyze-go", "/usr/local/opt/mole/libexec/bin/analyze-go",
    ]
    guard let binary = binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    let cache = store.root.appendingPathComponent(
      "mole-analysis-"
        + WorkEvidence.hash(
          path + "|\(identity.st_dev):\(identity.st_ino)|"
            + protected.sorted().joined(separator: "|")) + ".json")
    struct Saved: Codable {
      var date: Date
      var value: MoleEvidence?
    }
    if let data = try? store.read(cache, limit: 16384),
      let saved = try? JSONDecoder().decode(Saved.self, from: data),
      (0..<21600).contains(Date().timeIntervalSince(saved.date))
    {
      return saved.value
    }
    var result: Self?
    defer {
      if let bytes = try? JSONEncoder().encode(Saved(date: Date(), value: result)) {
        try? store.write(bytes, to: cache, limit: 16384)
      }
    }
    let output = store.root.appendingPathComponent("mole-output-" + UUID().uuidString)
    let fd = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: output)
    }
    var argv =
      [binary, "--json", path].map { (value: String) in value.withCString { strdup($0) } } + [nil]
    var environment =
      ["HOME=" + NSHomeDirectory(), "PATH=/usr/bin:/bin", "LC_ALL=C", "NO_COLOR=1"]
      .map { (value: String) in value.withCString { strdup($0) } } + [nil]
    defer {
      argv.forEach { free($0) }
      environment.forEach { free($0) }
    }
    guard bz_capture_tool(&argv, &environment, fd, 8000, 1_048_576) == 0 else { return nil }
    do {
      try handle.seek(toOffset: 0)
      result = try decode(
        handle.read(upToCount: 1_048_577) ?? Data(), root: path, protected: protected)
    } catch { return nil }
    return result
  }
}
