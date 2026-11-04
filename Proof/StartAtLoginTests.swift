import BurnCore
import Foundation

/// Start at login is on for a fresh install and never overrides a choice. A fake login item
/// stands in for macOS, so nothing on this Mac is registered.
func startAtLoginProof() throws {
  let fm = FileManager.default
  let base = fm.temporaryDirectory.appendingPathComponent("bz-start-at-login-" + UUID().uuidString)
  defer { try? fm.removeItem(at: base) }
  final class LoginItem {
    var enabled = false
    var registrations = 0
    var removals = 0
    var refusal: String?
  }
  func launch(_ root: URL, _ item: LoginItem) -> StartAtLogin.Outcome {
    StartAtLogin.decideAtLaunch(
      root: root, isEnabled: { item.enabled },
      register: {
        item.registrations += 1
        if let refusal = item.refusal { throw StoreError.message(refusal) }
        item.enabled = true
      })
  }
  func choose(_ enabled: Bool, _ root: URL, _ item: LoginItem) throws {
    try StartAtLogin.choose(
      enabled, root: root,
      register: {
        if let refusal = item.refusal { throw StoreError.message(refusal) }
        item.registrations += 1
        item.enabled = true
      },
      unregister: {
        if let refusal = item.refusal { throw StoreError.message(refusal) }
        item.removals += 1
        item.enabled = false
      })
  }
  /// What an observer that has run leaves behind, as on any install of an older version.
  func observerRan(_ root: URL) throws { try Store(root: root).save(Catalog()) }

  // A fresh install starts at login on its first launch, even when the installer's setup wrote
  // its configuration first or the app is opened days after an install with --no-open.
  let fresh = base.appendingPathComponent("fresh")
  try MachineReviewConfiguration(
    harness: "codex", executable: "/bin/true", launcher: "/bin/true", server: "/bin/true"
  ).save(root: fresh)
  let item = LoginItem()
  equal(launch(fresh, item), .registered, "A fresh install did not start at login")
  check(item.enabled && item.registrations == 1, "A fresh install registered \(item.registrations) times")
  equal(StartAtLogin.recorded(root: fresh), true, "A fresh install did not record its choice")
  try observerRan(fresh)
  equal(launch(fresh, item), .unchanged, "A later launch changed a decided login item")
  equal(item.registrations, 1, "A later launch registered again")

  // Turned off in Settings, it stays off through every update.
  try choose(false, fresh, item)
  check(!item.enabled && item.removals == 1, "Settings did not turn it off")
  equal(StartAtLogin.recorded(root: fresh), false, "Settings did not record the opt-out")
  for _ in 0..<2 { equal(launch(fresh, item), .unchanged, "An update overrode the opt-out") }
  check(!item.enabled && item.registrations == 1, "An update turned Start at login back on")
  // The choice holds without a catalog too, for example after the catalog was deleted.
  try fm.removeItem(at: fresh.appendingPathComponent("catalog.bzcat"))
  equal(launch(fresh, item), .unchanged, "A missing catalog overrode the opt-out")
  check(!item.enabled && item.registrations == 1, "A missing catalog turned it back on")
  // Back on in Settings, then removed in System Settings → Login Items: updates leave that too.
  try choose(true, fresh, item)
  check(item.enabled && item.registrations == 2, "Settings did not turn it back on")
  equal(StartAtLogin.recorded(root: fresh), true, "Settings did not record turning it on")
  item.enabled = false
  equal(launch(fresh, item), .unchanged, "An update overrode removal in System Settings")
  check(!item.enabled && item.registrations == 2, "An update re-added a removed login item")

  // An update from a version that never asked keeps what the Mac does now: nothing says
  // whether the person switched it off.
  for already in [false, true] {
    let older = base.appendingPathComponent("older-\(already)")
    try observerRan(older)
    let existing = LoginItem()
    existing.enabled = already
    equal(launch(older, existing), .unchanged, "An update from an older version changed it")
    check(
      existing.enabled == already && existing.registrations == 0,
      "An update from an older version registered a login item")
    equal(StartAtLogin.recorded(root: older), already, "An update did not keep the Mac's setting")
    equal(launch(older, existing), .unchanged, "A second launch after an update changed it")
  }
  // A reinstall after deleting BZ's folder can find its login item still there.
  let reinstall = base.appendingPathComponent("reinstall")
  let kept = LoginItem()
  kept.enabled = true
  equal(launch(reinstall, kept), .unchanged, "A reinstall registered its login item again")
  equal(kept.registrations, 0, "A reinstall registered its login item again")
  equal(StartAtLogin.recorded(root: reinstall), true, "A reinstall did not record it as on")

  // macOS refuses: the first launch says so once, and later launches don't retry on their own.
  let refused = base.appendingPathComponent("refused")
  let denied = LoginItem()
  denied.refusal = "Operation not permitted"
  equal(launch(refused, denied), .refused("Operation not permitted"), "A refusal was hidden")
  equal(launch(refused, denied), .unchanged, "A refusal was retried on the next launch")
  equal(denied.registrations, 1, "A refusal was retried")
  equal(StartAtLogin.recorded(root: refused), false, "A refusal was recorded as on")
  // A change Settings could not make records nothing.
  throwsError(try choose(true, refused, denied))
  equal(StartAtLogin.recorded(root: refused), false, "A refused change was recorded")

  // Only the installed app changes this Mac's login items: never a debug build or a proof,
  // and never with an isolated BZ home.
  let app = URL(fileURLWithPath: "/Users/someone/Applications/BurnZombies.app")
  check(StartAtLogin.applies(bundle: app, environment: [:]), "The installed app was skipped")
  checkFalse(
    StartAtLogin.applies(bundle: URL(fileURLWithPath: "/tmp/BurnZombies/.build/debug"), environment: [:]),
    "A debug build changed login items")
  checkFalse(
    StartAtLogin.applies(bundle: app, environment: ["BURNZOMBIES_HOME": "/tmp/bz-test"]),
    "An isolated BZ home changed this Mac's login items")
}
