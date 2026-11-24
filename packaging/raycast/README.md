# BurnZombies for Raycast

Control [BurnZombies](https://github.com/swordfish444/BurnZombies) directly from Raycast:

- **Audit Agent Leftovers** — fast read-only scan of orphaned processes, worktrees, and build caches (`burnzombies audit`).
- **Autopilot Status** — live counts, open questions, Look-Only state, and backup retention.
- **Hunt Zombies Now** — trigger an immediate sweep.
- **Toggle Look-Only Mode** — pause or resume automatic burns.

## Install BurnZombies

```sh
brew install --cask swordfish444/tap/burnzombies
```

## Submitting to the Raycast Store

Copy `packaging/raycast` (plus `packaging/artwork/AppIcon.png` as `assets/icon.png`) into a branch of `raycast/extensions` under `extensions/burnzombies`, run `npm install && npm run build && npm run lint`, and open a PR.
