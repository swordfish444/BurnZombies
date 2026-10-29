# Mole and BurnZombies

Mole is a useful discovery provider. BurnZombies should combine its toolkit with the existing harness's reasoning, then execute only a narrowly described operation whose safety can be checked immediately before execution.

## What ships now

When Homebrew Mole is already installed, `disk_inspect` can include its JSON analysis of the exact measured branch. BurnZombies invokes only the bundled analyzer directly, with no shell, sudo, interactive UI, downloads, or cleanup commands. Each result is limited to 12 entries, an 8-second execution window and 1 MiB of accepted output. The analyzer and its own `du`/Spotlight helpers run in a private process group that is closed on completion, timeout or output overflow. Results and failures are cached for six hours. The two-inspection limit and eight-call bound apply to each focused review within a hunt. Automatic hunts default to every four hours, with a configurable schedule and a manual **Hunt Zombies** action; no internal daily token cap stops useful work. Absence or failure of Mole does not block native discovery.

Paths outside the measured branch, linked paths and protected paths are discarded. A branch containing protected paths, online-only data or incomplete native measurements is not sent to Mole. Partial and unavailable results remain explicit. Mole's `cleanable` flag is a hint, never deletion permission. Native APFS measurements remain the source for storage accounting. Mole is an optional separately installed program; its GPL code is not copied into BurnZombies.

## Supported owner operation

Discovery can now lead to one bounded owner-controlled action: **unused local BuildKit cache**. An independent harness review receives exact eligible record IDs, previews a selected set and consumes a one-use cleanup token. No folder marking or per-session hook is needed. Native code gathers evidence and enforces the boundary; the model selects the useful operation.

Only an already running, single-node local embedded Docker builder is supported. Current owner inventory combines exact Engine API v1.51 bytes/timestamps with Buildx's state flags. Automatic policy, retention, newest-record protection, the free-space goal and remaining daily byte allowance apply. The adapter pins the owner, revalidates before dispatch, and supplies anchored exact IDs plus unused/unshared/immutable/regular filters to the engine. The engine rechecks active references under its own locks. No raw path, image, container or volume removal is exposed.

Prepared and uncertain attempts remain recorded; unknown completion is never retried automatically or counted as recovery. Receipts distinguish cache capacity released inside Docker from physical disk space returned to macOS. See [the full boundary and validation limits](DISK-CLEANUP.md#build-cache-without-marking-folders).

## Other operation classes

Future adapters should approve **operation classes**, not arbitrary paths, and prove the owning tool's concurrency and preservation semantics. A manager command named `prune`, `verify` or `clean` is not sufficient proof. Keep valuable evidence, databases, source and worktrees on separate preservation paths.

| Operation | Evidence before execution | Execution boundary |
| --- | --- | --- |
| Docker build cache — implemented | Exact local embedded builder; old, unused, immutable, unshared regular records | Exact-ID owner GC, policy allowance and durable receipts; no raw host deletion |
| Package-manager downloads — not automated | Exact manager/store identity, retention and documented concurrent-use protection | A future manager-native adapter; never install, upgrade or uninstall |
| Generated project output | Producer/build manifest, ignored and untracked output, reproducibility, completed use, complete consumer visibility | Exact identity-bound preview and cleanup, rechecked at execution |
| Harness worktrees | Owner attachment, saved changes/commits, ignored-file retention, no active consumers | Owning harness's recoverable archive |
| Investigation logs | Retention release plus cloud file identity, size and checksum matching local bundle | Remove only verified local originals; evict synced cache without deleting cloud files |

The supported cache action uses the existing Automatic disk policy, daily byte limit and free-space target. It does not require the user to label each cache directory. That policy does not waive the incomplete-visibility block for raw file/worktree removal or authorize unsupported managers.

For every action, save an intent before mutation, bind the preview to exact identities and the operation arguments, revalidate immediately, persist the owner-tool receipt, and measure actual disk change. A change, missing visibility, unsupported tool version or ambiguous result preserves the data. Do not count intended bytes as recovered space.

Mole's current `clean` removes categories broadly and rejects the former `--select`, `--categories` and `--exclude` flags. Its `purge --yes` selects eligible artifacts across configured roots. Neither exposes the exact immutable candidate manifest needed for a surgical unattended executor. Do not wrap either broad command as a BurnZombies burn action. A future upstream integration should add a versioned JSON plan and exact apply-by-plan interface, with identity checks and structured receipts.

## Research and validation

Reviewed upstream `tw93/Mole` commit `45ee88cbb07b325901b80d7db8b1624fa1dceb05` and locally installed Mole 1.65.0. Relevant upstream sources: [JSON analysis and scan status](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/cmd/analyze/json.go), [cleanup flags and preview ledger](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/bin/clean.sh), [project purge](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/bin/purge.sh), and [license](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/LICENSE).

Mole proof covers outside-scope paths, symlinks, protected entries, partial results, cached bounded inspection, and no deletion through the recommendation path. BuildKit protocol fixtures additionally cover exact selection, active-reference races, retained/shared controls, policy/owner drift, late revocation and uncertain dispatch. Read-only inspection passed on the installed Docker engine; all 57 records were younger than the current retention. One real-engine contract using a generated, verified-absent ID accepted the production filters and preserved every existing record, container state, image and volume. It reclaimed zero bytes. Positive real-engine cache deletion remains unproven; no cache or physical disk recovery is claimed from these checks.
