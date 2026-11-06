# The backup key never stalls Autopilot

Status: asked for after build 62's first burn pass waited on a keychain question (2026-11-06). Started on main after build 64, then rebuilt on #75 (build 67). #75 moved the key into a private file, so only its one-time move out of the Keychain, and any later Keychain read, still needs this.

## What happened

- Since #68, retire and junk reclaim keep unsaved files in an encrypted archive. Its key, `archive-key-v1`, lives in the login keychain.
- Reading the key makes macOS ask the owner whether BZ may use it when the running app isn't on the item's access list, or when the keychain is locked. The read then waits for the answer.
- Retire runs inside the burn pass. The pass takes copies one at a time, and `tick` returns early while one is still running. So one unanswered question stopped every later tick: nothing burned and no question opened.
- Seen live on 2026-11-06 at 00:23Z: a sample showed `AutopilotWorktrees.perform` → `PrivateRecovery.capture` → `SecItemCopyMatching` → `SecKeychainItemCopyContent`, with SecurityAgent up.
- The read already asked for no UI (`kSecUseAuthenticationUIFail`, since #22). That setting never reaches the file-based keychain:
  - Security's legacy `SecItemCopyMatching` path ignores it.
  - An item read there asks with prompt credentials unless the process has turned keychain interaction off with `SecKeychainSetUserInteractionAllowed(false)`. Then it uses empty credentials and fails instead of asking (`Globals::itemCredentials` in Security's `libsecurity_keychain`).

Since #75 the key lives in `recovery-key/<namespace>.key` in BZ's data folder. The first load on a new build still reads the old Keychain item to move it, and that read hits the same prompt for every build with a new code hash. If the first load comes from the burn pass, it stalls the pass exactly as build 62 did. That's the case this fixes.

## Goals

1. No burn BZ makes waits on a keychain question. The key is read with interaction off in a way the file keychain obeys, and no read is waited on longer than a fixed bound.
2. A copy whose key can't be read is refused with a plain reason, and nothing else stalls.
3. The owner is asked once, in the menu, to allow the key. Allowing it starts a burn pass at once.
4. A proof drives a key loader that never returns.

## Non-goals

- No change to the key, its file, its old keychain item, its access list or the archive format. BZ never edits the item.
- No change to the Worktrees window, whose owner actions already read the key interactively.
- No notification. The ask lives in the menu, next to the questions.

## 1. Reading the key without a question

`WorktreeRecoveryKey.keychainKey`, the move's read:

- Every Keychain read holds one process-wide lock.
- With `allowInteraction: false`, the read turns keychain interaction off for exactly its own duration (`SecKeychainSetUserInteractionAllowed(false)`), then puts the previous setting back. `kSecUseAuthenticationUIFail` stays for data-protection items.
- The setting is process-wide, so the lock keeps a quiet read from overlapping a read that is allowed to ask.
- A denied read returns its denial, not "not found": Security's legacy `SecItemCopyMatching` counts the item before reading its secret and keeps the first error. But a search may skip a locked keychain when it may not ask to unlock it, or when the owner cancels the unlock dialog. So "not found" only counts while the default keychain is unlocked. Otherwise the read throws, and no new key is made that would orphan the recovery copies sealed with the old one.

Callers that relied on the default now really get no question. The owner's own actions read interactively on purpose: the Worktrees window (already), and Undo/Restore of an Autopilot burn (section 3).

## 2. The gate: `AutopilotRecoveryKey`

The app has one (`.shared`); proofs build their own with a fake reader and a short bound.

- `forBurn()` returns the key or throws. It never asks, and it never waits longer than `bound` (15 s): the read runs on its own thread, and a read that hasn't answered in time is left to finish on its own. At most one quiet read is outstanding. While one is, `forBurn()` throws at once.
- A failed or late quiet read starts a wait: `AutopilotKeyWait` (since, asking). Any later read that returns the key ends it, including the late read itself.
- `allow()` is the owner's Allow. It reads with interaction allowed, so macOS's dialog appears right after the owner's click. It ends the wait when the key comes back. Otherwise it throws a plain reason, and the wait stays.
- `forOwner(create:)` is the same interactive read for Undo/Restore. Its success ends a wait too.

## 3. Burns

- Retire reads the key right before it backs the copy up, through `forBurn()`, and passes that key to capture and to validate. That's one read per copy instead of two. Junk reclaim does the same before it backs up a folder.
- The refusal reads: "I need your OK to use my backup key, so I left it alone. Click Allow in BZ's menu." A failed read and a late read say the same thing.
- While the key waits:
  - the burn pass holds old copies without a receipt, since every retire needs the key. The copy that ran into it carries the refusal;
  - a key refusal stands only while the key waits. Once a read succeeds, those items are tried at the next pass, not 6 hours later;
  - each pass starts one quiet read in the background (`retry`). If it gets the key, say because the keychain was unlocked, the wait ends without the owner, and the next pass burns what waited;
  - Burn now and the AI's burns get the refusal at once.
- When the owner allows the key, a burn pass starts right away.
- Undo and Restore of an Autopilot burn read the key with `forOwner`: the owner just clicked, so macOS may ask then.
- The agent socket's `command` tool refuses Allow. Only the owner's click in the app makes macOS ask.

## 4. Asking the owner

- The snapshot carries `recoveryKey` (since, asking). The CLI and AI summary add a note while it is set.
- The menu-bar popover shows a card in the slot under the totals. Look-only comes first, then this card, then Full Disk Access.
  - Card: "N GB WAITS FOR YOUR OK" / "Let BZ use its backup key." / "Enter your password when macOS asks." with an Allow button.
  - While macOS asks: "macOS is asking you now." The button is off.
- The Details window's Autopilot section shows an orange "Allow BZ's backup key" button above the questions button.
- After Allow, the footer says "Thanks. Old copies can burn again." If it fails, the footer gives the reason.

## 5. Proof

- `BurnProof --quick` and `--autopilot-recovery-key`, with no real keychain:
  - A gate whose reader blocks forever: `forBurn()` throws within the bound plus slack, and a wait starts. A second `forBurn()` throws at once without a second read. Releasing the reader with a key ends the wait.
  - A reader that fails like the keychain does: a wait starts. `allow()` with a working interactive read ends it, and `forBurn()` then returns the key.
  - The engine with that blocking gate: a tick finishes within the bound plus slack. The first copy is refused with the key reason, and the second is held with no receipt. The next tick runs. The snapshot shows the wait. Allow ends it, and both copies burn.
  - The socket's `command` tool refuses Allow.
  - A reader that refuses and then works (a keychain that gets unlocked): a failed retry writes nothing, and once the key reads, the wait ends and the copy burns without Allow.
- `BurnProof --autopilot-worktrees`: retire of a real worktree with a blocking reader returns the key refusal within the bound. The folder, its registration and the refs are untouched, and no archive is left.
- `BurnZombiesApp --autopilot-proof`: the popover card and the Details prompt render.
