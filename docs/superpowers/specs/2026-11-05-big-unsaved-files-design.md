# Big unsaved files: ask about them instead of skipping the copy forever

Status: decided with the owner, who chose that a Yes deletes the big files for good, with these conditions:

1. The card names each big file or folder, with where it is, its size, its kind and when it last changed, and says they are deleted for good and that Undo won't bring them back.
2. The risk a Yes approves names the kind of big files its card showed. A new kind gets a card of its own, and BZ acting on its own never deletes a kind the owner hasn't said yes to.
3. Tells and receipts list what was deleted for good, and before Undo is pressed it says it can't bring those files back.

Built on main after build 58.

## Why

Retire backs up every unsaved file of an old copy into the repository's own storage before it removes the folder. More than 512 MB of untracked files would grow the repository instead of freeing the disk, so retire refuses such a copy. Since build 53 it doesn't count browser profiles that test runs leave behind, but other big unsaved files still refuse.

Nothing ever asked about them:

- The refusal became a receipt. Six hours later (`retryRefusalsAfter`) the copy was tried again and refused again, with no end.
- The owner's lessons already covered these copies ("Copies nobody touched since yesterday are done, even with unsaved work"), so the copies never became unsure, and no question could reach them. The AI couldn't ask either, because its question tool takes only unsure items.
- The refusal text once promised a question that never came ("so I'll ask you before touching it").

On the first Mac this held back a copy untouched for a week whose big unsaved folder held 21 throwaway checkouts of the project (914 MB). Next to that folder were four small new scripts.

## Goals

1. A copy skipped for big unsaved files becomes a question built like every other card. The card names the copies and their big unsaved files, and says plainly what a Yes costs.
2. A Yes becomes a lesson carrying a risk fact for that kind of big unsaved files, so later copies like these aren't asked about again.
3. A No keeps those copies, and only those, and the 6-hour retries stop.
4. No text promises a question that may not come.

## Non-goals

Nothing changes in:

- the quiet rule, the 1 GB minimum per question, one open question per subject, or the limit of 3 open questions;
- every other safety rail: the 512 MB cap on what goes into a restore point, browser profiles, ignored files, submodules, locks, programs using a copy, and Full Disk Access;
- the owner's **Burn now**: on a copy with big unsaved files it is still refused, since no card showed the files;
- the AI's authority. The AI may never burn such a copy.

## 1. Retire names the big files

A copy's unsaved files are its untracked, unignored files, leaving out browser profiles. When they come to more than 512 MB, retire picks the big ones:

1. The candidates are folders Git tracks nothing in, and single untracked files elsewhere, of at least 100 MB (`AutopilotPolicy.worthBytes`).
   - Inside a folder Git tracks nothing in, retire takes the deepest folder that holds 100 MB when none of its own folders does. So a folder of checkouts counts as one entry, not 21.
   - A folder that holds files Git tracks is never taken whole, so new source files beside generated output always stay in the backup.
2. Candidates are taken biggest first, only until what is left fits in a restore point. Anything smaller stays in the backup, as before.
3. If that is not enough, the biggest remaining untracked entries are taken the same way.

Each pick is an `AutopilotBigFiles`: its path inside the copy, bytes, file count, kind, newest change and risks.

- **Kind:** the kinds making up a tenth of its bytes or more, biggest first, at most two: "TypeScript files", "videos and Swift files", "images and other files". With none, it is just "files".
- **Risks:** one of five per kind (`bigCode`, `bigMedia`, `bigData`, `bigArchives`, `bigOther`), for every kind making up a tenth of its bytes or more. Code counts whenever it holds any, however small, so a Yes to big videos never deletes code that sits among them.

A copy that doesn't qualify to have them dropped (see 5) is refused as today: "It has big files that aren't saved anywhere else, so I left it alone." The receipt now carries the list.

A project inside a dropped entry (a nested `.git`), ignored or not, still refuses the copy. That matches today: Git would add it, or the walk of ignored files would find it. Before anything is dropped, retire walks each dropped folder for one, skipping rebuildable folders as that walk does.

## 2. The risk facts

The engine marks a copy from the latest refusal receipt that names its big files, as long as the copy's files still look as they did to that refusal. `bigFilesKey` is the copy's facts, leaving out its age, use, chat and big-file risks, plus its count of unsaved files. So a copy that only got older, or that was already marked with one kind when a new one turned up, keeps or gains its marks.

- It sets one fact per risk found, such as `bigCode=yes` or `bigMedia=yes`.
- The item keeps the list, so the card can show it.

A copy without these facts has no big files that BZ knows of, and reads as `bigCode=no` and so on.

A refusal from an older build that named no files doesn't stand. The copy is tried again at the next look, so its files get named.

## 3. Only a lesson that names a kind covers it

The five facts are named risks: a burn lesson covers a copy with `bigCode=yes` only when its match allows `yes` by name.

- No other lesson burns such a copy: not one learned before this change, not a starter rule, and not the AI.
- A question's coverage includes these copies, so a card about copies of that age shows them and counts them.
- `subsumes` reads a burn lesson without the fact as `[no]`. So a lesson that lets one kind go is never taken into one that doesn't.
- `answered` doesn't let an answer from before cards named their risks cover them, because no older card ever showed big files.
- The replay treats a card that showed big files as being about them.
- `narrowed` adds a kind to a Yes lesson only when its card showed that kind, so other lessons stay as they were.

The five facts join `riskFacts` for copies, with `yes` as the risky value. A Yes allows a kind only when its card showed it, the same narrowing every risk gets. A later copy with a kind the card didn't show gets a card of its own (R31, R36).

## 4. The card

A copy with big unsaved files is unsure, so `proposeQuestions` asks about its age as usual. On the card:

- **Cautions:** each kind is counted, for example "1 has big unsaved code files".
- **Rows:** copies with big unsaved files come first. Under each, up to two dim lines name its big files, for example "tmp/checkouts · 914 MB of TypeScript files · Oct 10", then "+ 2 more, 300 MB".
- **Cost line:** an amber line says what a Yes costs before anything is pressed, whether or not the details are open: "A Yes deletes its 914 MB of big unsaved files for good. Undo won't bring these back; everything else in it is backed up first." A card without the details list shows this line in place of the note, which would otherwise say the copy can be undone.
- **View details:** each such copy gets a risky tag ("914 MB not backed up"), a fact for each big file or folder, and a **Big files** filter.

## 5. Yes

The lesson allows `yes` for each kind the card showed, and then burns the copies.

Retire drops the big files only under these conditions:

- the copy carries a risk for every kind it holds now, and it burns under a lesson (`rule:`). The policy guarantees that lesson names those kinds.
- A kind that turned up since the card refuses the copy again, naming it, so the new kind can be asked about.

The dropped files are left out as Git adds the snapshot (`:(exclude,literal)` pathspecs, as with browser profiles), and so are ignored files inside them. Removing the folder deletes them. The rest is backed up and verified as always.

What the owner sees afterwards:

- **The receipt** lists what went: "Its big unsaved files were deleted for good: tmp/checkouts (914 MB of TypeScript files)." The receipt also keeps the list.
- **Restore** brings the copy back without them. Its receipt says the big unsaved files didn't come back.

## 6. BZ's own calls

BZ acts on its own (3.4 of the teach-intent spec) only when every risk on the question was on a card the owner said yes to on that subject. That includes each kind of big files, so it never deletes a kind the owner hasn't approved. Its lesson allows exactly the approved kinds.

On the tell, before Undo is pressed:

- Each copy's row names what it deleted.
- A line says: "Its 914 MB of big unsaved files were deleted for good. Undo brings the copy back without them."

After the Undo, the note says how many copies came back without their big files, and the tell waits for **OK**.

## 7. No

A No keeps what the card asked about: one keep per named risk the card showed, kept to its risky value (for example `bigCode: [yes]`), at the card's age and newer, when that keeps every thing on the card. Otherwise it keeps one per risk shown, and then falls back to the rules of 2.1 in the teach-intent spec. A No about big files never keeps clean copies that the owner's other lessons burn.

## 8. Retries stop

A copy with big unsaved files is unsure, or kept after a No, so it isn't burnable and nothing tries it again. Its why reads: "It has big files that aren't saved anywhere else, so I won't burn it without your OK." That holds whether or not a question can be asked; for example, it may be too small to ask about on its own.

The AI's sweep prompt says to ask about such copies instead of judging them burn.

## Data changes

- `AutopilotBigFiles` {path, bytes, files, kind, changed, risks}. One stored without risks reads as the risk its kind is.
- `AutopilotReceipt.bigFiles`: what a refusal found, or what a burn deleted.
- `AutopilotReceipt.bigKey`: what the copy's files looked like when a refusal named them.
- `AutopilotItem.bigFiles`: the list the engine attached, for the card. It is not a fact.
- `AutopilotQuestionRow.bigFiles`, and `AutopilotQuestion.bigBytes`: what a Yes deletes in all.
- `AutopilotTell.bigBytes`: what its burns deleted for good.
- `AutopilotCard.cost`, and `AutopilotCardRow.details` for the dim lines under a row.

Every new field is optional, so old files still load.

## Proof

- **`--autopilot-worktrees`:**
  - Retire names a folder of checkouts, leaving the small new files beside it out.
  - It burns under a lesson without the big files: the small files are restored, and ignored files inside the dropped folder aren't kept.
  - It refuses under the AI, under **Burn now**, before the copy is known to hold them, and when a new kind turns up.
  - A project inside a big folder still refuses the copy, and so does one in an ignored folder inside it.
- **`--autopilot-policy`:**
  - Picking the big files, with their kinds and risks (a folder of videos and code is both).
  - The key that keeps a copy marked.
  - Named-risk matching, coverage, `subsumes`, the legacy `answered`, guesses, the replay and the AI's eligibility.
  - The card's cautions, rows and cost line; the details tag, facts and filter.
  - The Yes and No lessons, and their sentences.
- **`--autopilot-learning`** (`AutopilotBigFilesTests.swift`), engine scenarios:
  1. A lesson covers a copy, and its refusal names the files.
  2. The copy turns unsure, and nothing tries it again.
  3. The card names the files.
  4. A Yes burns it without its big files. The next copy with the same kind burns without a question, and a copy with big videos gets a card of its own.
  5. A No keeps only big-file copies, and clean copies still burn.
  6. An older refusal that named no files is tried again at once.
  7. BZ acts on an approved kind, its tell says what went, Undo's note says it came back without them, and an unapproved kind is asked about.
- **`--autopilot-proof`:** renders of a question card about big files and of a tell that deleted some, read back by OCR.
