---
name: burnzombies-setup
description: Safely audit a Mac for AI coding-agent bloat (orphaned processes, stale Git worktrees, rebuildable caches) and optionally install BurnZombies in look-only preview mode without touching global agent configs or hooks.
---

# BurnZombies Safe Audit & Setup

Use this skill when a user wants to check whether their Mac has AI coding-agent leftovers (orphaned Playwright browsers, Node workers, stale Git worktrees, `node_modules`, DerivedData, Gradle/AI scratch) or wants to install BurnZombies safely.

## Rules

- **Never** run the legacy `burnzombies install` or `burnzombies install-skill` commands (they modify global harness configs).
- **Never** start a burn, answer a Teach BZ question, or turn off `--look-only` on the user's behalf.
- **Always** check whether the user runs persistent worktree pools or wants `--look-only --observe-only --no-login-item` first.

## 1. Measure First (Zero-Persistence Read-Only Audit)

If BurnZombies is already installed:

```sh
bz="${BURNZOMBIES_CLI:-$HOME/Applications/BurnZombies.app/Contents/MacOS/burnzombies}"
[[ -x "$bz" ]] || bz="/Applications/BurnZombies.app/Contents/MacOS/burnzombies"
"$bz" audit
```

Report free disk, orphaned processes/robot browsers, worktree counts by placement (`agent`, `pool`, `sibling`, `locked`), and reclaimable caches before recommending installation.

## 2. Safe Look-Only Install (Zero Burns, Zero AI Spend, Optional No Login Item)

Preferred via Homebrew Cask:

```sh
brew install --cask swordfish444/tap/burnzombies
burnzombies setup --look-only --observe-only --no-login-item
```

Or via version-pinned installer (download, inspect, then execute):

```sh
installer="$(mktemp -t burnzombies-installer)"
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/v0.21.0/install.sh -o "$installer"
bash "$installer" --look-only --observe-only --no-login-item
rm "$installer"
```

## 3. Fence Off Protected Worktrees & Directories

- Git-native hard rail (protects both the worktree AND its `node_modules`/build folders):
  ```sh
  git -C /path/to/worktree worktree lock --reason "keep slot" /path/to/worktree
  ```
- Folder fence via CLI:
  ```sh
  burnzombies autopilot never-touch add ~/Code
  ```
- Verify setup (read-only):
  ```sh
  burnzombies doctor
  burnzombies autopilot
  ```
