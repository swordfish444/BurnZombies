import Darwin
import Foundation

/// Mechanical execution boundaries. Deciding whether work is abandoned belongs to the harness.
public enum AgentSafety {
  public static func ancestors(of pid: Int32, native: Native = Native()) -> Set<Int32>? {
    guard pid > 1 else { return nil }
    var result = Set<Int32>()
    var next = pid
    for _ in 0..<128 {
      guard next > 1 else { return result }
      guard result.insert(next).inserted,
        case .found(let observation) = native.probe(next) else { return nil }
      next = observation.parent
    }
    return nil
  }

  public static func refusal(_ record: Record, preferences: Preferences,
    protectedPIDs: Set<Int32>, now: Date = Date()) -> String? {
    let o = record.latest
    if o.uid != getuid() || o.identity.pid <= 1 || protectedPIDs.contains(o.identity.pid) {
      return "System, monitor, or requesting harness ancestry."
    }
    if record.protection || preferences.protectedExecutables.contains(o.executable)
      || (record.ignoreUntil.map { $0 > now } ?? false) { return "User protection or snooze." }
    if o.zombie { return "Exited OS child: its parent must reap it; signaling it cannot reclaim memory." }
    if !o.metricsValid || o.executable.isEmpty || record.missingSince != nil {
      return "Incomplete process identity or visibility."
    }
    if o.executable.hasPrefix("/System/") || o.executable.hasPrefix("/usr/libexec/")
      || o.executable.hasPrefix("/usr/sbin/") || o.executable.contains(".app/Contents/MacOS/") {
      return "OS service or application main process."
    }
    if ["launchd", "kernel_task", "login", "WindowServer", "sshd", "security", "op",
      "codex", "claude", "gemini", "copilot", "cursor-agent", "burnzombies-mcp", "BurnZombiesApp"].contains(o.name) {
      return "Protected service, credential tool, or harness."
    }
    return nil
  }
}
