import BurnCore
import Foundation

/// Every deletion here is inside a synthetic home. No real Gradle cache is inspected or changed.
func autopilotGradleCacheProof() throws {
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-gradle-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = WorkspaceSafety.canonical(temporary.path)
  defer { try? fm.removeItem(atPath: base) }
  let home = base + "/home"
  let caches = home + "/" + AutopilotGradleCaches.relativePath
  let root = URL(fileURLWithPath: base + "/state")
  let recognized = ["8.14.5", "9.8.2", "build-cache-1", "jars-9", "modules-2", "transforms-4"]
  let preserved = ["keyrings", "journal-1", "private-notes", "modules-custom", "8.14.backup"]
  for name in recognized + preserved {
    try gradleCacheWrite("fixture for " + name, at: caches + "/" + name + "/payload")
  }
  try gradleCacheWrite("tag", at: caches + "/CACHEDIR.TAG")
  try gradleCacheWrite("lock", at: caches + "/cache.lock")
  // A recognized name is still refused if it is a file or a symlink.
  try gradleCacheWrite("plain file", at: caches + "/7.6")
  try gradleCacheWrite("outside data", at: base + "/outside/payload")
  try fm.createSymbolicLink(atPath: caches + "/6.9", withDestinationPath: base + "/outside")

  for name in recognized + ["8.0", "0.9"] {
    check(AutopilotGradleCaches.isCacheDirectory(name), "recognized Gradle cache: " + name)
    check(AutopilotGradleCaches.displayName(name) != nil, "recognized cache has a label")
  }
  equal(AutopilotGradleCaches.displayName("8.14.5"), "Gradle 8.14.5 cache")
  equal(AutopilotGradleCaches.displayName("modules-2"), "Gradle downloaded packages 2")
  for name in preserved + [
    "", ".", "..", "8", "8..2", "8.2.", ".8.2", "8.2/child", "../8.2",
    "8.2-custom", "modules-", "modules-0", "modules-01", "modules-2/private", "jars-９",
    "CACHEDIR.TAG", "cache.lock",
  ] {
    checkFalse(AutopilotGradleCaches.isCacheDirectory(name), "preserved Gradle name: " + name)
  }

  var sized: [String] = []
  let items = AutopilotDisk.items(
    worktrees: [], home: home, mains: false,
    sizer: { path in
      sized.append(path)
      return 500_000_000
    })
  equal(Set(items.compactMap(\.path)), Set(recognized.map { caches + "/" + $0 }),
    "Gradle caches are independent items; unknown contents, links and files stay unlisted")
  checkFalse(sized.contains(caches), "the whole Gradle root is never sized as one candidate")
  for name in preserved {
    checkFalse(sized.contains(caches + "/" + name), "unknown contents are not even sized")
  }
  for item in items {
    equal(AutopilotGradleCaches.keepParent(for: item, home: home), caches,
      "recognized children retain the explicit parent keep")
    check(AutopilotDisk.regenerable(item.path!, home: home), "recognized cache is regenerable")
  }
  checkFalse(AutopilotDisk.regenerable(caches, home: home), "legacy root is no longer removable")
  for name in preserved {
    checkFalse(AutopilotDisk.regenerable(caches + "/" + name, home: home),
      "unknown Gradle child is not regenerable")
  }

  guard let old = items.first(where: { $0.path == caches + "/8.14.5" }),
    let busy = items.first(where: { $0.path == caches + "/9.8.2" })
  else { throw StoreError.message("Gradle child fixture was not discovered.") }
  let burned = AutopilotDisk.reclaim(
    old, authority: "operator", home: home, inUse: { _ in 0 }, root: root)
  equal(burned.outcome, "burned", "an unused version can be reclaimed separately")
  checkFalse(fm.fileExists(atPath: old.path!), "unused version was removed")
  let held = AutopilotDisk.reclaim(
    busy, authority: "operator", home: home,
    inUse: { path in
      equal(path, busy.path!, "live-use check is scoped to the individual version")
      return 1
    }, root: root)
  equal(held.outcome, "refused", "active version is preserved")
  let unknownUse = AutopilotDisk.reclaim(
    busy, authority: "operator", home: home, inUse: { _ in -1 }, root: root)
  equal(unknownUse.outcome, "refused", "unknown process visibility still preserves the cache")

  // Neither old persisted root items nor forged package-cache facts may bypass the whitelist.
  for path in [caches, caches + "/keyrings", caches + "/private-notes", caches + "/6.9"] {
    var forged = busy
    forged.path = path
    forged.id = "disk:" + AutopilotItem.hash(path)
    let receipt = AutopilotDisk.reclaim(
      forged, authority: "operator", home: home, inUse: { _ in 0 }, root: root)
    equal(receipt.outcome, "refused", "unrecognized or linked cache remains protected")
    if path != caches + "/6.9" {
      check(AutopilotGradleCaches.keepParent(for: forged, home: home) == nil,
        "parent keep is only inherited by recognized child names")
    }
  }
  var elsewhere = busy
  elsewhere.path = home + "/project/.gradle/caches/9.8.2"
  check(AutopilotGradleCaches.keepParent(for: elsewhere, home: home) == nil,
    "a project cache cannot inherit a keep on the global cache")
  elsewhere.path = caches + "/9.8.2/nested"
  check(AutopilotGradleCaches.keepParent(for: elsewhere, home: home) == nil,
    "parent keep helper requires an immediate child")
  elsewhere.path = busy.path
  elsewhere.facts["home"] = "repo"
  check(AutopilotGradleCaches.keepParent(for: elsewhere, home: home) == nil,
    "parent keep helper requires a global cache item")

  for path in preserved.map({ caches + "/" + $0 + "/payload" }) + [
    busy.path! + "/payload", caches + "/CACHEDIR.TAG", caches + "/cache.lock",
    caches + "/7.6", base + "/outside/payload",
  ] {
    check(fm.fileExists(atPath: path), "unrelated data survived granular cleanup: " + path)
  }
}

private func gradleCacheWrite(_ text: String, at path: String) throws {
  let url = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
}
