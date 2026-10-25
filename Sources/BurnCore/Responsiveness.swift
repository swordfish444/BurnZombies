import Foundation

/// Small local command-launch probe. It never reads user files or contacts a service.
/// Seven launches with a discarded warm-up; median elapsed time is saved in the receipt.
public enum Responsiveness {
  public static func sample() -> Double? {
    var samples = [Double]()
    for i in 0..<8 {
      let command = Process()
      command.executableURL = URL(fileURLWithPath: "/usr/bin/true")
      command.environment = [:]
      command.standardInput = FileHandle.nullDevice
      command.standardOutput = FileHandle.nullDevice
      command.standardError = FileHandle.nullDevice
      let exited = DispatchSemaphore(value: 0)
      command.terminationHandler = { _ in exited.signal() }
      let start = ProcessInfo.processInfo.systemUptime
      do { try command.run() } catch { return nil }
      guard exited.wait(timeout: .now() + 1) == .success else {
        if command.isRunning { command.terminate() }
        return nil
      }
      guard command.terminationStatus == 0 else { return nil }
      if i > 0 { samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
    }
    return samples.sorted()[samples.count / 2]
  }
}
