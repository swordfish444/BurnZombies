<p align="center">
  <picture>
    <source media="(max-width: 600px)" srcset="docs/media/readme-hero-phone.png">
    <img src="docs/media/readme-hero.png" width="900" alt="A Mac menu-bar app for Claude Code, Codex and Cursor. Run your agents forever. Let BurnZombies handle the exhaust: zombie processes, stale worktrees, node_modules and build junk. Beside it, the author's real menu-bar panel after two days of Autopilot: 685.6 GB of disk reclaimed and 453 worktrees cleaned.">
  </picture>
</p>

<h3 align="center">BurnZombies (BZ) cleans up after your AI coding agents, on its own.</h3>

<p align="center">
  It stops the processes they orphan and deletes the worktrees and rebuildable junk they leave behind, backing up every worktree first. On the author's Mac, which had about 1,000 agent worktrees, its first two days freed <b>685.6 GB</b> and cleared <b>453</b> stale ones.
</p>

<p align="center">On your Mac, paste this into Terminal:</p>

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

<p align="center"><sub>macOS 14+ · no account, API key or sudo · free and open source (MIT) · <a href="install.sh">read the script first</a></sub></p>

## How it works

1. **Install it.** One command. A flaming skull joins your menu bar, and within a minute it shows what it found.
2. **Run your agents.** Claude Code, Codex, Cursor: as many sessions, worktrees, dev servers and builds as you like. Nothing about how you work changes.
3. **BZ burns the exhaust.** Every 15 minutes it stops orphaned processes and deletes stale worktrees and rebuildable junk, backing up each worktree first. When it isn't sure, it asks you one yes/no question and remembers your answer.

<p align="center">
  <img src="docs/media/readme-question.jpg" width="480" alt="A Teach BZ question card, with example data: Burn 5 tool caches? Frees 20.3 GB. Unused for a month. Inside your projects. Your tools rebuild them when needed. Yes, burn them or No, keep them.">
  <br><sub>When BZ isn't sure, it asks. One tap, and it remembers. (Example data.)</sub>
</p>

## What happens next

- **Minute one:** BZ shows what it found and asks its first questions. Its starter rules start burning the obvious right away.
- **Around minute 10:** if Claude Code or Codex is signed in, the first AI sweep judges what the rules don't cover. It runs on your own login: roughly $0.30–$1.20 a sweep on API pricing, or plan usage on a subscription.
- **From then on:** BZ looks every 15 minutes, quietly. AI sweeps run only when there's something new to judge, at most every 30 minutes.

## What it burns

- 🧟 **Zombie processes**: Node workers, headless browsers and build watchers left running after their app or chat is gone.<br>
  **Safety net:** a polite `SIGTERM`, sent only after an exact identity check.
- 📁 **Stale worktrees** nothing is using.<br>
  **Safety net:** first, a Git ref inside the repo saves every commit, uncommitted change and untracked file, and BZ verifies it. Restore from **Findings** for 30 days.
- 🗑️ **Rebuildable junk**: `node_modules`, build output, DerivedData.<br>
  **Safety net:** your tools rebuild it when needed.

## Safe by default

- **Hands off what's in use.** BZ never touches macOS, your apps, your AI tools, your main project folders, or any worktree or program something is using. It also reads the session records Claude Code and Codex keep, so even an idle chat's folder stays safe.
- **On its own, only the obvious.** Starter rules take orphaned programs idle for 6+ hours with no open port, merged worktrees with no local changes untouched for a month, and junk inside worktrees untouched for two weeks. Switch any of them off in **Settings → Autopilot**.
- **AI with limits.** Your Claude Code or Codex may burn a low-risk item on its own only when it's at least 85% sure. Worktrees made by Claude Code, Codex or the Conductor app always wait for your yes.
- **You have the last word.** **No** and **Keep forever** always win, and every **Yes** becomes a rule you can forget in **Settings → Autopilot → What BZ has learned**. The [proof suite](Proof) tests these rules on every code change. [How cleanup stays safe →](docs/SAFETY.md)

## FAQ

<details>
<summary><b>Can I keep the AI off?</b></summary>

Yes. Without Claude Code or Codex signed in there's no AI at all; with one, AI sweeps are on by default. Install with `curl … | bash -s -- --observe-only` to keep them off, or run `burnzombies setup --observe-only` later (`--with-ai` turns them back on). **Settings → Usage & estimated cost** shows what sweeps used. [Model and cost →](docs/INSTALL.md#model-and-cost)

</details>

<details>
<summary><b>What does the AI see?</b></summary>

The plain facts BZ gathered about each item, like where it is, its size and what started it, plus any project files it reads in the folders it's judging, such as `package.json`, READMEs and configs. It's told never to read secrets such as `.env` files, keys or credentials. All of it goes through your own Claude Code or Codex login, like any other request you make with it.

</details>

<details>
<summary><b>Can I see what it would burn before it burns anything?</b></summary>

**Findings** lists everything BZ found, why, and what burning it would do. There's no look-only mode yet: the starter rules start in the first minute. Everything they burn is backed up (worktrees), rebuildable (junk) or an orphaned program that sat idle for 6 hours. `--observe-only` turns off only the AI.

</details>

<details>
<summary><b>Can I undo a burn?</b></summary>

Worktrees, yes: **Restore** in **Findings** for 30 days. The restore point is a Git ref in the repo (`refs/burnzombies/retired/…`) that holds every commit and local change. Ignored files over 5 MB and anything inside rebuildable folders aren't kept. Junk folders get rebuilt by your tools. Programs get a graceful stop, which can't be undone.

</details>

<details>
<summary><b>I run long background jobs on purpose. Are they safe?</b></summary>

Click **Keep forever** on one in **Findings**, and BZ and the AI leave it alone. On its own, BZ only stops a program whose app or chat is gone and that has no open port.

</details>

<details>
<summary><b>Does it need Full Disk Access?</b></summary>

No. Without it, BZ skips the places macOS protects (Desktop, Documents, Downloads, iCloud Drive and other apps' data) and tells you what it skipped. With it, the same rules cover those folders too. To grant it, click **Allow Full Disk Access** in the menu. [Access setup →](docs/INSTALL.md#optional-full-disk-access)

</details>

<details>
<summary><b>What does the install script do?</b></summary>

It downloads the release it pins, checks it against that release's SHA-256 checksums, checks the archive's paths and the app's code signature, and puts BurnZombies.app in `~/Applications`. No sudo. Releases are signed with BurnZombies' own certificate but aren't notarized by Apple yet. [Read install.sh](install.sh) · [Installer options →](docs/INSTALL.md#installer-options)

</details>

<details>
<summary><b>Can Claude Code or Codex install it for me?</b></summary>

Yes. Give it this prompt:

> Install and set up BurnZombies using https://raw.githubusercontent.com/swordfish444/BurnZombies/main/llms.txt. Preserve my existing agent settings and verify setup without running cleanup.

</details>

<details>
<summary><b>How do I uninstall?</b></summary>

Stop BZ, then delete the app and its data folder. Restore points stay in your repos until you delete them. [Three steps →](docs/INSTALL.md#uninstall)

</details>

## Learn more

[User guide](docs/USER_GUIDE.md) · [How Autopilot decides](docs/AUTOPILOT.md) · [Safety](docs/SAFETY.md) · [Install options](docs/INSTALL.md) · [MCP](docs/MCP.md) · [Feedback](https://github.com/swordfish444/BurnZombies/issues/new?template=feedback.yml)

<p align="center"><b>You build. We burn.</b></p>
