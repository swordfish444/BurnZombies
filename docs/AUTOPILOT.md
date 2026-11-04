# Autopilot

BurnZombies cleans up on its own. It looks for three kinds of leftovers right away, then every minute for its first half hour and every 15 minutes after that. It burns the ones it is sure about and asks you a tiny yes/no question when it isn't. Each answer teaches it a rule. After about a dozen answers it handles nearly everything without you.

| Leftover | What it is | What "burn" does |
| --- | --- | --- |
| **Zombies** | Programs whose app or chat is gone: test runners, build watchers, robot browsers, dev servers from finished chats. | A graceful stop (SIGTERM) for the program and everything it started. Never a force-kill. |
| **Old copies** | Git worktrees you or your agents made and stopped using. | Every commit and local change is saved in a restore point inside the repository, then the folder is removed. **Restore** puts it back. |
| **Junk folders** | Rebuildable output: `node_modules`, build folders, Xcode DerivedData, tool caches. | The folder is deleted. Your tools rebuild it when needed. |

## How it decides

Only things worth it are looked at: anything freeing at least 100 MB of disk or memory, or a program keeping a CPU core at least a quarter busy. Smaller things are not shown, asked about, judged or burned. Old copies that haven't been measured yet are sized a little at each look before they count.

Each item gets a few plain facts ("orphaned: yes", "saved: merged", "folder: node_modules"). Then, in order:

1. **Protected** — never touched, never asked about: macOS, your apps, your AI tools, BurnZombies itself, anything a running chat is working in, your main project folders, copies something is using right now.
2. **Your keeps win.** "Keep forever" on an item, a "No, keep them" answer, or a confident AI "keep" always blocks burning.
3. **Your yes answers** burn every matching item, now and later.
4. **Starter rules** burn the obvious from the first minute. Switch each off in **Settings → Autopilot**:
   - programs whose app or chat is gone, idle for 6+ hours, with no open port. A program that has barely used the CPU since it started counts as idle from its start, so old leftovers go right away;
   - old copies already merged, unchanged and untouched for a month (not ones made by Codex, Claude or Conductor). They are always backed up first;
   - rebuildable folders (`node_modules`, build output, Xcode build folders) inside copies untouched for two weeks.
5. **The AI** may burn on its own only when it is at least 85% sure *and* the item is low-risk: an orphaned program with no open port, a known junk folder, or a copy nothing uses that wasn't made by Codex, Claude or Conductor.
6. Everything else is **unsure** and becomes a question.

Copies made by Codex, Claude or Conductor are checked like any other copy, so your yes answers cover them too; the starter rules and the AI never burn them on their own. A copy whose files BurnZombies could not finish reading gets no age, so no rule about how long things sat unused matches it. Clearing a junk folder inside a copy doesn't count as using the copy.

## Full Disk Access

Optional. Without it, Autopilot handles all three kinds of leftovers everywhere except the places macOS protects: Desktop, Documents, Downloads, iCloud Drive and other cloud drives, Mail, Messages, Photos, other apps' data, and removable and network drives. It never looks inside them, so macOS never asks for access, and it never counts them as empty: copies there are not sized, judged, asked about or burned, and its coverage note says so plainly:

> Full Disk Access is off, so I skip the places macOS protects: Desktop, Documents, Downloads, iCloud Drive, Mail, Messages, Photos, other apps' data and external drives. 1 old copy is in Documents. Turn on Full Disk Access to cover them too. Everything else is covered.

Turn it on and the next inventory refresh brings those places in. Leftover programs are handled either way, and AI sweeps run either way. [Access setup →](INSTALL.md#optional-full-disk-access)

## Training

BurnZombies asks one question per subject: old project copies, each kind of program (Node, Java, …) and each kind of folder (node_modules, tool caches, …). A question covers everything in its subject that sat unused at least as long as its most recent member, so one answer can settle the whole subject; what makes some of them riskier is counted on the card instead of becoming more questions. After a No, the next question is about the older ones only. It must free at least 1 GB to be asked; the biggest subjects come first, at most three at a time, one big card at a time:

> **Burn 92 old project copies?**
> **Frees 14.4 GB** · `Unused for a week` `⚠ 12 have work only on this Mac`
> Each one is backed up first, so you can undo it. — *Yes, burn them* · *No, keep them* · *Not sure — skip*

Facts that make burning riskier (work only on this Mac, unsaved changes, still running a server, used since yesterday) show in amber. The header shows where you are in the current round of questions, never a percentage.

The AI's questions follow the same rules: it may reword or replace the open question about a subject but never adds a second one, waits a day after you skip one, and never asks about things used today.

Yes and No become rules immediately, and Yes starts burning the matches right away. Skip hides the question for a day. **Settings → Autopilot → What BZ has learned** lists every rule in plain English with a Forget button; **Start training over** clears them.

## The AI sweep

Native code catalogs and applies rules without any model. With Claude Code or Codex signed in, BurnZombies also runs short AI sweeps in the background. Only Claude Code and Codex run sweeps.

- **When.** The first starts about 10 minutes after install, once the first look is complete. After that, a sweep runs when there is something new to judge, at most every 30 minutes, and rechecks every 4 hours. **Hunt Zombies** in the menu bar, or **Sweep now** in **Settings → Autopilot**, starts one right away.
- **What it uses.** Claude Code uses Sonnet by default; Codex uses its own default. Change it in **Settings → Review intelligence**.
- **What it can do.** Six tools (catalog, inspect, decide, burn, ask, report), plus reading project files to understand what something is. It has no shell, and the app re-checks every burn.
- **How long.** A few minutes, capped at 15. A sweep that runs out of time after judging things counts as done, and the next picks up the rest.
- **Failures** back off 15 → 30 → 60 → 120 minutes (at least an hour after a login or usage-limit problem). The loop never stops for good, and your rules keep working while the AI is unavailable.
- **Cost.** Roughly $0.30–$1.20 a sweep on API pricing; on a Claude or ChatGPT subscription it uses plan usage instead. **Settings → Usage & estimated cost** shows what sweeps used.

Without Claude Code or Codex, or after installing with `--observe-only`, BurnZombies still burns what the starter rules and your answers cover. **Settings → Autopilot** turns Autopilot, AI included, off.

## Undo

- **Old copies:** **Restore** in **Findings** for 30 days. The restore point lives in the repository as `refs/burnzombies/retired/…` and holds every commit and local change. Ignored files over 5 MB, and anything inside rebuildable folders, aren't saved.
- **Junk folders:** your tools rebuild them.
- **Programs:** a graceful stop, which can't be undone.

Uninstalling leaves restore points in place; [Uninstall](INSTALL.md#uninstall) shows how to delete them.

## Safety rails that never change

- Exact identity check (boot, PID, start time, path) immediately before every signal; SIGTERM only.
- Old copies are only removed after their restore point verifies; submodules with unsaved work, locked copies and in-progress merges/rebases are refused.
- Junk folders must be a known rebuildable kind, untracked by git, outside private areas (iCloud, Mail, Messages, Photos, `.ssh`, Keychains), and unused by any program.
- Without Full Disk Access, nothing in a place macOS protects is read, sized, judged or burned, and neither is a copy whose project lives in one.
- At most 50 programs, 20 copies and 20 junk folders burned per look.

## Command line

The command isn't on your PATH; call it from the app:

```sh
bz="$HOME/Applications/BurnZombies.app/Contents/MacOS/burnzombies"
"$bz" autopilot              # snapshot: counts, questions, rules
"$bz" autopilot catalog      # items, unsure first
"$bz" autopilot inspect ID   # live detail for one item
"$bz" autopilot sweep        # run an AI sweep now
```
