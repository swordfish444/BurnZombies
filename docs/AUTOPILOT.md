# Autopilot

BurnZombies cleans up on its own. Every 15 minutes it looks for three kinds of leftovers, burns the ones it is sure about, and asks you a tiny yes/no question when it isn't. Each answer teaches it a rule. After about a dozen answers it handles nearly everything without you.

| Leftover | What it is | What "burn" does |
| --- | --- | --- |
| **Zombies** | Programs whose app or chat is gone: test runners, build watchers, robot browsers, dev servers from finished chats. | A graceful stop (SIGTERM) for the program and its helpers. Never a force-kill. |
| **Old copies** | Git worktrees you or your agents made and stopped using. | Every commit and local change is saved in a restore point inside the repository, then the folder is removed. **Restore** puts it back. |
| **Junk folders** | Rebuildable output: `node_modules`, build folders, Xcode DerivedData, tool caches. | The folder is deleted. Your tools rebuild it when needed. |

## How it decides

Each item gets a few plain facts ("orphaned: yes", "saved: merged", "folder: node_modules"). Then, in order:

1. **Protected** — never touched, never asked about: macOS, your apps, agent harnesses, BurnZombies itself, anything a running chat is working in, your main project folders, copies something is using right now.
2. **Your keeps win.** "Keep forever" on an item, a "No, keep them" answer, or a confident AI "keep" always blocks burning.
3. **Your yes answers** burn every matching item, now and later.
4. **Starter rules** (switch each off in Settings) burn the obvious: programs orphaned and idle for 6+ hours with no open port; copies already merged, unchanged and untouched for a month; rebuildable folders inside old copies.
5. **The AI** may burn on its own only when it is at least 85% sure *and* the item is low-risk: an orphaned program without an open port, a copy not owned by Codex/Claude/Conductor that nothing uses, or a known junk folder.
6. Everything else is **unsure** and becomes training material.

## Training

BurnZombies groups unsure items into patterns and asks about the biggest one first — at most three questions at a time, one big card at a time:

> **Can I burn old copies of your projects that are already saved on GitHub?**
> I found 212 like this, using 48 GB. — *Yes, burn them* · *No, keep them* · *Not sure — skip*

Yes and No become rules immediately (and burn right away for Yes). Skip hides the question for a day. Settings → **What BZ has learned** lists every rule in plain English with a Forget button; **Start training over** clears them.

## The AI sweep

Native code catalogs and applies rules without any model. When there is something new to judge (or every 4 hours), BurnZombies runs one headless sweep in your harness — Claude Code by default (`sonnet`), Codex also supported — with six tools: catalog, inspect, decide, burn, ask, report. It can read project files to understand what something is, but it has no shell, and every burn is re-checked by the app. A sweep is capped at 15 minutes. Failures back off (15 → 30 → 60 → 120 minutes); the loop never stops for good, and your rules keep working while the AI is unavailable.

## Safety rails that never change

- Exact identity check (boot, PID, start time, path) immediately before every signal; SIGTERM only.
- Old copies are only removed after their restore point verifies; submodules with unsaved work, locked copies and in-progress merges/rebases are refused.
- Junk folders must be a known rebuildable kind, untracked by git, outside private areas (iCloud, Mail, Messages, Photos, `.ssh`, Keychains), and unused by any process.
- At most 50 programs, 20 copies and 20 junk folders per sweep.

## Command line

```sh
burnzombies autopilot              # snapshot: counts, questions, rules
burnzombies autopilot catalog      # items, unsure first
burnzombies autopilot inspect ID   # live detail for one item
burnzombies autopilot sweep        # run an AI sweep now
```
