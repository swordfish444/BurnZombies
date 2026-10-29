# Reclaim the leftovers. Keep the work.

**Settings → Disk cleanup** starts collapsed and in **Recommend** mode. A read-only storage map covers accessible home storage, Applications, Library and private system data. It follows actual directory sizes, independently of cleanup roots or output-folder names. Native code measures facts; your existing harness investigates what produced the storage and recommends what to do.

## Start with the recommendation

Discovery cards start at **10 GB of measured unshared storage**. Each has a short recommendation and one practical next step. Smaller outputs are still measured: repeated folders can form one large opportunity. Referenced footprint, coverage gaps and paths stay under Details. Unshared storage excludes APFS clone sharing and hardlinks. It is a conservative lower bound on stored blocks, not a guarantee that every file is disposable.

The harness can inspect measured branches, read bounded producer/build/retention evidence, group repeated outputs and ask the native scanner to go deeper. It then finishes; no model sits waiting for a filesystem walk. Completed subtrees become available while the rest of a large scan continues. Completed measurements and advice survive app restarts; an interrupted branch starts a new local walk. Online-only files are not hydrated. Permission gaps are reported, never interpreted as empty space.

The AI distinguishes reusable source, retained evidence, rebuildable output and owner-managed caches. An old timestamp, ignored folder, completed chat or suggestive name alone is insufficient. Prefer the owner's cleanup/archive workflow; preserve dirty-source artifacts and active consumers. A useful recommendation can explain a blocked opportunity without pretending it is ready to delete. Discovery tools never execute commands, change cleanup rules or remove files.

If Mole is already installed through Homebrew, exact-branch inspections can also use its JSON analyzer. The adapter is read-only, bounded and cached; protected or incompletely mapped branches stay native-only. Mole's cleanup hints are evidence for the harness, never permission to delete. No Mole installation, global skill or per-chat hook is added. See [the supported integration](MOLE-INTEGRATION.md).

Expand **Advanced** to tune retention, scan cadence, free-space goal, daily removal cap, cleanup roots, protected folders or instructions. Existing guarded cleanup cards live there too: **Keep** protects an exact folder; **Approve cleanup…** confirms replaceable output and enables guarded automatic cleanup for approved folders. It does not remove anything immediately or invoke an extra model call. The free-space goal gates removal, not discovery. Folder rules are exact, not recursive cleanup grants. Recommend mode never removes anything.

## Discovery and removal have different boundaries

Discovery has no generated-folder allowlist. Its native walker yields between metadata slices, stays on the same filesystem, never follows symlinks and caps the stored index. The AI sees compact summaries, not millions of paths. It can follow a large branch beyond the index depth and inspect bounded source/manifests; it cannot read credentials, profiles or transcripts through those tools. Large scans run independently of process observation.

Each root runs in one private, short-lived CLI worker. Atomic checkpoints are bounded to 4,096 nodes and 8 MiB and must match the exact root and run ID. The app validates paths lexically; filesystem resolution stays inside the worker. A worker with no traversal progress for 30 seconds, or a root taking more than 30 minutes, is stopped and reaped before another root starts. Finished subtrees survive; the interrupted root stays incomplete with a coverage gap. Other queued roots continue, and the stalled root is retried only on the next normal scan cycle or an explicit exploration request. A policy change cancels the current worker. If teardown cannot be confirmed, discovery stops spawning workers and reports the failure. None of these events triggers a model call or grants cleanup permission.

That isolation covers background traversal and queued deeper walks. Explicit inspection and evidence-reading tools have separate bounded request paths; they are not claims that every possible filesystem operation is interruptible.

The **raw folder removal** path remains intentionally narrow: configured repository-root `.cache`, `dist-web`, `dist`, `build`, `test-results`, `playwright-report`, and individual `artifacts/<run>` folders. Whole-machine discovery does not expand destructive permissions. Existing worktrees and unsupported owner-managed caches receive recommendations for their owning tool. The newest configured number of evidence runs remain protected. Oversized or incomplete removal inventories are preserved.

Before removal, the path must belong to the same repository, be ignored and contain no tracked files. Filesystem identity and a complete fingerprint must match. Retention must have passed; locks and unfinished Git operations block removal. Symlinks, hardlinks, special files, secrets-like files and databases are refused. The user must classify the exact folder as regenerable. The reviewer must corroborate reproducibility and completed use.

**Active consumers or incomplete same-user handle visibility block raw folder and worktree removal.** No permission downgrade or age threshold bypasses this boundary. Protected macOS services can make those removal paths unavailable. Discovery can still explain the opportunity; process observation continues. The separate BuildKit operation below relies on the storage owner's reference locks and never deletes host paths.

Discovery and cleanup participate in the same deep hunt, scheduled every four hours by default or started explicitly with **Hunt Zombies**. The frequency is configurable; each focused harness invocation retains its eight-call bound and failure pause. Daily token/count cutoffs do not stop useful work. Discovery reviews expose only storage tools and concise storage instructions; up to two supplied branches match the inspection budget. Unhandled branches stay queued, with backoff after repeated attempts without progress. Small file changes and unchanged recommendations do not launch new reviews. Deeper native scans produce evidence for a later review without keeping a model running. Destructive actions always use fresh, complete evidence. Settings changes and local scans never invoke a model directly. See [usage accounting](USAGE.md).

## Build cache without marking folders

BurnZombies can inventory an already running local Docker embedded builder and let the harness select an exact set of unused BuildKit cache records. It never starts Docker, creates a builder, contacts a remote engine, or invokes system/image/container/volume pruning. Other builder drivers remain unsupported.

The supported action requires **Automatic** disk mode, free space below the configured goal, a useful eligible set of at least 10 GB, and the remaining daily byte allowance. Every selected record must be regular, immutable, unused, unshared, older than retention, and outside the configured newest-cache protection. The model receives only a bounded opportunity; it cannot supply a shell command or broaden the exact-ID filter. Recommend mode shows the opportunity without deleting anything.

The adapter pins the local owner/socket, re-reads exact bytes and timestamps through Docker Engine API v1.51, and matches them to Buildx state flags. Current Buildx JSON rounds sizes and ages, so those formatted values never authorize cleanup. Unsupported versions, conflicting evidence or changed ownership preserve the cache. Immediately before dispatch it rechecks the live policy, free-space goal and plan expiry. BuildKit's own reference and retention checks protect a build that begins after the preview.

A durable intent precedes dispatch. One-use previews bind the caller and exact records. Completion requires the owner to report those records removed and a fresh inventory to confirm their absence, while container states, images and volumes remain preserved. A timeout or ambiguous result earns no credit and blocks automatic retries until reconciled. New protected cache records and repeated observation timestamps do not wake another AI review.

**Cache released inside Docker is shown separately from disk reclaimed on the Mac.** Docker's sparse backing file can retain its host allocation after cache GC. The adapter does not inflate the main disk counter with inventory size or unmeasured VM recovery.

## Whole worktrees need their owner's lifecycle

An archived chat, merged branch, clean Git status or idle process is useful evidence, not standalone deletion authority. A checkout can contain untracked evidence, ignored assets, unpushed commits or future consumers. BurnZombies identifies existing linked worktrees but leaves their removal to the owning manager. It does not auto-archive unrelated Codex chats or adopt their checkouts.

Codex provides recoverable managed-worktree cleanup and protects pinned/in-progress work. Use that manager for its existing checkouts. BurnZombies's optional explicit disposable-workspace API supports its own owner-released worktrees with commit preservation and complete visibility; see [worktree cleanup](WORKTREE-CLEANUP.md). Generated-output removal does not increment the worktrees-cleaned counter.

## Receipts and recovery

Removal first persists an intent and rechecks the current policy. The exact folder is atomically isolated on the same volume and its fingerprint is checked again. A change aborts the operation and attempts restoration. An interrupted isolation remains at the recovery location in its receipt; startup never silently purges it. Successful removal is permanent for explicitly regenerable output.

Disk credit requires verified removal plus a durable receipt. Credit is the observed free-space increase, capped at allocated blocks removed. APFS sharing, snapshots and concurrent disk writes mean an inventory size is not guaranteed reclaimable space. Moving a folder to another location on the same volume earns no credit. Failed or interrupted cleanup earns none.

## Research behind the boundary

Reviewed October 28, 2026:

- [Codex worktree cleanup](https://learn.chatgpt.com/docs/environments/git-worktrees#worktree-cleanup): native retention, protected tasks and recoverable archives. This supports owner-managed cleanup rather than deleting another harness's directory.
- [Git worktree](https://git-scm.com/docs/git-worktree): locks and clean removal; `prune` removes stale administration, not live checkout contents. BurnZombies never uses force removal.
- [Apple local snapshots](https://support.apple.com/en-us/102154): snapshots affect available/reclaimable storage. Directory totals cannot establish unique physical bytes recovered.
- [Gradle directory layout](https://docs.gradle.org/current/userguide/directory_layout.html): native retention and cache lifecycle. Global cache cleanup belongs with the package manager; it is not an arbitrary old-folder rule.
- [Docker pruning](https://docs.docker.com/engine/manage-resources/pruning/): stopped/unused objects have separate removal boundaries, particularly volumes. BurnZombies does not infer that persistent container data is disposable.
- [BuildKit cache manager](https://github.com/moby/buildkit/blob/master/cache/manager.go), [Buildx prune](https://github.com/docker/buildx/blob/master/commands/prune.go), and [Docker's versioned API schema](https://github.com/moby/moby/blob/v28.5.2/api/swagger.yaml): exact owner inventory, anchored ID filters, reference locks and cache-retention checks. [Docker Desktop's Mac storage FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/) distinguishes VM cache release from host disk recovery.

Validation covers adversarial protocol fixtures and a read-only check against Docker 29.7.2, Buildx v0.36.1-desktop.1 and BuildKit v0.32.2. That live check found 57 records, all within the existing 14-day retention. A separate single no-match actuator contract generated an ID proved absent, exercised the production filters, and verified that all 57 records, container states, images and volumes remained. It reclaimed zero bytes. Positive cache-removal paths are fixture-tested; actual engine deletion is not yet demonstrated by this proof. Neither test justifies relaxing retention or claiming reclaimed space.

The resulting strategy is a small evidence packet, a remembered user policy, an independent model decision, and a fresh guarded action. More assertive prompts cannot substitute for missing ownership or consumer evidence.
