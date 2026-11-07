# Tame the horde

[Install once](INSTALL.md). BurnZombies then runs from the menu bar on its own: it finds leftovers across your whole Mac, burns what is safe and asks you about the rest. No chat needs to be open, and your chats do no extra work.

## Autopilot and Teach BZ

BZ looks right away, every minute for its first half hour, then every 15 minutes. It burns programs, old project copies and junk folders it is sure about; its safe starter rules work from the first minute. Installed with `--look-only`, it finds and asks the same way but burns nothing until you choose **Start burning** in the menu. When it isn't sure, the menu shows **BZ has N quick questions**, and **Teach BZ** shows one card at a time with **Yes, burn them** / **No, keep them**. Yes burns all the matches now and later; No keeps them. Every answer becomes a rule. **View details** on a card lists everything it covers, with filters, a card with everything BZ knows when you rest the pointer on a row, and a page per thing you can flip through with the arrow keys; **Spare** takes one out of the fire for good (**Unspare** gives it back), and the card's count and size follow. Tips come and go in the corner above the question. **Findings** lists everything in plain words with **Burn now**, **Keep forever** and **Restore**. The switch in the menu, or **Off** in **Settings**, turns Autopilot off. **Settings** has one choice, **How much can BZ do on its own?**: Off, Look only, Ask first or Act when sure. **Burns without asking** lists your lessons and the starter rules, each with a switch, and has **Start training over**. [How Autopilot decides](AUTOPILOT.md).

## Your whole Mac

BZ watches every program your macOS user runs, across every project, terminal, agent and old session. It isn't tied to one chat or folder, and closing your chats doesn't stop it. It never asks about or touches macOS, your apps, anything a running chat is working in, or your main project folders.

## Menu bar and impact

Click the skull in the menu bar. Autopilot is on from the start; the small switch beside **Autopilot on** turns it off and back on. The **Today**, **7 days** and **All time** tabs switch its four totals. **Impact** opens the bigger view, **Findings** shows what BZ found and burned, and **Burn Log** lists the programs it stopped, newest first, with the day (old copies and junk folders are under **Findings → Burned**). The gear opens **Settings**. **Hunt Zombies** starts an AI sweep now; while it runs, **Hunting Zombies →** opens the live hunt scene and activity log. No restart or special setup needed.

## AI sweeps

With Claude Code or Codex signed in, BZ asks it to judge new things in short AI sweeps that run in the background. Looking around between sweeps uses no AI. Without either, BZ still burns what its starter rules and your answers cover; [add AI later](INSTALL.md#with-or-without-claude-code-or-codex).

- **When.** The first starts about 10 minutes after install, once the first look is complete. After that, one runs when there is something new to judge, at most every 30 minutes, and rechecks every 4 hours. **Hunt Zombies** starts one right away. One runs at a time.
- **How long.** A few minutes, capped at 15. A sweep that runs out of time after judging some things counts as done; the next picks up the rest.
- **What it can do.** Read project files to understand what something is, record what it thinks, burn and ask you questions. It has no shell, and BZ re-checks every burn.
- **What it may burn on its own.** Only when it is at least 85% sure, and only an orphaned program with no open port, a known junk folder, or a copy nothing uses that wasn't made by Codex, Claude or Conductor. Everything else needs your yes.
- **If it fails.** BZ waits 15, 30, 60, then 120 minutes before trying again (at least an hour after a login or usage-limit problem). It never stops for good and never switches tools or accounts. Your rules keep working meanwhile.
- **Model and cost.** Claude Code uses Sonnet by default; Codex uses its own default. Change it with **How smart** in **Settings**: Quick, Smart or Smartest. On API pricing a sweep costs roughly $0.30–$1.20; on a Claude or ChatGPT subscription it uses plan usage instead. **Settings → Used this week** shows what it would cost if you paid per use: today, this week and this month. Unknown prices stay unknown, never guessed.

Scheduled sweeps never open a window or take focus, and closing the hunt window doesn't stop one. To turn the AI off, choose **Which AI → Off** in **Settings**, or run `~/Applications/BurnZombies.app/Contents/MacOS/burnzombies setup --observe-only`; `--with-ai` turns it back on. The Autopilot switch in the menu, or **Off** in **Settings**, pauses all of Autopilot: it still looks and asks, but burns nothing on its own and runs no scheduled AI sweeps.

## Undo

- **Old copies:** **Restore** in **Findings** for 30 days. Before burning a copy, BZ saves every commit and local change as a restore point inside its repository (`refs/burnzombies/retired/…`). Ignored files over 5 MB, anything in rebuildable folders like `node_modules`, and browser profiles that test runs leave behind, ignored or not, aren't saved. A copy with more than 512 MB of other unsaved files waits for your answer to a card that names those big files. A Yes deletes them for good, and Restore brings the copy back without them.
- **Junk folders:** your tools rebuild them when needed.
- **Programs:** a graceful stop (SIGTERM), which can't be undone. If something needs the program again, it starts a fresh one.

## What the numbers mean

The main views show zombies burned, memory released, disk reclaimed and worktrees cleaned. Only verified exits count as burned programs and released memory. Old copies and junk folders count once they are really gone, and a restore takes its share back out. Click **Worktrees cleaned** to see every copy BZ found, with its owner and unsaved work. [Worktree safety and recovery](WORKTREE-CLEANUP.md).

CPU time saved, in the impact details, counts the CPU a program was using before it stopped, over the time your Mac stayed awake afterward, up to 24 hours per burn. Sleep, restarts and programs that come back add nothing. Agent speed stays neutral when timing samples are noisy, unchanged or slower. Anything pending or uncertain gets no credit.

The Burn Log shows why each program was judged a leftover. A true OS zombie has already exited and must be reaped by its parent; killing it can't free memory.

## Privacy and uninstall

Private state lives in `~/Library/Application Support/BurnZombies`: bounded program identities, executable and folder paths, counters, receipts and the most recent AI sweep output (at most 1 MiB). BZ doesn't collect command arguments, environment variables or credentials. What an AI sweep sees can reach Claude Code's or Codex's model provider; its instructions tell it never to read secrets such as `.env` files, keys or credentials.

To uninstall, follow [the three steps](INSTALL.md#uninstall). Default setup adds no chat hooks and changes no Claude Code or Codex settings, so there's nothing else to clean up. If you once used the optional chat integration, remove only BurnZombies' entries through your tool's own settings.

## Never touches

**Settings → Never touches** is one list of what BZ leaves alone, no matter what: folders and apps you add, anything you chose **Keep forever** or **Spare** for, and your **No** answers. Anything inside a listed folder stays, and so does an old copy that holds one. Rules, the AI and **Burn now** all stop here.

To protect a program, choose **Keep forever** on it in **Findings**. That covers its later runs too, until you take it off this list.

The old **Disk cleanup** section is gone. Autopilot does the cleaning, and what you protected there moved onto this list. [What it was](DISK-CLEANUP.md).

## Advanced findings

You don't need this to get started. **Findings → Advanced findings…** opens BZ's older, step-by-step review. Each item shows why it was found, what blocks it, its exact scope and how to recover it. Things BZ can't handle stay visible; BZ never claims something is abandoned just because it is idle or old.

**Approve once** rechecks the current evidence before acting. Copies use a separate **Manage, preserve and retire** sheet, which adopts that exact copy and saves its ignored and local files in an independently verified, encrypted backup first. It can't override a copy someone is using or one BZ couldn't fully check. **Keep** protects that item everywhere until you clear it; **Tomorrow** only changes when you're reminded.

**Gradle build daemons** report their own state. An exact idle daemon is retired through Gradle itself, which finishes any build that races the request before exiting, and BZ verifies the exit before counting the memory. Supported Gradle versions: exactly 8.14.6 and 9.8.2.

Notifications start as a private digest. You choose 1–5 a day (3 by default), with at least an hour between them. Details are off by default; only recognized Gradle daemons offer a stop button in the notification. Ignoring or dismissing a notification approves nothing.

For a repeated Gradle workflow, **Review recurring rule…** shows exactly what it covers, current matches, what blocks them and past decisions. **Shadow only** shows what would match without cleaning anything. An enabled rule has a daily limit and an expiry, starts with a single test item (its "canary") that must be verified, and still needs the AI's agreement plus BZ's own current checks every time. Pausing stops future cleanups but can't cancel one already started. **I needed this — pause its workflow**, or restoring something, pauses that workflow. **Forget workflow preferences** also pauses its automation; recovery records remain.
