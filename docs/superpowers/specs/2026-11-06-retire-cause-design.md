# Retire says why it couldn't check a copy

Status: asked for on 2026-11-06. Builds 64 to 68 refused copies with "I could not check it safely, so I left it alone.", and nothing recorded why.

## What happened

- `AutopilotWorktrees.retire` turns every error that isn't one of its own refusals into that one sentence. The receipt and the burn log keep only the sentence.
- On the maintainer's Mac it came up 54 times since 2026-11-03, and 24 times on 2026-11-06 alone. A read-only look at the 14 copies still there found two causes.
  1. **pnpm's `node_modules` isn't counted as rebuildable (17 of the 24).**
     - Since #68, a `node_modules` stays out of the backup only when every entry in it is a package.
     - pnpm links each scoped package (`@types/node`) into `.pnpm`. The check wants a real `package.json` inside a scope folder, so it says no.
     - It also says no to the caches tools keep there (`.vite`, `.vite-temp`, `.prisma`, `.cache`).
     - The backup then walks the whole `node_modules` (100,000 to 200,000 entries) and stops at its limit of 100,000.
     - Junk reclaim runs into the same check: "I couldn't preserve this folder's unique contents".
     - In 4 of these copies, a submodule's workspace packages are hard-linked into `node_modules/.pnpm`. Their walk would still stop at those hard links with `node_modules` left out.
  2. **A project inside the copy (7 of the 24).** These are Claude Code session folders that each hold another repository's worktree. The backup's walk refuses a nested `.git`. Refusing is right, but the sentence is wrong: a plain one for this case already exists.

## Goals

1. Every refusal that comes from an error records a short cause: the step, and what failed. That can be a Git command and its status or time limit, the walk's limit, free space, or a file that changed. It never holds a path or a name.
2. The reason the owner sees stays plain. A known backup stop that has a plain reason gets it.
3. pnpm's `node_modules` counts as rebuildable.
4. A proof for each.

## Non-goals

- Hard-linked files still keep a copy: that rail stays. Their refusal now names them.
- No change to which Git commands run, to their limits, or to the backup format.
- No UI change. The owner's card keeps showing the plain reason.

## 1. The cause

- `AutopilotReceipt.cause: String?` reads "step: what failed", for example:
  - "checking its changes: git status timed out after 60 s";
  - "backing it up: Nested repository is protected.".
- The steps are fixed words:
  - reading its Git folder;
  - checking Git's state;
  - checking where its work is saved;
  - checking its changes;
  - checking its submodules;
  - listing its unsaved files;
  - backing it up;
  - saving its commit;
  - checking the backup;
  - checking it once more.
- What failed:
  - **A Git run:** a new `WorktreeGit.Failure` carries the subcommand, the runner's status and its time limit. The runner's statuses read as follows.
    - 124 → "timed out after N s".
    - 125 → "printed more than 8 MB".
    - 130 → "was stopped".
    - 64, 71 and 72 → "couldn't run".
    - Above 128 → "was killed by signal N".
    - Anything else → "exited with status N".

    Its message (`localizedDescription`) stays exactly what it was.
  - **A walk or backup stop:** its fixed message, such as "Hardlinked files require owner handling.".
  - **Anything else:** the error's domain and code. `localizedDescription` is never used, because Foundation's can hold a path.
  - A message holding a "/" or a quote is left out.
- The cause shows in two places:
  - the receipt, in `receipts.json`, MCP and the CLI;
  - the burn log line: "Skipped X: reason (cause)".
- The Hunt's live log and the owner's card keep the reason alone.
- Junk reclaim's catch-all records a cause the same way. Its sentence doesn't change.

## 2. Plain reasons for known stops

| Stop | Reason |
|---|---|
| A nested repository, or a nested bare one | "There is another project folder inside it that I can't back up, so I left it alone." (exists) |
| More than 100,000 files and folders | "It has too many files for me to back up, so I left it alone." |
| The walk ran past its 120 s | "Backing it up took too long, so I left it alone." |
| Not enough free space | "There isn't enough free space to back it up, so I left it alone." |
| A file changed during the backup | "It changed while I was backing it up, so I left it alone." (exists) |
| Anything else | "I could not check it safely, so I left it alone." (as now) |

The walk's single "limit reached" error splits in three: too many entries, out of time, and cancelled. That way the cause tells a big copy from a busy Mac. The message for too many entries stays as it was.

## 3. pnpm's `node_modules`

`AutopilotDisk.regenerable` for `node_modules` still needs a package manager's metadata file and at most 10,000 entries. Two more kinds of entry count:

- **A link inside a scope folder** counts like a link at the top. pnpm links each package there.
- **A folder or regular file whose name starts with a dot.** npm forbids package names that start with a dot, so such an entry is the package manager's own state or a tool's cache (`.cache`, `.vite`, `.prisma`). The tools make it again.

Nothing else changes: a folder must still hold a real `package.json`, and any other kind of entry still says no.

## 4. Proof

- **`BurnProof --autopilot-worktrees`** (real Git, sacrificial repositories):
  - A copy holding another repository is refused with the nested-project reason. Its cause names the backup step and the nested repository. Neither one holds the copy's path or name, and the copy is untouched.
  - A copy whose index is broken makes `git status` fail. It is refused with the general reason, and its cause is "checking its changes: git status exited with status 128". The copy is untouched.
  - A copy with a pnpm-shaped `node_modules` retires, and the archive doesn't hold `node_modules`. That folder has `.modules.yaml`, a `.pnpm` folder with a file hard-linked from a store outside the copy, `@scope/pkg` links, `.vite` and `.prisma`. Before the fix, the hard link stopped it.
- **`BurnProof --quick`** (no Git):
  - `WorktreeGit.Failure` reads right for each status.
  - Causes are filtered: a message with a path is left out, and unknown errors show only their domain and code.
  - `regenerable` says yes to the pnpm layout, and no in these cases:
    - a scope folder holding a real folder without a `package.json`;
    - a top-level folder without one;
    - a dot entry that is a FIFO;
    - no metadata file.
- **`BurnProof --autopilot-sweep`**: the burn log line for a refusal with a cause ends with it. Without a cause, it reads as before.
