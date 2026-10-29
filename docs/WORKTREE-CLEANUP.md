# Worktree discovery, retirement and recovery

The Worktrees window inventories registered Git checkouts under folders you select, including small checkouts, detached HEADs, missing registrations and repositories with many linked worktrees. Open it by clicking **Worktrees cleaned** in Impact. Discovery is read-only. Age and file/commit dates are review hints, not a last-used measurement or permission to delete.

## Review and manage

1. Add a repository or its parent folder and scan. Disk settings can suggest folders; you still choose which to add. Scans publish partial results, report coverage limits and rotate detailed inspection across large inventories. Canceling preserves completed observations.
2. Select a checkout to inspect its identity, HEAD/branch, local and ignored changes, consumers, owner claims and blockers. **Refresh PR metadata** optionally uses your existing GitHub CLI login for bounded exact-commit metadata. Merged PRs never establish retirement authority.
3. **Manage this worktree** explicitly adopts an eligible existing linked checkout. Main/bare repository anchors, default-branch checkouts and recognized Codex/Claude/Cursor-managed locations stay protected. Owner-managed locations receive a handoff to their owning application. **Keep** vetoes retirement.
4. Every consumer can retain a private owner token and later release it with factual completion evidence. All owners must release; HEAD, branch/content or ownership changes invalidate old authority. Human retirement requires an exact current revision and an observed completion explanation. Uncertainty preserves the checkout.
5. Clean retirement needs a fresh caller-bound, single-use preview. Dirty or ignored content requires the separate manual **Archive and retire** flow. **Rescue local work** makes a verified snapshot while keeping the original. Supported symlinks are archived as links, never traversed.

Selected clean checkouts can be reviewed as a batch of at most 50 exact IDs/revisions. Only eligible items execute. Each item receives its own archive and current checks; changed or vetoed items are skipped. Batch review does not confirm completion on your behalf.

## Preserve before removal

Before removing anything, BurnZombies writes a durable operation journal, retains a Git recovery ref, creates an independent encrypted archive and restores it into an isolated directory. It verifies Git objects, file digests, the raw index and staged/unstaged status. The archive contains reachable commit objects, staged objects, working files, untracked/ignored files, supported extended attributes, modes and modification times. Repository configuration, hooks and remote credentials are not copied. A clean archive can preserve a unique local commit even without a remote-tracking ref.

The app rechecks the complete source file set, hashes, identity, claims, policy and native consumers before removal. Clean removal uses `git worktree remove` without force. Explicit manual dirty retirement uses a single `--force` only after independent recovery verification. There is no double force, branch deletion, broad `git clean`, garbage collection or automatic metadata prune. Git documents these separate [worktree operations](https://git-scm.com/docs/git-worktree); independent commit preservation uses [Git bundles](https://git-scm.com/docs/git-bundle).

Recovery files use chunked AES-GCM authenticated encryption with a random key stored in this Mac's Keychain. Archive integrity is bound to the operation, file and chunk. Losing the key can make independent recovery impossible. **Check recovery key** allows an explicit access/unlock prompt after an app upgrade; background work never prompts. A missing key is not silently replaced while unpurged archives depend on it. Keep the private state directory and Keychain together in your backup strategy.

**Archive and quarantine** first verifies recovery, then uses Git's move operation to put the checkout in a private directory on the same volume. Moving reclaims no disk space. Final retirement recommends seven days of grace, or requires an explicit **Retire now** choice. Files added or changed during quarantine block final removal. The independent archive remains after final retirement.

## What stays protected

Removal requires complete same-user cwd, executable and vnode-file visibility plus no observed consumer. Large descriptor tables are collected dynamically with explicit bounds. An unresolvable executable, inaccessible descriptor, process identity race, unknown ownership, disconnected volume or inspection limit blocks removal. Full Disk Access setup does not guarantee complete native process visibility.

Additional blockers include active claims, a Keep decision, locks, unfinished Git operations, sparse/conflicted/assume-unchanged indexes, submodules, nested repositories, filters/LFS, shallow/partial clones, hardlinks, online-only files, special file types/bits, native flags, extended ACLs, unsupported encodings and failed database or archive verification. The supported file ceiling is 100,000 entries, with a 10 GiB capture ceiling and bounded Git/worker deadlines. Root-directory ACLs are refused; creation/access times are outside the recovery contract. Unsupported state needs owner-native recovery; it is never silently discarded.

The final check narrows races but cannot make every future filesystem access atomic with Git removal. Owner release must mean continuing and future consumers have finished. Retain before reuse. Readiness changes are eligible for a new bounded review; unchanged age or resource churn does not repeatedly spend model tokens.

## Recovery and interrupted work

**Recovery** lists durable operations separately from the short-lived Burn Log. **Restore to new folder** creates and verifies a standalone repository in a new canonical directory. It never overwrites an existing destination. Recovery has been tested after deleting the original sacrificial repository. A failed restore retains the archive and records its partial destination for inspection.

On restart, incomplete operations become **uncertain**; they are never replayed or credited automatically. **Reconcile recovery** verifies the archive and the actual original/quarantine state. It can establish that the original is intact, the exact quarantine exists, or the checkout is absent. Absence discovered during reconciliation receives no cleanup or disk attribution. Ambiguous state remains protected. An interrupted purge is reconciled only when its exact archive directory is proven absent.

**Purge recovery** is a separate explicit destructive decision. No background archive expiry is enabled; archives remain until you choose to purge them. Purging independent recovery leaves Git recovery refs intact. The worktree SQLite database, claims and recovery dependency records outlive process-log pruning. A corrupt or newer database disables worktree management while process observation continues.

## Automatic policy and model access

Automatic clean retirement requires an explicitly managed repository with automatic retirement enabled, every exact owner released for at least 24 hours, complete checks, verified independent recovery, and the shared disk settings in Automatic mode below their free-space goal. It respects the shared daily disk allowance and a default maximum of three worktree retirements per day. Dirty retirement, adoption, human confirmation, quarantine finalization, restoration and archive purge stay manual. Legacy BurnZombies-created disposable workspaces keep their original stricter clean/remote-reachability contract and private owner tokens through migration.

MCP exposes bounded inventory, inspection, claims, release/retain, recommendations and guarded automatic clean retirement. Review sessions receive only their supplied IDs. Background reviewers cannot adopt, invent human confirmation, change policy, release owners, force removal or purge archives. No private file contents or owner-token hashes enter inventory responses.

## CLI

The installed app owns all mutations. These commands use its authenticated private socket:

```sh
burnzombies worktrees list
burnzombies worktrees scan
burnzombies worktrees operations
printf '%s\n' '{"action":"list","offset":100}' | burnzombies worktrees request
printf '%s\n' '{"action":"inspect","id":"EXACT_ID"}' | burnzombies worktrees request
```

Native management requests use exact IDs/revisions from inspection, for example `adopt`, `keep`, `rescue`, or `restore` with an operation ID and a new absolute `path`. Use the UI for reviewing destructive choices. The paired CLI flow keeps confirmation, preview and retirement in one authenticated process:

```sh
burnzombies worktrees retire EXACT_ID CURRENT_REVISION --evidence 'Observed completion and no remaining consumer.'
burnzombies worktrees archive-retire EXACT_ID CURRENT_REVISION --evidence 'Observed completion; preserve all local content before removal.'
burnzombies worktrees quarantine EXACT_ID CURRENT_REVISION --evidence 'Observed completion; preserve and quarantine this local work.'
```

Do not copy a preview token between separate CLI invocations: it is caller-bound. A lost response is not permission to retry. Inspect operation history first. Worktree requests allow up to 15 minutes for preservation; scans and Git subprocesses have their own shorter bounds.

## Impact and validation

Only a verified removal with a durable receipt counts as a worktree cleaned. Disk credit is the observed filesystem free-space increase around removal, capped by allocated regular-file blocks. APFS sharing, snapshots and unrelated activity limit attribution; a completed retirement may earn zero disk bytes. Rescue, quarantine moves, failed/interrupted operations and reconciliation earn no removal credit. Recovery storage is displayed separately.

See [validation and remaining live-host limits](VALIDATION.md#worktree-lifecycle-011) for actual fixture, native, scale and packaging evidence. A local build is not an installed or published release.
