# Retire Says What Failed: Implementation Plan

> **For agentic workers:** steps use checkbox (`- [ ]`) syntax. Write each proof first, watch it fail, then make it pass.

**Goal:** a refusal that comes from an error records a short, sanitized cause, and the owner still reads a plain reason. This builds on #81 (build 73), which already fixed the most common causes.

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

- [ ] Quick proof: `WorktreeGit.Failure.summary` for each runner status.
- [ ] Worktree proof: real failing runs give their subcommand and status.
  - A missing branch gives `rev-parse` and 128.
  - An unmatched file gives `ls-files` and 1, after `--literal-pathspecs`.
- [ ] Implement:
  - `run` works out the subcommand;
  - `capture` throws a `Failure` whose message is the old one.

## Task 2: the cause (proof first)

**Files:** `Sources/BurnCore/AutopilotModels.swift`, `Sources/BurnCore/AutopilotWorktrees.swift`.

- [ ] Quick proof: `cause(of:at:)` gives "step: what failed" for a Git failure, for a walk message, for a message with a path or a quoted name (left out), for Foundation's errors (domain and code) and for a cancellation.
- [ ] Add `AutopilotReceipt.cause: String?` and `cause(of:at:)`.

## Task 3: retire names the step (proof first)

**Files:** `Sources/BurnCore/AutopilotWorktrees.swift`, `Sources/BurnCore/WorktreeInspection.swift`; `Proof/AutopilotWorktreeTests.swift`.

- [ ] Worktree proof:
  - #81's plain refusals carry causes: a project inside, a pipe, a damaged HEAD.
  - A broken index gives "checking its changes: git status exited with status 128".
  - A locked copy has no cause.
  - No cause names the copy.
- [ ] Implement:
  - `perform` takes `step: inout String`, set before each group of work;
  - `retire`'s catch-all sets the receipt's cause;
  - `Refusal` gets a cause, and the Git-state `errno` refusal uses it.
- [ ] Split the walk's limit guard into too many entries (the old message), out of time, and cancelled.

## Task 4: plain reasons only (proof first)

**Files:** `Sources/BurnCore/AutopilotWorktrees.swift`; `Proof/RetireCauseTests.swift`.

- [ ] Quick proof:
  - the three limits;
  - Git's statuses;
  - Foundation's errors and an unknown message give the general reason, never their own text;
  - free space.
- [ ] Implement:
  - `plainReason` matches `WorktreeGit.Failure` by status;
  - it maps the out-of-time and cancelled messages;
  - everything else gets the general reason.

## Task 5: the burn log line and junk reclaim (proof first)

**Files:** `Sources/BurnCore/AutopilotEngine.swift`, `Sources/BurnCore/AutopilotDisk.swift`; `Proof/AutopilotSweepTests.swift`.

- [ ] Sweep proof:
  - a refusal with a cause logs "Skipped X: reason (cause)";
  - one without a cause logs as before.
- [ ] Implement it in `execute`.
- [ ] Reclaim's catch-all sets its receipt's cause.

## Task 6: docs, build, ship

- [ ] `docs/AUTOPILOT.md`:
  - a refusal's receipt and burn log name the step that stopped it;
  - when `node_modules` counts as rebuildable.
- [ ] Run `scripts/test.sh` (quick).
- [ ] Run these groups one at a time: `--autopilot-worktrees`, `--autopilot-sweep`, `--autopilot-disk`, `--security-boundaries`, `--autopilot-look-only` and `--autopilot-learning`.
- [ ] Run `scripts/build-app.sh`, the signed release build.
- [ ] Merge main, then set the build to main's + 1 in `BuildIdentity.swift` and `scripts/build-app.sh`.
- [ ] Open the PR. Squash-merge it with `--match-head-commit` once Quick checks pass.
- [ ] Install:
  - check `runningAppBuild`;
  - back up the `.app` and the state;
  - install the signed bundle;
  - check the next tick's receipts for causes.
