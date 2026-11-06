import BurnCore
import Darwin
import Foundation

// Command lines recorded from robot browsers on a real Mac, trimmed to the flags that matter.
private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
private let helpers =
  "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/142.0.7444.60/Helpers/"
private let renderer = helpers + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
private let gpu = helpers + "Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
/// The Playwright CLI's daemon: headless, driven over a pipe, with a throwaway profile.
private let playwrightPipe = [
  chrome, "--disable-field-trial-config", "--disable-background-networking",
  "--no-default-browser-check", "--password-store=basic", "--use-mock-keychain", "--headless",
  "--user-data-dir=/var/folders/86/abc/T/playwright_chromiumdev_profile-Xk2a9Q",
  "--remote-debugging-pipe", "--no-startup-window",
]
/// Playwright MCP with its persistent profile: headed, driven over a pipe.
private let playwrightHeaded = [
  chrome, "--no-first-run", "--user-data-dir=/Users/u/Library/Caches/ms-playwright/mcp-chrome-5f3a",
  "--remote-debugging-pipe", "--no-startup-window",
]
private let puppeteerPort = [
  "/Users/u/.cache/puppeteer/chrome/mac_arm-131.0.6778.204/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
  "--allow-pre-commit-input", "--enable-automation", "--headless=new", "--remote-debugging-port=0",
  "--user-data-dir=/var/folders/86/abc/T/puppeteer_dev_chrome_profile-QqKb1z", "about:blank",
]
private let chromedriver = [
  chrome, "--allow-pre-commit-input", "--enable-automation", "--remote-debugging-port=0",
  "--test-type=webdriver", "--use-mock-keychain",
  "--user-data-dir=/var/folders/86/abc/T/.org.chromium.Chromium.aB3dEf", "data:,",
]
private let firefoxPipe = [
  "/Users/u/Library/Caches/ms-playwright/firefox-1490/firefox/Nightly.app/Contents/MacOS/firefox",
  "-no-remote", "-headless", "-profile", "/var/folders/86/abc/T/playwright_firefoxdev_profile-9QzY",
  "-juggler-pipe", "-silent",
]
private let webkitPipe = [
  "/Users/u/Library/Caches/ms-playwright/webkit-2215/Playwright.app/Contents/MacOS/Playwright",
  "--inspector-pipe", "--headless", "--no-startup-window",
  "--user-data-dir=/var/folders/86/abc/T/playwright_webkitdev_profile-u2Hk",
]
private let headlessShell = [
  "/Users/u/Library/Caches/ms-playwright/chromium_headless_shell-1200/chrome-headless-shell-mac-arm64/chrome-headless-shell",
  "--headless", "--remote-debugging-pipe=cbor", "--no-startup-window",
  "--user-data-dir=/var/folders/86/abc/T/playwright_chromiumdev_profile-Q9",
]
/// Someone debugging their own Chrome by hand: a port, but no sign of automation.
private let debuggingByHand = [chrome, "--remote-debugging-port=9222", "--user-data-dir=/Users/u/chrome-debug"]
private let ownChrome = [chrome]

private func fingerprint(_ arguments: [String]) -> RobotBrowser? {
  RobotBrowser.fingerprint(executable: arguments[0], arguments: arguments)
}

/// A process seen once: started `age` seconds ago and barely busy since, so idle since it started.
private func seen(
  _ pid: Int32, _ executable: String, parent: Int32 = 1, age: TimeInterval, rss: UInt64 = 300 << 20
) -> Record {
  var o = Observation(
    identity: ProcessIdentity(pid: pid, seconds: UInt64(Date().timeIntervalSince1970 - age)),
    executable: executable)
  o.uid = getuid()
  o.parent = parent
  o.rss = rss
  o.cpuNS = 200_000_000
  return Record(o)
}

private func catalog(_ records: [Record]) -> [String: Record] {
  Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
}

private func probe(
  arguments: [Int32: [String]], listening: Set<Int32> = [], clients: [Int32: Int] = [:],
  cwd: String = "/Users/u/proj"
) -> AutopilotProcessProbe {
  AutopilotProcessProbe(
    listening: { listening.contains($0) }, agent: { _ in "none" }, cwd: { _ in cwd },
    alive: { _ in false }, arguments: { arguments[$0] }, clients: { clients[$0] ?? 0 })
}

private func thread(_ live: Bool, cwd: String = "/Users/u/proj") -> AgentThread {
  AgentThread(id: "codex:t", agent: "codex", cwd: cwd, live: live, lastActive: Date())
}

/// Robot browsers: recognized from their own command line, burned once nothing can drive them,
/// and their drivers burned once their chat is over. The owner's own browser is never one.
func robotBrowserPolicyProof() throws {
  // Fingerprints.
  equal(fingerprint(playwrightPipe)?.control, .pipe, "Playwright CLI daemon's browser")
  equal(fingerprint(playwrightPipe)?.throwawayProfile, true, "Playwright's temporary profile")
  equal(fingerprint(playwrightPipe)?.headless, true)
  equal(fingerprint(playwrightHeaded)?.control, .pipe, "a pipe is never opened by hand")
  equal(fingerprint(playwrightHeaded)?.throwawayProfile, false, "MCP's profile keeps logins")
  equal(fingerprint(playwrightHeaded)?.headless, false)
  equal(fingerprint(puppeteerPort)?.control, .port, "Puppeteer over a port")
  equal(fingerprint(puppeteerPort)?.throwawayProfile, true)
  equal(fingerprint(chromedriver)?.control, .port, "chromedriver")
  equal(fingerprint(chromedriver)?.throwawayProfile, true, "chromedriver's scoped profile")
  equal(fingerprint(firefoxPipe)?.control, .pipe, "Playwright's Firefox")
  equal(fingerprint(firefoxPipe)?.throwawayProfile, true, "Firefox names its profile apart")
  equal(fingerprint(webkitPipe)?.control, .pipe, "Playwright's WebKit")
  equal(fingerprint(headlessShell)?.control, .pipe, "headless shell, pipe with a format")
  isNil(fingerprint(debuggingByHand))
  isNil(fingerprint(ownChrome))
  isNil(fingerprint([chrome, "--flag-switches-begin", "--flag-switches-end"]))
  isNil(
    fingerprint([
      renderer, "--type=renderer", "--enable-automation",
      "--user-data-dir=/var/folders/86/abc/T/playwright_chromiumdev_profile-Xk2a9Q",
    ]))
  isNil(
    RobotBrowser.fingerprint(
      executable: "/opt/homebrew/bin/node",
      arguments: ["/opt/homebrew/bin/node", "x.js", "--remote-debugging-pipe", "--headless"]))

  // The live reader: this program's own arguments, one entry each.
  let ownArguments = Native().arguments(getpid())
  check(
    ownArguments?.first?.hasSuffix("BurnProof") == true && (ownArguments?.count ?? 0) >= 2,
    "own arguments: \(String(describing: ownArguments)), line: \(String(describing: Native().commandLine(getpid())))")
  check(RobotBrowser.isBrowser(chrome), "Google Chrome")
  check(RobotBrowser.isBrowser("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"))
  check(RobotBrowser.isBrowser("/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"))
  check(RobotBrowser.isBrowser("/Applications/Firefox.app/Contents/MacOS/firefox"))
  check(RobotBrowser.isBrowser(webkitPipe[0]), "Playwright's WebKit")
  checkFalse(RobotBrowser.isBrowser(renderer), "a helper is not the browser")
  checkFalse(RobotBrowser.isBrowser("/Applications/Slack.app/Contents/MacOS/Slack"))
  checkFalse(RobotBrowser.isBrowser("/opt/homebrew/bin/node"))
  equal(RobotBrowser.bundle(chrome), "/Applications/Google Chrome.app/")
  equal(RobotBrowser.bundle(renderer), "/Applications/Google Chrome.app/", "outermost bundle")
  isNil(RobotBrowser.bundle("/opt/homebrew/bin/node"))
  equal(AutopilotProcesses.family(chrome), "browser", "Chrome is a browser, not other")

  // An abandoned pipe browser: its driver is gone and no one can ever reconnect. It's burned even
  // while a chat works in its folder, since that chat can't reach it and it holds its profile.
  let main = seen(700, chrome, age: 20 * 60)
  let paint = seen(701, renderer, parent: 700, age: 20 * 60)
  let graphics = seen(702, gpu, parent: 700, age: 20 * 60)
  let abandoned = AutopilotProcesses.items(
    catalog([main, paint, graphics]), threads: [thread(true)], protectedPIDs: [],
    probe: probe(arguments: [700: playwrightPipe]))
  equal(abandoned.count, 1, "helpers ride with their browser")
  let robot = abandoned.first
  isNil(robot?.protectedReason)
  equal(robot?.facts["robot"], "abandoned")
  equal(robot?.facts["family"], "browser")
  equal(robot?.facts["orphaned"], "yes", "its driver is gone")
  equal(robot?.facts["idle"], "10m")
  equal(robot?.name, "Google Chrome (robot)")
  equal(robot?.bytes, 900 << 20, "the browser and its helpers")
  check(robot?.detail.contains("Nothing can drive it") == true, robot?.detail ?? "no detail")
  if let robot {
    let decision = AutopilotPolicy.decide(robot, memory: AutopilotMemory())
    equal(decision.status, .burn, "abandoned robot browser idle 10 minutes")
    equal(decision.authority, "starter:starter-robot-browsers")
  }
  let fresh = AutopilotProcesses.items(
    catalog([seen(700, chrome, age: 120)]), threads: [], protectedPIDs: [],
    probe: probe(arguments: [700: playwrightPipe])
  ).first
  equal(fresh?.facts["robot"], "abandoned")
  if let fresh {
    equal(AutopilotPolicy.decide(fresh, memory: AutopilotMemory()).status, .unsure, "not idle yet")
  }

  // A port browser is abandoned only with a throwaway profile and nothing connected; a chat
  // working in its folder could still connect, so it protects it.
  func portItem(_ arguments: [String], clients: Int, threads: [AgentThread] = []) -> AutopilotItem? {
    AutopilotProcesses.items(
      catalog([seen(800, arguments[0], age: 3 * 3600)]), threads: threads, protectedPIDs: [],
      probe: probe(arguments: [800: arguments], listening: [800], clients: [800: clients])
    ).first
  }
  equal(portItem(puppeteerPort, clients: 0)?.facts["robot"], "abandoned")
  equal(portItem(chromedriver, clients: 0)?.facts["robot"], "abandoned")
  equal(portItem(puppeteerPort, clients: 1)?.facts["robot"], "driven", "a client is attached")
  let kept = [chrome, "--headless", "--remote-debugging-port=9223", "--user-data-dir=/Users/u/.codex/passive"]
  equal(portItem(kept, clients: 0)?.facts["robot"], "driven", "a profile someone keeps")
  equal(
    portItem(puppeteerPort, clients: 0, threads: [thread(true)])?.protectedReason,
    "A chat is still working in this project.")
  if let port = portItem(puppeteerPort, clients: 0) {
    equal(AutopilotPolicy.decide(port, memory: AutopilotMemory()).authority, "starter:starter-robot-browsers")
  }

  // The owner's own browser is never an item, and a robot's tree may hold nothing else bundled.
  // Programs with no robot browser keep exactly the facts they had.
  let plain = AutopilotProcesses.items(
    catalog([seen(930, "/opt/homebrew/bin/node", age: 3 * 3600)]), threads: [],
    protectedPIDs: [], probe: probe(arguments: [:])
  ).first
  check(plain != nil, "a plain leftover is an item")
  isNil(plain?.facts["robot"])
  let own = AutopilotProcesses.items(
    catalog([seen(900, chrome, age: 3 * 3600), seen(901, renderer, parent: 900, age: 3 * 3600)]),
    threads: [], protectedPIDs: [], probe: probe(arguments: [900: ownChrome]))
  check(own.isEmpty, "the owner's Chrome is an app they use")
  let debugging = AutopilotProcesses.items(
    catalog([seen(910, chrome, age: 3 * 3600)]), threads: [], protectedPIDs: [],
    probe: probe(arguments: [910: debuggingByHand], listening: [910]))
  check(debugging.isEmpty, "Chrome opened by hand for debugging is theirs")
  let stranger = AutopilotProcesses.items(
    catalog([
      seen(920, chrome, age: 3 * 3600),
      seen(921, "/Applications/Notes.app/Contents/MacOS/Notes", parent: 920, age: 3 * 3600),
    ]), threads: [], protectedPIDs: [], probe: probe(arguments: [920: playwrightPipe])
  ).first
  equal(stranger?.protectedReason, "Part of it is something I must not touch.")

  // A driver holding a robot browser: burned an hour after its chat ended, when it serves no port.
  let driverPath = "/Users/u/.nvm/versions/node/v22.23.1/bin/node"
  func driver(threads: [AgentThread], listening: Set<Int32> = [], age: TimeInterval = 3 * 3600)
    -> AutopilotItem?
  {
    AutopilotProcesses.items(
      catalog([
        seen(600, driverPath, age: age, rss: 140 << 20), seen(601, chrome, parent: 600, age: age),
        seen(602, renderer, parent: 601, age: age),
      ]), threads: threads, protectedPIDs: [],
      probe: probe(arguments: [601: playwrightPipe], listening: listening)
    ).first
  }
  let ended = driver(threads: [thread(false)])
  isNil(ended?.protectedReason)
  equal(ended?.facts["robot"], "driven")
  equal(ended?.facts["family"], "node")
  equal(ended?.facts["orphaned"], "maybe", "a detached daemon was never seen with its parent")
  check(ended?.detail.contains("robot browser") == true, ended?.detail ?? "no detail")
  if let ended {
    let decision = AutopilotPolicy.decide(ended, memory: AutopilotMemory())
    equal(decision.status, .burn, "a driver whose chat ended, idle an hour")
    equal(decision.authority, "starter:starter-robot-drivers")
  }
  equal(
    driver(threads: [thread(true)])?.protectedReason, "A chat is still working in this project.")
  for (label, item) in [
    ("no chat ever worked there", driver(threads: [])),
    ("it serves a port", driver(threads: [thread(false)], listening: [600])),
    ("idle only minutes", driver(threads: [thread(false)], age: 20 * 60)),
  ] {
    guard let item else {
      failTest("driver item: " + label)
      continue
    }
    equal(AutopilotPolicy.decide(item, memory: AutopilotMemory()).status, .unsure, label)
  }

  // Burn-time rails: only a robot browser's own bundle is exempt, and nothing else is relaxed.
  equal(
    AutopilotProcesses.rail(main, protectedPIDs: [], preferences: Preferences()),
    "It's part of an app you use.")
  isNil(AutopilotProcesses.rail(main, protectedPIDs: [], preferences: Preferences(), robot: true))
  var kept2 = main
  kept2.protection = true
  equal(
    AutopilotProcesses.rail(kept2, protectedPIDs: [], preferences: Preferences(), robot: true),
    "You asked me to keep it.")
  let members = AutopilotProcesses.robots(
    in: [main, paint, graphics, seen(703, "/opt/homebrew/bin/node", parent: 700, age: 60)],
    arguments: { $0 == 700 ? playwrightPipe : nil })
  equal(members.browsers.keys.sorted(), [700])
  equal(members.members, [700, 701, 702], "the browser and its own helpers, nothing else")

  // Temp leftovers have a rule of their own.
  let trail = AutopilotItem(
    id: "disk:trail", kind: .disk, name: "Robot-browser leftovers", bytes: 300 << 20,
    facts: ["folder": "browser-temp", "home": "temp", "stale": "day", "size": "small"])
  equal(
    AutopilotPolicy.decide(trail, memory: AutopilotMemory()).authority,
    "starter:starter-browser-trail")
  var off = AutopilotMemory()
  off.starterDisabled = ["starter-robot-browsers", "starter-robot-drivers", "starter-browser-trail"]
  if let robot { equal(AutopilotPolicy.decide(robot, memory: off).status, .unsure, "switched off") }
  equal(AutopilotPolicy.decide(trail, memory: off).status, .unsure)

  // Playwright's downloads: only browser builds, and never the newest of each kind.
  equal(
    AutopilotDisk.playwrightBuilds([
      "chromium-1200", "chromium-1228", "chromium_headless_shell-1200",
      "chromium_headless_shell-1228", "ffmpeg-1011", "ffmpeg-1013", "mcp-chrome", "mcp-firefox-2b",
      "daemon", "b", "cli-update-check.json", ".links", "webkit-2215",
    ]), ["chromium-1200", "chromium_headless_shell-1200", "ffmpeg-1011"])
  try playwrightCacheProof()
  try browserTrailProof()
}

/// Every entry under `path`, and `path` itself, last changed `seconds` ago. Deepest first, since
/// changing a folder's contents stamps the folder.
private func age(_ path: String, by seconds: TimeInterval) {
  let when = Date().addingTimeInterval(-seconds)
  var paths = [path]
  if let walker = FileManager.default.enumerator(atPath: path) {
    for case let relative as String in walker { paths.append(path + "/" + relative) }
  }
  for entry in paths.sorted(by: { $0.count > $1.count }) {
    var times = [
      timespec(tv_sec: Int(when.timeIntervalSince1970), tv_nsec: 0),
      timespec(tv_sec: Int(when.timeIntervalSince1970), tv_nsec: 0),
    ]
    _ = utimensat(AT_FDCWD, entry, &times, AT_SYMLINK_NOFOLLOW)
  }
}

private func playwrightCacheProof() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-playwright-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: home) }
  let library = home.appendingPathComponent("Library/Caches/ms-playwright")
  let dotCache = home.appendingPathComponent(".cache/ms-playwright")
  for folder in [
    library.appendingPathComponent("chromium-1200"), library.appendingPathComponent("chromium-1228"),
    library.appendingPathComponent("mcp-chrome"), library.appendingPathComponent("daemon"),
    dotCache.appendingPathComponent("chromium-1100"), dotCache.appendingPathComponent("chromium-1200"),
  ] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(count: 4096).write(to: folder.appendingPathComponent("payload"))
  }
  let canonical = WorkspaceSafety.canonical(home.path)
  let items = AutopilotDisk.items(
    worktrees: [], home: home.path, caches: true, mains: false, sizer: { _ in 200_000_000 })
  let offered = items.compactMap(\.path).filter { $0.contains("ms-playwright") }.sorted()
  equal(
    offered,
    [
      canonical + "/.cache/ms-playwright/chromium-1100",
      canonical + "/Library/Caches/ms-playwright/chromium-1200",
    ], "old builds only, in both places Playwright keeps them")

  func reclaim(_ path: String) -> AutopilotReceipt {
    AutopilotDisk.reclaim(
      AutopilotItem(
        id: "disk:" + path, kind: .disk, name: (path as NSString).lastPathComponent,
        path: path, bytes: 200_000_000,
        facts: ["folder": "package-cache", "home": "global-cache", "stale": "month"]),
      authority: "starter:test", home: home.path, inUse: { _ in 0 })
  }
  let newest = reclaim(canonical + "/Library/Caches/ms-playwright/chromium-1228")
  equal(newest.outcome, "refused", "the newest build is the one in use")
  check(FileManager.default.fileExists(atPath: canonical + "/Library/Caches/ms-playwright/chromium-1228"))
  let profile = reclaim(canonical + "/Library/Caches/ms-playwright/mcp-chrome")
  equal(profile.outcome, "refused", "an agent's browser profile holds its logins")
  check(FileManager.default.fileExists(atPath: canonical + "/Library/Caches/ms-playwright/mcp-chrome"))
  let old = reclaim(canonical + "/.cache/ms-playwright/chromium-1100")
  equal(old.outcome, "burned", old.detail)
  checkFalse(FileManager.default.fileExists(atPath: canonical + "/.cache/ms-playwright/chromium-1100"))
}

private func browserTrailProof() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-trail-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let fm = FileManager.default
  func make(_ name: String, files: [String] = ["Default/Cookies"]) throws -> String {
    let path = folder.appendingPathComponent(name).path
    for file in files {
      let url = URL(fileURLWithPath: path + "/" + file)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(count: 64 << 10).write(to: url)
    }
    return path
  }
  let dead = try make("playwright_chromiumdev_profile-old1")
  let recording = try make("playwright-artifacts-old2", files: ["video.webm"])
  let puppeteer = try make("puppeteer_dev_chrome_profile-old3")
  let busy = try make("playwright_chromiumdev_profile-busy")
  let recent = try make("playwright_chromiumdev_profile-new")
  let live = try make("playwright_chromiumdev_profile-live")
  try fm.createSymbolicLink(atPath: live + "/SingletonLock", withDestinationPath: "host-\(getpid())")
  let stale = try make("playwright_chromiumdev_profile-stale")
  try fm.createSymbolicLink(atPath: stale + "/SingletonLock", withDestinationPath: "host-999999")
  let unrelated = try make("my-notes")
  let elsewhere = try make("elsewhere-target")
  try fm.createSymbolicLink(
    atPath: folder.appendingPathComponent("playwright_chromiumdev_profile-link").path,
    withDestinationPath: elsewhere)
  for path in [dead, recording, puppeteer, busy, live, stale, unrelated, elsewhere] {
    age(path, by: 3 * 3600)
  }

  let base = WorkspaceSafety.canonical(folder.path)
  let found = AutopilotBrowserTrail.leftovers(in: folder.path).map { ($0.path as NSString).lastPathComponent }
  equal(
    found.sorted(),
    [
      "playwright-artifacts-old2", "playwright_chromiumdev_profile-busy",
      "playwright_chromiumdev_profile-old1", "playwright_chromiumdev_profile-stale",
      "puppeteer_dev_chrome_profile-old3",
    ], "old, unlocked, real folders with a robot browser's name")
  guard let item = AutopilotBrowserTrail.item(in: folder.path, minimumBytes: 1) else {
    failTest("leftovers make one item")
    return
  }
  equal(item.facts["folder"], "browser-temp")
  equal(item.path, base)
  check(item.bytes >= 5 * (64 << 10), "sized: \(item.bytes)")
  isNil(AutopilotBrowserTrail.item(in: folder.path, minimumBytes: 1 << 40))

  let elsewhereItem = AutopilotItem(
    id: item.id, kind: .disk, name: item.name, path: "/private/tmp", bytes: item.bytes,
    facts: item.facts)
  equal(
    AutopilotBrowserTrail.reclaim(elsewhereItem, authority: "starter:test", folder: folder.path)
      .outcome, "refused", "only the temp folder it was found in")

  let withdrawn = AutopilotBrowserTrail.reclaim(
    item, authority: "starter:starter-browser-trail", folder: folder.path,
    inUse: { $0.hasSuffix("-busy") ? 1 : 0 }, authorize: { false })
  equal(withdrawn.outcome, "refused", "look-only or a new keep since the decision")
  check(fm.fileExists(atPath: dead), "nothing removed without authority")
  let receipt = AutopilotBrowserTrail.reclaim(
    item, authority: "starter:starter-browser-trail", folder: folder.path,
    inUse: { $0.hasSuffix("-busy") ? 1 : 0 })
  equal(receipt.outcome, "burned", receipt.detail)
  check(receipt.bytes >= 4 * (64 << 10), "credited: \(receipt.bytes)")
  for gone in [dead, recording, puppeteer, stale] {
    checkFalse(fm.fileExists(atPath: gone), "removed " + gone)
  }
  for kept in [busy, recent, live, unrelated, elsewhere] {
    check(fm.fileExists(atPath: kept), "kept " + kept)
  }
  check(
    (try? fm.destinationOfSymbolicLink(
      atPath: folder.appendingPathComponent("playwright_chromiumdev_profile-link").path)) != nil,
    "a link is never followed or removed")
}
