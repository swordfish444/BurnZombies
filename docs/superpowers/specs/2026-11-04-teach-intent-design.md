# Teach intent: questions you can decide on, lessons that carry over, proof it's improving

Status: decided with the owner. They chose card A, chose "Act, then tell me", and accepted the lessons and evals as played back. Builds on main after PR #39; if PR #40 lands first, merge it in.

## Why

On a real Mac with 27 answers, three things went wrong:

1. **Cards hid what mattered.** "Burn 5 old project copies? Frees 2.8 GB · Already merged · No unsaved changes · Made by Patrol6 agents" gives nothing to decide on. It left out which copies they were and that they were used the afternoon before, which was the only reason BZ asked. `stalePhrases` has no `today`, so that age never showed.
2. **Answers stayed narrow.** 27 answers became 27 rules, many tied to one project, folder or maker. Those facts never changed the owner's answer. Dropping them would have made 7 of the 27 questions unnecessary, and all 7 would have been guessed right.
3. **There's no sign of getting smarter.** The owner said: "The more we train on questions, the smarter it should get." They want lightweight evals that confirm it.

## Goals

1. A question gives the least detail needed to decide: which things, when they were last used, what's safe about them, and what's risky.
2. Answers become a few general lessons about *why*, not *which project*.
   - Each lesson is one plain sentence with a track record.
   - Each drives both the native engine and the AI.
3. BZ guesses before asking and keeps score. Once it has earned trust on a subject, it acts on what it's sure of and tells the owner afterwards, with Undo.
4. Lightweight evals prove the improvement:
   - a replay over the owner's own answers, as a CLI command and one line in Settings;
   - proof tests with simulated owners;
   - honest live counts.

## Non-goals and anti-goals

- Nothing changes in:
  - safety rails, burn mechanics or restore points;
  - the quiet rule (never ask about things used today or still busy);
  - the 1 GB minimum per question, one open question per subject, or the limit of 3 open questions;
  - AI burn eligibility. The AI gains no new authority to burn.
- No percentages or scores that don't map to something real. Counts only.
- No extra reading. A card stays one screen; a lesson stays one sentence.
- BZ never acts on its own:
  - on a subject the owner has never answered;
  - on a risk the owner hasn't said yes to before;
  - against any No.
- The four owner rules made from earlier "even if used today" AI questions burn at any age. That was the owner's choice, and they stay exactly as they are. In general, a rule with no recency fact is never rewritten, absorbed or migrated.
- Copies whose age BZ couldn't read (`stale: unknown`) stay out of rules and questions. That's a separate follow-up.

## Part 1: The question card (owner chose card A, "show the copies")

From top to bottom:

- **Headline:** `Burn {count} {noun} {when}?`. `when` describes the most recently used member in calendar words relative to now, computed when the card is shown.
  - Copies and folders: "you used yesterday", "untouched since Monday" (2–6 days), "untouched for 2 weeks", "untouched for 2 months", "untouched for 3+ months".
  - Programs: "idle for 3 hours", "idle for 2 days".
  - Quiet questions never cover today, but the phrases handle it anyway ("you used this morning"). This fixes the missing `today` phrase.
- **Frees line:** "Frees 2.8 GB", plus "of memory" for programs.
- **Safe line:** one sentence saying what every member shares. It's computed from the members' facts, not from the pattern, because native patterns hold only the subject and recency.
  - Copies: "Their work is on GitHub." when all are pushed or merged; "Nothing is unsaved." when all have no changes; "Their chats are finished." when all chats ended.
  - Programs: "None is serving anything." and "Their apps are gone."
  - Folders: "Your tools rebuild them when needed."
- **Cautions:** amber, counted, as today ("3 have unsaved changes").
- **Rows:** up to 3 members, biggest first. Each row has a title, a dim subtitle and a time on the right. Then "+ N more".

  | Kind | Title | Subtitle | Right side |
  | --- | --- | --- | --- |
  | Copy | The task: the chat title when a chat is attached, otherwise the humanized branch (`codex/fix-login-selector` → "fix login selector") | Project name | When a file last changed, in calendar words: "today 9 am", "Mon 5 pm", "Oct 12" |
  | Program | Program name | "started by Codex" | Idle time |
  | Folder | Folder kind | Project | Last change |
- **Backup note:** unchanged per kind. Then **Yes, burn them · No, keep them · Not sure — skip**.

Questions store their rows, a `newest` date and their `risks` (Part 3).

- These are filled in `question()` and `ask()`.
- `refreshQuestions` refreshes them along with count and bytes.
- Older questions without rows fall back to `examples`.

## Part 2: Lessons

### 2.1 What an answer teaches

A Yes, a No, BZ's own act, or an Undo creates the rule `widen(generalize(match), verdict)`.

`generalize` applies only when the match pins the subject's recency fact (`stale` for copies and folders, `idle` for programs) to known values, not `unknown`. In that case it drops the identity facts `repo`, `place`, `agent` and `size`. Otherwise the match is kept exactly as it is.

- Why drop them: in the owner's answers, those facts never changed the answer.
- Why require recency: a general pattern with no recency fact would cover things used an hour ago.

Native questions are already only subject plus recency. Generalizing mostly widens the AI's narrower questions.

### 2.2 Merging

An existing operator lesson of the same kind and verdict is absorbed when a new lesson subsumes it, meaning the new lesson matches every item the old one matches.

- The old rule is removed.
- Its question ids and tallies move to the new lesson (`from`, `formerIDs`).
- Rules without pinned recency are never absorbed.
- Forget on a lesson removes it and every question it was made from, so those subjects can be asked again.

### 2.3 Migration (memory version 2)

On first load of version-1 memory:

1. Write `memory.v1.json` beside it.
2. Regeneralize each operator rule whose question pins known recency. Recompute its id and keep the old id in `formerIDs`.
3. Absorb subsumed lessons.
4. Seed per-lesson tallies from `receipts.json`. A receipt whose authority is `rule:<id>` (current or former id) counts as burned, and as undone too when its outcome is `restored`.
5. Seed scores by replaying the answered questions (Part 4.1), marked `replayed`.

The four any-recency rules keep the same id and match, byte for byte.

### 2.4 How lessons read (Settings → Autopilot → What BZ has learned)

These are display-only groups. Each is one sentence with an evidence line and a Forget button that forgets every lesson in the group. Native templates write the words deterministically; the AI doesn't.

- **Copies to burn, general lessons:** grouped by recency floor, which is the lowest stale value. The sentence is "Copies nobody touched since yesterday are done", plus:
  - "once…" for conditions every lesson in the group requires, e.g. "once their work is on GitHub and nothing is unsaved";
  - "even with…" for risky values any lesson in the group covers, e.g. "even with unsaved work, work only on this Mac, or work I couldn't check".
- **Copies to burn, tied to projects:** one line that names the projects and what's done. Example: "In api, web-app and 2 more projects, merged copies are done at any age once no chat is using them."
- **Programs to burn:** one line per kind listing each family with its idle floor. Example: "Leftover programs can stop once idle: Node after 10 minutes, Java helpers after an hour."
- **Folders to burn:** grouped by floor. Example: "Rebuildable folders untouched since yesterday can go: tool caches, node_modules, build folders."
- **Keeps:** one line each. Example: "Busy Java helpers serving a port stay."
- **Evidence line:** "From 11 answers · burned 364 copies, 396 GB · undone 0".
  - Programs read "stopped … of memory"; folders read "deleted …".
  - An answer BZ gave itself counts as one of "my own calls": "From 11 answers and 1 of my own calls". With no answer of the owner's behind the lesson, it reads "From my own call" (or "From 3 of my own calls").
- **Starter rules** stay listed with their switches, as today.

### 2.5 Track record

Memory keeps a tally per lesson: count, bytes and undone.

- It updates when a burn receipt names the lesson, and when a restore undoes one.
- Don't recount from receipts after migration: the receipts file is capped.

### 2.6 The AI pilots from lessons

- `autopilot_catalog` returns `lessons`: id(s), sentence, kind, verdict, exact match, answers, burned, bytes and undone. It still returns rules and the last 20 answers.
- The sweep prompt names the lessons as the owner's intent and its brief:
  - judge unsure items by why the owner burns or keeps things;
  - ask where no lesson reaches;
  - never contradict a lesson.
- `autopilot_ask` takes an optional `guess` (`yes`/`no`), recorded as the AI's guess. Without it, BZ's own guess is used.

## Part 3: Guess, score, act then tell (owner chose "Act, then tell me")

**Subject:** all copies, one program family, or one folder kind (the existing `subject()`).

**Risks:** the risky facts present among a question's members, stored on the question as `fact=value` strings:
- `saved=local`, `changes=small|large`, `listening=yes`;
- any fact that is `unknown`;
- `stale=today`, `idle=active|10m`.

Legacy questions derive them from the match and the caution text.

### 3.1 Guess

Every question gets a guess when it's created: `{answer, sure, why, source: native|ai}`.

- **Lean:** the owner's most common Yes/No on the same subject. With no answers on the subject, use the same kind. With no answers there either, or a tie, there's no guess.
- **Sure** only when all of these hold:
  1. Trust is earned for the subject (3.3).
  2. The lean is yes.
  3. The owner has said yes on this subject before.
  4. Every risk on the question appeared on a question the owner said yes to on this subject.
  5. No keep lesson on this subject overlaps the question.
- **Why,** for display: "You said yes to 6 like these, including ones with unsaved work."

### 3.2 Score

When the owner answers Yes or No to a question that has a guess, append `{questionID, subject, guess, answer, right, date, replayed}` to memory `scores`, keeping the last 300.

- Skips aren't scored.
- A "Good call" on a tell scores right; an Undo scores wrong.

### 3.3 Trust

A subject is trusted when its last 5 scores are all right. One wrong score ends trust until 5 right ones in a row come again. A wrong score is a No that BZ didn't expect, or an Undo.

### 3.4 Act, then tell

This happens when a question would be opened (natively in `refreshQuestions`, or by the AI's `ask`), its guess is sure, and **Act on its own when sure** is on (the default). BZ doesn't open the question. Instead it:

1. records the question as answered yes, with `answeredBy: bz`;
2. creates the lesson exactly as for a Yes;
3. burns the matches right away;
4. adds a **tell**: `{id, questionID, ruleID, kind, count, bytes, rows, date, state}`.

The one-question-per-subject, 1 GB and quiet rules apply unchanged, because only a would-be question can become a tell.

Teach BZ shows open tells before questions:

- **Card:** the headline "Burned 3 copies on my own.", rows as on a question card, and the line "You'd have said yes: you said yes to 6 like these."
- **Good call:** closes the tell and scores right.
- **Undo:**
  1. Restores every restorable burn the tell's lesson made since the tell (copies). Restored items become kept, as today.
  2. Turns the lesson into a keep, widened toward riskier like a No.
  3. Records the owner's answer as No and scores wrong.
  4. Closes the tell.

  Programs and folders can't be brought back. Their card says "Stopped programs can't be restarted by me; I'll ask next time." The lesson and trust still flip.
- **Untouched tells** close after 7 days without a score.

The setting lives in Settings → Autopilot. When it's off, sure questions are asked and scored like any other.

## Part 4: Proof it's improving

### 4.1 Replay: the eval

`AutopilotEval.replay(answered:)` is a pure function over the answered questions in order. It uses the same `generalize`, `widen`, guess, sure and trust code as the live path, so it measures what the live system would do.

For each Yes/No (skips teach nothing) it reports:
- the outcome: **settled** (an earlier lesson covered it), **acted** (sure and trusted) or **asked**;
- the guess, and whether it matched.

The summary counts answers, settled, acted, asked, guesses made, guesses right, wrong settles and wrong acts.

On the owner's real history today:
- 3 settled and 7 acted, all matching the owner (100 GB);
- 17 asked, with guesses 13 of 14 right. The miss was the busy-Java No, and BZ wasn't sure of that one.

Where it shows up:
- **CLI:** `burnzombies autopilot eval [--json]` prints one line per answer (date, owner, guess, outcome, subject, GB) and the summary.
- **Settings:** shown once there are at least 5 answers. Example: "Replaying your 27 answers, I'd have asked 17 and handled the other 10 on my own the way you would have."

### 4.2 Live counts (Settings → How I'm doing)

Plain counts only:

- "I guessed 9 of your last 10 answers right." This counts owner-scored guesses, replayed ones included.
- "This week: 2 questions, 120 GB burned on my own. Last week: 9 questions, 80 GB."
  - Questions are those shown that week; tells don't count.
  - "On my own" is every burn whose authority isn't the owner's Burn now: lessons, starter rules, the AI and tells.
- "You undid 0 of the 498 copies I burned." Only copies can be undone, so this counts copies, from the impact tally that keeps them for good.

### 4.3 Proof tests (in `scripts/test.sh --integration`)

- **Units:**
  - generalize, widen and absorb;
  - migration: the any-recency rules are unchanged, tallies are seeded, scores are replayed;
  - the card: headline `when`, rows, the safe line and the `today` phrase;
  - guess, sure, trust and score;
  - the act and undo paths;
  - eval output.
- **Replay fixture:** an anonymized history shaped like the owner's, with generic project names. Its expected summary is a regression gate: settled + acted may not drop, and wrong acts stay 0.
- **Simulated owners:** deterministic, with no model.
  - A synthetic Mac of copies, programs and folders with varied facts gains new items each round.
  - Personas answer by fixed policies:
    - liberal: done once on GitHub or untouched a day;
    - cautious: keeps anything with unsaved work;
    - server keeper: keeps programs serving a port.
  - Over several rounds, assert:
    - BZ never burns an item the persona would keep, tells included;
    - questions per round fall;
    - GB handled without asking rises;
    - consistent subjects earn trust and get tells;
    - one Undo returns the subject to asking.
- **UI proof** (`--autopilot-proof`): renders the new card with rows, a tell card, and the lessons with How I'm doing.

## Data changes

- `AutopilotQuestion`: `rows`, `newest`, `risks`, `guess`, `answeredBy`.
- `AutopilotRule`: `from` (question ids) and `formerIDs`.
- `AutopilotMemory`: `version = 2`, `scores`, `tells`, `tallies`, `actsOnItsOwn` (default true).
- `AutopilotCard`: `rows`, `more`, `line`, and a headline with `when`.
- `AutopilotCommand`: `tellGood(id)`, `tellUndo(id)`, `setActsOnItsOwn(Bool)`, `forgetLesson(ids)`.
- `AutopilotSnapshot`: `lessons` (the display groups), `tells`, and `progress` (the 4.2 counts and the 4.1 line).
- MCP: `autopilot_catalog` returns `lessons`; `autopilot_ask` accepts `guess`.
- Every new field is optional when decoding, so old files still load.

## Left to the builder

- Exact template words beyond the examples above.
- How branch names are humanized.
- Type and field names.
- Visual details, following the existing TeachView style.

Write Swift that type-checks on CI's Swift 6.2: break long `+`, `??` and `map` chains into small typed steps.

## Rollout

- `docs/AUTOPILOT.md`:
  - rewrite the Training section;
  - add "How I'm doing" and tells;
  - mention tells under Undo.
- Bump the build number like other Autopilot PRs.
- Live install: a local build installed after a backup, following the operator's procedure. Then read the live Settings and `autopilot eval` and report them to the owner.
