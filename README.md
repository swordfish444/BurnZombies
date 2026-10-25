<p align="center"><img src="Sources/BurnApp/Resources/EmberSkull.png" width="80" alt="BurnZombies"></p>

# BurnZombies

**Keep your agents running. Lose the leftovers.**

Long sessions leave a mess: abandoned Node workers, forgotten browser helpers, cancelled jobs that never quite died. Eventually your Mac pays for work that already ended.

BurnZombies puts cleanup inside the agent harness you already use. **Your agent figures out what is abandoned. BurnZombies handles guarded stops and shows what you got back.** Keep the session. Skip the reboot.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-242420?logo=apple&logoColor=white)](#install)
[![MCP ready](https://img.shields.io/badge/MCP-ready-ff541f)](docs/MCP.md)
[![MIT](https://img.shields.io/badge/license-MIT-242420)](LICENSE)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

Apple Silicon or Intel, macOS 14+. One command installs the menu bar app, MCP tools, agent skill and a quiet checkpoint for detected **Codex, Claude Code, Cursor, GitHub Copilot CLI and Gemini CLI**. No account, API key, compiler or package manager for BurnZombies.

Tell your agent once:

> **Tame the horde with BurnZombies and keep this session healthy.**

It checks buildup as you work, uses its session context to separate leftovers from live jobs, and cleans up within your permissions. No special launch wrapper. No computer restart. [Harness setup and first-use trust](docs/INSTALL.md).

## Dead weight. Gone.

![BurnZombies verifies a real helper cleanup and updates Impact](docs/media/live-cleanup.gif)

- **Built for long runs.** A quiet checkpoint brings cleanup into the ongoing agent session. Unchanged state adds no chatter.
- **Your harness does the thinking.** The model can inspect ownership, dependencies and current work instead of obeying a fixed “old process = zombie” rule.
- **Keep the good stuff alive.** Exact identities, protected harnesses, graceful stops and verified receipts. Uncertain work stays running.
- **See the payoff.** Zombies burned, memory released, CPU time saved and agent speed in a quiet menu bar app.
- **Stays out of your way.** No startup audits, blocked end-of-turn hooks or windows opening when an agent connects.
- **Safe cleanup, on demand.** Queue a review from the app or ask the agent directly.

The native app observes and verifies. It runs no separate model and makes no autonomous kill decisions. Your existing harness owns reasoning and tool approval. [How it works →](docs/MCP.md)

**Next:** more real-session validation, notarized Mac releases, and Windows. [Roadmap →](docs/ROADMAP.md)

[User guide](docs/USER_GUIDE.md) · [MCP](docs/MCP.md) · [How cleanup works](docs/SAFETY.md) · [Build & contribute](CONTRIBUTING.md) · [Security](SECURITY.md)

If BurnZombies clears room for your next run, **give it a star**. [Tell us what your agents leave behind](https://github.com/swordfish444/BurnZombies/issues/new?template=feedback.yml).

**You build. We burn.**
