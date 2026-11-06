import BurnCore
import Darwin
import Foundation

/// A refusal that came from an error says which step stopped it and how, never with a path or a
/// name in it, and the owner reads a plain reason. No Git here: retires of real copies are proved
/// in `--autopilot-worktrees`.
func retireCauseProof() {
  rcGitFailureProof()
  rcCauseProof()
  rcPlainReasonProof()
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

/// The owner reads a plain reason: the walk's and the backup's own stops have their words, Git's
/// failures are told by how the runner ended them, and anything else gets the general reason, never
/// an error's own text (the cause has what failed).
private func rcPlainReasonProof() {
  func plain(_ message: String) -> String {
    AutopilotWorktrees.plainReason(StoreError.message(message))
  }
  func git(_ status: Int32) -> String {
    AutopilotWorktrees.plainReason(
      WorktreeGit.Failure(command: "status", status: status, seconds: 60, message: "m"))
  }
  let general = "I could not check it safely, so I left it alone."
  let stopped = "I stopped before I finished checking it, so I left it alone."
  equal(
    plain("Nested repository is protected."),
    "There is another project folder inside it that I can't back up, so I left it alone.")
  equal(
    plain("Checkout inspection limit reached; coverage incomplete."),
    "It has too many files for me to back up, so I left it alone.")
  equal(
    plain("Checkout inspection ran out of time; coverage incomplete."),
    "Backing it up took too long, so I left it alone.", "a busy Mac isn't a big copy")
  equal(plain("Checkout inspection was cancelled; coverage incomplete."), stopped)
  equal(
    plain("Recovery source changed; nothing removed."),
    "It changed while I was backing it up, so I left it alone.")
  equal(plain("Something nobody planned for."), general, "no error text reaches the owner")
  equal(git(124), "Git took too long to answer about it, so I left it alone.")
  equal(git(125), "It has too many files for me to back up, so I left it alone.")
  equal(git(130), stopped)
  equal(git(128), "Git gave an error when I checked it, so I left it alone.")
  let denied = NSError(
    domain: NSCocoaErrorDomain, code: 513,
    userInfo: [NSLocalizedDescriptionKey: "You don't have permission to save the file notes.txt."])
  equal(AutopilotWorktrees.plainReason(denied), general, "nor does Foundation's")
  equal(
    AutopilotWorktrees.plainReason(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))),
    "There isn't enough free space to back it up first, so I left it alone.")
}
