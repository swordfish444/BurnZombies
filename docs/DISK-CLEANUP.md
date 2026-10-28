# Reclaim the leftovers. Keep the work.

**Settings → Disk cleanup** starts collapsed and in **Recommend** mode. A read-only storage map covers accessible home storage, Applications, Library and private system data. It follows actual directory sizes, independently of cleanup roots or output-folder names. Native code measures facts; your existing harness investigates what produced the storage and recommends what to do.

## Start with the recommendation

Discovery cards start at **10 GB of measured unshared storage**. Each has a short recommendation and one practical next step. Smaller outputs are still measured: repeated folders can form one large opportunity. Referenced footprint, coverage gaps and paths stay under Details. Unshared storage excludes APFS clone sharing and hardlinks. It is a conservative lower bound on stored blocks, not a guarantee that every file is disposable.

The harness can inspect measured branches, read bounded producer/build/retention evidence, group repeated outputs and ask the native scanner to go deeper. It then finishes; no model sits waiting for a filesystem walk. Completed subtrees become available while the rest of a large scan continues. Completed measurements and advice survive app restarts; an interrupted branch starts a new local walk. Online-only files are not hydrated. Permission gaps are reported, never interpreted as empty space.

The AI distinguishes reusable source, retained evidence, rebuildable output and owner-managed caches. An old timestamp, ignored folder, completed chat or suggestive name alone is insufficient. Prefer the owner's cleanup/archive workflow; preserve dirty-source artifacts and active consumers. A useful recommendation can explain a blocked opportunity without pretending it is ready to delete. Discovery tools never execute commands, change cleanup rules or remove files.

If Mole is already installed through Homebrew, exact-branch inspections can also use its JSON analyzer. The adapter is read-only, bounded and cached; protected or incompletely mapped branches stay native-only. Mole's cleanup hints are evidence for the harness, never permission to delete. No Mole installation, global skill or per-chat hook is added. See [the integration and execution plan](MOLE-INTEGRATION.md).

Expand **Advanced** to tune retention, scan cadence, free-space goal, daily removal cap, cleanup roots, protected folders or instructions. Existing guarded cleanup cards live there too: **Keep** protects an exact folder; **Approve cleanup…** confirms replaceable output and enables guarded automatic cleanup for approved folders. It does not remove anything immediately or invoke an extra model call. The free-space goal gates removal, not discovery. Folder rules are exact, not recursive cleanup grants. Recommend mode never removes anything.

## Discovery and removal have different boundaries

Discovery has no generated-folder allowlist. Its native walker yields between metadata slices, stays on the same filesystem, never follows symlinks and caps the stored index. The AI sees compact summaries, not millions of paths. It can follow a large branch beyond the index depth and inspect bounded source/manifests; it cannot read credentials, profiles or transcripts through those tools. Large scans run independently of process observation.

The separate **removal** path remains intentionally narrow: configured repository-root `.cache`, `dist-web`, `dist`, `build`, `test-results`, `playwright-report`, and individual `artifacts/<run>` folders. Whole-machine discovery does not expand destructive permissions. Owner-managed caches and existing worktrees receive recommendations for their owning tool. The newest configured number of evidence runs remain protected. Oversized or incomplete removal inventories are preserved.

Before removal, the path must belong to the same repository, be ignored and contain no tracked files. Filesystem identity and a complete fingerprint must match. Retention must have passed; locks and unfinished Git operations block removal. Symlinks, hardlinks, special files, secrets-like files and databases are refused. The user must classify the exact folder as regenerable. The reviewer must corroborate reproducibility and completed use.

**Active consumers or incomplete same-user handle visibility block removal.** No permission downgrade or age threshold bypasses this boundary. Protected macOS services can make unattended disk cleanup unavailable. Discovery can still explain the opportunity; process observation continues.

Discovery and cleanup share the same hourly cooldown, eight daily starts, recorded-input threshold, eight-call review budget and failure pause. Small file changes and unchanged recommendations do not launch new reviews. Deeper scans produce new evidence for a later budgeted review. Destructive actions always use fresh, complete evidence. Settings changes and local scans never invoke a model directly. See [usage accounting](USAGE.md).

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
