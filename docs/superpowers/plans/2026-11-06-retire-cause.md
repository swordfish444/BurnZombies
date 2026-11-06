# Retire Says Why: Implementation Plan

> **For agentic workers:** steps use checkbox (`- [ ]`) syntax. Write each proof first, watch it fail, then make it pass.

**Goal:** a refusal that comes from an error records a short, sanitized cause, and the owner still reads a plain reason. pnpm's `node_modules` counts as rebuildable, so its copies retire.

**Spec:** `docs/superpowers/specs/2026-11-06-retire-cause-design.md`. Read it first.

**Tech stack:** Swift 6 (CI type-checks with 6.2.3), the repo's proof runner (`Proof/`, `.build/debug/BurnProof`).

## Global constraints

- **No private names** in code, tests, docs or commits. Causes never hold a path or a name.
- **Never touch** the live Mac's state or `refs/burnzombies/retired/*`. Proofs use sacrificial repositories in a temporary folder.
- **Old files still load:** `cause` is optional.
- **Messages stay:** every error message the inventory records as a gap stays word for word. The only new ones are the walk's out-of-time and cancelled messages.
- **Proof runs:** one group at a time. This Mac flakes on in-use checks under load.
- **Swift 6.2.3 on CI:** write long `+` and `??` chains as small typed steps.

## Task 1: Git failures say what failed (proof first)

**Files:** `Sources/BurnCore/WorktreeInspection.swift`; new `Proof/RetireCauseTests.swift`; `Proof/Runner.swift`.

- [ ] Proof `retireCauseProof()`, added to `--quick`. `WorktreeGit.Failure(command:status:seconds:message:)` must read:
  - 124 → "git status timed out after 60 s";
  - 125 → "printed more than 8 MB";
  - 130 → "was stopped";
  - 71 → "couldn't run (status 71)";
  - 137 → "was killed by signal 9";
  - 128 → "exited with status 128".

  Its `localizedDescription` must equal its message.
- [ ] A real failing run must throw a `Failure`. For example, `WorktreeGit.run` with `rev-parse` in a folder that isn't a repository gives command "rev-parse" and status 128.
- [ ] Watch it fail to compile, then implement:
  - `run` works out the subcommand: the first argument after the context flags that doesn't start with "-" and matches `[a-z][a-z0-9-]*`; otherwise "git".
  - `capture` takes it and throws `Failure` with the old message.

## Task 2: the cause (proof first)

**Files:** `Sources/BurnCore/AutopilotModels.swift`, `Sources/BurnCore/AutopilotWorktrees.swift`; `Proof/RetireCauseTests.swift`.

- [ ] Proof `AutopilotWorktrees.cause(of:at:)`:
  - a `Failure` → "checking its changes: git status timed out after 60 s";
  - `StoreError.message("Hardlinked files require owner handling.")` → "backing it up: Hardlinked files require owner handling.";
  - a `StoreError` with "/" or a quote → "backing it up: an error whose message I left out";
  - an `NSError` whose description holds a path → "…: NSCocoaErrorDomain 513", with no path in it;
  - `CancellationError` → "…: it was cancelled".
- [ ] Add `AutopilotReceipt.cause: String?`.
- [ ] Implement `cause(of:at:)` and `plainReason(for:)`. The latter maps the walk's and the backup's known messages to the table in spec section 2.

## Task 3: retire names the step (proof first)

**Files:** `Sources/BurnCore/AutopilotWorktrees.swift`, `Sources/BurnCore/WorktreeInspection.swift`, `Sources/BurnCore/PrivateRecovery.swift`; `Proof/AutopilotWorktreeTests.swift`.

- [ ] Proof `apCauseProof(world)` in `--autopilot-worktrees`:
  - **Nested project:** a copy holding an untracked folder with its own repository.
    - It is refused with the nested-project reason.
    - Its cause starts with "backing it up: " and names the nested repository.
    - The cause holds neither the copy's path nor its name.
    - The copy is untouched.
  - **Broken index:** a copy whose index file is garbage.
    - It is refused with "I could not check it safely, so I left it alone.".
    - Its cause is "checking its changes: git status exited with status 128".
    - The copy is untouched.
  - **Plain refusals stay as they were:** a locked copy keeps its reason and has no cause.
- [ ] Implement:
  - `perform` takes `step: inout String`, set before each group of Git work;
  - `retire`'s catch-all builds the receipt from `plainReason(for:)` and `cause(of:at:)`;
  - `Refusal` gets `cause`, and the Git-state `errno` refusal gets one ("checking Git's state: " plus `strerror`);
  - `WorktreeInspection` and `PrivateRecovery` keep the messages that `plainReason` maps as static constants. Messages stay the same, apart from the split below.
- [ ] Split the walk's limit guard into too many entries (the old message), out of time, and cancelled.

## Task 4: pnpm's `node_modules` (proof first)

**Files:** `Sources/BurnCore/AutopilotDisk.swift`; `Proof/RetireCauseTests.swift`, `Proof/AutopilotWorktreeTests.swift`.

- [ ] Quick proof on a folder fixture: `regenerable` says yes to a pnpm layout. The layout has these entries:
  - `.modules.yaml`;
  - `.pnpm/`;
  - `.bin/`;
  - `@scope/pkg`, a link;
  - `@other/real`, holding a `package.json`;
  - `.vite/`, `.prisma/` and `.cache/`;
  - `.pnpm-debug.log`, a file;
  - `left-pad`, a link.

  It says no in these cases:
  - a scope folder holding a real folder without a `package.json`;
  - a top-level folder without one;
  - a dot entry that is a FIFO;
  - no metadata file.
- [ ] Worktree proof `apPnpmRetire(world)`: a copy with that layout, plus a `.pnpm` file hard-linked from a store outside the copy.
  - It retires.
  - The store file is still there.
  - The archive holds nothing from `node_modules`.
- [ ] Implement:
  - in a scope folder, a link counts;
  - at the top, a dot-named folder or regular file counts.

## Task 5: the burn log line (proof first)

**Files:** `Sources/BurnCore/AutopilotEngine.swift`; `Proof/AutopilotSweepTests.swift`.

- [ ] Proof: a `retireWorktree` source returns a refusal with cause "checking its changes: git status timed out after 60 s".
  - The sweep log's last line is "Skipped stuck: <reason> (<cause>)".
  - The receipt keeps the cause.
  - A refusal without a cause logs as before.
- [ ] Implement it in `execute`.

## Task 6: junk reclaim

**Files:** `Sources/BurnCore/AutopilotDisk.swift`.

- [ ] Reclaim's catch-all receipt sets `cause = cause(of: error, at: "backing it up")`. Its sentence doesn't change.

## Task 7: docs, build, ship

- [ ] `docs/AUTOPILOT.md`:
  - a refusal's receipt and burn log name the step that stopped it;
  - pnpm's `node_modules` counts as rebuildable.
- [ ] Run `swift build`, then `scripts/test.sh` (quick).
- [ ] Run these groups one at a time: `--autopilot-worktrees`, `--autopilot-sweep`, `--autopilot-disk` and `--security-boundaries`.
- [ ] Run `scripts/build-app.sh`, the signed release build.
- [ ] Merge main, then set the build to main's + 1 in `BuildIdentity.swift` and `scripts/build-app.sh`.
- [ ] Open the PR. Squash-merge it with `--match-head-commit` once Quick checks pass.
- [ ] Install:
  - check `runningAppBuild`;
  - back up the `.app` and the state;
  - install the signed bundle;
  - check the next tick's receipts for causes.
