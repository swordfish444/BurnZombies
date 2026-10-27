import BurnCore
import Foundation
import Darwin

func diskProof() async throws {
  let root = URL(fileURLWithPath: WorkspaceSafety.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("bz-disk-proof-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repo = root.appendingPathComponent("repo"), state = root.appendingPathComponent("state")
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  try WorkspaceSafety.git(repo.path, ["init"])
  try Data("build/\nartifacts/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
  try Data("precious source".utf8).write(to: repo.appendingPathComponent("source.txt"))
  try WorkspaceSafety.git(repo.path, ["add", "source.txt", ".gitignore"])
  let build = repo.appendingPathComponent("build"); try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
  let output = build.appendingPathComponent("output.bin")
  try Data(repeating: 17, count: 2_097_152).write(to: output)
  let old = Date().addingTimeInterval(-3*86400)
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: output.path)
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: build.path)
  var policy = DiskPolicy(); policy.roots = [repo.path]; policy.minimumAgeDays = 2; policy.minimumCandidateMB = 1
  policy.targetFreeGB = 1000; policy.mode = "automatic"
  let store = try Store(root: state)
  var inventory = DiskInventory.scan(policy: policy, previous: .init(), visibility: { _ in 0 })
  guard let first = inventory.candidates.first(where: { $0.path == build.path }) else { throw StoreError.message("Generated fixture not discovered") }
  checkFalse(first.reviewable, "Ignored output cannot create its own deletion permission")
  policy.rules = [.init(path: build.path, disposition: "regenerable")]
  inventory = DiskInventory.scan(policy: policy, previous: inventory, visibility: { _ in -1 })
  checkFalse(inventory.candidates.first!.reviewable, "Incomplete visibility remains a hard stop")
  inventory = DiskInventory.scan(policy: policy, previous: inventory, visibility: { _ in 1 })
  checkFalse(inventory.candidates.first!.reviewable, "Active consumer remains a hard stop")
  inventory = DiskInventory.scan(policy: policy, previous: inventory, visibility: { _ in 0 })
  guard let candidate = inventory.candidates.first(where: { $0.path == build.path && $0.reviewable }) else { throw StoreError.message("Released regenerable fixture should qualify: \(inventory.candidates.map(\.guardReason))") }
  var protectedPolicy = policy; protectedPolicy.protectedPaths = [output.path]
  throwsError(try DiskInventory.check(candidate, policy: protectedPolicy, visibility: { _ in 0 }))
  let lock = repo.appendingPathComponent(".git/index.lock")
  try Data().write(to: lock)
  throwsError(try DiskInventory.check(candidate, policy: policy, visibility: { _ in 0 }))
  try FileManager.default.removeItem(at: lock)
  let artifacts = repo.appendingPathComponent("artifacts")
  try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
  var evidencePaths = [String]()
  for day in [3, 4, 5] {
    let run = artifacts.appendingPathComponent("run-\(day)")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
    let file = run.appendingPathComponent("replaceable.bin")
    try Data(repeating: 19, count: 1_048_576).write(to: file)
    let date = Date().addingTimeInterval(-Double(day)*86400)
    for path in [file.path, run.path] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
    evidencePaths.append(run.path)
  }
  var retention = policy; retention.keepNewest = 2
  retention.rules += evidencePaths.map { .init(path: $0, disposition: "regenerable") }
  let retained = DiskInventory.scan(policy: retention, previous: .init(), visibility: { _ in 0 })
  equal(retained.candidates.filter { $0.kind == "evidence" && $0.reviewable }.map(\.path), [evidencePaths[2]], "Newest evidence retention must keep two full runs")
  let link = build.appendingPathComponent("external")
  try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: output.path)
  let linked = try DiskInventory.manifest(build.path)
  check(linked.unsafe || !linked.complete, "Symlink inspection must fail closed")
  try FileManager.default.removeItem(at: link)
  try Data("private".utf8).write(to: build.appendingPathComponent(".env.production"))
  throwsError(try DiskInventory.check(candidate, policy: policy, visibility: { _ in 0 }))
  try FileManager.default.removeItem(at: build.appendingPathComponent(".env.production"))
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: build.path)
  try policy.save(store)
  let monitor = try Monitor(root: state, workspaceVisibility: { _ in 0 }), service = AgentService(monitor: monitor)
  func call(_ request: AgentRequest) async -> AgentReply { var r = request; r.callerPID = getpid(); return await service.call(r) }
  _ = await monitor.refresh()
  let listed = await call(AgentRequest("status"))
  guard let id = listed.disk.first?.id else { throw StoreError.message("Disk candidate not in shared bounded queue") }
  let rationale = "The test created this exact disposable build output, preserved source, completed the build and has no remaining consumer."
  let preview = await call(AgentRequest("disk_preview", findingID: id, rationale: rationale))
  guard let token = preview.previewToken else { throw StoreError.message(preview.message) }
  policy.rules[0].disposition = "keep"; try policy.save(store)
  let protected = await call(AgentRequest("disk_clean", previewToken: token))
  checkFalse(protected.ok, "New keep rule after preview did not block removal")
  check(FileManager.default.fileExists(atPath: output.path))
  policy.rules[0].disposition = "regenerable"; try policy.save(store)
  _ = await monitor.refresh()
  let fresh = await call(AgentRequest("disk_preview", findingID: id, rationale: rationale))
  guard let next = fresh.previewToken else { throw StoreError.message(fresh.message) }
  let removed = await call(AgentRequest("disk_clean", previewToken: next))
  check(removed.ok, removed.message)
  checkFalse(FileManager.default.fileExists(atPath: build.path))
  check(FileManager.default.fileExists(atPath: repo.appendingPathComponent("source.txt").path))
  let replay = await call(AgentRequest("disk_clean", previewToken: next)); checkFalse(replay.ok)
  let saved = try store.load()
  equal(saved.diskReceipts?.filter { $0.outcome == "verified" }.count, 1)
  equal(saved.lifetimeWorktreesCleaned ?? 0, 0, "Generated output cannot count as a cleaned worktree")
  check((saved.lifetimeDiskReclaimedBytes ?? 0) <= 2_097_152)
  let today = ImpactNumbers.make(catalog: saved, period: .today)
  equal(today.disk, saved.lifetimeDiskReclaimedBytes ?? 0)
  var preset = DiskPolicy(); preset.preset("proactive"); equal(preset.minimumAgeDays, 2); equal(preset.keepNewest, 2)
  preset.roots = [NSHomeDirectory()]; throwsError(try preset.validate())
  print("PASS exact disk opt-in, active/unknown visibility refusal, sensitive files, policy-change race, single-use removal, untouched source and verified byte accounting (isolated complete-visibility fixture)")
}
