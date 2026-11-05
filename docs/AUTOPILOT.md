# Autopilot

BurnZombies cleans up on its own. It looks for three kinds of leftovers right away, then every minute for its first half hour and every 15 minutes after that. It burns the ones it is sure about and asks you a tiny yes/no question when it isn't. Each answer teaches it a lesson. After about a dozen answers it handles nearly everything without you.

| Leftover | What it is | What "burn" does |
| --- | --- | --- |
| **Zombies** | Programs whose app or chat is gone: test runners, build watchers, robot browsers, dev servers from finished chats. | A graceful stop (SIGTERM) for the program and everything it started. Never a force-kill. |
| **Old copies** | Git worktrees you or your agents made and stopped using. | Every commit and local change is saved in a restore point inside the repository, then the folder is removed. **Restore** puts it back. |
| **Junk folders** | Rebuildable output: `node_modules`, build folders, Xcode DerivedData, tool caches. | The folder is deleted. Your tools rebuild it when needed. |

## How it decides

Only things worth it are looked at: anything freeing at least 100 MB of disk or memory, or a program keeping a CPU core at least a quarter busy. Smaller things are not shown, asked about, judged or burned. Old copies that haven't been measured yet are sized a little at each look before they count.

Each item gets a few plain facts ("orphaned: yes", "saved: merged", "folder: node_modules"). Then, in order:

1. **Protected** — never touched, never asked about: macOS, your apps, your AI tools, BurnZombies itself, anything a running chat is working in, your main project folders, copies something is using right now.
2. **Your keeps win.** "Keep forever" on an item, a "No, keep them" answer, an Undo, or a confident AI "keep" always blocks burning.
3. **Your yes answers** burn everything their lesson covers, now and later. So do the calls BZ makes on its own once it has earned your trust ([Act, then tell](#act-then-tell)).
4. **Starter rules** burn the obvious from the first minute (with look-only, once you start burning). Switch each off in **Settings → Autopilot**:
   - programs whose app or chat is gone, idle for 6+ hours, with no open port. A program that has barely used the CPU since it started counts as idle from its start, so old leftovers go right away;
   - old copies already merged, unchanged and untouched for a month (not ones made by Codex, Claude or Conductor). They are always backed up first;
   - rebuildable folders (`node_modules`, build output, Xcode build folders) inside copies untouched for two weeks.
5. **The AI** may burn on its own only when it is at least 85% sure *and* the item is low-risk: an orphaned program with no open port, a known junk folder, or a copy nothing uses that wasn't made by Codex, Claude or Conductor.
6. Everything else is **unsure** and becomes a question.

Copies made by Codex, Claude or Conductor are checked like any other copy, so your yes answers cover them too; the starter rules and the AI never burn them on their own. A copy whose files BurnZombies never finished reading (a hard-linked file, a project inside it or a special file stops that walk) gets its age from a second look instead: the newest of its last commit, Git's index and everything in it except what is inside its junk folders, a few copies at each look. Until then, or when that look can't finish either (a folder it can't open, too many files), it has no age, so no rule about how long things sat unused matches it; the same goes for a copy outside the folders you selected, whose unsaved changes BurnZombies never reads. Junk inside such a copy counts as inside an old copy only once a second look, which skips the junk and Git's own files, finds nothing in the copy changed for two weeks; an old last commit alone never makes a copy old. Clearing a junk folder inside a copy doesn't count as using the copy.

## Look-only

Install with `--look-only`, or switch on **Settings → Autopilot → Look only**, to see what BurnZombies would burn before it burns anything. It finds, sizes, asks and judges exactly as above, but nothing burns on its own: not the starter rules, not your yes answers, not the AI. BZ doesn't act on its own either: a question it is sure of is asked like any other. The menu says **Look-only · nothing burns** and shows how much it would burn; **Findings** says what and why, with *I'd burn N once you start burning* on top.

- Your answers still become lessons, and AI sweeps still run on their usual schedule, at the usual cost. When a sweep asks to burn something, the app holds it without a receipt; its verdicts burn once you start.
- **Start burning** in the menu, or switching **Look only** off, starts burning what waited right away instead of at the next look, within the usual limits per look; the rest follows at the next looks.
- Switching look-only on holds every burn that hasn't started. One already underway, like a copy halfway through its backup, finishes.
- **Burn now** on one item in **Findings** is you deciding, so it still burns that item.
- Reinstalling keeps look-only as it is: `--look-only` turns it on, and only you turn it off.

## Full Disk Access

Optional. Without it, Autopilot handles all three kinds of leftovers everywhere except the places macOS protects: Desktop, Documents, Downloads, iCloud Drive and other cloud drives, Mail, Messages, Photos, other apps' data, and removable and network drives. It never looks inside them, so macOS never asks for access, and it never counts them as empty: copies there are not sized, judged, asked about or burned, and its coverage note says so plainly:

> Full Disk Access is off, so I skip the places macOS protects: Desktop, Documents, Downloads, iCloud Drive, Mail, Messages, Photos, other apps' data and external drives. 1 old copy is in Documents. Turn on Full Disk Access to cover them too. Everything else is covered.

Turn it on and the next inventory refresh brings those places in. Leftover programs are handled either way, and AI sweeps run either way. [Access setup →](INSTALL.md#optional-full-disk-access)

## Training

BurnZombies asks one question per subject: old project copies, each kind of program (Node, Java, …) and each kind of folder (node_modules, tool caches, …). A question covers everything in its subject that sat unused at least as long as its most recent member, so one answer can settle the whole subject; what makes some of them riskier is counted on the card. After a No, the next question is about the older ones only. A Yes covers only the risks its card showed, so leftovers that turn up later with a risk that card didn't show get a question of their own, which names that risk ([Lessons](#lessons)). So does anything else your answers leave undecided, such as a copy with two risks you said yes to on separate cards. It must free at least 1 GB to be asked; the biggest subjects come first, at most three at a time, one big card at a time.

### The question card

The card names the things it is about and when each was last used:

> **Burn 5 copies you used yesterday?**
> **Frees 2.8 GB**
> Their work is on GitHub. Nothing is unsaved.
> **fix login selector** api · yesterday 5 pm
> **add dark mode toggle** web-app · yesterday 1 pm
> **tidy the footer** web-app · yesterday 7 pm
> \+ 2 more
> Each one is backed up first, so you can undo it. — *Yes, burn them* · *No, keep them* · *Not sure — skip*

- **The headline** says how many and when the most recent one was used: "you used yesterday", "untouched since Monday", "untouched for 2 weeks"; for programs, "idle for 3 hours".
- **The rows** name up to three of them, biggest first. A copy shows its task (its chat's title, or its branch in plain words), its project and when a file last changed; a program shows its name, who started it and how long it sat idle; a folder shows which one it is ("node_modules in api") and when it last changed. Then how many more.
- **The line under the size** says what all of them share that is safe, such as "Their work is on GitHub."
- **Facts that make burning riskier** show in amber, counted: work only on this Mac, unsaved changes ("2 have unsaved changes", or "1 has lots of unsaved changes" when there are many), still running a server, and anything BZ couldn't check ("1 couldn't be checked").

The header shows where you are in the current round of questions, never a percentage.

The AI's questions follow the same rules: it may reword or replace the open question about a subject but never adds a second one, waits a day after you skip one, and never asks about things used today.

### Lessons

Yes and No each become a lesson right away, and Yes starts burning what it covers (with look-only, once you start burning). Skip hides the question for a day and teaches nothing; after that it can be asked again, as a new card.

A lesson is about why, not which project: it leaves out the project, where the copy lives and which tool made it, so one answer about one project's copies covers every project's. A Yes also covers things left unused even longer. A No keeps everything as recent as the newest thing on its card, and anything newer; the older things on the card get the next question. A Yes covers only the risks its card showed, as you saw it, even if BZ found more while the card was on screen: when every copy on the card had its work on GitHub and nothing unsaved, a later copy with unsaved work isn't burned under it. That copy gets a question of its own, which names the new risk. A No to that question keeps the copies on that card, as recent as its newest and newer, but not the clean copies your earlier Yes covers: those still go. A lesson that covers another takes it in, so a few lessons hold all your answers.

"Got it!" after an answer shows the lesson in one sentence. **Settings → Autopilot → What BZ has learned** lists them all:

> Copies nobody touched for a week are done once their work is on GitHub and nothing is unsaved.
> From 4 answers · burned 17 copies, 38.6 GB · undone 0

Each has a **Forget** button, which forgets the lesson and the answers behind it so those things can be asked again. **Start training over** forgets everything you taught; the starter rules stay.

### Guessing and trust

Before it asks, BZ guesses your answer from what you said before about the same subject, and each Yes or No you give checks the guess. A subject is all old copies, one kind of program or one kind of folder. BZ trusts itself on a subject once its last 5 guesses there were right; one miss ends that until it gets 5 right in a row again.

### Act, then tell

When BZ is about to ask a question it is sure of, it answers yes itself, burns, and tells you afterwards. It is sure only when all of these hold:

- it has earned trust on the subject;
- you have said yes on that subject before, and yes is what you usually say there;
- every risk on the question (work only on this Mac, unsaved changes, a running server, something it couldn't check) was on a card you said yes to on that subject;
- no keep lesson of yours on that subject touches it.

So it never acts on a subject you haven't answered, on a risk you haven't said yes to, or against a No. What it learns from its own call stays within the risks you approved: a later copy with a risk you never saw isn't burned under it.

It tells you on the first card in **Teach BZ**:

> **Burned 3 copies on my own.**
> **Freed 2.4 GB**
> **migrate billing tables** api · used Oct 26
> **update onboarding copy** web-app · used Oct 24
> **bump build tools** api · used Oct 21
> You'd have said yes: you said yes to 6 like these. — *Good call* · *Undo*

- **Good call** closes it and counts as a right guess.
- **Undo** first turns BZ's lesson into a keep, so nothing more burns under it, then brings back every copy it burned from its restore point. The keep is the one your No to that card would have taught. It counts as your No and as a wrong guess, which ends trust on that subject, so BZ asks before it acts there again. If a copy can't come back, the card stays after the Undo, says how many and why, and closes when you press *OK*.
- **What Undo can't bring back:** stopped programs and deleted folders. Their card says so before you press anything, and its button reads *I'd have said no*. It still turns the lesson into a keep and ends trust.
- A card like this that you don't touch closes after a week.

**Settings → Autopilot → Act on its own when sure** is on by default. Off, BZ asks every question, sure or not, and still checks its guesses. While Autopilot is off or look-only is on, it doesn't act either. If you turn look-only on just after it acted, what it meant to burn waits too, and its card shows once you start burning.

## How I'm doing

Below the lessons in **Settings → Autopilot**, a few plain counts, each shown once it has something to say:

- "I guessed 9 of your last 10 answers right."
- "This week: 3 questions, 6.5 GB burned on my own. Last week: 9 questions, 80.0 GB." Questions are the ones you were shown; what BZ did on its own isn't one. "On my own" is the disk BZ freed without your **Burn now**: lessons, starter rules, the AI and its own calls.
- "You undid 0 of the 29 copies I burned."
- Once you've answered 5 questions: "Replaying your 27 answers, I'd have asked 17 and handled the other 10 on my own the way you would have." The replay goes through your answers in order with the same lessons, guesses and trust BZ uses now. `burnzombies autopilot eval` shows it answer by answer ([Command line](#command-line)).

## The AI sweep

Native code catalogs and applies rules without any model. With Claude Code or Codex signed in, BurnZombies also runs short AI sweeps in the background. Only Claude Code and Codex run sweeps.

- **When.** The first starts about 10 minutes after install, once the first look is complete. After that, a sweep runs when there is something new to judge, at most every 30 minutes, and rechecks every 4 hours. **Hunt Zombies** in the menu bar, or **Sweep now** in **Settings → Autopilot**, starts one right away.
- **What it uses.** Claude Code uses Sonnet at medium thinking by default, whatever your own Claude Code settings say; Codex uses its own default. Change it in **Settings → Review intelligence**.
- **What it can do.** Six tools (catalog, inspect, decide, burn, ask, report), plus reading project files to understand what something is. It has no shell, and the app re-checks every burn.
- **How long.** A few minutes, capped at 15. A sweep that runs out of time after judging things counts as done, and the next picks up the rest.
- **Failures** back off 15 → 30 → 60 → 120 minutes (at least an hour after a login or usage-limit problem). The loop never stops for good, and your rules keep working while the AI is unavailable.
- **Cost.** Roughly $0.30–$1.20 a sweep on API pricing; on a Claude or ChatGPT subscription it uses plan usage instead. **Settings → Usage & estimated cost** shows what sweeps used.

Without Claude Code or Codex, or after installing with `--observe-only`, BurnZombies still burns what the starter rules and your answers cover; to burn nothing until you say so, use [look-only](#look-only). **Settings → Autopilot** turns Autopilot, AI included, off.

## Undo

- **Old copies:** **Restore** in **Findings** for 30 days. The restore point lives in the repository as `refs/burnzombies/retired/…` and holds every commit and local change. Ignored files over 5 MB, and anything inside rebuildable folders, aren't saved.
- **Junk folders:** your tools rebuild them.
- **Programs:** a graceful stop, which can't be undone.
- **What BZ did on its own:** **Undo** on its card in **Teach BZ** brings back the copies it burned and turns its lesson into a keep, so it asks next time. If a copy can't come back, the card says how many and why until you press *OK*. Programs and folders can't come back; their button reads *I'd have said no* and still teaches the keep ([Act, then tell](#act-then-tell)).

Uninstalling leaves restore points in place; [Uninstall](INSTALL.md#uninstall) shows how to delete them.

## Safety rails that never change

- Exact identity check (boot, PID, start time, path) immediately before every signal; SIGTERM only.
- Something the app refused waits 6 hours before it is tried again, unless it or the answer that allows it changes. AI sweeps wait too, so they don't repeat checks the app already refused.
- One burn per item at a time: while a copy is being backed up and removed, a second burn of it, from the AI or from **Burn now**, is turned away.
- Old copies are only removed after their restore point verifies; submodules with unsaved work, locked copies and in-progress merges/rebases are refused.
- Junk folders must be a known rebuildable kind, untracked by git, outside private areas (iCloud, Mail, Messages, Photos, `.ssh`, Keychains), and unused by any program.
- Without Full Disk Access, nothing in a place macOS protects is read, sized, judged or burned, and neither is a copy whose project lives in one.
- At most 50 programs, 20 copies and 20 junk folders burned per look.

## Command line

The command isn't on your PATH; call it from the app:

```sh
bz="$HOME/Applications/BurnZombies.app/Contents/MacOS/burnzombies"
"$bz" autopilot              # snapshot: counts, questions, lessons, how it's doing, rules
"$bz" autopilot catalog      # items, unsure first
"$bz" autopilot inspect ID   # live detail for one item
"$bz" autopilot sweep        # run an AI sweep now
"$bz" autopilot look-only    # hold every burn until you choose Start burning
"$bz" autopilot eval         # replay your answers: a line each, then a summary
"$bz" autopilot eval --json  # the same replay as JSON
```

`eval` replays your Yes and No answers in order and says what BZ would have done with each: settled by an earlier lesson, acted on because it was sure, or asked, with its guess and whether it matched. The summary counts each, the guesses it got right, and how much it would have handled without asking:

```
27 answers: 3 settled, 7 acted, 17 asked. Guessed 13 of 14 right. Wrong: 0 settled, 0 acted. Handled 126.6 GB without asking. 17 lessons.
```
