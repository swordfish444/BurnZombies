# Blazer Map prototype

Compare three views of the same read-only snapshot. The design question: which view makes the biggest disk costs and the most important agent activity easiest to find?

```sh
swift run burnzombies map --demo --open
swift run burnzombies map --open
```

The first command uses sample data and makes no local scan. The second reads local volume and agent diagnostics from BurnCore and supplements them with the observer's saved worktree, cache and folder inventory. It does not require a running observer, start a scan in the app, or request cleanup. Without saved inventory, some layers can be empty. Run the command again to refresh.

Omit `--open` to print a private temporary HTML path without opening a window. The page is self-contained and makes no network requests. `--json` writes the same snapshot to stdout. Live output can contain paths and diagnostic text; use `--demo` for screenshots or sharing.

Use the bottom switcher or the left and right arrow keys to compare the maps. Open the Evidence Ledger from any map to see and sort the full results. The URL accepts `?variant=treemap` for Burn Pit, `?variant=radar`, `?variant=graveyard`, or `?variant=ledger`. Search and layer filters carry over.

- **Burn Pit** shows the largest disk estimates as slabs in a furnace. Pick a slab for its path and evidence. Use the Disk folders layer for directory measurements.
- **Activity Radar** puts recent activity near the center. The rings show time since last activity. Pick a contact for its status and source.
- **Graveyard** groups worktrees and zombie signals into plots by last activity. The counts include all matching findings in each plot. Choose a marker to inspect it, or open Evidence Ledger to see the full set.

Try finding the largest cache in Burn Pit, spotting the live Loop Zombie on Activity Radar, then finding a worktree with an unknown age in Graveyard. Repeat with a live snapshot and a narrow window.

The native option is a Map entry from Findings. Keep the snapshot model shared across the CLI and SwiftUI so both use the same definitions. Use the existing worktree or Findings review flow for any future cleanup handoff.

Storage estimates are bounded and can overlap or share APFS blocks. They are not estimates of bytes a cleanup would free. Saved inventory is shown with its source and observation time. Protected locations and external volumes are outside this prototype's scan, and zero visible findings does not prove there are none.
