import AppKit
import BurnCore
import Darwin
import Foundation

enum BlazerMapCommand {
  static func run(_ arguments: [String]) throws {
    let flags = Set(arguments)
    guard flags.count == arguments.count, flags.isSubset(of: ["--demo", "--json", "--open"]),
      !(flags.contains("--json") && flags.contains("--open"))
    else { throw StoreError.message("Use map [--demo] [--json | --open].") }

    let snapshot = flags.contains("--demo") ? demo() : BlazerMap.scan()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if flags.contains("--json") {
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
      return
    }
    let payload = try encoder.encode(snapshot).base64EncodedString()
    let html = BlazerMapPage.html.replacingOccurrences(of: "__BLAZER_MAP_PAYLOAD__", with: payload)
    var template = Array(
      FileManager.default.temporaryDirectory.appendingPathComponent("burnzombies-map.XXXXXX").path.utf8CString)
    let directory = try template.withUnsafeMutableBufferPointer { buffer -> URL in
      guard let path = mkdtemp(buffer.baseAddress) else {
        throw StoreError.message("Could not create a private map directory.")
      }
      return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    let file = directory.appendingPathComponent("zombie-map.html")
    try Data(html.utf8).write(to: file, options: .withoutOverwriting)
    guard chmod(file.path, 0o600) == 0 else {
      throw StoreError.message("Could not secure the local map.")
    }
    print(file.path)
    if flags.contains("--open"), !NSWorkspace.shared.open(file) {
      throw StoreError.message("Could not open the browser. Open the printed file manually.")
    }
  }

  private static func demo(now: Date = Date()) -> BlazerMap {
    func row(
      _ kind: BlazerMap.Row.Kind, _ name: String, _ path: String?, _ state: String,
      _ detail: String, gb: Double? = nil, ram: Double? = nil, days: Double? = nil,
      live: Bool = false
    ) -> BlazerMap.Row {
      .init(
        id: kind.rawValue + ":" + name, kind: kind, name: name, path: path, state: state,
        detail: detail, source: "Demo fixture", diskBytes: gb.map { UInt64($0 * 1e9) },
        memoryBytes: ram.map { UInt64($0 * 1e9) },
        lastUsed: days.map { now.addingTimeInterval(-$0 * 86_400) }, observedAt: now, live: live)
    }
    return BlazerMap(
      observedAt: now, durationMS: 0,
      volume: .init(
        freeBytes: 43_800_000_000, totalBytes: 500_000_000_000, usedPercent: 91.24,
        exhaustBytesPerHour: 6_200_000_000, overdriveActive: true,
        overdriveReason: "43.8 GB free · disk usage growing by 6.2 GB/hr"),
      indexedSessions: 64, liveSessions: 4,
      rows: [
        row(.cache, "xcode-scratch", "~/Library/Caches/xcode-scratch", "Signature detected",
          "Build/Products and ModuleCache signatures reveal renamed Xcode DerivedData.", gb: 25.2, days: 19),
        row(.worktree, "ios-v2-release", "~/.codex/worktrees/ios-v2-release", "Possibly stale",
          "mobile-app · feat/ios-v2-release · Agent managed. Last file or commit activity was 21 days ago.", gb: 14.8, days: 21),
        row(.cache, "android-sdk-2025", "~/SDKs/android-sdk-2025", "Signature detected",
          "An older Android SDK installation with the expected tools and platforms layout.", gb: 10.8, days: 58),
        row(.worktree, "auth-rewrite", "~/.claude/worktrees/auth-rewrite", "Contains local work",
          "identity-service · feat/auth-rewrite · 7 modified files; leave for review.", gb: 8.4, days: 3),
        row(.cache, "gradle-isolate", "~/Library/Caches/gradle-isolate", "Held",
          "An isolated Gradle cache with an active lock.", gb: 6.4, days: 0.05),
        row(.worktree, "device-gps-replay", "~/.codex/worktrees/device-gps-replay", "Active",
          "bodycam · feat/gps-replay · An agent is still working here.", gb: 4.2, days: 0.02),
        row(.worktree, "review-preview", "~/Projects/.worktrees/review-preview", "Ready to retire",
          "web · feat/review-preview · Previously confirmed in the saved inventory.", gb: 3.1, days: 42),
        row(.cache, "headless-profile", "~/Library/Caches/headless-profile", "Partial measurement",
          "Only part of this browser profile was visible.", gb: 1.9, days: 4),
        row(.worktree, "db-backfill", "~/.codex/worktrees/db-backfill", "Inspection blocked",
          "schema · feat/db-backfill · Detailed inspection is pending.", days: nil),
        row(.zombie, "Loop Zombie", "~/.codex/worktrees/device-gps-replay", "Live signal",
          "Codex · repeated worktree lock collisions with no edit activity in the sampled tail.", days: 0.005, live: true),
        row(.zombie, "Token Vampire", "~/.claude/worktrees/auth-rewrite", "Historical signal",
          "A large transcript was observed in a previous session.", days: 1.5),
        row(.zombie, "Gradle worker", nil, "Observed orphan",
          "PID 41207 · The worker reparented to launchd. It may still be in use.", ram: 1.3, days: 5, live: true),
        row(.zombie, "Focus Thief", nil, "Live signal",
          "A headed automation browser was detected.", days: 0.002, live: true),
        row(.folder, "Developer", "~/Library/Developer", "Measured",
          "A measured disk folder; this is not a cleanup candidate.", gb: 59.4),
        row(.folder, "SDKs", "~/SDKs", "Measured",
          "Includes android-sdk-2025. Inventory and candidate estimates can overlap.", gb: 38.8),
        row(.folder, "Caches", "~/Library/Caches", "Partial measurement",
          "Only part of this folder was visible.", gb: 37.6),
      ],
      notes: [
        "Demo data. No local scan was run.",
        "Folder measurements can overlap candidate paths. Disk estimates don't predict APFS recovery.",
      ], demo: true)
  }
}
