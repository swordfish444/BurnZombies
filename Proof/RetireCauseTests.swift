import BurnCore
import Darwin
import Foundation

/// A refusal that came from an error says which step stopped it and how, never with a path or a
/// name in it, and the owner reads a plain reason. pnpm's `node_modules` counts as rebuildable.
/// No Git here: retires of real copies are proved in `--autopilot-worktrees`.
func retireCauseProof() throws {
  rcGitFailureProof()
  rcCauseProof()
  rcPlainReasonProof()
  try rcPnpmModulesProof()
}

/// What a failed Git run says: the subcommand and how the bounded runner ended it.
private func rcGitFailureProof() {
  func summary(_ status: Int32, _ command: String = "status") -> String {
    WorktreeGit.Failure(command: command, status: status, seconds: 60, message: "m").summary
  }
  equal(summary(124), "git status timed out after 60 s")
  equal(summary(125, "ls-files"), "git ls-files printed more than 8 MB")
  equal(summary(130), "git status was stopped")
  equal(summary(71), "git status couldn't run (status 71)")
  equal(summary(72), "git status couldn't run (status 72)")
  equal(summary(137), "git status was killed by signal 9")
  equal(summary(128), "git status exited with status 128")
  equal(summary(1, "for-each-ref"), "git for-each-ref exited with status 1")
  equal(summary(1, "/private/secret-place"), "git exited with status 1", "never a path for a name")
  let failure = WorktreeGit.Failure(
    command: "status", status: 128, seconds: 60, message: "Git refused the bounded request.")
  equal(
    failure.localizedDescription, "Git refused the bounded request.",
    "the message is what Git failures always said")
}

/// "step: what failed", with nothing that could name a file.
private func rcCauseProof() {
  let changes = "checking its changes"
  let backup = "backing it up"
  equal(
    AutopilotWorktrees.cause(
      of: WorktreeGit.Failure(command: "status", status: 124, seconds: 60, message: "m"),
      at: changes),
    "checking its changes: git status timed out after 60 s")
  equal(
    AutopilotWorktrees.cause(
      of: StoreError.message("Hardlinked files require owner handling."), at: backup),
    "backing it up: Hardlinked files require owner handling.")
  let left = "backing it up: an error whose message I left out"
  equal(
    AutopilotWorktrees.cause(
      of: StoreError.message("Something is already at /Users/someone/secret-project."), at: backup),
    left, "a message with a path is left out")
  equal(
    AutopilotWorktrees.cause(
      of: StoreError.message("Couldn't open \u{201C}secret-project\u{201D}."), at: backup),
    left, "and so is one that quotes a name")
  let denied = NSError(
    domain: NSCocoaErrorDomain, code: 513,
    userInfo: [
      NSFilePathErrorKey: "/Users/someone/secret-project/notes.txt",
      NSLocalizedDescriptionKey: "You don't have permission to save the file notes.txt.",
    ])
  equal(
    AutopilotWorktrees.cause(of: denied, at: backup), "backing it up: NSCocoaErrorDomain 513",
    "Foundation's errors give their domain and code, never their description")
  equal(
    AutopilotWorktrees.cause(of: CancellationError(), at: backup),
    "backing it up: it was cancelled")
}

/// The backup's known stops read plainly to the owner; anything else keeps the general reason.
private func rcPlainReasonProof() {
  func plain(_ message: String) -> String? {
    AutopilotWorktrees.plainReason(for: StoreError.message(message))
  }
  let nested = "There is another project folder inside it that I can't back up, so I left it alone."
  let changed = "It changed while I was backing it up, so I left it alone."
  equal(plain("Nested repository is protected."), nested)
  equal(plain("Nested bare repository is protected."), nested)
  equal(
    plain("Checkout inspection limit reached; coverage incomplete."),
    "It has too many files for me to back up, so I left it alone.")
  equal(
    plain("Checkout inspection ran out of time; coverage incomplete."),
    "Backing it up took too long, so I left it alone.")
  equal(
    plain("Insufficient private recovery capacity; preserve the original without truncation."),
    "There isn't enough free space to back it up, so I left it alone.")
  for message in [
    "Recovery source changed; nothing removed.", "Recovery source changed.",
    "Contents changed after recovery; nothing removed.",
    "File contents changed after recovery; nothing removed.",
    "Generated folder changed during recovery.",
    "A big file the owner let go changed during recovery.",
  ] {
    equal(plain(message), changed, message)
  }
  isNil(plain("Hardlinked files require owner handling."))
  isNil(plain("Checkout inspection was cancelled; coverage incomplete."))
  isNil(
    AutopilotWorktrees.plainReason(
      for: WorktreeGit.Failure(command: "status", status: 124, seconds: 60, message: "m")))
  isNil(AutopilotWorktrees.plainReason(for: NSError(domain: NSCocoaErrorDomain, code: 4)))
}

/// pnpm links every package in `node_modules` into `.pnpm`, scoped ones too, and tools keep their
/// caches beside them. Such a folder is rebuildable; anything that isn't a package still isn't.
private func rcPnpmModulesProof() throws {
  let fm = FileManager.default
  let temporary = fm.temporaryDirectory.appendingPathComponent(
    "bz-retire-cause-" + UUID().uuidString)
  try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
  let base = WorkspaceSafety.canonical(temporary.path)
  defer { try? fm.removeItem(atPath: base) }
  func write(_ path: String, _ text: String = "{}\n") throws {
    try fm.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }
  func link(_ path: String, to target: String) throws {
    try fm.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
  }
  /// A pnpm install with tools' caches, then one change.
  func modules(_ name: String, _ change: (String) throws -> Void = { _ in }) throws -> String {
    let folder = base + "/" + name + "/node_modules"
    try write(folder + "/.modules.yaml", "layoutVersion: 5\n")
    try write(folder + "/.pnpm/@scope+pkg@1.0.0/node_modules/@scope/pkg/package.json")
    try write(folder + "/.pnpm/left-pad@1.0.0/node_modules/left-pad/package.json")
    try write(folder + "/.bin/tool", "#!/bin/sh\n")
    try link(folder + "/@scope/pkg", to: "../.pnpm/@scope+pkg@1.0.0/node_modules/@scope/pkg")
    try write(folder + "/@other/real/package.json")
    try link(folder + "/left-pad", to: ".pnpm/left-pad@1.0.0/node_modules/left-pad")
    try write(folder + "/.vite/deps/chunk.js", "cached\n")
    try write(folder + "/.vite-temp/vite.config.mjs", "temporary\n")
    try write(folder + "/.prisma/client/index.js", "generated\n")
    try write(folder + "/.cache/tool/state", "cached\n")
    try write(folder + "/.pnpm-debug.log", "log\n")
    try change(folder)
    return folder
  }
  let pnpm = try modules("pnpm")
  check(AutopilotDisk.regenerable(pnpm), "pnpm's node_modules is rebuildable")
  let scopeFolder = try modules("scope-folder") { try write($0 + "/@scope/notes/a.txt") }
  checkFalse(
    AutopilotDisk.regenerable(scopeFolder),
    "a folder in a scope without a package.json isn't a package")
  let topFolder = try modules("top-folder") { try write($0 + "/notes/a.txt") }
  checkFalse(AutopilotDisk.regenerable(topFolder), "nor is one at the top")
  let fifo = try modules("fifo") { folder in
    guard mkfifo(folder + "/.pipe", 0o600) == 0 else {
      throw StoreError.message("mkfifo failed")
    }
  }
  checkFalse(
    AutopilotDisk.regenerable(fifo),
    "a dot entry that is neither a folder nor a file doesn't count")
  let repository = try modules("repository") { try write($0 + "/.git/HEAD", "ref\n") }
  checkFalse(AutopilotDisk.regenerable(repository), "a repository is never a tool's cache")
  let unmarked = try modules("unmarked") { try fm.removeItem(atPath: $0 + "/.modules.yaml") }
  checkFalse(AutopilotDisk.regenerable(unmarked), "no package manager's metadata, no rebuild")
}
