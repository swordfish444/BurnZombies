# Big unsaved files: ask about them instead of skipping the copy forever

Status: built on main after build 54. What a Yes does to the big files themselves is the owner's call, because it can't be undone; see [The decision](#the-decision).

## Why

Retire backs up every unsaved file of an old copy into the repository's own storage before it removes the folder. More than 512 MB of untracked files would grow the repository instead of freeing the disk, so retire refuses such a copy. Since build 53, browser profiles that test runs leave behind don't count. Other big unsaved files still refuse.

Nothing ever asked about them:

- The refusal became a receipt. Six hours later (`retryRefusalsAfter`) the copy was tried again and refused again, with no end.
- The owner's lessons covered these copies ("Copies nobody touched since yesterday are done, even with unsaved work"), so they never became unsure, and no question could reach them. The AI couldn't ask either: its question tool takes only unsure items.
- The refusal text once promised a question ("so I'll ask you before touching it") that never came.

On the first Mac this held back a copy untouched for a week whose big unsaved folder held 21 throwaway checkouts of the project (914 MB), next to four small new scripts.

## Goals

1. A copy skipped for big unsaved files becomes a question built like every other card. The card names the copies and their big unsaved files (where they are, how big, what kind and when they last changed), and says plainly what a Yes costs.
2. A Yes becomes a lesson that carries a new risk fact, `bigFiles=yes`, so later copies like these aren't asked again.
3. A No keeps those copies, and only those, and the 6-hour retries stop.
4. No text promises a question that may not come.

## Non-goals

Nothing changes in:

- the quiet rule, the 1 GB minimum per question, one open question per subject, or the limit of 3 open questions;
- every other safety rail: the 512 MB cap on what goes into a restore point, browser profiles, ignored files, submodules, locks, programs using a copy, and Full Disk Access;
- the owner's **Burn now**: on a copy with big unsaved files it is still refused, since the owner hasn't seen the files.

The AI gains no authority. BZ never deletes files that exist nowhere else on its own call (see 6).

## 1. Retire names the big files

When a copy's unsaved files (untracked and not ignored, browser profiles left out) come to more than 512 MB, retire picks the big ones:

1. Candidates are folders Git tracks nothing in, and single untracked files, of at least 100 MB (`AutopilotPolicy.worthBytes`). Inside a folder Git tracks nothing in, it takes the deepest folder that holds 100 MB when none of its own folders does: a folder of checkouts is one entry, not 21. A folder that holds files Git tracks is never taken whole, so new source files beside generated output are never in it.
2. They are taken biggest first, until what is left fits in a restore point (512 MB). Anything smaller stays in the backup, as before.
3. If that is not enough, the biggest remaining untracked entries are taken the same way.

Each is an `AutopilotBigFiles`: its path inside the copy, bytes, file count, kind and newest change. The kind comes from what most of its bytes are: "TypeScript files", "videos", "images", "archives", "databases", "logs", and so on, or "files".

A copy that doesn't qualify to have them dropped (see 5) is refused as today, "It has big files that aren't saved anywhere else, so I left it alone.", and the receipt carries the list.

A project folder inside a dropped entry (a nested `.git`) still refuses the copy, as it does today when Git would add it.

## 2. The risk fact

`bigFiles=yes` is a new copy fact. The engine sets it from the latest refusal receipt that names big files, while the copy's facts are what that refusal saw (its revision). The item keeps the list for its card. A copy without the fact has none that BZ knows of, and reads as `bigFiles=no`.

A refusal from an older build, which named no files, doesn't stand: the copy is tried again at the next look, so its files get named.

## 3. Only a lesson that names it covers it

`bigFiles` is a named risk. A burn lesson covers a copy with `bigFiles=yes` only when its match allows `yes` by name:

- Lessons learned before this, starter rules and BZ's own calls never burn such a copy.
- A question's coverage includes them, so a card about copies of that age shows them and counts them.
- `subsumes` reads a burn lesson without the fact as `bigFiles: [no]`, so a lesson that allows big files is never taken into an older one that doesn't.
- `answered` doesn't let an answer from before cards named their risks cover them: no older card ever showed big files.
- The replay treats a card that showed big files as about them.

The fact joins `riskFacts` for copies (`yes` is risky), so a Yes allows it only when its card showed it, the same narrowing every risk gets.

## 4. The card

A copy with big unsaved files is unsure, so `proposeQuestions` asks about its age as usual. On the card:

- The caution is counted: "1 has big unsaved files".
- Rows put copies with big unsaved files first, biggest first. Under each one, up to two dim lines name its big files: ".lane/commit-check · 914 MB of TypeScript files · Oct 10", then "+ 2 more, 300 MB".
- The note says what a Yes costs, before anything else: "A Yes deletes 914 MB of unsaved files for good. The rest is backed up first, so you can undo it."

## 5. Yes

The lesson allows `bigFiles: [yes, no]` and burns the copies.

Retire drops the big files only when the copy carries `bigFiles=yes` and burns under an owner's lesson (`rule:`). The policy guarantees that lesson names the risk. They are left out as Git adds the snapshot (`:(exclude,literal)` pathspecs, like browser profiles), and so are ignored files inside them. Removing the folder deletes them. The rest is backed up and verified as always.

The receipt says it: "Removed. Your unsaved changes are backed up, so you can restore it. Its big unsaved files (914 MB in .lane/commit-check) were deleted for good." **Restore** brings the copy back without them, and its receipt says so.

## 6. BZ never deletes them on its own call

- A guess is never sure on a question that shows big unsaved files, so BZ asks.
- An act's lesson never allows `bigFiles=yes`, even when the owner approved it on the subject.
- The AI may not burn such a copy (`aiEligible`). The sweep prompt says to ask instead.

## 7. No

A No keeps what the card was asked for: one keep per named risk the card showed, kept to its risky value (`bigFiles: [yes]`) at the card's age and newer, when that keeps every thing on the card. Otherwise the rules of 2.1 in the teach-intent spec apply. A No about big files never keeps clean copies that the owner's other lessons burn.

## 8. Retries stop

A copy with `bigFiles=yes` is unsure, or kept after a No. It isn't burnable, so nothing tries it again. Its why reads "It has big files that aren't saved anywhere else, so I won't burn it without your OK." That holds whether or not a question can be asked; it is too small to ask about alone, for example.

## The decision

What a Yes does to the files themselves:

- **A. Delete them for good** (built). This frees the disk now. Undo brings the copy back without them, and the card says so first.
- B. Back them up anyway. Undo brings everything back, but the bytes stay in the repository as long as the restore point does.
- C. Move them to the Trash. They can be put back until the Trash is emptied, and the disk is freed only then.

## Data changes

- `AutopilotBigFiles` {path, bytes, files, kind, changed}.
- `AutopilotReceipt.bigFiles`: what a refusal found, or what a burn deleted.
- `AutopilotItem.bigFiles`: the list the engine attached, for the card. It is not a fact.
- `AutopilotQuestionRow.bigFiles`, and `AutopilotQuestion.bigBytes` (what a Yes deletes in all).
- `AutopilotCardRow.details`: the dim lines under a row.

Every new field is optional, so old files still load.

## Proof

- `--autopilot-worktrees`: retire names a folder of checkouts and leaves small new files out of it, burns under an owner's lesson without the big files (the small files are restored), and refuses under the AI and under **Burn now**. A project inside a big folder still refuses.
- `--autopilot-learning` (new `AutopilotBigFilesTests.swift`), an engine scenario:
  1. A lesson covers a copy, and its refusal names the files.
  2. The copy turns unsure, and nothing retries it.
  3. The card shows the files and their cost.
  4. A Yes burns it without its big files, and the lesson covers the next copy like it.
  5. A No keeps only big-file copies, and clean copies still burn.
  6. An older refusal that named no files is retried at once.
- `--autopilot-policy`: named-risk matching, coverage, subsumes, legacy `answered`, guess and act, and the AI's eligibility.
