import BurnCore
import CBurn
import Darwin
import Foundation

private final class MetadataPaths {
  var paths: [String] = []
}

func worktreeVisibilityProof() throws {
  let path = "/synthetic/checkout/file\nwith-newline"
  let valid =
    "p123\0\nf3\0tREG\0D0x10\0i24\0n\(path)\0\nf4\0tDIR\0D0x10\0i25\0n/synthetic/other\0\n"
  func parse(_ input: String, pid: Int32 = 123, fds: [Int32] = [3, 4]) -> (Int32, [String]) {
    let box = MetadataPaths()
    let data = Data(input.utf8)
    let result = data.withUnsafeBytes { bytes in
      fds.withUnsafeBufferPointer { expected in
        bz_worktree_lsof_parse(
          bytes.baseAddress?.assumingMemoryBound(to: CChar.self), data.count, pid,
          expected.baseAddress, Int32(fds.count),
          { context, path in
            guard let context, let path else { return }
            Unmanaged<MetadataPaths>.fromOpaque(context).takeUnretainedValue().paths.append(
              String(cString: path))
          }, Unmanaged.passUnretained(box).toOpaque())
      }
    }
    return (result, box.paths)
  }
  let complete = parse(valid)
  equal(complete.0, 0)
  equal(complete.1, [path, "/synthetic/other"])
  for bad in [
    valid.replacingOccurrences(of: "p123", with: "p124"),
    valid.replacingOccurrences(of: "f4", with: "f3"),
    valid.replacingOccurrences(of: "tDIR\0", with: ""),
    valid.replacingOccurrences(of: "D0x10", with: "D0"),
    valid.replacingOccurrences(of: "i25", with: "i0"),
    valid.replacingOccurrences(of: "n/synthetic/other", with: "nrelative"),
    valid.replacingOccurrences(of: "n/synthetic/other", with: "n/synthetic/escaped\\x0a"),
    valid.replacingOccurrences(of: "n/synthetic/other", with: "n/synthetic/other (deleted)"),
    valid.replacingOccurrences(of: "tDIR", with: "tunknown"),
    valid.replacingOccurrences(of: "f4\0tDIR", with: "f4\0xunexpected\0tDIR"),
    String(valid.dropLast(2)), "", "p123\0\n",
  ] { check(parse(bad).0 != 0, "Incomplete/ambiguous metadata authorized a complete observation") }
  check(parse(valid, fds: [3, 4, 5]).0 != 0)
  check(parse(valid, fds: [3, 3]).0 != 0)
  check(parse(valid, fds: [3]).0 != 0)

  // Reproduce a live executable moved by an updater, without restarting or
  // signaling any user application. Its actual mapped image must be observed.
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-moved-exe-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("sleep")
  let moved = root.appendingPathComponent("moved-sleep")
  try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: source.path)
  var argv = [strdup(source.path), strdup("60"), nil]
  defer { argv.forEach { free($0) } }
  var environment = [strdup("PATH=/usr/bin:/bin"), nil]
  defer { environment.forEach { free($0) } }
  var child: pid_t = -1
  guard posix_spawn(&child, source.path, nil, nil, &argv, &environment) == 0, child > 1 else {
    throw StoreError.message("Cannot start moved-image fixture")
  }
  defer {
    kill(child, SIGTERM)
    var status: Int32 = 0
    _ = waitpid(child, &status, 0)
  }
  // posix_spawn can return while dyld/exit is still changing process metadata.
  // Establish the live fixture before racing an updater-style rename.
  let readyDeadline = Date().addingTimeInterval(2)
  var ready = false
  while Date() < readyDeadline {
    var before = [CChar](repeating: 0, count: 256)
    let readyBox = MetadataPaths()
    let status = bz_worktree_pid_paths(
      child,
      { context, path in
        guard let context, let path else { return }
        Unmanaged<MetadataPaths>.fromOpaque(context).takeUnretainedValue().paths.append(
          String(cString: path))
      }, Unmanaged.passUnretained(readyBox).toOpaque(), &before, before.count)
    if status == 0 && readyBox.paths.contains(WorkspaceSafety.canonical(source.path)) {
      ready = true
      break
    }
    Thread.sleep(forTimeInterval: 0.01)
  }
  check(ready, "Moved-image fixture did not become visible before rename")
  try FileManager.default.moveItem(at: source, to: moved)
  let box = MetadataPaths()
  var gap = [CChar](repeating: 0, count: 256)
  let coverage = bz_worktree_pid_paths(
    child,
    { context, path in
      guard let context, let path else { return }
      Unmanaged<MetadataPaths>.fromOpaque(context).takeUnretainedValue().paths.append(
        String(cString: path))
    }, Unmanaged.passUnretained(box).toOpaque(), &gap, gap.count)
  equal(coverage, 0, "Moved-image coverage: " + String(cString: gap))
  check(
    box.paths.contains(WorkspaceSafety.canonical(moved.path)),
    "Moved executable was lost from native coverage")
  let zombie = bz_zombie_fixture()
  guard zombie > 1 else { throw StoreError.message("Cannot start zombie visibility fixture") }
  defer {
    var status: Int32 = 0
    _ = waitpid(zombie, &status, 0)
  }
  var exited = bz_process()
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if bz_read(zombie, &exited) == 1 && exited.status == 5 { break }
    Thread.sleep(forTimeInterval: 0.01)
  }
  equal(exited.status, 5, "Fixture did not become a kernel zombie")
  let zombieBox = MetadataPaths()
  gap = [CChar](repeating: 0, count: 256)
  let zombieCoverage = bz_worktree_pid_paths(
    zombie,
    { context, path in
      guard let context, let path else { return }
      Unmanaged<MetadataPaths>.fromOpaque(context).takeUnretainedValue().paths.append(
        String(cString: path))
    }, Unmanaged.passUnretained(zombieBox).toOpaque(), &gap, gap.count)
  equal(zombieCoverage, 0, "Zombie coverage: " + String(cString: gap))
  check(zombieBox.paths.isEmpty)
  print(
    "PASS strict Apple metadata protocol: PID/descriptor completeness, truncation, duplication, types and lossless names; real moved-executable coverage"
  )
}
