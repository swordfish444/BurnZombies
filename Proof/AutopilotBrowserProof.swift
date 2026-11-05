import BurnCore
import Darwin
import Foundation

private func running(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Every live descendant of `pid`, from a fresh look at the process table.
private func family(of pid: Int32) -> [Int32] {
  let all = Native().scan().observations
  var found: [Int32] = []
  var frontier = [pid]
  while let next = frontier.popLast() {
    for o in all where o.parent == next && !found.contains(o.identity.pid) {
      found.append(o.identity.pid)
      frontier.append(o.identity.pid)
    }
  }
  return found
}

/// The Chrome a robot most often drives on a Mac: the one in Applications. Its bundle is what the
/// app rail protects, so it is the one worth proving.
private func installedChrome() -> String? {
  let path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}

/// Starts Chrome from a shell that exits at once, so launchd adopts it like a robot browser whose
/// driver died. With `pipe`, its fds 3 and 4 are this proof's pipes, the way Playwright drives it;
/// the caller closes the returned ends once Chrome is up, as a dead driver's would close. (Chrome
/// quits when its pipe closes while it is still starting.)
private func strandedChrome(_ chrome: String, _ arguments: [String], pipe: Bool, in folder: URL)
  throws -> (pid: Int32, ends: [FileHandle])
{
  let pidFile = folder.appendingPathComponent("pid-" + UUID().uuidString)
  let shell = Process()
  shell.executableURL = URL(fileURLWithPath: "/bin/sh")
  let redirects = pipe ? "3<&0 4>&1 </dev/null >/dev/null 2>&1" : "</dev/null >/dev/null 2>&1"
  shell.arguments = ["-c", "\"$@\" \(redirects) & echo $! > '\(pidFile.path)'", "sh", chrome] + arguments
  let toBrowser = Pipe()
  let fromBrowser = Pipe()
  if pipe {
    shell.standardInput = toBrowser
    shell.standardOutput = fromBrowser
  } else {
    shell.standardInput = FileHandle.nullDevice
    shell.standardOutput = FileHandle.nullDevice
  }
  shell.standardError = FileHandle.nullDevice
  try shell.run()
  shell.waitUntilExit()
  guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
    let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  else { throw StoreError.message("Chrome did not start") }
  return (pid, pipe ? [toBrowser.fileHandleForWriting, fromBrowser.fileHandleForReading] : [])
}

/// Sends one DevTools command over a browser's pipe and waits for its reply, as Playwright does.
private func devtools(_ ends: [FileHandle], _ id: Int, _ method: String, _ params: [String: Any] = [:])
  -> [String: Any]?
{
  guard ends.count == 2,
    let body = try? JSONSerialization.data(
      withJSONObject: ["id": id, "method": method, "params": params]),
    (try? ends[0].write(contentsOf: body + Data([0]))) != nil
  else { return nil }
  let fd = ends[1].fileDescriptor
  var pending = Data()
  let deadline = Date().addingTimeInterval(10)
  while Date() < deadline {
    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&ready, 1, 200) >= 0 else { return nil }
    guard ready.revents != 0 else { continue }
    var chunk = [UInt8](repeating: 0, count: 65_536)
    let count = read(fd, &chunk, chunk.count)
    guard count > 0 else { return nil }
    pending.append(contentsOf: chunk[..<count])
    while let zero = pending.firstIndex(of: 0) {
      let message = Data(pending[pending.startIndex..<zero])
      pending = Data(pending[(zero + 1)...])
      if let reply = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
        reply["id"] as? Int == id
      {
        return reply
      }
    }
  }
  return nil
}

private func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if condition() { return true }
    usleep(100_000)
  }
  return condition()
}

/// Real headless Chrome, driven over a pipe and over a port, outlives the shell that started it.
/// Autopilot sees each as an abandoned robot browser with its helpers, a connected client keeps
/// the port one, both burn as one tree, and the throwaway profile each left is cleared while a
/// running browser's profile stays. The owner's own Chrome is never cataloged.
func autopilotBrowserProof() async throws {
  guard let chrome = installedChrome() else {
    print("SKIP real robot browsers: Google Chrome isn't in /Applications")
    return
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-robot-browsers-" + UUID().uuidString)
  // Stands in for the user's temp folder, where these profiles land.
  let temp = root.appendingPathComponent("T")
  try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let monitor = try Monitor(
    legacyAuthority: true, discoveryHome: nil, root: root.appendingPathComponent("state"),
    accessCheck: fixtureAccess, discoveryWalker: fixtureWalker())
  var browsers: [Int32] = []
  defer {
    for pid in browsers { for helper in family(of: pid) + [pid] where running(helper) { kill(helper, SIGKILL) } }
  }
  let quiet = [
    "--headless", "--no-first-run", "--no-default-browser-check", "--use-mock-keychain",
    "--password-store=basic", "--disable-background-networking", "--disable-component-update",
    "--disable-sync", "--metrics-recording-only",
  ]
  let own = AgentSafety.ancestors(of: getpid()) ?? []
  // A browser that quits reading its pipe must not take this proof with it.
  signal(SIGPIPE, SIG_IGN)
  // An hour on, so the browsers count as idle without waiting for it.
  let later = Date().addingTimeInterval(3600)

  // 1. Over a pipe, as Playwright drives it: no startup window, and a browser context and page
  // made over the pipe. Then the driver dies and its pipe closes; Chrome keeps running, as it
  // does when Playwright's driver is killed.
  let pipeProfile = temp.appendingPathComponent("playwright_chromiumdev_profile-bzproof1")
  let (piped, pipeEnds) = try strandedChrome(
    chrome,
    quiet + ["--user-data-dir=" + pipeProfile.path, "--remote-debugging-pipe", "--no-startup-window"],
    pipe: true, in: root)
  browsers.append(piped)
  // Playwright's own context options; with them Chrome keeps running once the pipe closes.
  let context = (devtools(pipeEnds, 1, "Target.createBrowserContext", ["disposeOnDetach": true])?[
    "result"] as? [String: Any])?["browserContextId"] as? String
  check(context != nil, "Chrome answers over its pipe")
  check(
    devtools(
      pipeEnds, 2, "Target.createTarget", ["url": "about:blank", "browserContextId": context ?? ""])
      != nil, "a page opens in that context")
  check(waitFor(15) { !family(of: piped).isEmpty }, "Chrome started its helpers")
  for end in pipeEnds { try? end.close() }
  usleep(3_000_000)
  check(running(piped), "a Playwright-style browser outlives its driver's pipe")
  _ = await monitor.refresh()
  var items = AutopilotProcesses.items(
    await monitor.autopilotRecords(), threads: [], protectedPIDs: own, now: later)
  guard let pipeItem = items.first(where: { $0.pid == piped }) else {
    let record = await monitor.autopilotRecords().values.first { $0.latest.identity.pid == piped }
    let argv = Native().arguments(piped)
    failTest(
      "the stranded pipe browser is cataloged: parent \(String(describing: record?.latest.parent)), valid \(String(describing: record?.latest.metricsValid)), arguments \(argv?.count ?? -1), robot \(String(describing: argv.flatMap { RobotBrowser.fingerprint(executable: chrome, arguments: $0) })), rail \(String(describing: record.map { AutopilotProcesses.rail($0, protectedPIDs: own, preferences: Preferences(), robot: true) }))"
    )
    return
  }
  equal(pipeItem.facts["robot"], "abandoned")
  equal(pipeItem.facts["family"], "browser")
  isNil(pipeItem.protectedReason)
  check(pipeItem.name.hasPrefix("Google Chrome (robot)"), pipeItem.name)
  check(pipeItem.detail.contains("helper"), "its helpers ride with it: " + pipeItem.detail)
  checkFalse(
    items.contains { family(of: piped).contains($0.pid ?? -1) }, "helpers aren't items of their own")
  let decision = AutopilotPolicy.decide(pipeItem, memory: AutopilotMemory())
  equal(decision.authority, "starter:starter-robot-browsers")

  let helpers = family(of: piped)
  _ = try await monitor.autopilotBurn(
    pipeItem.processKey!, authority: "starter:starter-robot-browsers", label: pipeItem.name,
    rationale: "Proof: nothing can drive it.")
  check(
    waitFor(15) { !([piped] + helpers).contains(where: running) },
    "the browser and its \(helpers.count) helpers stopped")

  // 2. Over a port, as Puppeteer and chromedriver drive it. A connected client keeps it; once the
  // client goes, nothing is driving it.
  let portProfile = temp.appendingPathComponent("puppeteer_dev_chrome_profile-bzproof2")
  let (ported, _) = try strandedChrome(
    chrome,
    quiet + ["--user-data-dir=" + portProfile.path, "--remote-debugging-port=0", "about:blank"],
    pipe: false, in: root)
  browsers.append(ported)
  let activePort = portProfile.appendingPathComponent("DevToolsActivePort")
  check(
    waitFor(15) { (try? String(contentsOf: activePort, encoding: .utf8)) != nil },
    "Chrome opened its debugging port")
  let port = (try? String(contentsOf: activePort, encoding: .utf8))?.split(separator: "\n").first
    .flatMap { UInt16($0) }
  guard let port else {
    failTest("debugging port read")
    return
  }
  let client = socket(AF_INET, SOCK_STREAM, 0)
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  address.sin_port = port.bigEndian
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  equal(connected, 0, "a client connects to the debugging port")
  usleep(500_000)
  _ = await monitor.refresh()
  items = AutopilotProcesses.items(
    await monitor.autopilotRecords(), threads: [], protectedPIDs: own, now: later)
  let attached = items.first { $0.pid == ported }
  equal(attached?.facts["robot"], "driven", "a client is connected")
  equal(attached?.facts["listening"], "yes")
  if let attached {
    checkFalse(
      AutopilotPolicy.decide(attached, memory: AutopilotMemory()).status == .burn,
      "a browser something is connected to stays")
    // Judged before the client came, it is still left running.
    do {
      _ = try await monitor.autopilotBurn(
        attached.processKey!, authority: "starter:starter-robot-browsers", label: attached.name,
        rationale: "Proof: judged before the client came.")
      failTest("a burn stops a browser a client is connected to")
    } catch {
      check(running(ported), "the connected browser keeps running")
    }
  }
  close(client)
  check(
    waitFor(5) { Native().clients(ported) == 0 }, "the client is gone")
  _ = await monitor.refresh()
  items = AutopilotProcesses.items(
    await monitor.autopilotRecords(), threads: [], protectedPIDs: own, now: later)
  guard let portItem = items.first(where: { $0.pid == ported }) else {
    failTest("the stranded port browser is cataloged")
    return
  }
  equal(portItem.facts["robot"], "abandoned", "nothing connected, throwaway profile")
  equal(
    AutopilotPolicy.decide(portItem, memory: AutopilotMemory()).authority,
    "starter:starter-robot-browsers")
  let portHelpers = family(of: ported)
  _ = try await monitor.autopilotBurn(
    portItem.processKey!, authority: "starter:starter-robot-browsers", label: portItem.name,
    rationale: "Proof: nothing connected.")
  check(
    waitFor(15) { !([ported] + portHelpers).contains(where: running) },
    "the port browser and its helpers stopped")

  // 3. A browser something still runs keeps its profile; the two left behind are cleared.
  let liveProfile = temp.appendingPathComponent("playwright_chromiumdev_profile-bzproof3")
  let (live, liveEnds) = try strandedChrome(
    chrome, quiet + ["--user-data-dir=" + liveProfile.path, "--remote-debugging-pipe", "about:blank"],
    pipe: true, in: root)
  browsers.append(live)
  defer { for end in liveEnds { try? end.close() } }
  check(
    waitFor(15) {
      FileManager.default.fileExists(atPath: liveProfile.appendingPathComponent("SingletonLock").path)
        || (try? FileManager.default.destinationOfSymbolicLink(
          atPath: liveProfile.appendingPathComponent("SingletonLock").path)) != nil
    }, "the running browser locked its profile")
  let left = AutopilotBrowserTrail.leftovers(in: temp.path, now: later.addingTimeInterval(3600))
    .map { ($0.path as NSString).lastPathComponent }.sorted()
  equal(
    left, ["playwright_chromiumdev_profile-bzproof1", "puppeteer_dev_chrome_profile-bzproof2"],
    "the stopped browsers' profiles, not the running one's")
  guard
    let trail = AutopilotBrowserTrail.item(
      in: temp.path, now: later.addingTimeInterval(3600), minimumBytes: 1)
  else {
    failTest("their profiles make one item")
    return
  }
  let receipt = AutopilotBrowserTrail.reclaim(
    trail, authority: "starter:starter-browser-trail", folder: temp.path,
    now: later.addingTimeInterval(3600))
  equal(receipt.outcome, "burned", receipt.detail)
  checkFalse(FileManager.default.fileExists(atPath: pipeProfile.path), "pipe profile cleared")
  checkFalse(FileManager.default.fileExists(atPath: portProfile.path), "port profile cleared")
  check(FileManager.default.fileExists(atPath: liveProfile.path), "the running browser's stays")
  check(running(live), "and the running browser with it")

  // 4. The owner's own Chrome, if it is open, is never an item.
  for o in Native().scan().observations where o.executable == chrome && o.parent == 1 {
    if let argv = Native().arguments(o.identity.pid),
      RobotBrowser.fingerprint(executable: chrome, arguments: argv) == nil
    {
      checkFalse(items.contains { $0.pid == o.identity.pid }, "the owner's Chrome stays theirs")
    }
  }
}
