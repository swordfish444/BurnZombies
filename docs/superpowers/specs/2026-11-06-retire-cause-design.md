# Retire says what failed

Status: asked for on 2026-11-06. Builds 64 to 68 refused copies with "I could not check it safely, so I left it alone.", and nothing recorded why. Rebuilt on #81 (build 73).

#81 changed three things:
- pnpm copies burn;
- retire's backup keeps hard-linked files by their contents;
- the backup walk's, the backup's and Git's known reasons read plainly.

This change adds what #81 left out:
- which step failed and how, recorded where the log and the receipt can show it;
- an owner's reason that stays plain for every error.

## What happened

- `AutopilotWorktrees.retire` turned every error that wasn't one of its own refusals into that one sentence. The receipt and the burn log kept only the sentence.
- On the maintainer's Mac it came up 54 times since 2026-11-03, and 24 times on 2026-11-06 alone. A read-only look at the 14 copies still there found two causes.
  1. **pnpm's `node_modules` wasn't counted as rebuildable (17 of the 24).**
     - The backup walked the whole install, 100,000 to 200,000 entries, and stopped at its limit of 100,000.
     - Four of these copies also hold a submodule whose workspace packages pnpm hard-links into the install.
     - #81 fixed both.
  2. **A project inside the copy (7 of the 24).** These are Claude Code session folders that each hold another repository's worktree. Refusing is right. #81 gave this case its plain reason.
- After #81, a reason it has no words for reads "What stopped me:", followed by the error's own text. That text can be Foundation's description, which names files. Nothing records which step failed, or which Git command.

## Goals

1. Every refusal that comes from an error records a short cause: the step, and what failed. It never holds a path or a name. Examples: a Git command and its status or time limit, the walk's limit, free space, a file that changed.
2. The reason the owner reads stays plain. No error's own text reaches it.
3. A proof for each.

## Non-goals

- No change to #81's rules for pnpm installs or hard links.
- No change to which Git commands run, to their limits, or to the backup format.
- No UI change. The owner's card keeps showing the plain reason.

## 1. The cause

- `AutopilotReceipt.cause: String?` reads "step: what failed", for example:
  - "checking its changes: git status timed out after 60 s";
  - "backing it up: Nested repository is protected.".
- The steps are fixed words:
  - reading its Git folder;
  - checking where its work is saved;
  - checking its changes;
  - checking its submodules;
  - listing its unsaved files;
  - backing it up;
  - saving its commit;
  - checking the backup;
  - saving its restore point;
  - checking it once more.

  A Git-state check that can't read a file gives "checking Git's state:" followed by the system's error text.
- What failed:
  - **A Git run:** a new `WorktreeGit.Failure` carries the subcommand, the runner's status and its time limit. The runner's statuses read as follows.
    - 124 → "timed out after N s".
    - 125 → "printed more than 8 MB".
    - 130 → "was stopped".
    - 64, 71 and 72 → "couldn't run".
    - Above 128 → "was killed by signal N".
    - Anything else → "exited with status N".

    Its message (`localizedDescription`) stays exactly what it was.
  - **A walk or backup stop:** its fixed message, such as "Links or special files require supported recovery.".
  - **Anything else:** the error's domain and code. `localizedDescription` is never used.
  - A message holding a "/" or a quote is left out.
- The cause shows in two places:
  - the receipt, in `receipts.json`, MCP and the CLI;
  - the burn log line: "Skipped X: reason (cause)".
- The Hunt's live log and the owner's card keep the reason alone.
- Junk reclaim's catch-all records a cause the same way. Its sentence doesn't change.

## 2. The owner's reason

- `plainReason` (from #81) keeps its table of the walk's and the backup's messages.
- Git failures are told by the runner's status from `WorktreeGit.Failure`, not by parsing the message.
- Two more walk messages have words:

  | Stop | Reason |
  |---|---|
  | The walk ran past its 120 s | "Backing it up took too long, so I left it alone." |
  | The walk was cancelled | "I stopped before I finished checking it, so I left it alone." |

  The walk's single "limit reached" error splits in three: too many entries, out of time, and cancelled. That way a busy Mac isn't reported as a big copy. The message for too many entries stays as it was.
- Anything else reads "I could not check it safely, so I left it alone." That replaces "What stopped me:" and the error's text. The cause carries what failed instead.

## 3. Proof

- **`BurnProof --quick`** (no Git):
  - `WorktreeGit.Failure` reads right for each status.
  - Causes are filtered: a message with a path or a quoted name is left out, and Foundation's errors give only their domain and code.
  - Plain reasons for the walk's three limits, a changed file, Git's statuses, Foundation's errors and free space.
- **`BurnProof --autopilot-worktrees`** (real Git, sacrificial repositories):
  - `WorktreeGit.run` throws a `Failure` naming the subcommand, even after options such as `--literal-pathspecs`.
  - #81's plain refusals now carry causes, and none holds the copy's path or name:
    - a project inside → "backing it up: Nested repository is protected.";
    - a pipe → "backing it up: Links or special files require supported recovery.";
    - a damaged HEAD → "reading its Git folder: git config exited with status 128".
  - A broken index → "checking its changes: git status exited with status 128". The copy is untouched.
  - A locked copy keeps its own reason and has no cause.
- **`BurnProof --autopilot-sweep`**: the burn log line for a refusal with a cause ends with it. Without a cause, it reads as before.
