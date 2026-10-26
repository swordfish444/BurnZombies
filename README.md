<p align="center"><img src="Sources/BurnApp/Resources/EmberSkull.png" width="80" alt="BurnZombies"></p>

# BurnZombies

**Keep your agents running. Lose the leftovers.**

Long sessions leave a mess: abandoned Node workers, forgotten browser helpers, cancelled jobs that never quite died. Eventually your Mac pays for work that already ended.

BurnZombies watches your whole Mac—across projects, terminals, agents and old sessions. **Your existing harness supplies the intelligence. BurnZombies runs quietly in the background, cleans up confirmed leftovers and shows what you got back.** No active chat. No reboot.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-242420?logo=apple&logoColor=white)](#install)
[![MCP ready](https://img.shields.io/badge/MCP-ready-ff541f)](docs/MCP.md)
[![MIT](https://img.shields.io/badge/license-MIT-242420)](LICENSE)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

Apple Silicon or Intel, macOS 14+. The installer selects an available **Codex, Claude Code, Cursor CLI, GitHub Copilot CLI or Gemini CLI** starts the menu bar observer, and connects the MCP tools and portable lifecycle skill. Use your existing harness login. No BurnZombies account, API key or package manager.

Your working agent remembers which helpers it still needs and releases them when the job is done. BurnZombies keeps that evidence between chats and uses it in bounded background reviews. The observer continues across projects, even with no chat open. [Setup details →](docs/INSTALL.md)

Want to choose the brain? **Settings → Review intelligence** lets you set the model and thinking level for background reviews.

Installing through an agent? Tell it:

> **Install BurnZombies to watch this Mac and clean up abandoned agent helpers in the background.**

## Dead weight. Gone.

Everything that matters in one small panel: **zombies burned, memory released, CPU time saved and agent speed.** Before your first cleanup, the counters stay at zero and the speed card shows **Still warming up.**

<p align="center">
  <img src="docs/media/menu-bar-empty.png" width="360" alt="BurnZombies before the first cleanup: compact menu, zero counters, Still warming up, and Ready for your first burn.">
  <img src="docs/media/menu-bar.png" width="360" alt="BurnZombies compact menu after cleanups: three counters in one row, smaller units, agent speed, memory pressure and links to Impact and Burn Log.">
</p>

**Small by default. More when you need it.** Open Impact for Today, 7 days or All time. Burn Log keeps the cleanup receipts one click away.

<details>
<summary><strong>See the full Impact view</strong></summary>

<p align="center">
  <img src="docs/media/impact.png" width="1008" alt="BurnZombies Impact view with TAME THE HORDE, the ember mascot, memory and CPU-time counters, a compact speed card and period filters.">
</p>

</details>

- **Your whole Mac.** All visible processes owned by your macOS user, across projects and sessions—not just the current agent's children.
- **Works with no chat open.** The resident observer schedules reviews. No tool-use hooks or conversation reminders.
- **Remembers what finished.** Agents record helper ownership and observed completion. Active consumers keep their helpers; released work gets reviewed first.
- **Your harness does the thinking.** Model reasoning and live ownership evidence decide what is abandoned. No fixed “old process = zombie” rule.
- **Keep the good stuff alive.** Exact identities, protected harnesses, graceful stops and verified receipts. Uncertain work stays running.
- **See the payoff.** Zombies burned, memory released, CPU time saved and agent speed in a quiet menu bar app.
- **Stays out of your way.** No windows opening when reviews start. One bounded reviewer, with cooldowns and a pause on failure.

Native code observes, schedules and verifies. Your selected harness supplies the model and uses MCP for guarded cleanup. Reviews use its existing account and usage allowance. [How it works →](docs/MCP.md) · [Lifecycle evidence →](docs/LIFECYCLE-EVIDENCE.md)

**Next:** more real-session validation, notarized Mac releases, and Windows. [Roadmap →](docs/ROADMAP.md)

[User guide](docs/USER_GUIDE.md) · [MCP](docs/MCP.md) · [How cleanup works](docs/SAFETY.md) · [Build & contribute](CONTRIBUTING.md) · [Security](SECURITY.md)

If BurnZombies clears room for your next run, **give it a star**. [Tell us what your agents leave behind](https://github.com/swordfish444/BurnZombies/issues/new?template=feedback.yml).

**You build. We burn.**
