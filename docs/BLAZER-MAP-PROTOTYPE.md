# Blazer Map prototype

Compare three views of the same read-only snapshot. The design question: which view makes the biggest disk costs and the most important agent activity easiest to find?

```sh
swift run burnzombies map --demo --open
swift run burnzombies map --open
```

The first command uses sample data and makes no local scan. The second reads local volume and agent diagnostics from BurnCore and supplements them with the observer's saved worktree, cache and folder inventory. It does not require a running observer, start a scan in the app, or request cleanup. Without saved inventory, some layers can be empty. Run the command again to refresh.

Omit `--open` to print a private temporary HTML path without opening a window. The page is self-contained and makes no network requests. `--json` writes the same snapshot to stdout. Live output can contain paths and diagnostic text; use `--demo` for screenshots or sharing.

Use the bottom switcher or the left and right arrow keys to compare layouts. The URL accepts `?variant=treemap`, `?variant=radar`, or `?variant=ledger`. Search, the layer picker, and selection carry over.

- **Disk Treemap**: Pick the biggest cache or worktree by area, then inspect its path and source. Disk folders are a separate layer because their measurements can contain the candidate paths. Overlapping paths and smaller items stay searchable in the ledger.
- **Activity Radar**: Find a recent zombie signal or an older worktree by its last known activity. Ring position is age, not risk. The ledger includes findings with unknown age and contacts beyond the radar's display limit.
- **Evidence Ledger**: Find an exact path, sort by name, status, last activity or size, and check for held or partial evidence. Disk and RAM are kept in separate groups when sorting by size.

Try finding the largest cache, spotting the live Loop Zombie, then deciding why `auth-rewrite` needs review. Repeat with a live snapshot and a narrow window. Compare time to answer, mistakes between disk and RAM, and whether the source and observation time are easy to find.

The proposed native shape is a Map entry from the existing Findings window: Treemap first, Ledger one click away. If the radar makes live agent issues faster to spot, add it as a separate activity mode. Keep the snapshot model shared across the CLI and SwiftUI so both use the same definitions. The prototype has no cleanup controls; any future handoff should use the existing worktree or Findings review flow.

Storage estimates are bounded and can overlap or share APFS blocks. They are not estimates of bytes a cleanup would free. Saved inventory is shown with its source and observation time. Protected locations and external volumes are outside this prototype's scan, and zero visible findings does not prove there are none.
