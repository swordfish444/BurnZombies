# Reclaim the leftovers. Keep the work.

**Settings → Disk cleanup tuning** starts collapsed and in **Recommend** mode. A local inventory finds supported generated folders inside configured repository roots. It costs no model tokens. Native code supplies facts and enforces permissions; the existing harness makes the semantic decision about completed use and reproducibility.

## Tune it once, refine it over time

- **Conservative / Balanced / Proactive** set minimum age, newest-run protection, scan cadence and daily removal cap. Custom values remain editable.
- **Free-space target** holds the disk review queue while available space is above the target. It never overrides a guard.
- **Minimum candidate size** keeps small clutter out of the inventory.
- **Protected paths** protect both a directory and any candidate containing it.
- **Keep / Review / Regenerable** are durable exact-folder classifications. Review is the default, not deletion permission. Regenerable requires explicit confirmation that the folder contains replaceable output, not valuable evidence or user data.
- **Preferences for the reviewing agent** preserve nuances such as keeping release evidence longer or never discarding repro cases. They are supplied with the candidate, not inserted into working chats. These are saved preferences, not model training.

Save applies the next local scan. Recommend mode never removes anything. Automatic mode can remove an explicitly permitted folder only after independent harness review and fresh native checks. Changing age or free-space settings cannot grant that permission. Folder rules are exact, not recursive wildcards granting every future checkout cleanup authority.

## What qualifies

Discovery is bounded and rotates repository coverage. It considers repository-root `.cache`, `dist-web`, `dist`, `build`, `test-results`, `playwright-report`, and individual `artifacts/<run>` folders. The newest configured number of evidence runs remain protected. Oversized or incomplete inventories are preserved.

Before removal, the exact path must still belong to the same repository, be ignored and contain no tracked files. Filesystem identity and a complete metadata fingerprint must match. The retention period must have passed; locks and unfinished Git operations block removal. Symlinks, hardlinks, special files, secrets-like files and databases are refused. The user must have classified the exact folder as regenerable. The reviewer must corroborate reproducibility and completed use, not infer these from an old timestamp.

**Active consumers or incomplete same-user handle visibility block removal.** No permission downgrade, privacy-permission change or age threshold bypasses this boundary. Protected macOS services can make unattended disk cleanup unavailable on a particular Mac. The inventory explains the refusal; process observation continues.

Only one disk/worktree candidate enters a review batch. The shared reviewer keeps its hourly cooldown, daily attempt/input limits and failure pause. Unchanged reviewed evidence is not resubmitted. Settings changes and scans never invoke a model directly. See [usage accounting](USAGE.md).

## Whole worktrees need their owner's lifecycle

An archived chat, merged branch, clean Git status or idle process is useful evidence, not standalone deletion authority. A checkout can contain untracked evidence, ignored assets, unpushed commits or future consumers. BurnZombies identifies existing linked worktrees but leaves their removal to the owning manager. It does not auto-archive unrelated Codex chats or adopt their checkouts.

Codex provides recoverable managed-worktree cleanup and protects pinned/in-progress work. Use that manager for its existing checkouts. BurnZombies's optional explicit disposable-workspace API supports its own owner-released worktrees with commit preservation and complete visibility; see [worktree cleanup](WORKTREE-CLEANUP.md). Generated-output removal does not increment the worktrees-cleaned counter.

## Receipts and recovery

Removal first persists an intent and rechecks the current policy. The exact folder is atomically isolated on the same volume and its fingerprint is checked again. A change aborts the operation and attempts restoration. An interrupted isolation remains at the recovery location in its receipt; startup never silently purges it. Successful removal is permanent for explicitly regenerable output.

Disk credit requires verified removal plus a durable receipt. Credit is the observed free-space increase, capped at allocated blocks removed. APFS sharing, snapshots and concurrent disk writes mean an inventory size is not guaranteed reclaimable space. Moving a folder to another location on the same volume earns no credit. Failed or interrupted cleanup earns none.

## Research behind the boundary

Reviewed October 27, 2026:

- [Codex worktree cleanup](https://learn.chatgpt.com/docs/environments/git-worktrees#worktree-cleanup): native retention, protected tasks and recoverable archives. This supports owner-managed cleanup rather than deleting another harness's directory.
- [Git worktree](https://git-scm.com/docs/git-worktree): locks and clean removal; `prune` removes stale administration, not live checkout contents. BurnZombies never uses force removal.
- [Apple local snapshots](https://support.apple.com/en-us/102154): snapshots affect available/reclaimable storage. Directory totals cannot establish unique physical bytes recovered.
- [Gradle directory layout](https://docs.gradle.org/current/userguide/directory_layout.html): native retention and cache lifecycle. Global cache cleanup belongs with the package manager; it is not an arbitrary old-folder rule.
- [Docker pruning](https://docs.docker.com/engine/manage-resources/pruning/): stopped/unused objects have separate removal boundaries, particularly volumes. BurnZombies does not infer that persistent container data is disposable.

The resulting strategy is a small evidence packet, a remembered user policy, an independent model decision, and a fresh guarded action. More assertive prompts cannot substitute for missing ownership or consumer evidence.
