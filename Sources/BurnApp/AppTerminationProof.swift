#if DEBUG
  import AppKit
  import Foundation

  /// Run the real model/delegate termination path with AppKit's real event loop.
  /// Demo state opens no windows and starts no observer, AI or cleanup workers.
  @MainActor final class AppTerminationProof: NSObject, NSApplicationDelegate {
    let mode: String
    let output: URL
    let delegate = AppDelegate()

    init(mode: String, output: String) {
      self.mode = mode
      self.output = URL(fileURLWithPath: output)
      super.init()
      delegate.model = AppModel(demo: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      switch mode {
      case "update":
        // The same async exit used after the update helper has acknowledged handoff.
        Task { await delegate.model.terminateAfterShutdown() }
      case "quit":
        delegate.model.quit()
      case "external":
        // An AppKit event, rather than an already executing MainActor task.
        RunLoop.main.perform { NSApp.terminate(nil) }
      default:
        exit(2)
      }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      delegate.applicationShouldTerminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
      guard delegate.model.readyToTerminate, NSApp.windows.allSatisfy({ !$0.isVisible }) else {
        exit(3)
      }
      do {
        try Data("shutdown-complete-before-exit\n".utf8).write(to: output)
      } catch { exit(4) }
    }
  }
#endif
