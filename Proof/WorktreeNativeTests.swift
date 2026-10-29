import BurnCore
import CBurn
import CryptoKit
import Darwin
import Foundation

private final class NativePathMatch {
  let target: String
  var matched = false
  init(_ target: String) { self.target = target }
}

func worktreeNativeProof(descriptorOnly: Bool = false) async throws {
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent(
    "bz-native-worktree-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = URL(fileURLWithPath: WorkspaceSafety.canonical(temporary.path))
  defer { try? fm.removeItem(at: base) }
  let target = base.appendingPathComponent("high-fd-control")
  try Data("synthetic descriptor control".utf8).write(to: target)
  var limit = rlimit()
  guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
    throw StoreError.message("Cannot inspect fixture descriptor allowance.")
  }
  let originalLimit = limit
  guard limit.rlim_max >= 6200 else {
    throw StoreError.message("Host cannot run the >4,096-descriptor regression fixture.")
  }
  if limit.rlim_cur < 6200 {
    limit.rlim_cur = 6200
    guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
      throw StoreError.message("Cannot reserve descriptor capacity inside the proof process.")
    }
  }
  var descriptors: [Int32] = []
  defer {
    descriptors.forEach { close($0) }
    var saved = originalLimit
    _ = setrlimit(RLIMIT_NOFILE, &saved)
  }
  for _ in 0..<5000 {
    let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else {
      throw StoreError.message("Sacrificial descriptor fixture exhausted its process allowance.")
    }
    descriptors.append(fd)
  }
  let held = open(target.path, O_RDONLY | O_CLOEXEC)
  guard held > 4096 else {
    throw StoreError.message("Descriptor control did not exceed the old fixed buffer.")
  }
  descriptors.append(held)
  let match = NativePathMatch(target.path)
  var gap = [CChar](repeating: 0, count: 256)
  let coverage = bz_worktree_pid_paths(
    getpid(),
    { context, path in
      guard let context, let path else { return }
      let value = Unmanaged<NativePathMatch>.fromOpaque(context).takeUnretainedValue()
      if String(cString: path) == value.target { value.matched = true }
    }, Unmanaged.passUnretained(match).toOpaque(), &gap, gap.count)
  equal(coverage, 0, String(cString: gap))
  check(match.matched, "An open file above descriptor 4,096 was missed")
  descriptors.forEach { close($0) }
  descriptors = []
  print("PASS real 5,000-descriptor native coverage and high-descriptor open-file control")
  if descriptorOnly { return }

  let repository = base.appendingPathComponent("repository")
  let checkout = base.appendingPathComponent("finished")
  try fm.createDirectory(at: repository, withIntermediateDirectories: false)
  _ = try WorktreeGit.run(repository.path, ["init", "--initial-branch=main"])
  try Data("native fixture content\n".utf8).write(to: repository.appendingPathComponent("source"))
  _ = try WorktreeGit.run(repository.path, ["add", "."])
  _ = try WorktreeGit.run(
    repository.path,
    [
      "-c", "user.name=Proof", "-c", "user.email=proof@example.invalid", "commit", "-m",
      "native fixture",
    ])
  _ = try WorktreeGit.run(repository.path, ["worktree", "add", "--detach", checkout.path])
  let state = base.appendingPathComponent("state")
  let key = SymmetricKey(data: Data(repeating: 49, count: 32))
  // Only the access-setup prerequisite and secret material are injected. The
  // production worker, kernel path reader, Git, files, recovery and actuator run.
  let service = try WorktreeService(
    root: state, access: { fixtureAccess() }, recoveryKey: { key },
    scanRunner: WorktreeScanRunner(executable: URL(fileURLWithPath: CommandLine.arguments[0])))
  func request(_ q: WorktreeRequest) async throws -> WorktreeReply {
    try await service.request(q, caller: "native-fixture")
  }
  _ = try await request(.init("add_root", path: base.path))
  let inventory = try await request(.init("scan"))
  guard let row = inventory.records.first(where: { $0.path == checkout.path }) else {
    throw StoreError.message("Native fixture inventory missing.")
  }
  guard row.gaps.isEmpty, row.consumer == "none observed" else {
    throw StoreError.message(
      "Native positive removal remains blocked: "
        + (row.gaps + inventory.gaps).joined(separator: "; "))
  }
  _ = try await request(.init("adopt", id: row.id, revision: row.revision))
  _ = try await request(
    .init(
      "confirm", id: row.id, revision: row.revision,
      evidence: "The native sacrificial fixture finished and has no continuing consumer."))
  let preview = try await request(.init("preview", id: row.id, revision: row.revision))
  let result = try await request(.init("retire", token: preview.token))
  equal(result.operations.first?.phase, "completed")
  checkFalse(fm.fileExists(atPath: checkout.path))
  let restore = base.appendingPathComponent("restored")
  _ = try await request(.init("restore", id: result.operations.first!.id, path: restore.path))
  equal(
    try Data(contentsOf: restore.appendingPathComponent("source")),
    Data("native fixture content\n".utf8))
  await service.shutdown()
  print(
    "PASS actual native worker → inventory → guarded retirement → encrypted recovery → restoration; no simulated consumer visibility"
  )
}
