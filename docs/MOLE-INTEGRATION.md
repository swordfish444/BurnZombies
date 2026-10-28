# Mole and BurnZombies

Mole is a useful discovery provider. BurnZombies should combine its toolkit with the existing harness's reasoning, then execute only a narrowly described operation whose safety can be checked immediately before execution.

## What ships now

When Homebrew Mole is already installed, `disk_inspect` can include its JSON analysis of the exact measured branch. BurnZombies invokes only the bundled analyzer directly, with no shell, sudo, interactive UI, downloads, or cleanup commands. Each result is limited to 12 entries, an 8-second execution window and 1 MiB of accepted output. The analyzer and its own `du`/Spotlight helpers run in a private process group that is closed on completion, timeout or output overflow. Results and failures are cached for six hours. The existing two-inspection review limit and shared daily token budget still apply. Absence or failure of Mole does not block native discovery.

Paths outside the measured branch, linked paths and protected paths are discarded. A branch containing protected paths, online-only data or incomplete native measurements is not sent to Mole. Partial and unavailable results remain explicit. Mole's `cleanable` flag is a hint, never deletion permission. Native APFS measurements remain the source for storage accounting. Mole is an optional separately installed program; its GPL code is not copied into BurnZombies.

## The next execution layer

Remove manual folder marking by approving **operation classes**, not arbitrary paths. The harness should select from a small set of owner-controlled operations, using fresh evidence. Start with reproducible build caches. Keep valuable evidence, databases, source and worktrees on separate preservation paths.

| Operation | Evidence before execution | Execution boundary |
| --- | --- | --- |
| Docker build cache | Exact local builder, unused cache records, no volume/image scope | BuildKit's cache prune with reviewed filters and byte cap |
| Package-manager downloads | Exact manager/store identity and supported dry-run | Manager-native cache cleanup; never install, upgrade or uninstall |
| Generated project output | Producer/build manifest, ignored and untracked output, reproducibility, completed use, complete consumer visibility | Exact identity-bound preview and cleanup, rechecked at execution |
| Harness worktrees | Owner attachment, saved changes/commits, ignored-file retention, no active consumers | Owning harness's recoverable archive |
| Investigation logs | Retention release plus cloud file identity, size and checksum matching local bundle | Remove only verified local originals; evict synced cache without deleting cloud files |

Automatic execution needs one general policy choice, such as safe reproducible caches, plus a daily byte limit and free-space target. It must not require a user to label every new cache directory. A policy choice does not waive the user's incomplete-visibility block for raw file/worktree removal.

For every action, save an intent before mutation, bind the preview to exact identities and the operation arguments, revalidate immediately, persist the owner-tool receipt, and measure actual disk change. A change, missing visibility, unsupported tool version or ambiguous result preserves the data. Do not count intended bytes as recovered space.

Mole's current `clean` removes categories broadly and rejects the former `--select`, `--categories` and `--exclude` flags. Its `purge --yes` selects eligible artifacts across configured roots. Neither exposes the exact immutable candidate manifest needed for a surgical unattended executor. Do not wrap either broad command as a BurnZombies burn action. A future upstream integration should add a versioned JSON plan and exact apply-by-plan interface, with identity checks and structured receipts.

## Research and validation

Reviewed upstream `tw93/Mole` commit `45ee88cbb07b325901b80d7db8b1624fa1dceb05` and locally installed Mole 1.65.0. Relevant upstream sources: [JSON analysis and scan status](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/cmd/analyze/json.go), [cleanup flags and preview ledger](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/bin/clean.sh), [project purge](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/bin/purge.sh), and [license](https://github.com/tw93/Mole/blob/45ee88cbb07b325901b80d7db8b1624fa1dceb05/LICENSE).

Proof covers outside-scope paths, symlinks, protected entries, partial results, cached bounded inspection, and no deletion through the recommendation path. Owner-operation execution above is a proposed follow-up; it is not enabled by this release.
