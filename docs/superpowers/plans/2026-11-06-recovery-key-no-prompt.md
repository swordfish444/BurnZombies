# Backup Key Without a Prompt: Implementation Plan

> **For agentic workers:** steps use checkbox (`- [ ]`) syntax. Write each proof first, watch it fail, then make it pass.

**Goal:** a keychain question about the recovery key never stalls Autopilot. Burns read the key without UI and within a bound. A copy whose key can't be read is refused plainly, and the owner is asked once, in the menu.

**Spec:** `docs/superpowers/specs/2026-11-06-recovery-key-no-prompt-design.md`. Read it first.

**Tech stack:** Swift 6 (CI type-checks with 6.2.3), SwiftUI, the repo's proof runner (`Proof/`, `.build/debug/BurnProof`).

## Global constraints

- **No real keychain in proofs.** Every new proof injects its reader. Only the existing opt-in `--worktree-keychain` proof touches a (throwaway) keychain item.
- **Never touch** the live Mac's state, the live `archive-key-v1` item, or `refs/burnzombies/retired/*`.
- **No private names** in code, tests, docs or commits.
- **Swift 6.2.3 on CI:** write long `+`, `??` and `map` chains as small typed steps.
- **Old files still load:** new snapshot fields are optional.
- **Proof runs:** one group at a time, each in its own temporary root.
- **Release builds:** everything in `AutopilotProof.swift` stays inside its `#if DEBUG`. Run `scripts/build-app.sh` before merging.

## Task 1: quiet reads the file keychain obeys

**Files:** `Sources/BurnCore/WorktreeRecovery.swift`, `Sources/CBurn/` (shim only if Swift's deprecation warning must be kept out).

- [ ] Add `static let lock = NSLock()` to `WorktreeRecoveryKey`, and hold it across the whole `load` (query and add).
- [ ] With `allowInteraction == false`, read `SecKeychainGetUserInteractionAllowed`, set it to false, run the query and the add, then restore it in a `defer`.
- [ ] Keep `kSecUseAuthenticationUI` as it is.
- [ ] Prove the throwaway-item round trip still passes: `BurnProof --worktree-keychain`.

## Task 2: the gate (proof first)

**Files:** new `Sources/BurnCore/AutopilotRecoveryKey.swift`; new `Proof/AutopilotRecoveryKeyTests.swift`; `Proof/Runner.swift`.

- [ ] Proof `recoveryKeyGateProof()`:
  - a reader that blocks on a semaphore: `forBurn()` throws `AutopilotRecoveryKey.Waiting` in under bound + 2 s, and `wait` is set;
  - a second `forBurn()` throws in under 0.2 s, and the reader was called once;
  - signal the reader to return a key: `wait` clears within a second;
  - a reader that throws: `forBurn()` throws and `wait` is set; `allow()` with an interactive read that returns a key clears it; `forBurn()` then returns that key;
  - `allow()` whose read fails throws, and `wait` stays.
- [ ] Register `--autopilot-recovery-key` and add the proof to `--quick`.
- [ ] Run it and watch it fail to compile, then implement:
  - `AutopilotKeyWait` (Codable, Sendable, Equatable: `since`, `asking`);
  - `AutopilotRecoveryKey` (`@unchecked Sendable`, NSLock-guarded state):
    - `init(bound:read:)`;
    - `forBurn()`, `allow()`, `forOwner(create:)`;
    - `wait`;
    - `static let refusal`.

## Task 3: retire and reclaim use the gate (proof first)

**Files:** `Sources/BurnCore/AutopilotWorktrees.swift`, `Sources/BurnCore/AutopilotDisk.swift`, `Proof/AutopilotWorktreeTests.swift`.

- [ ] Proof `apBlockedKeyRetire(world)` in `--autopilot-worktrees`, on a new clean merged worktree `keywait`. Retire with `recoveryKey: nil` and a gate whose reader blocks must:
  - be refused with `AutopilotRecoveryKey.refusal` in under bound + 5 s;
  - leave the folder and its registration in place;
  - make no `refs/burnzombies/retired/` ref;
  - leave no new folder in `private-recovery`.
- [ ] Implement:
  - `retire` and `reclaim` take `keys: AutopilotRecoveryKey = .shared`;
  - `perform` reads `let key = try recoveryKey ?? keys.forBurn()` right before capture (a `Waiting` error becomes `Refusal(AutopilotRecoveryKey.refusal)`), and passes `key` to capture and validate;
  - `reclaim` does the same before its capture.
- [ ] `restore` takes `keys` and reads `try recoveryKey ?? keys.forOwner(create: false)` only when the receipt has an archive.

## Task 4: the engine holds, re-tries and asks (proof first)

**Files:** `Sources/BurnCore/AutopilotEngine.swift`, `Sources/BurnCore/AutopilotModels.swift`, `Sources/BurnCore/AutopilotLive.swift`, `Proof/AutopilotRecoveryKeyTests.swift`.

- [ ] Proof `recoveryKeyEngineProof()`: two burn-authorized copies (starter-rule facts), whose sources' `retireWorktree` calls the gate's `forBurn()` and burns on success. With a blocking reader:
  - `tick` returns in under bound + 3 s;
  - one receipt, refused with the key reason; the other copy has no receipt;
  - a second tick returns, `lastTick` advances, no new receipt;
  - the snapshot's `recoveryKey` is set.
  - `apply(.allowRecoveryKey)` with a working interactive read: `recoveryKey` clears, and both copies burn within 5 s.
  - The socket's `command` tool with `.allowRecoveryKey` fails, and the wait stays.
- [ ] Implement:
  - `AutopilotSources.recoveryKeyWait` (default `{ nil }`) and `allowRecoveryKey` (default throws);
  - `AutopilotCommand.allowRecoveryKey`;
  - `AutopilotSnapshot.recoveryKey`;
  - the hold in `burnAuthorized`;
  - `standingRefusals(_:now:keyWaits:)`;
  - `apply` and the socket refusal;
  - the summary note.
- [ ] Wire `live`: the shared gate goes to retire, reclaim and restore, and `recoveryKeyWait` / `allowRecoveryKey` come from it.

## Task 5: the ask in the menu

**Files:** `Sources/BurnApp/ImpactView.swift`, `Sources/BurnApp/AutopilotSupport.swift`, `Sources/BurnApp/main.swift`, `Sources/BurnApp/AutopilotProof.swift`.

- [ ] Proof in `--autopilot-proof`: a demo snapshot with `recoveryKey` set renders the popover card ("Let BZ use its backup key", "Allow") and the Details prompt.
- [ ] Implement `AppModel.allowRecoveryKey()` (local: `asking = true`; footer message on finish), `keyCard` in `MiniImpactView` and the prompt in `AutopilotMenuSection`.

## Task 6: docs, build, ship

- [ ] `docs/AUTOPILOT.md` and `docs/SAFETY.md`: one sentence each.
- [ ] Run, one at a time: `--autopilot-recovery-key`, `--autopilot-worktrees`, `--autopilot-sweep`, `--autopilot-look-only`, `--autopilot-disk`, `--worktree-keychain`, then `BurnZombiesApp --autopilot-proof`, `scripts/test.sh` and `scripts/build-app.sh`.
- [ ] PR. Before merging:
  - merge origin/main;
  - set `BuildIdentity.swift` and `scripts/build-app.sh` to main's build + 1;
  - run `scripts/check.sh`;
  - squash-merge with `--match-head-commit` once Quick checks pass.
- [ ] Install:
  - check `runningAppBuild` first;
  - back up to `BurnZombies-backups/<date>-pre-build<N>/` without overwriting anything;
  - swap in the signed `scripts/build-app.sh` bundle;
  - check `doctor`, `lastTick` and the receipts.
