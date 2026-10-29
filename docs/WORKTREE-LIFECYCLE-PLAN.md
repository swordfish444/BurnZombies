# Worktree lifecycle management: implementation plan

Date: October 29, 2026. Status: implementation reference; local delivery and remaining acceptance limits are recorded in [validation](VALIDATION.md#worktree-lifecycle-011). This document itself grants no cleanup authority.

Source baseline: remote `main` at `562cba5eec2ee45ca9d78dac40e528da630c67b0`, verified during planning. The original local `main` was at `2a56d04`; this plan includes the subsequent disk-discovery, owner-maintenance, review-transport and Full Disk Access changes through PR #18. Reconcile later changes to the affected files before implementation.

## 1. Outcome and product boundaries

BurnZombies should answer five questions for every discovered worktree: what is it, who still needs it, what valuable state exists only here, what action is available, and how can that action be reversed?

The finished product provides a repository-grouped inventory, evidence-backed stale-work recommendations, explicit ownership and completion records, clean retirement, verified rescue of dirty work, restoration, and opt-in automatic retirement of eligible managed worktrees. The existing menu bar observer, process cleanup and disk cleanup remain part of the same app.

Build this in the native Swift application and shared BurnCore. Keep operation local to the logged-in user. Existing selected-harness reasoning remains useful for investigation and completion assessment. Native prerequisites, recorded operator policy and the guarded executor determine which operations are possible. A model's confidence or a free-form instruction cannot bypass a protection.

Discovery permission, management permission, removal permission and recovery-purge permission are separate. Discovering a directory does not adopt it. Choosing a repository as a scan root does not authorize removing its worktrees. An existing generated-output rule does not authorize removing the enclosing checkout.

Initial supported actions cover ordinary local linked worktrees. Main checkouts and bare repositories appear in the inventory as protected anchors. Other applications' managed checkouts remain with their owner unless a supported integration provides exact identity, protections and a safe lifecycle operation. Unsupported features still appear with an actionable explanation.

Cloud sync, Windows, a replacement Git client, branch deletion, automatic transcript ingestion, arbitrary repository deletion and general filesystem cleanup are outside this delivery. Existing process, Gradle and BuildKit capabilities need no redesign for this feature.

## 2. What exists and what changes

| Surface | Current implementation | Required extension |
|---|---|---|
| Workspace identity | `WorkspaceSafety` accepts UUID directories under BurnZombies's private workspace root and verifies their Git relationships. | Discover arbitrary linked worktrees without granting removal authority; keep a separate exact identity and eligibility check. |
| Ownership | `WorkspaceClaim` supports one private owner token per created workspace, release and retain. `Monitor.recordWorkspace` caps tracked claims at 64. | Multiple consumers, explicit adoption of existing checkouts, human retirement decisions, durable ownership history and revocation. |
| Safety | Tracked, staged, untracked and ignored files; Git operations and locks; unusual indexes; filters; submodules; filesystem types; remote-ref reachability; live consumers. | Preserve these checks, return structured findings and coverage, and add operation-specific preservation requirements. |
| Native consumers | `bz_path_in_use` returns in-use, unused or unknown and preserves incomplete visibility. | Report the exact kinds of missing coverage and observed consumers; keep unknown blocking removal. |
| Cleanup | `Monitor.cleanWorkspace` prepares a receipt, saves a recovery ref, rechecks, removes without force and verifies. | Move orchestration behind one worktree service; add durable operation recovery, snapshots and first-class restore. |
| Storage discovery | Bounded native workers and `DiskDiscovery` measure large branches, record gaps and request bounded harness recommendations. | Use discovered locations as repository seeds; worktree discovery must include small checkouts and have its own inventory. |
| Owner operations | `OwnerMaintenance` supplies cached Gradle/BuildKit facts; owner-specific operations revalidate before execution. | Follow that separation for future worktree-owner adapters; existing cache/process actuators never remove worktrees. |
| Reviews | Typed `ReviewLane`, evidence revisions, scoped tools, persisted attempts and bounded workers. | Add inventory-advice routing, explicit workspace routing and invalidation on material evidence changes. |
| Permissions | `FullDiskAccess` gates scans and reviews with an operational check tied to the app build. | Preserve that setup contract; expose per-repository gaps. A granted setup check is not proof of complete handle visibility. |
| Persistence | Bounded compressed process catalog; workspace receipts are limited to 500 and generally 30 days. | A transactional worktree catalog and recovery index that outlive activity-log pruning. |
| UI and impact | Compact menu, Impact, Burn Log, disk settings and usage history. | Worktrees window, evidence details, adoption/retirement flows, batch plans and Recovery view. |
| Public interface | Workspace create/release/retain plus guarded preview/clean over shared IPC/MCP; limited CLI ownership bridge. | Paginated inventory, inspection, management, plan, restore and operation status through the same core. |

Relevant sources: [workspace checks](../Sources/BurnCore/Workspace.swift), [native visibility](../Sources/CBurn/Workspace.c), [monitor](../Sources/BurnCore/Monitor.swift), [store](../Sources/BurnCore/Store.swift), [catalog](../Sources/BurnCore/Models.swift), [discovery](../Sources/BurnCore/DiskDiscovery.swift), [review lanes](../Sources/BurnCore/ReviewBatch.swift), [agent service](../Sources/BurnCore/AgentBridge.swift), [impact](../Sources/BurnCore/ImpactNumbers.swift), and [existing fixture coverage](../Proof/WorkspaceTests.swift).

Two limits matter for planning. The current commit recovery ref depends on the original repository's object store surviving. Also, the positive cleanup fixture injects complete consumer visibility when the real native reader reports unknown. That is useful protocol proof, but it does not establish successful production actuation on this Mac. Both need explicit acceptance evidence below.

## 3. Architecture and storage decision

```text
Existing disk discovery + configured folders + explicit repositories + owner adapters
                               |
                     bounded repository discovery
                               |
             Git, filesystem, consumer and owner observations
                               |
                 WorktreeStore + evidence evaluation
                      /                       \
          UI / CLI / MCP inspection      selected-harness advice
                      \                       /
                     exact retirement proposal
                               |
                   WorktreeService operation journal
                               |
             preserve -> revalidate -> remove -> verify
                               |
                    durable receipt and restoration
```

Use a dedicated `WorktreeStore` backed by system SQLite. Incremental inventory, claims, snapshots and multi-step operations warrant transactions and indexed queries; growing the frequently rewritten process catalog would couple unrelated workloads and retention limits. Keep the process catalog and other cleanup stores intact. Add a small SQLite module binding if needed, without a new database framework or network service.

One service owns mutations. UI, CLI and MCP request operations through the existing authenticated local bridge; they do not independently open action-capable stores. Reads expose bounded projections. Scanner results carry a generation, and stale results cannot overwrite a newer owner decision or operation.

Start with ordinary SQLite transactions and durable settings; choose journal mode based on measured local concurrency. Database transactions do not make Git and filesystem operations atomic. Persist explicit intent and reconcile external side effects. Back up the database with its supported backup mechanism rather than copying a live database file and assuming consistency.

Proposed components:

| Component | Responsibility |
|---|---|
| `WorktreeModels.swift` | Identities, observations, claims, policies, decisions, plans and receipts. |
| `WorktreeStore.swift` | Versioned schema, transactional journal, migration, bounded queries and recovery index. |
| `WorktreeDiscovery.swift` | Seed reconciliation, Git registration inventory, moved/missing detection and scan coverage. |
| `WorktreeInspection.swift` | Bounded Git/filesystem/consumer probes and structured findings. |
| `WorktreeEligibility.swift` | Mechanical prerequisites and human-readable blockers; no model-generated authority. |
| `WorktreeService.swift` | Claims, adoption, proposals, execution serialization, cancellation and startup reconciliation. |
| `WorktreeRecovery.swift` | Preservation manifests, archives, verification, restoration and explicit purge. |
| `WorktreeOwner.swift` | Small owner-adapter interface; implement adapters only for verified capabilities. |
| `WorktreesView.swift`, `RecoveryView.swift` | Repository inventory, details, batch review and restoration. |

Keep the C boundary small: enrich native observation and exact filesystem identity operations. Refactor existing `WorkspaceSafety` primitives for reuse, but retain the private-root restriction in the existing action until adoption and the new executor are ready. Do not make changing that restriction the first implementation step.

## 4. Data, identity and evidence contract

The catalog has repositories, worktrees, observations, owner claims, policies, operations, recovery items and activity events. Store raw file contents only inside explicitly requested recovery archives, never inside inventory/model evidence.

Repository identity combines an application ID with the verified common Git directory and filesystem identity. Worktree identity combines an application ID, volume/directory identity, per-worktree Git administration, canonical location and the verified registration relationship. A path is a locator; a branch name is metadata. A changed directory at the same path is a new or uncertain object. Moved, remounted or repaired objects require verified reconciliation before action.

Keep these dimensions independent: ownership, activity, content, preservation, inspection coverage and permitted action. Each observation records its source, exact scope, observation time, completeness, limitations and evidence revision. Imported facts retain their original time. Unknown and not-supported are explicit values.

Derive these presentation states, retaining all additional blockers:

| State | Rule and next action |
|---|---|
| Active | Any retained owner, live consumer or continuing-use evidence. Keep. |
| Ready to retire | Exact retirement authority, completed-use evidence and all prerequisites for the selected action. Preview. |
| Possibly stale | Inactivity indicators without enough intent/completion evidence. Review or keep. |
| Contains local work | Unique content or commits need preservation. Inspect and rescue. |
| Inspection blocked | Required observation is incomplete, failed, stale or unsupported. Explain the missing check. |
| Missing or moved | Registration and filesystem disagree. Locate or repair; no automatic prune. |
| Retired / recoverable | Removal verified and recovery available. Restore or inspect retention. |

Age, last commit time, folder modification time and last observed activity remain separate facts. File events are invalidation hints, not a complete history. Sleep, downtime and event loss create coverage gaps. A new checkout of an old commit must not immediately look abandoned.

Separate preservation evidence from delivery evidence. A local remote-tracking ref is a cached fact, not a live remote acknowledgment. A deleted upstream, closed PR or merged PR is not removal permission. Normal merge ancestry, squash/rebase merges, subsequent local commits and ambiguous patch matches need distinct descriptions. Patch similarity alone never satisfies preservation. Detached commits require explicit retention too.

## 5. Discovery and inspection

Use configured worktree-discovery roots, explicit repository additions, BurnZombies's private workspace root, existing storage-map repository seeds and verified owner inventories. Existing disk cleanup roots can suggest discovery locations but do not become worktree cleanup grants. Never inherit the 10 GB storage-card threshold: a tiny worktree may contain the only copy of important work.

Walk incrementally without following directory symlinks or crossing filesystem boundaries implicitly. Detect `.git` directories, `.git` pointer files and bare repositories, then let Git resolve their actual layout. Deduplicate by verified common-directory identity and reconcile `git worktree list --porcelain -z`. Registered paths outside scan roots can appear as known registrations; inspect those locations only within the applicable discovery permission. A path being registered does not authorize traversing arbitrary mounts.

Read machine formats as bytes with NUL delimiters; preserve unusual paths without lossy string conversion. Pass arguments directly with option boundaries, never through shell interpolation. Keep hooks, fsmonitor, prompts and repository-defined filters from being executed by inspection. Probe supported Git capabilities and show unsupported features rather than guessing flags.

Inspection covers staged and unstaged changes, all untracked/ignored entries, Git operations and locks, index flags, nested repositories, submodules, filters, sparse state, filesystem types, allocated storage and native consumers. Inventory may stop early and report partial coverage; action inspection must complete its required checks. Do not hydrate cloud files or fetch missing objects during ordinary scans.

Offer registration repair and metadata cleanup as separate reviewed maintenance operations. A missing directory on an unavailable volume is not a stale registration. Before metadata removal, preserve any unique per-worktree HEAD, index and reflog dependencies; show Git's repository-scoped dry-run result and require the affected set to match the reviewed plan on revalidation. If a supported operation cannot safely bound that set, leave it as a manual owner handoff. Never hide a repository-wide `prune --expire now` behind a single-row cleanup button. Metadata repair/pruning receives no worktree-storage credit.

Reuse the isolated-worker pattern from disk discovery, with a separately bounded worktree queue. Do not run a Git status or recursively hash every checkout on every process sample. Cache stable facts, invalidate on relevant events and reconcile periodically. Deep inspections and snapshot creation run outside the monitor actor. Truncation must include a continuation cursor or a visible gap.

Proposed initial performance acceptance is a generated inventory of 1,000 small worktrees across 100 repositories: first-page results arrive before the full scan completes, the UI remains usable, cancellation is honored at bounded worker checkpoints, no model call occurs for unchanged evidence, and the inventory reconciles with Git. Measure runtime, memory and I/O on the actual supported machine before fixing numerical resource budgets. All sacrificial fixtures use invented labels and paths.

## 6. Ownership, adoption and integration

Extend created workspaces to multiple private consumer claims. Each claim records actor, purpose, completion condition, state and factual release evidence. Preserve existing token secrecy and caller authentication. Every active claim blocks retirement; retaining any claim invalidates outstanding plans. A dead owner or missing heartbeat never automatically releases it.

Add an explicit adoption flow for existing ordinary linked worktrees. Adoption records management responsibility and policy but does not fabricate completed-use evidence. Human-confirmed retirement can supply the exact intent for an unmanaged candidate after the user reviews local state. That decision is bound to the evidence revision; it cannot override active consumers or unsupported filesystem/Git conditions. Background reviewers cannot create human approvals, adopt checkouts, release another owner, change policy or purge archives.

For harness-managed worktrees, first verify whether a supported API or local interface can provide exact identities, pinned/in-progress protections, archive/remove behavior and restoration. Keep a capability record: inventory, activity, retirement and restoration are separate capabilities. Only expose supported operations. If safe retirement is unavailable, show the owner and a concrete handoff action while keeping direct removal disabled. Do not modify private application databases or collect chats to compensate for missing APIs.

Use the existing portable lifecycle skill and MCP/native bridge. Update the skill to cover worktree claims and handoffs. Do not add always-on hooks, wrappers, new recurring Codex tasks or a second harness runtime. Measure real working-agent registration/release behavior; skill installation alone is not delivery proof.

Optional GitHub enrichment is a later additive adapter. Match repository and commit identities, fetch only bounded PR metadata using an already authorized connector, preserve timestamps/rate-limit/auth failures and never require a network request to scan local work. A manual metadata refresh is separate from cleanup. Do not fetch refs, push, refresh credentials or acquire new permissions inside removal.

## 7. Clean retirement and restoration

The clean path supports an ordinary linked worktree with no local-only filesystem content, no unsupported features and no continuing consumer. It requires either an owner release plus corroborated completion, or a revision-bound human retirement decision. A default branch checked out as a linked worktree is protected by default even if it is not the main checkout.

Every action plan binds the worktree and repository identities, HEAD, inspection/content revision, claim revision, policy revision, selected preservation method, recovery location and short-lived caller-bound token. A batch holds exact per-item plans. No path-glob execution or batch-wide force flag exists.

Execution order:

1. Reserve an operation ID and exclude overlapping checkout/descendant/repository operations across worktree and generated-output cleanup. Serialize mutations of the same Git administration. This coordinates BurnZombies operations; it does not pretend to lock other applications.
2. Persist operation intent, exact authority and preservation requirements.
3. Preserve HEAD in a recovery ref and create a verified self-contained Git object archive for app-managed recoverable removal. Verify the required object closure in isolation. The default new flow must restore even if the original repository disappears; retain existing ref-only receipts with an honest dependency label.
4. Persist the recovery manifest and mark preservation verified. Failed preservation leaves the original worktree intact.
5. Recheck current identities, claims, policy, content, Git state and consumer visibility immediately before actuation. Any material change invalidates the plan.
6. Use `git worktree remove` without force for clean retirement. Never delete a branch or run repository-wide garbage collection as part of this action.
7. Verify the exact path and registration are gone and recovery remains available, then commit one completed receipt. Only that commit updates impact projections.

The journal uses prepared, preserving, preservation-verified, removing, verifying, completed, refused, failed and uncertain phases. After a crash, reconcile observable outcomes. Never blindly rerun a destructive step or credit an acknowledgment. A durable intent and verified recovery may allow completion to be established after restart; ambiguous cases stay uncertain with zero credit.

Restore verifies archive integrity and object completeness, checks a new destination for collisions and available space, and recreates a checkout through a supported safe route. Default to a detached restoration so branch conflicts cannot silently repoint a branch. Restore to a new directory before offering any relocation. Do not execute checkout filters or network helpers without a separately supported path.

Git and macOS do not provide a transaction over arbitrary future consumers and all filesystem changes. Record and document that residual race. Ownership release, narrow operation scope, immediate checks and independent recovery are the protection strategy.

## 8. Dirty-work rescue and retirement

Ship dirty snapshot/restore before offering dirty removal. A saved patch or Git bundle is insufficient: the snapshot must preserve staged versus unstaged state, binary changes, deletions, executable bits, untracked and ignored files, permitted symlinks as links, and the local Git objects required for recovery. A bundle does not contain the index or working tree.

Use a versioned manifest and streaming archive with content integrity checks. Capture a stable view or verify the relevant file/index/HEAD identities before and after capture; ongoing writes invalidate the snapshot. Copying a changing directory and calling it complete is not acceptable. Backups live outside the target and its descendants. Preflight space and inode capacity; a full disk pauses rescue rather than weakening it.

Treat recovery contents as sensitive. Keep private permissions, exclude content from model packets and logs, and encrypt archives containing local files using an app recovery key protected by macOS Keychain. Name the recovery-key lifecycle in implementation scope and make key/export dependencies visible. Verify decryption before removal. Losing the key is a recovery failure; never describe ciphertext alone as a usable backup. This plan creates no key or credential.

Initial rescue supports ordinary files and well-defined links only. Nested repositories, submodules, external hardlinks, sockets/special files, unusual index states, incomplete partial/shallow/promisor object graphs and LFS/checkout filters remain explicit blockers until their own capture-and-restore fixtures pass. Unsupported cases still support inspection and a concrete owner/manual recovery recommendation.

Before enabling removal, restore each new snapshot into an isolated destination and compare file bytes, supported metadata, HEAD and staged/unstaged state. Never restore over the original to test a backup. Include enough verified object/config information to recover without the original repository while avoiding automatic execution of saved hooks/configuration.

The new user action is **Archive and retire**. It requires exact human confirmation, no active claims or consumers, complete capture and successful restore verification. It remains separate from clean retirement and is excluded from unattended cleanup initially.

Where Git supports moving the checkout, allow a journaled move to a private same-volume quarantine with a proposed seven-day recovery grace period. Verify registration and identity after the move. Moving is not storage recovery and can break external path references; explain that before the action. Unsupported move cases stay blocked. A copied directory is never represented as a valid moved Git worktree without reconciling its administration.

Final dirty removal deliberately expands the present clean-only contract. Introduce an independently reviewed, separately named action whose authority binds the exact verified snapshot and target. If Git requires single-force removal of that dirty checkout, expose it only inside this action after repeated revalidation. Never double-force, override a pre-existing user lock, accept arbitrary paths, or reuse the clean preview token. Do not silently delete local files merely to make the clean guard pass. Git refusal or a changed target preserves the checkout/quarantine and archive.

Recovery archives have a proposed 30-day minimum retention after verified final removal, with Keep indefinitely and explicit Purge controls. Quarantine/grace expiration alone does not authorize irreversible removal unless the user selected that exact retention policy. Archive expiry marks purge eligibility, not permission. Default purge is manual; any later automatic purge needs a separately enabled retention policy. Storage pressure never silently purges the only recovery copy.

## 9. UI, CLI and model-facing contracts

Add **Worktrees** to the compact menu without opening a window during scans or reviews. The window groups by repository, supports search and filters, and displays branch/detached state, owner, last observed use, local-work summary, coverage and storage. Default ordering puts useful retirement/review opportunities first; active work stays easy to find. Remember Keep decisions and exact protected identities.

Selecting a row shows the evidence timeline and all blockers, the difference between observed inactivity and confirmed completion, current preservation coverage and the next available action. Display times as observations, not invented last-used dates. Local diff viewing is an explicit user action and does not send file contents to the model.

Actions: Keep, Inspect, Manage this worktree, Retain, Confirm retirement, Rescue, Retire, Archive and retire, Restore and Purge recovery. Only offer actions supported by the exact worktree. **Review suggested worktrees** opens an exact batch plan; it must not imply that all suggestions are eligible for deletion. Per-item changes skip that item without widening the remaining batch.

Recovery shows original repository/path, retirement time, archive location and size, retention, key/dependency status, integrity state and restoration controls. Keep the recovery index independently of the 30-day Burn Log. Distinguish complete recovery, commit-only recovery and recovery requiring the original repository.

Proposed CLI commands are `worktrees list`, `inspect`, `plan`, `claim`, `release`, `retain`, `retire`, `rescue`, `restore` and `operations`. Exact argument and JSON schemas are defined during their delivery slice. Mutations require exact IDs and expected revisions; list/inspect never create claims or remove files.

Expose equivalent bounded MCP operations through the same service. Preserve existing workspace create/release/retain/preview/clean names as compatibility adapters. Add capability/schema versions and pagination. Older clients may continue the existing narrow workspace workflow but do not gain adoption, dirty removal or policy changes by omission of new fields. Missing evidence defaults to unknown.

Separate read-only advice tools from owner-policy and destructive tools. Background review receives only queued IDs, compact evidence, coverage and scoped operations. It cannot see recovery keys/tokens or file contents. Labels, PR text and recorded owner statements remain untrusted data. Advice is invalidated by evidence or policy revisions, not by passage of time alone; bounded retries require changed evidence or an explicit request.

## 10. Policy, scheduling and accounting

Add a worktree-specific policy. Default to Recommend for discovered worktrees. Protect main/bare/default-branch anchors, pinned/kept work, active claims and unsupported owners. Per-repository adoption and automatic-retirement settings are explicit; a global free-space goal is not worktree-removal authority.

Proposed initial defaults: flag 14 days without observed activity for review; apply a 24-hour grace after release before unattended retirement; permit manual reviewed retirement earlier; initially allow at most three automatic clean retirements per day within the existing shared disk-removal allowance. These values control prioritization and scheduling, never prove completion. Tune them from observed recommendations and vetoes, without relaxing preservation prerequisites.

Use the existing resident scheduler and selected harness. Add typed worktree-advice evidence and retain an explicit workspace-action lane; remove the current catch-all routing of unknown non-process evidence into workspace cleanup. Unknown queue types must be refused. Process, cache, disk and worktree opportunities receive bounded fair scheduling so one lane cannot starve another. No model invocations for stable unchanged inventory and no active-chat dependency.

Account/quota failures retain the existing hard pause and no-provider-switch behavior. Permission loss pauses inspection/actions and reports the missing capability. Resuming requires fresh evidence where the gap invalidated continuity. A free-space goal or cleanup cap can defer execution without hiding inventory.

Report footprint, estimated removable allocation, recovery-storage allocation and verified observed disk credit separately. Measure source and archive volumes separately. Preserve the current conservative cap on observed free-space gain and qualify concurrent activity/APFS attribution; an archive or clone can produce zero or negative net storage benefit. No credit for same-volume relocation, metadata pruning, archive creation or a successful command alone.

Treat the operation receipt as the single source for new worktree credit. Batch totals include only completed unique operation IDs, avoid parent/child double counting, and distinguish worktree retirement from generated-output cleanup. Restoration records new consumption separately from historical cleanup totals; a restored-then-retired checkout is a new operation, never a replay of the old receipt. Keep host storage metrics separate from existing Docker internal-capacity metrics.

## 11. Migration, compatibility and rollback

Deliver inventory first alongside existing state, with no change to cleanup eligibility. At the action cutover, import claims and receipts with stable IDs and provenance. Keep ambiguous/interrupted legacy operations uncertain. Preserve current owner tokens through the new service, and invalidate all outstanding previews.

Use an idempotent, journaled cross-store cutover: import action records into WorktreeStore as inactive/pending; durably remove their action-capable copies from the old catalog; then enable the new service. A crash at any step must preserve data and leave at most one execution authority. Keep a private migration backup that the app never loads as live action state. Exercise each interruption point in a fixture.

Existing public operation names route through the new service so legacy callers cannot bypass multiple-owner claims or updated policy. Stale application builds must not retain action-capable imported records in the live legacy catalog. Do not claim that an already shipped binary understands a new schema marker: the safe fallback is that it has no migrated claim to act on. New and old observers remain mutually excluded by the instance lock.

Preserve historical impact once. Original IDs remain available for deduplication; existing lifetime counters form the legacy baseline and imported receipts do not increment them. New worktree operations contribute from the new transactional ledger. Other cleanup categories continue their existing accounting. Tests cover all-time and period totals across the cutover and rollback.

Failure to open or migrate the worktree store pauses worktree mutation; it does not justify restoring an old action-capable snapshot automatically. Inventory-only failures should not unnecessarily disable unrelated process cleanup. Downgrade leaves migrated checkouts and archives intact with worktree automation disabled; provide documented inspection/export and supported restoration. Rollback after dirty retirement requires a recovery-capable build or exported recovery, not an older app pretending those actions never happened.

Retain every recovery manifest and object/archive dependency until the user explicitly purges that item. Activity-log pruning cannot delete recovery records, their keys or their Git refs. Purging a recovery item must also explain that deleting its last bundle/ref may remove the final preserved copy of commits. Never run garbage collection implicitly to reclaim those objects.

## 12. Delivery slices and acceptance

These slices are ordered for reviewability and risk. The first useful release is inventory; removal expands only after its recovery path is proved. No calendar estimate is implied.

| Slice | Deliverable and likely surfaces | Dependencies | Acceptance |
|---|---|---|---|
| 1 | Worktree models, transactional store, schema and fake-clock/probe boundaries; `WorktreeModels`, `WorktreeStore`, package binding. | None. | Missing/unknown states, durable transactions, corruption handling, schema upgrade/refusal, bounded queries and backup/restore fixtures pass. No existing action changes. |
| 2 | Bounded repository/worktree discovery; disk seed integration, capability probes and reconciliation. | 1. | Fixture inventory matches Git, including small, detached, moved, missing, locked, bare and outside-root registrations; no traversal beyond permission and no source mutation. |
| 3 | Structured inspection/eligibility plus read-only Worktrees UI/CLI/MCP. | 2. | Each state explains evidence, gaps and next action; 1,000-worktree fixture stays usable; root changes/cancellation/restarts reconcile; real-machine comparison is read-only. |
| 4 | Shared ownership, human adoption, retain/release and journaled legacy cutover; `Monitor`, `AgentBridge`, `LifecycleInput`, skill. | 3. | Wrong-owner/token/caller, multiple consumers, dead owner, retain-after-preview and interrupted migration preserve work. Existing API clients keep narrow behavior; old live catalog cannot execute migrated claims. |
| 5 | Clean retirement service, self-contained preservation, Restore UI and durable recovery index. | 4. | Actual native sacrificial removal and restore pass; restore works after the fixture's original repository disappears; crashes at each operation phase reconcile with no double execution/credit. |
| 6 | Optional owner/GitHub metadata adapters with explicit capabilities and bounded cached provenance. | 3; action integration needs 5. | Rate limits, auth loss, offline mode, identity mismatches and unsupported lifecycle APIs stay unknown/protected; squash/rebase/subsequent-commit fixtures do not yield false preservation claims. |
| 7 | Exact batch plans, Keep policies, Recovery management, reviewed registration maintenance and unified impact projections. | 5. | A changed item is skipped; overlapping disk/worktree cleanup cannot race; existing policy grants cannot broaden scope; metadata maintenance preserves recovery and matches its reviewed set; historical and new totals deduplicate; retained recovery survives log pruning. |
| 8 | Dirty snapshot and verified restore, initially with no dirty deletion. | 5, 7. | Supported file bytes, modes, links, index and working-tree state restore independently; changed files, bad keys, full disks, incomplete object graphs and unsupported features refuse safely. |
| 9 | Explicit Archive and retire, supported quarantine, dirty final-removal action and manual purge. | 8. | Exact confirmation/snapshot/identity binding, grace/retention behavior, active-consumer vetoes, crash reconciliation and restore after actual removal pass. No generic force endpoint exists. |
| 10 | Opt-in automatic clean retirement, typed review routing, fair scheduling, release documentation and field validation. | 5, 7; does not auto-enable 9. | Only explicitly managed/released eligible work is selected; recommendations precede enablement; quota/access gaps pause; unchanged evidence invokes no model; all excluded controls survive. |

Milestone A is slices 1–3: discover and explain. Milestone B is slices 4–7: manage, retire clean work and restore it. Milestone C is slices 8–10: rescue dirty work and offer narrow unattended maintenance. Slice 6 can ship additively and is not a prerequisite for local inventory or self-contained recovery.

## 13. Verification and release proof

Follow the repository's existing checks: `scripts/test.sh` before a PR, `scripts/test.sh --integration` for lifecycle/action changes, sacrificial regression fixtures, and real native UI exercise for UI changes. Run affected MCP, lifecycle-install and installer checks when those contracts change. Record actual macOS/architecture, duration, injected boundaries and limitations. No cleanup test targets real user work.

The acceptance matrix includes:

| Risk | Required proof |
|---|---|
| Losing unique work | Staged/unstaged/binary/deleted/untracked/ignored content, detached commits and preserved-ref/object closure; dirty restoration compares complete supported state. |
| Mistaking inactivity for completion | Old commit in a new checkout, idle editor/server, closed chat, dead owner, expired heartbeat, merged/closed PR, deleted upstream and stale remote refs all retain the appropriate blockers. |
| Identity/race errors | Same-path replacement, moved repository, symlink/path tricks, unusual byte paths, changed HEAD/index/files, retained claim after preview, PID reuse and overlapping cleanup refuse or reconcile safely. |
| Unsupported Git/filesystem state | User locks, merge/rebase/cherry-pick, sparse/assume-unchanged, filters, submodules, nested repositories, special files, LFS and missing objects are protected until explicitly supported. |
| Incomplete visibility | Native process/descriptor limits, protected processes, permission denial/revocation, disconnected volume, worker timeout, truncation and cloud placeholders never become evidence of emptiness. |
| Interrupted operations | Crash/failure before and after every durable phase, Git side effect, rename, archive write, fsync and receipt commit leaves recoverable state and no false benefit. |
| Recovery loss | Corrupt/missing archive, unavailable key, deleted original repository, destination collision, insufficient space and expired log history produce honest recoverability states. |
| Privilege/prompt boundary | Malicious labels/PR text, forged peer, wrong/replayed token, advice-only caller and older clients cannot gain management, policy, purge or removal authority. |
| Migration/accounting | Mixed legacy/new events, restarts, rollback, repeated receipts, batch partial success and restore/re-retire preserve exact counts and recovery discoverability. |

Run real inventory observation against selected developer repositories only after synthetic coverage passes. Compare to Git registrations and human assessment. Classify disagreements as discovery misses, false stale suggestions, missed stale opportunities, missing ownership or incomplete coverage. Review only disputed classifications; do not repeat unchanged audits.

For positive actuation proof, create sacrificial repositories through the shipping app/CLI and use the production native visibility path. Include a clean released checkout, an active control, a dirty control, a retained owner, a missing-volume registration and a restore destination. An injected complete-visibility fixture cannot substitute for this proof. If the real Mac reports unknown, record the exact blocker and keep unattended actuation unavailable there; do not loosen the guard to obtain a pass.

Before enabling dirty removal, independently review its capture/restore and force-boundary implementation and prove actual recovery after removal. Before enabling automatic clean retirement, inspect a recommendation-only observation period, verify exact per-repository policy readback, then enable only the already proved category. Dirty retirement and recovery purge remain explicit actions.

Release notes and `WORKTREE-CLEANUP`, `SAFETY`, `MCP`, `USER_GUIDE` and `VALIDATION` must describe each supported category and its proof accurately. Update install/skill packaging only for delivered capabilities. Build and package through existing workflows, preserve selected harness/model settings and prior history, and verify the installed version separately from source-test success. Publication, installation and real cleanup are later execution actions, not part of this planning change.

## 14. Measures of success and residual limits

Track inventory reconciliation, unknown/blocked coverage, human-vetoed stale suggestions, missed stale opportunities, successful independent restores, operation refusals by cause, interrupted-operation recovery, verified storage credit versus retained backup cost, and model invocations per changed evidence set. These are concrete diagnostics; do not combine them into an invented safety score.

Release requires zero unintended fixture removals, successful restoration for every supported destructive path, preserved excluded controls, correct migration/receipt accounting and clear explanations for unsupported paths. Passing a finite matrix does not prove that arbitrary future consumers cannot race an operation. Keep that limitation visible, and expand support only when new evidence and recovery tests justify it.

The implementation starting point is slices 1–3 on the latest reconciled main: a read-only Worktrees inventory with structured coverage and an evidence detail pane. That creates immediate value while establishing the shared identity, evidence and persistence contracts used by every later action.

## Primary references

- [Git worktree](https://git-scm.com/docs/git-worktree): machine-readable registrations, clean removal, locks, move restrictions and metadata pruning.
- [Git status](https://git-scm.com/docs/git-status): staged/unstaged state, untracked/ignored files and machine formats.
- [Git bundle](https://git-scm.com/docs/git-bundle): object/ref preservation and the exclusion of the index and working tree.
- [SQLite atomic commit](https://sqlite.org/atomiccommit.html): transactional durability and its filesystem assumptions.
- [SQLite backup API](https://sqlite.org/backup.html): consistent database backup; separate from worktree-content recovery.

Owner/harness capability claims remain discovery work. No unverified third-party API is a prerequisite for the local core.
