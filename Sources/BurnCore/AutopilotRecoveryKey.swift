import CryptoKit
import Foundation

/// Old copies wait for the owner: macOS would ask whether BZ may use its backup key, and BZ never
/// asks on its own. The menu asks once. `asking` is true while macOS's dialog is up.
public struct AutopilotKeyWait: Codable, Sendable, Equatable {
  public var since: Date
  public var asking: Bool
  public init(since: Date, asking: Bool = false) {
    self.since = since
    self.asking = asking
  }
}

/// The backup key for Autopilot's burns. A burn BZ makes on its own reads the key without a
/// keychain question, and never waits on that read longer than `bound`, so one unanswered dialog
/// can't stall the burn pass: the copy is refused and the next one goes on. A read that fails or
/// comes back late starts a wait (`wait`), which the owner ends with the menu's Allow (`allow`):
/// that read may show macOS's dialog, right after the owner's click. A read that brings the key
/// back, quiet or not, ends the wait.
public final class AutopilotRecoveryKey: @unchecked Sendable {
  /// What a copy says when its key can't be read without asking.
  public static let refusal =
    "I need your OK to use my backup key, so I left it alone. Click Allow in BZ's menu."
  /// What the owner hears when Allow still didn't bring the key back.
  public static let notAllowed =
    "I still couldn't get my backup key, so old copies still wait. Click Allow to try again."
  public struct Waiting: LocalizedError {
    public var errorDescription: String? { AutopilotRecoveryKey.refusal }
  }
  struct NotAllowed: LocalizedError {
    var errorDescription: String? { AutopilotRecoveryKey.notAllowed }
  }

  /// The app's own, reading the login keychain.
  public static let shared = AutopilotRecoveryKey()

  /// How long a burn gives a quiet read. One normally answers in milliseconds.
  public let bound: TimeInterval
  let read: @Sendable (_ interactive: Bool, _ create: Bool) throws -> SymmetricKey
  private let lock = NSLock()
  /// The quiet read under way, if any. At most one is ever outstanding: one that never comes back
  /// costs one thread, not one per copy.
  private var flight: Flight?
  private var waiting: AutopilotKeyWait?

  private final class Flight: @unchecked Sendable {
    let started = Date()
    let done = DispatchGroup()
    /// Set once, under the gate's lock.
    var result: Result<SymmetricKey, Error>?
  }

  public init(
    bound: TimeInterval = 15,
    read: @escaping @Sendable (_ interactive: Bool, _ create: Bool) throws -> SymmetricKey = {
      interactive, create in
      try WorktreeRecoveryKey.load(create: create, allowInteraction: interactive)
    }
  ) {
    self.bound = bound
    self.read = read
  }

  /// While burns that need the key wait for the owner.
  public var wait: AutopilotKeyWait? { lock.withLock { waiting } }

  /// The key for a burn BZ makes: never with a keychain question, never later than `bound`.
  /// Throws `Waiting` when it can't be had that way.
  public func forBurn() throws -> SymmetricKey {
    let (current, fresh): (Flight, Bool) = lock.withLock {
      if let flight { return (flight, false) }
      let started = Flight()
      started.done.enter()
      flight = started
      return (started, true)
    }
    if fresh {
      DispatchQueue.global(qos: .utility).async { [self] in
        finish(current, Result { try read(false, true) })
      }
    }
    // A burn that finds a read already out shares it, within what is left of its bound.
    let remaining = bound + current.started.timeIntervalSinceNow
    if remaining > 0 { _ = current.done.wait(timeout: .now() + remaining) }
    return try lock.withLock {
      switch current.result {
      case .success(let key)?: return key
      case .failure?: break
      case nil:
        // Late: macOS may be showing its dialog. The read is left to finish on its own.
        if waiting == nil { waiting = AutopilotKeyWait(since: Date()) }
      }
      throw Waiting()
    }
  }

  /// The owner's Allow: reads the key with macOS's question allowed, so its dialog appears now.
  /// Ends the wait when the key comes back; otherwise says so plainly and old copies still wait.
  public func allow() throws {
    lock.withLock {
      var asking = waiting ?? AutopilotKeyWait(since: Date())
      asking.asking = true
      waiting = asking
    }
    do { _ = try forOwner(create: true) } catch { throw NotAllowed() }
  }

  /// The key for something the owner just did, such as Undo: macOS may ask. Its key ends a wait.
  public func forOwner(create: Bool = true) throws -> SymmetricKey {
    lock.withLock { waiting?.asking = true }
    do {
      let key = try read(true, create)
      lock.withLock {
        waiting = nil
        // A quiet read still out is stale now that the key reads; the next burn starts afresh.
        flight = nil
      }
      return key
    } catch {
      lock.withLock { waiting?.asking = false }
      throw error
    }
  }

  private func finish(_ done: Flight, _ result: Result<SymmetricKey, Error>) {
    lock.withLock {
      done.result = result
      let current = flight === done
      if current { flight = nil }
      switch result {
      case .success: waiting = nil
      case .failure: if current && waiting == nil { waiting = AutopilotKeyWait(since: Date()) }
      }
    }
    done.done.leave()
  }
}
