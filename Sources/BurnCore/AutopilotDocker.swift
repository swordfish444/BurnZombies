import Darwin
import Foundation

/// Docker's build cache as one Autopilot leftover. It is a junk folder to the rest of Autopilot, with
/// no folder: only Docker removes anything, one exact old record at a time (`BuildKitCache`). BZ asks
/// about it once, nothing but the owner's answer decides it, and it says nothing when Docker isn't
/// installed or running. Asking Docker wakes it, so that happens in the background, every few hours.
public final class AutopilotDockerCache: @unchecked Sendable {
  public typealias Open =
    @Sendable () throws -> (engine: BuildKitCache, target: BuildKitCache.Target)

  /// The `folder` fact that names it.
  public static let folder = "docker-build-cache"
  public static let name = "Docker's build cache"
  /// What its card says is safe about it.
  public static let safeLine = "Nothing uses it now. Docker makes it again when it needs it."
  static let itemID = "disk:" + AutopilotItem.hash(folder)
  /// Its facts never change. Everything in it sat unused for at least two weeks, which `week` (7+
  /// days) truthfully covers, so how old it is can't put a Yes out of reach or ask a second question.
  /// `docker` is a named risk: only a lesson that names it covers the cache.
  static let facts = ["folder": folder, "home": "docker", "stale": "week", "docker": "yes"]
  /// How long it waits before asking Docker again: after an answer, and when Docker didn't answer.
  static let looksEvery: TimeInterval = 6 * 3600
  static let looksAgainAfter: TimeInterval = 3600
  /// A burn takes this many records at a time, and starts no new batch after `burnsFor`. What's left
  /// goes at the next look.
  static let batch = 32
  static let burnsFor: TimeInterval = 120

  private let open: Open
  private let alive: @Sendable (String) -> Bool
  private let lock = NSLock()
  private var cached: AutopilotItem?
  private var socketPath: String?
  private var nextLook = Date.distantPast
  private var looking = false
  /// Changes when a burn begins and ends, so a look that overlapped one can't bring its item back.
  private var generation: UInt64 = 0

  /// `open` reaches Docker, or throws when it can't. `alive` says whether its socket answers.
  public init(open: @escaping Open, alive: @escaping @Sendable (String) -> Bool) {
    self.open = open
    self.alive = alive
  }

  /// The running app's: the Docker on this Mac, through the checks in `BuildKitCache.live`. Only the
  /// app makes this, so no proof ever reaches the Mac's real Docker.
  public static func live(root: URL = Store.defaultRoot) -> AutopilotDockerCache {
    AutopilotDockerCache(
      open: {
        let engine = try BuildKitCache.live(store: Store(root: root))
        return (engine, try BuildKitCache.currentTarget())
      }, alive: { accepting($0) })
  }

  /// Whether this is Docker's build cache.
  public static func isCache(_ item: AutopilotItem) -> Bool { item.facts["folder"] == folder }
  /// Whether a question or lesson is about Docker's build cache alone.
  public static func about(_ match: [String: [String]]) -> Bool { match["folder"] == [folder] }

  /// Where Docker lives on this Mac: Never touches on any of these, or on what holds them, covers
  /// the cache too.
  static func places(home: String = NSHomeDirectory()) -> [String] {
    [
      "/Applications/Docker.app", home + "/Applications/Docker.app", home + "/.docker",
      home + "/Library/Containers/com.docker.docker",
      home + "/Library/Group Containers/group.com.docker",
    ]
  }

  /// The item, when there is something old enough. Never blocks: a look that's due runs in the
  /// background, and a Docker that quit since hides it right away.
  public func items(now: Date = Date()) -> [AutopilotItem] {
    let due = lock.withLock { () -> Bool in
      guard !looking, now >= nextLook else { return false }
      looking = true
      return true
    }
    if due {
      DispatchQueue.global(qos: .utility).async { [self] in
        look(now: now)
        lock.withLock { looking = false }
      }
    }
    let (item, path) = lock.withLock { (cached, socketPath) }
    guard let item, let path else { return [] }
    guard alive(path) else {
      lock.withLock {
        cached = nil
        socketPath = nil
        nextLook = min(nextLook, now.addingTimeInterval(Self.looksAgainAfter))
      }
      return []
    }
    return [item]
  }

  /// Asks Docker what's old enough now, and says whether it answered. Any failure means it isn't
  /// there to ask: no item, no words.
  @discardableResult public func look(now: Date = Date()) -> Bool {
    let started = lock.withLock { generation }
    var found: AutopilotItem?
    var path: String?
    var looked = false
    if let opened = try? open(),
      let inventory = try? opened.engine.inspect(
        target: opened.target, retention: .standard, now: now)
    {
      found = Self.item(inventory)
      path = String(inventory.owner.endpoint.dropFirst("unix://".count))
      looked = true
    }
    lock.withLock {
      guard generation == started else { return }
      cached = found
      socketPath = path
      nextLook = now.addingTimeInterval(looked ? Self.looksEvery : Self.looksAgainAfter)
    }
    return looked
  }

  static func item(_ inventory: BuildKitCache.Inventory) -> AutopilotItem? {
    let chosen = Set(inventory.eligibleIDs)
    let records = inventory.records.filter { chosen.contains($0.id) }
    guard !records.isEmpty else { return nil }
    return AutopilotItem(
      id: itemID, kind: .disk, name: name,
      detail:
        "Old leftovers from Docker builds. No build, image, container or volume uses them, and Docker makes them again when it needs them.",
      bytes: inventory.eligibleBytes, facts: facts, observedAt: inventory.date,
      lastUsed: records.compactMap(\.lastUsed).max())
  }

  private struct Withdrawn: Error {}

  /// Removes what is old enough now, by exact record, biggest and newest-built first, checking
  /// everything again for each batch. `authorize` says, right before each prune, whether the decision
  /// to burn still stands. It credits only what Docker reports gone and a fresh look confirms; what a
  /// prune that didn't answer did earns nothing, and that item waits like any refusal, then starts
  /// again from fresh evidence.
  public func reclaim(
    _ item: AutopilotItem, authority: String, authorize: @escaping () -> Bool
  ) -> AutopilotReceipt {
    func refuse(_ reason: String, cause: String? = nil) -> AutopilotReceipt {
      var receipt = AutopilotReceipt.refused(item, authority: authority, reason)
      receipt.cause = cause
      return receipt
    }
    guard item.kind == .disk, item.id == Self.itemID else {
      return refuse("That isn't Docker's build cache, so I left it alone.")
    }
    // No look runs on top of a burn, and the next one reads what's left.
    lock.withLock {
      generation &+= 1
      cached = nil
      nextLook = .distantFuture
    }
    defer {
      lock.withLock {
        generation &+= 1
        nextLook = .distantPast
      }
    }
    let opened: (engine: BuildKitCache, target: BuildKitCache.Target)
    do { opened = try open() } catch {
      return refuse(
        "I couldn't reach Docker, so I left its build cache alone.",
        cause: AutopilotWorktrees.cause(of: error, at: "reaching Docker"))
    }
    var released: UInt64 = 0
    var stopped: (reason: String, cause: String?)?
    // What Docker kept this time doesn't get in the way of the rest.
    var tried = Set<String>()
    var kept = false
    let deadline = Date().addingTimeInterval(Self.burnsFor)
    repeat {
      do {
        let inventory = try opened.engine.inspect(target: opened.target, retention: .standard)
        let order = BuildKitCache.removalOrder(inventory).filter { !tried.contains($0) }
        let ids = Array(order.prefix(Self.batch))
        if ids.isEmpty { break }
        tried.formUnion(ids)
        let plan = try BuildKitCache.preview(
          inventory: inventory, recordIDs: ids, retention: .standard)
        let receipt = try opened.engine.clean(
          plan: plan, retention: .standard,
          authorize: { if !authorize() { throw Withdrawn() } })
        released += receipt.cacheReleasedBytes
        if receipt.outcome == "uncertain" {
          stopped = (
            "Docker didn't confirm what went, so I'm not counting it. I'll look again later.",
            "asking Docker to prune: it didn't confirm what went"
          )
          break
        }
        if receipt.removedIDs.count < ids.count { kept = true }
      } catch is Withdrawn {
        stopped = ("Permissions changed since I decided, so I left it alone.", nil)
        break
      } catch {
        stopped = (
          "I couldn't check Docker's build cache safely, so I left it alone.",
          AutopilotWorktrees.cause(of: error, at: "checking Docker")
        )
        break
      }
    } while Date() < deadline
    guard released > 0 else {
      if let stopped { return refuse(stopped.reason, cause: stopped.cause) }
      return refuse(
        kept
          ? "Docker kept all of it, so something may still need it."
          : "Nothing in Docker's build cache is old enough now.")
    }
    return AutopilotReceipt(
      itemID: item.id, kind: .disk, name: item.name, authority: authority, outcome: "burned",
      detail: "Burned \(AutopilotPolicy.roughly(released)) of Docker's build cache."
        + (stopped == nil && !kept ? " Docker makes it again when it needs it." : " Some of it stayed."),
      bytes: released)
  }

  /// What the AI reads when it looks closely: there's no folder to look in.
  static func inspect(_ item: AutopilotItem) -> [String: String] {
    [
      "state": item.detail, "size": AutopilotPolicy.format(item.bytes),
      "decidedBy": "The owner. BZ asks them once.",
    ]
  }

  /// Whether something answers on a Unix socket. Starts nothing and wakes nothing.
  public static func accepting(_ path: String) -> Bool {
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { return false }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: path.utf8)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let answered = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return answered == 0
  }
}
