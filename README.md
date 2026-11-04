<p align="center"><img src="Sources/BurnApp/Resources/EmberSkull.png" width="80" alt="BurnZombies"></p>

# BurnZombies

**Keep your agents running. Lose the leftovers — on autopilot.**

Long agent sessions leave a mess: orphaned Node workers, robot browsers, build watchers, project copies nobody opens again and gigabytes of rebuildable junk. BurnZombies watches your whole Mac, burns what is safe, and when it isn't sure it asks you one tiny yes/no question. Every answer becomes a rule. After about a dozen answers it runs itself.

| It burns | How |
| --- | --- |
| 🧟 **Zombies** — programs whose app or chat is gone | A graceful stop. Programs a live chat is using are never touched. |
| 📁 **Old copies** — git worktrees you stopped using | Every commit and change is saved in a restore point first. One click restores it. |
| 🗑️ **Junk folders** — `node_modules`, build output, DerivedData | Deleted; your tools rebuild them when needed. |

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-242420?logo=apple&logoColor=white)](#install)
[![MCP ready](https://img.shields.io/badge/MCP-ready-ff541f)](docs/MCP.md)
[![MIT](https://img.shields.io/badge/license-MIT-242420)](LICENSE)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

macOS 14+, Apple Silicon or Intel. It puts BurnZombies.app in `~/Applications` and starts it in the menu bar: look for the skull. No account, no API key, no sudo.

**Claude Code or Codex is optional.** With one installed and signed in, BZ uses it to judge new things through your existing login; without one, BZ still cleans with its own rules and your answers ([add AI later](docs/INSTALL.md#with-or-without-claude-code-or-codex)).

Options: `curl … | bash -s -- --observe-only` installs with AI judging off; `--no-open` installs without starting the app.

**Installing with an agent?** Give Claude Code or Codex this prompt:

> Install and set up BurnZombies using https://raw.githubusercontent.com/swordfish444/BurnZombies/main/llms.txt. Preserve my existing agent settings and verify setup without running cleanup.

## What happens next

- **The first minute.** BZ takes its first look right away and keeps looking every minute for its first half hour. Within about a minute the panel shows how much it found, like **Found 4.2 GB of leftovers**, and **BZ has 3 quick questions** when there's something to decide.
- **It burns the safe stuff on its own** from the first minute, with starter rules you can switch off in **Settings → Autopilot**:
  - programs whose app or chat is gone, idle for 6+ hours, with no open port. A program that has barely used the CPU since it started counts as idle from its start, so old leftovers go right away;
  - old project copies already merged, unchanged and untouched for a month. They are always backed up first;
  - rebuildable folders (`node_modules`, build output) inside copies untouched for two weeks.
- **It asks about the rest.** One tap: **Yes** burns all the matches, now and later; **No** keeps them. BZ never asks about or touches macOS, your apps, anything a running chat is working in, or your main project folders.
- **AI sweeps** (with Claude Code or Codex). The first starts about 10 minutes after install, once the first look is complete. After that, one runs when there is something new to judge, at most every 30 minutes, and rechecks every 4 hours. A sweep takes a few minutes, 15 at most. The AI may also burn clearly safe things on its own: an orphaned program with no open port, a known junk folder, or a copy nothing uses that wasn't made by Codex, Claude or Conductor.
- **Undo.** Restore an old copy from **Findings** for 30 days. Junk folders get rebuilt by your tools. Programs get a graceful stop, which can't be undone.

**Cost:** Claude Code uses Sonnet by default; Codex uses its own default. On API pricing a sweep costs roughly $0.30–$1.20; on a Claude or ChatGPT subscription it uses plan usage instead. Change the model in **Settings → Review intelligence**, turn the AI off with `burnzombies setup --observe-only` (back on with `--with-ai`), and see what sweeps cost in **Settings → Usage & estimated cost**.

**Uninstall:** stop BZ, then delete the app and its data folder. [Three steps →](docs/INSTALL.md#uninstall)

### Optional: Full Disk Access

BZ works without it everywhere except the places macOS protects (Desktop, Documents, Downloads, iCloud Drive, Mail, Messages, Photos, other apps' data and external drives), and it tells you what it skipped. To cover those too, click **Allow Full Disk Access** in the menu-bar banner, enable **BurnZombies** in System Settings, then come back; BZ checks access by itself. AI sweeps run either way. Dismiss the banner with **×** whenever you like; setup stays under the **Settings cog → Full Disk Access**. [Access setup →](docs/INSTALL.md#optional-full-disk-access)

<details>
<summary>See the permission setup</summary>

<p align="center"><img src="docs/media/full-disk-access-banner.png" width="360" alt="Compact BurnZombies menu with a Full Disk Access link and a separate dismiss button."></p>
<p align="center"><img src="docs/media/full-disk-access-complete.png" width="440" alt="Full Disk Access completed in Settings: muted section, green checkmark and Manage access link."></p>

</details>

## Teach BZ in a dozen taps

When BZ isn't sure, the menu shows **BZ has 3 quick questions**. Each one is a single card — **Burn 92 old project copies?** **Frees 14.4 GB**, with a few short facts like "Saved on GitHub" and "Unused for a week" (risky ones in amber) — and **Yes, burn them** / **No, keep them**. BZ only asks about things that free at least 1 GB. **Findings** shows everything in plain words: what it is, why BZ thinks so, and what happens if it burns it, with technical details tucked away. **Settings → Autopilot → What BZ has learned** lists every rule with a Forget button.

## Dead weight. Gone.

Everything that matters in one small panel: **zombies burned, memory released, disk reclaimed, worktrees cleaned and agent boost.** Every verified burn shows what you got back: memory released and programs cleared, or a measured speed boost when available. **Still warming up.** only appears before your first burn.

<p align="center">
  <img src="docs/media/menu-bar-empty.png" width="360" alt="BurnZombies before the first cleanup: compact menu, zero counters, Still warming up, and Ready for your first burn.">
  <img src="docs/media/menu-bar.png" width="360" alt="BurnZombies compact menu after cleanups: four counters in a compact two-by-two grid, smaller units, reclaimed memory and helpers cleared, memory pressure and links to Impact and Burn Log.">
</p>

**Small by default. More when you need it.** Switch the panel between Today, 7 days and All time, or open Impact for the bigger view. Burn Log keeps a record of every burn one click away.

### Hunt Zombies

Want to clear the buildup now? Click **Hunt Zombies** in the menu bar to start an AI sweep right away. **Hunting Zombies →** opens the live hunt: a side-scrolling patrol, suspicious figures under the scanner, and a flamethrower send-off when a burn is verified. The activity log below the scene lists what BZ found, burned and freed. Automatic sweeps never open a window or interrupt your screen.

<p align="center">
  <img src="docs/media/hunt-zombies.png" width="948" alt="Hunt Zombies with a side-scrolling night patrol, a figure under the scanner, cleanup counters and the activity feed.">
</p>

<details>
<summary><strong>See the full Impact view</strong></summary>

<p align="center">
  <img src="docs/media/impact.png" width="1008" alt="BurnZombies Impact view with TAME THE HORDE, the ember mascot, memory, disk and worktree counters, a compact agent boost card and period filters.">
</p>

</details>

- **Your whole Mac.** Every program your macOS user runs, across projects and sessions, not just the current chat's.
- **Works with no chat open.** BZ runs from the menu bar on its own. Your chats get no hooks, reminders or extra tools.
- **Keep the good stuff alive.** Exact identity checks, graceful stops and verified receipts. Anything uncertain keeps running.
- **The AI judges; BZ checks.** Claude Code or Codex can read project files to understand what something is. BZ re-checks every burn against its safety rails. No fixed “old program = zombie” rule. [How Autopilot decides →](docs/AUTOPILOT.md)
- **Old copies, in view.** Click **Worktrees cleaned** to see every copy BZ found, with its owner and unsaved work. [Worktree cleanup →](docs/WORKTREE-CLEANUP.md)
- **Find the big pockets.** **Settings → Disk cleanup** maps storage across your Mac, including folders outside your projects. Scanning uses no AI. [Disk discovery & cleanup →](docs/DISK-CLEANUP.md) · [Mole integration →](docs/MOLE-INTEGRATION.md)
- **See the payoff.** Zombies burned, memory released, disk reclaimed and worktrees cleaned in a quiet menu bar app.
- **Spends AI only on new things.** Looking around uses no AI. If a sweep fails, BZ waits longer each time (15 → 30 → 60 → 120 minutes) instead of hammering your plan, and your rules keep working meanwhile.

**Next:** more real-session validation, notarized Mac releases, and Windows. [Roadmap →](docs/ROADMAP.md)

[Install & uninstall](docs/INSTALL.md) · [User guide](docs/USER_GUIDE.md) · [Autopilot](docs/AUTOPILOT.md) · [MCP](docs/MCP.md) · [How cleanup works](docs/SAFETY.md) · [Build & contribute](CONTRIBUTING.md) · [Security](SECURITY.md)

If BurnZombies clears room for your next run, **give it a star**. [Tell us what your agents leave behind](https://github.com/swordfish444/BurnZombies/issues/new?template=feedback.yml).

**You build. We burn.**
