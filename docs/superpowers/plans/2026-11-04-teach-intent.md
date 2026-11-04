# Teach Intent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change Autopilot training in four ways:
- question cards show which things are involved and when each was last used;
- answers become general lessons with track records;
- BZ guesses before it asks, and once trusted, acts and then tells the owner;
- a replay eval and live counts prove it is improving.

**Architecture:** Pure policy code holds all the decisions; the engine, store, MCP, CLI and app only call it. That code lives in:
- `AutopilotLessons.swift`: generalize, learn and absorb, migrate, tally, display groups;
- `AutopilotGuess.swift`: risks, guess, trust, replay, progress;
- `AutopilotCardText.swift`: headline phrase, rows, safe line.

The replay uses the same functions as the live path, so it measures the shipped behavior.

**Tech Stack:** Swift 6 (CI type-checks with 6.2.3), SwiftUI, the repo's own proof runner (`Proof/`, `.build/debug/BurnProof`).

**Spec:** `docs/superpowers/specs/2026-11-04-teach-intent-design.md`. Read it first; this plan argues from it.

## Global Constraints

- **Swift 6.2.3 on CI:** write long `+`, `??` and `map` chains as small typed steps.
- **Old files still load:** every new stored field decodes with `decodeIfPresent`, falling back to a default. Old `memory.json`, `receipts.json` and question JSON must still load.
- **No private names:** no private project, folder or person names in code, tests, docs or commits. Use `api`, `web-app`, `project-1`.
- **Never touch:**
  - the live Mac's state under `~/Library/Application Support/BurnZombies`; tests use temporary roots;
  - `refs/burnzombies/retired/*`.
- **Rules without pinned recency** (no `stale`/`idle` value, or `unknown`) are never rewritten, absorbed or migrated. They stay identical, id included.
- **Unchanged:** quiet rule, 1 GB per question, one open question per subject, at most 3 open, AI burn eligibility, safety rails.
- **Counts only:** no percentages in any owner-facing text.
- **Commits:** commit at the end of each task. End every message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Proof style:** plain functions using the helpers in `Proof/` (`equal(actual, expected, "label")`, `failTest`), as in `Proof/AutopilotPolicyTests.swift`.
- **New suite:** `Proof/AutopilotLearningTests.swift`, `func autopilotLearningProof() async throws`. Register it two ways:
  - flag `--autopilot-learning` (name "Autopilot learning") in the flag table in `Proof/Runner.swift`;
  - the default run, after `autopilotSweepProof()`.
- **Focused run:** `swift build && .build/debug/BurnProof --autopilot-learning`. Existing suites: `--autopilot-policy`, `--autopilot-sweep`, `--autopilot-worktrees`, `--autopilot-disk`, `--autopilot-process`.

## Review Focus

1. **Build-40 memory loads once.** A `memory.json` from build 40 (version 1, no new fields) loads, migrates once, and keeps every keep, answer and any-recency rule. Task 3 pins this.
2. **Members with no last-use date.** The card still reads well, falling back to the stale-bucket phrase. Task 4 pins this.
3. **Undo with nothing to restore.** When a tell's burns can't be restored (programs, folders, a failed restore), the lesson and trust still flip and the tell closes. A failed restore is reported in the tell's `note`. Task 6 pins this.
4. **Bad AI input.** An AI `guess` other than yes/no is ignored. An AI pattern without recency is still refused (quiet rule) and is never generalized. Task 7 pins this.
5. **Calendar edges.** Last use at 00:10 today, at 23:50 yesterday, and 6 vs 7 days ago. Tests inject `now` and a fixed `Calendar` (gregorian, UTC). Task 4 pins this.

---

### Task 1: Lessons from answers

**Files:**
- Create: `Sources/BurnCore/AutopilotLessons.swift`
- Modify: `Sources/BurnCore/AutopilotModels.swift`. Add to `AutopilotRule`: `public var from: [String]?` and `public var formerIDs: [String]?`, both optional when decoding.
- Modify: `Sources/BurnCore/AutopilotEngine.swift`. Change `apply(.answer)` and `apply(.forgetRule)`.
- Create: `Proof/AutopilotLearningTests.swift`. Modify `Proof/Runner.swift` to register it.

**Interfaces (produces):**

```swift
extension AutopilotPolicy {
  static let identityFacts: Set<String>  // ["repo", "place", "agent", "size"]
  public static func pinsRecency(_ kind: AutopilotKind, _ match: [String: [String]]) -> Bool
  public static func generalize(_ kind: AutopilotKind, _ match: [String: [String]]) -> [String: [String]]
  public static func lessonMatch(_ kind: AutopilotKind, _ match: [String: [String]], verdict: AutopilotVerdict) -> [String: [String]]  // widen(generalize(...))
  public static func subsumes(_ wide: [String: [String]], _ narrow: [String: [String]]) -> Bool
  public static func overlaps(_ a: [String: [String]], _ b: [String: [String]]) -> Bool
  /// Adds an operator lesson. Two cases, both only for operator rules of the same kind and verdict that pin recency:
  /// - an existing lesson already subsumes `rule`: `rule`'s question id joins that lesson's `from`, and its id is returned;
  /// - `rule` subsumes existing lessons: they are removed, and their questionID, `from` and id move into `rule.from` / `rule.formerIDs`.
  @discardableResult public static func learn(_ rule: AutopilotRule, into rules: inout [AutopilotRule]) -> String
  /// All question ids a lesson was made from: questionID plus from.
  public static func questionIDs(_ rule: AutopilotRule) -> [String]
}
```

- `pinsRecency` is true when the kind's recency fact (`recencyFacts`) is present, non-empty, and has no `unknown`.
- `subsumes(wide, narrow)` is true when every key of `wide` is in `narrow` and `narrow[key]` ⊆ `wide[key]`.
- `overlaps(a, b)` is true when every key present in both has intersecting values.

**Engine:**
- `apply(.answer)` builds the rule from `lessonMatch(q.kind, q.match, verdict)`.
- Its title comes from `ruleTitle` of the question with its match generalized.
- It keeps `memory.rules.removeAll { $0.questionID == q.id }`, then calls `learn`.
- `forgetRule` removes every question in `questionIDs(rule)`.

- [ ] **Step 1: Write the failing tests** in `lessonsProof()`, called from `autopilotLearningProof()`.
  - `generalize`:
    - `(.worktree, ["repo": ["api"], "place": ["codex"], "size": ["large"], "saved": ["merged"], "stale": ["day"]])` returns `["saved": ["merged"], "stale": ["day"]]`.
    - `(.process, ["family": ["java"], "idle": ["10m"], "agent": ["codex"], "listening": ["yes"]])` returns `["family": ["java"], "idle": ["10m"], "listening": ["yes"]]`.
    - These return their input unchanged: `["repo": ["api"], "saved": ["merged"], "thread": ["none"]]`, `["repo": ["api"], "stale": ["unknown"]]` and `["repo": ["api"], "stale": ["day", "unknown"]]`.
  - `lessonMatch(.worktree, ["repo": ["api"], "stale": ["day"], "saved": ["merged"]], verdict: .burn)` returns `["saved": ["merged"], "stale": ["day", "week", "month", "older"]]`.
  - `subsumes`:
    - true for `(["stale": ["day", "week", "month", "older"]], ["stale": ["week", "month", "older"], "saved": ["merged"]])`;
    - false when swapped;
    - false for `(["saved": ["merged"]], ["stale": ["day"]])`.
  - `learn`, case "absorb": `A` (burn, `["stale": ["week", "month", "older"]]`, questionID q1) is in rules. Learning `B` (burn, `["stale": ["day", "week", "month", "older"]]`, q2) leaves rules with exactly one rule, with id `B.id`, `from == ["q1"]` and `formerIDs == [A.id]`.
  - `learn`, case "join": existing `B`; learning `C` (burn, `["stale": ["week", "month", "older"], "saved": ["merged"]]`, q3) leaves the count unchanged, returns `B.id`, and `B.from` contains `"q3"`.
  - `learn`, any-recency: a rule `X` (burn, `["repo": ["api"], "saved": ["merged"], "thread": ["none", "ended"]]`) is JSON-encoded before and after learning `B`. The encodings are byte-identical.
  - `learn`, burn vs keep: a keep lesson is never absorbed by a burn lesson.
  - `decide` after learning the generalized lesson from an AI-style question (`["repo": ["api"], "place": ["codex"], "saved": ["merged"], "stale": ["day"]]`, yes): a copy with `["repo": "web-app", "place": "patrol6", "saved": "merged", "stale": "week", "changes": "none", "inUse": "no", "thread": "none"]` gets `.burn` with authority `"rule:" + lessonID`.
- [ ] **Step 2:** Run `swift build && .build/debug/BurnProof --autopilot-learning`. Expect a build failure (missing symbols).
- [ ] **Step 3:** Implement the interfaces above, the engine changes and the runner registration.
- [ ] **Step 4:** Run `--autopilot-learning` and `--autopilot-policy`. Expect both to PASS.
- [ ] **Step 5:** Commit: "Autopilot: answers teach general lessons".

### Task 2: Guess, score, trust and the replay eval

**Files:**
- Create: `Sources/BurnCore/AutopilotGuess.swift`.
- Modify `AutopilotModels.swift`:
  - new types `AutopilotGuess` and `AutopilotScore`;
  - `AutopilotQuestion` gains `risks: [String]?`, `guess: AutopilotGuess?`, `answeredBy: String?`;
  - `AutopilotMemory` gains `scores: [AutopilotScore]` (default `[]`).
- Test: `Proof/AutopilotLearningTests.swift`, using `Proof/AutopilotTeachHistory.swift`. That file already exists: it holds `teachHistoryJSON`, 30 anonymized real questions in the app's own JSON format.

**Interfaces (produces):**

```swift
public struct AutopilotGuess: Codable, Sendable, Equatable {
  public var answer: AutopilotAnswer   // .yes or .no
  public var sure: Bool
  public var why: String
  public var source: String            // "native" | "ai"
}
public struct AutopilotScore: Codable, Sendable, Equatable {
  public var questionID: String
  public var subject: String
  public var guess: AutopilotAnswer
  public var answer: AutopilotAnswer
  public var right: Bool
  public var date: Date
  public var replayed: Bool?
}
extension AutopilotPolicy {
  public static let trustStreak = 5
  public static let maximumScores = 300
  /// Sorted "fact=value" strings for the risky facts present among items (spec Part 3 list).
  public static func risks(_ kind: AutopilotKind, _ items: [AutopilotItem]) -> [String]
  /// A stored question's risks: `risks` when set, otherwise from its match values plus caution text
  /// ("work only on this Mac" → saved=local, "unsaved changes" → changes=small, "running a server" → listening=yes).
  public static func risks(of question: AutopilotQuestion) -> Set<String>
  public static func trusted(_ subject: String, scores: [AutopilotScore]) -> Bool
  /// nil when there is nothing to go on. Owner answers only: questions with answeredBy == "bz" don't count.
  public static func guess(_ question: AutopilotQuestion, memory: AutopilotMemory) -> AutopilotGuess?
}
public enum AutopilotEval {
  public struct Step: Codable, Sendable, Equatable {
    public var questionID: String; public var date: Date; public var kind: AutopilotKind
    public var subject: String; public var owner: AutopilotAnswer; public var guess: AutopilotAnswer?
    public var outcome: String /* "settled" | "acted" | "asked" */; public var matched: Bool?; public var bytes: UInt64
  }
  public struct Summary: Codable, Sendable, Equatable {
    public var answers = 0, settled = 0, acted = 0, asked = 0, guesses = 0, right = 0
    public var wrongSettled = 0, wrongActed = 0; public var handledBytes: UInt64 = 0; public var lessons = 0
  }
  public struct Replay: Codable, Sendable, Equatable {
    public var steps: [Step]; public var summary: Summary; public var scores: [AutopilotScore]
  }
  public static func replay(_ questions: [AutopilotQuestion]) -> Replay
  /// Plain text for the CLI: one line per step, then the summary.
  public static func report(_ replay: Replay) -> String
}
```

**Algorithm.** The spec's Part 3 and 4.1 define it. The reference implementation is the spec's replay, and must be matched exactly:
- Replay only owner Yes/No answers, sorted by `answered`.
- For each question, let `g = generalize(match)`.
- **Settled:** a keep lesson of that kind overlaps `g` (guess no), or a burn lesson subsumes `g` (guess yes).
- **Otherwise:** `guess(q, running)`. The outcome is `acted` when sure, else `asked`. Only an asked question with a guess appends a score (`replayed: true`).
- After each step, `learn(lessonMatch(...))` into the running rules, and append `q` to the running answered questions.
- `handledBytes` sums the bytes of settled and acted steps.
- `lessons` is the final rule count.

**Guess** (spec 3.1):
- The lean comes from the same subject (`AutopilotPolicy.subject`). With no answers on the subject, it comes from the same kind. A tie, or no answers at all, means no guess.
- **Sure** requires all of:
  - `trusted(subject)`;
  - a lean of yes;
  - a yes on the subject before;
  - `risks(of: q)` ⊆ the union of `risks(of:)` over this subject's yes questions;
  - no keep rule of that kind and subject that overlaps `generalize(q.match)`.
- **why:**
  - "You said yes to N like these." when there are no risks;
  - "You said yes to N like these, including ones with {risk words}." otherwise.
  - Risk words: `saved=local` → "work only on this Mac", `changes=*` → "unsaved changes", `listening=yes` → "a running server", `*=unknown` → "things I couldn't check", `stale=today` / `idle=*` → "recent use". Join them with ", " and " and ".

- [ ] **Step 1: Write the failing tests** in `guessProof()`.
  - `risks(.worktree, [copy with saved=local and changes=small, copy with saved=unknown and changes=none])` equals `["changes=small", "saved=local", "saved=unknown"]`.
  - `trusted`:
    - 5 right scores → true;
    - 4 → false;
    - 5 right, then 1 wrong → false;
    - 1 wrong, then 5 right → true;
    - scores for another subject don't count.
  - `guess`:
    - no answered questions → nil;
    - two yes answers on `"worktree:"`, no scores → answer yes, not sure;
    - add 5 right scores for `"worktree:"`, with a question whose risks are all seen → sure;
    - the same question with risk `listening=yes`, never seen on a yes → not sure;
    - a keep rule overlapping the question → not sure;
    - a new program family with no answers on it but yes answers on another family → answer yes, not sure.
  - `replay` on `JSONDecoder().decode([AutopilotQuestion].self, from: Data(teachHistoryJSON.utf8))` gives a summary of `answers 27, settled 3, acted 7, asked 17, guesses 14, right 13, wrongSettled 0, wrongActed 0, handledBytes 126_591_930_368, lessons 17`, and has 14 scores.
  - `report(replay)` ends with a summary line containing "27 answers", "17 asked" and "13 of 14".
- [ ] **Step 2:** Run `--autopilot-learning`. Expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `--autopilot-learning`. Expect PASS.
- [ ] **Step 5:** Commit: "Autopilot: guess before asking, keep score, replay eval".

### Task 3: Migration to memory version 2, and lesson tallies

**Files:**
- Modify `AutopilotModels.swift`:
  - `AutopilotTally { count: Int; bytes: UInt64; undone: Int }`;
  - `AutopilotMemory.tallies: [String: AutopilotTally]`, default `[:]`;
  - `AutopilotMemory()` defaults to `version = 2`. A decoded file keeps its own version.
- Modify `AutopilotLessons.swift`: add `migrate`, `tally`, `lessonID`.
- Modify `AutopilotStore.swift`: migrate on load.
- Modify `AutopilotEngine.swift`: tally on burn and restore.

**Interfaces (produces):**

```swift
extension AutopilotPolicy {
  /// Version 1 → 2:
  /// - regeneralize operator rules whose question pins recency (new id; old id goes to formerIDs);
  /// - absorb with learn();
  /// - seed tallies from receipts;
  /// - seed scores from AutopilotEval.replay(memory.questions).scores.
  /// Version >= 2 returns its input unchanged.
  public static func migrate(_ memory: AutopilotMemory, receipts: [AutopilotReceipt]) -> AutopilotMemory
  /// The current lesson id for an authority "rule:<id>", where <id> is current or in some formerIDs.
  public static func lessonID(forAuthority authority: String, rules: [AutopilotRule]) -> String?
  /// outcome "burned": count+1, bytes += receipt.bytes. outcome "restored": also count, plus undone+1.
  /// Called once per receipt outcome.
  public static func tally(_ receipt: AutopilotReceipt, into memory: inout AutopilotMemory)
}
```

**Store:**
- `memory()` and `updateMemory` load through one private `loadMemory()`.
- When `loadMemory()` finds `version < 2`, it does the following under the lock:
  1. copies `memory.json` to `memory.v1.json`, unless that file already exists;
  2. migrates, using `receipts()`;
  3. saves.

**Engine:**
- Tally once where a burn receipt is recorded with outcome `burned`.
- In `.restore`, mark the restore as undone for the lesson. `migrate` counts a seeded `restored` receipt as burned and undone. Live, the burn was already tallied, so a restore only adds `undone`.

- [ ] **Step 1: Write the failing tests** in `migrationProof()`.
  - Build version-1 memory from the teach history the old way: one rule per Yes/No with `widen(q.match)`, `source .operator`, `questionID q.id`, `version 1`.
  - `migrate` then gives:
    - `version == 2`;
    - 17 rules;
    - the rules for q20, q21, q22, q24, q26, q28 and q29 byte-identical to before (JSON-encode each and compare);
    - 14 scores, all `replayed == true`.
  - Receipts:
    - two `burned` receipts by the old q04 rule (an absorbed one) and one `restored` by it give the surviving lesson `count 3, undone 1`;
    - a receipt authorized by `starter:...` or `ai:0.90` is not tallied.
  - Running `migrate` twice gives the same result.
  - Store: write a version-1 `memory.json` into a temp root, then read `memory()`:
    - the result is version 2;
    - `memory.v1.json` holds the original bytes;
    - a second `memory()` leaves `memory.v1.json` untouched (same bytes and same modification date).
- [ ] **Step 2:** Run. Expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `--autopilot-learning` and `--autopilot-sweep`. Expect PASS.
- [ ] **Step 5:** Commit: "Autopilot: migrate memory to lessons, keep per-lesson tallies".

### Task 4: The question card

**Files:**
- Create: `Sources/BurnCore/AutopilotCardText.swift`.
- Modify `AutopilotModels.swift`:
  - `AutopilotItem` gains `lastUsed: Date?` and `title: String?`;
  - new `AutopilotQuestionRow { title: String; subtitle: String?; bytes: UInt64; lastUsed: Date? }`;
  - `AutopilotQuestion` gains `rows: [AutopilotQuestionRow]?` and `newest: Date?`.
- Modify `AutopilotPolicy.swift`:
  - `question()` fills `rows` (top 3 by bytes), `newest` and `risks`;
  - `stalePhrases["today"] = "Used in the last day"`;
  - `card` is replaced (below).
- Modify `AutopilotEngine.swift`: `refreshQuestions` refreshes `rows`, `newest` and `risks` with count and bytes; `ask` fills them.
- Modify the item sources:
  - `AutopilotWorktrees.swift`: `lastUsed` = the `newest` date already computed there; `title` = the chat title when a chat is matched, else `humanize(branch:)` of the branch.
  - `AutopilotProcesses.swift`: `lastUsed` = when it was last busy, or its start; `title` = the program name.
  - `AutopilotDisk.swift`: `lastUsed` = the folder's last change.

**Interfaces (produces):**

```swift
public struct AutopilotCardRow: Equatable, Sendable { public var title: String; public var subtitle: String?; public var when: String }
// AutopilotCard gains: public var line: String?; public var rows: [AutopilotCardRow]; public var more: Int
extension AutopilotPolicy {
  public static func card(_ question: AutopilotQuestion, now: Date = Date(), calendar: Calendar = .current) -> AutopilotCard
  static func when(_ kind: AutopilotKind, newest: Date?, match: [String: [String]], now: Date, calendar: Calendar) -> String
  static func clock(_ date: Date, now: Date, calendar: Calendar) -> String
  static func idleText(_ date: Date, now: Date) -> String
  static func safeLine(_ kind: AutopilotKind, _ items: [AutopilotItem]) -> String?
  public static func humanize(branch: String) -> String?
}
```

**Exact copy:**
- **Headline:** `"Burn \(count) \(noun) \(when)?"`.
  - Nouns for copies: "copy"/"copies", or "copy of api"/"copies of api" when the match names one repo. Programs and folders use the existing nouns.
  - `when` for copies and folders, by calendar days between `startOfDay(newest)` and `startOfDay(now)`:

    | Days | Phrase |
    | --- | --- |
    | 0 | "you used today" |
    | 1 | "you used yesterday" |
    | 2–6 | "untouched since Monday" (full weekday name) |
    | 7–13 | "untouched for a week" |
    | 14–29 | "untouched for 2 weeks" (whole weeks) |
    | 30–59 | "untouched for a month" |
    | 60–89 | "untouched for 2 months" |
    | 90+ | "untouched for 3+ months" |

  - `when` for programs: "idle for 40 minutes", "idle for an hour", "idle for 3 hours" (under 48 hours), "idle for 2 days".
  - When `newest` is nil, use the stale-bucket phrase of the match, lowercased: "unused since yesterday", "used in the last day".
- **Rows:**
  - `clock`: "today 9 am", "yesterday 5 pm", "Mon 5 pm" (2–6 days), "Oct 12" (same year), "Oct 12, 2025". Hours use a 12-hour clock with "am"/"pm" and no minutes. Build the strings from calendar components, not locale formatters.
  - Program rows use `idleText` on the right: "idle 40 min", "idle 3 h", "idle 2 d".
  - Program subtitle: "started by Codex" / "Claude" / "Cursor" from `agent`. Copy and folder subtitle: the `repo` fact, unless it is "none" or empty.
  - `more = count - rows.count`, never negative.
- **Safe line:**
  - Copies: "Their work is on GitHub." (all pushed or merged), "Nothing is unsaved." (all changes none), "Their chats are finished." (all thread ended), joined with spaces. A single item reads "Its work is on GitHub.", "Nothing in it is unsaved." and "Its chat is finished."
  - Programs: "None is serving anything." / "It isn't serving anything." (all listening no) and "Their apps are gone." / "Its app is gone." (all orphaned yes).
  - Folders: nil.
  - The question stores the line computed when it is asked or refreshed: add `line: String?` to `AutopilotQuestion`.
- **`humanize`:** keep the text after the last `/`, turn `-` and `_` into spaces, collapse runs of spaces, and return nil when empty. `"codex/fix-login-selector"` → `"fix login selector"`.

- [ ] **Step 1: Write the failing tests** in `cardProof()`. Use `calendar = Calendar(identifier: .gregorian)` with `timeZone = UTC`, and `now = 2026-11-03 09:39 UTC` (a Tuesday).
  - A question of 5 copies: newest Mon 2026-11-02 19:00; rows (sorted by bytes) "fix login selector"/"web-app" Mon 17:00, then 13:00 and 19:00; all pushed or merged with no changes.
    - Expected: headline "Burn 5 copies you used yesterday?", line "Their work is on GitHub. Nothing is unsaved.", `rows[0].when` "yesterday 5 pm", `more` 2, frees "Frees 2.8 GB" (for `bytes 2_753_368_064`).
  - Calendar edges:
    - newest 00:10 today → "you used today";
    - 23:50 yesterday → "you used yesterday";
    - 6 days ago → "untouched since Wednesday";
    - 7 days ago → "untouched for a week";
    - 95 days ago → "untouched for 3+ months".
  - `newest` nil with match stale `["day"]` → headline ends "unused since yesterday?".
  - A program: `newest` 3 hours ago → "idle for 3 hours"; a row "idle 3 h".
  - `humanize("codex/fix-login-selector")` is "fix login selector", and `humanize("/")` is nil.
  - `stalePhrases["today"]` is "Used in the last day".
- [ ] **Step 2:** Run. Expect FAIL.
- [ ] **Step 3:** Implement. Existing card assertions in `Proof/AutopilotPolicyTests.swift` may need updating, but only where the new headline or noun changes them. Show those diffs in the commit message body.
- [ ] **Step 4:** Run `--autopilot-learning`, `--autopilot-policy`, `--autopilot-worktrees`, `--autopilot-disk` and `--autopilot-process`. Expect PASS.
- [ ] **Step 5:** Commit: "Autopilot: question cards name the things and when they were used".

### Task 5: Lesson groups and progress (what Settings shows)

**Files:**
- Modify `AutopilotLessons.swift`: add `lessonGroups`.
- Modify `AutopilotGuess.swift`: add `progress`.
- Modify `AutopilotModels.swift`:
  - new types `AutopilotLessonGroup` and `AutopilotProgress`;
  - `AutopilotSnapshot` gains `lessons: [AutopilotLessonGroup]` and `progress: AutopilotProgress`, both defaulting to empty.
- Modify `AutopilotEngine.snapshot()` to fill both.

**Interfaces (produces):**

```swift
public struct AutopilotLessonGroup: Codable, Sendable, Equatable, Identifiable {
  public var id: String              // e.g. "worktree:burn:day", "worktree:burn:projects", "process:burn", "rule:<id>" for keeps
  public var kind: AutopilotKind
  public var verdict: AutopilotVerdict
  public var sentence: String
  public var evidence: String
  public var ruleIDs: [String]
}
public struct AutopilotProgress: Codable, Sendable, Equatable { public var lines: [String] = [] }
extension AutopilotPolicy {
  public static func lessonGroups(_ memory: AutopilotMemory) -> [AutopilotLessonGroup]
  public static func progress(_ memory: AutopilotMemory, receipts: [AutopilotReceipt], totalBurns: Int?, now: Date) -> AutopilotProgress
}
```

**Groups** (spec 2.4), operator lessons only (starter rules are listed separately, as today):

- **Copies to burn that pin recency:** grouped by floor, the first stale value in safety order.
  - Floor today: "Copies are done the same day{once}{even}." Other floors: "Copies nobody touched {since yesterday | for a week | for a month | for 3 months} are done{once}{even}."
  - `{once}`: " once their work is on GitHub" when every lesson in the group requires saved ⊆ {pushed, merged}, plus " and nothing is unsaved" when every lesson requires changes == [none]. Use "once nothing is unsaved" when only the latter holds.
  - `{even}`: a comma, then "even with" and the risky values any lesson covers, in this order: "unsaved work" (changes small or large), "work only on this Mac" (saved local), "work I couldn't check" (saved or changes unknown).
    - A lesson with no constraint on a fact covers all of that fact's values.
    - Join two with " or ", and three as "A, B, or C".
- **Copies to burn that don't pin recency:** one group with id "worktree:burn:projects".
  - "In p1, p2 and N more projects, copies are done at any age{once}." Project names come from the lessons' `repo` values, ordered by how many lessons name them, then alphabetically. Name at most 2. With no repo values, write "For some projects".
  - `{once}` is " once their work is on GitHub and no chat is using them". Build it from the parts every lesson requires: saved ⊆ {pushed, merged}, and thread ⊆ {none, ended}.
- **Programs to burn:** one group per kind: "Leftover programs can stop once idle: Node after 10 minutes, Java helpers after an hour."
  - Families are ordered by floor, then by family key.
  - Names: node → "Node", java → "Java helpers", python → "Python", ruby → "Ruby", browser → "Robot browsers", build → "Build tools", shell → "Scripts".
  - Floors: active → "right away", 10m → "after 10 minutes", 1h → "after an hour", 6h → "after 6 hours", 1d → "after a day".
- **Folders to burn:** grouped by floor: "Rebuildable folders untouched since yesterday can go: tool caches, node_modules, build folders."
  - Order by tally bytes, then name. Names: node_modules → "node_modules", build-output → "build folders", xcode-derived → "Xcode build folders", package-cache → "tool caches", python-env → "Python environments".
- **Keeps:** one group per rule.
  - Programs: "{Name} serving a port stay while idle less than {next floor}." Example: "Java helpers serving a port stay while idle less than an hour." Drop "serving a port" when listening isn't [yes].
  - Other keeps: "{Noun plural, capitalized} stay: {facts(kind, match) joined with \", \"}."
- **Evidence:** "From {N} answer(s)" + " and {M} of my own call(s)" (when M > 0) + kind part + undone part.
  - N counts owner-answered questions in `questionIDs` that still exist in memory. M counts those with `answeredBy == "bz"`.
  - Kind part, from the group's summed tallies: copies " · burned {count} copies, {roughly(bytes)}", programs " · stopped {count} programs, {roughly(bytes)} of memory", folders " · deleted {count} folders, {roughly(bytes)}". Keeps have no kind part.
  - Undone part, copies only: " · undone {undone}".
  - Use the singular for 1.

**Progress lines**, in order, each only when it has something to say:
1. With n ≥ 1 owner-scored scores among the last 10: "I guessed {r} of your last {n} answers right." When n is 1: "I guessed your last answer right." or "I missed your last answer."
2. "This week: {q} question(s), {roughly(bytes)} burned on my own." plus " Last week: {q2} question(s), {roughly(bytes2)}." when last week had any.
   - Questions are those with `asked` in the window and `answeredBy != "bz"`.
   - Bytes come from `burned` receipts in the window whose authority isn't "operator".
   - A week is now − 7 days; last week is the 7 days before that.
3. "You undid {u} of my {b} burns." `u` counts restored receipts. `b` is `totalBurns`, or, when nil, the `burned` plus `restored` receipts.
4. With 5 or more owner answers: "Replaying your {A} answers, I'd have asked {asked} and handled the other {settled+acted} on my own the way you would have."
   - When `wrongSettled + wrongActed > 0`, it ends instead with "…on my own, {k} of them not the way you would have."

- [ ] **Step 1: Write the failing tests** in `groupsProof()`. Use the migrated teach-history memory from Task 3.
  - `lessonGroups` contains, among others, these sentences:
    - "Copies nobody touched since yesterday are done, even with unsaved work, work only on this Mac, or work I couldn't check."
    - "Copies are done the same day once their work is on GitHub and nothing is unsaved."
    - "Leftover programs can stop once idle: Node after 10 minutes, Java helpers after an hour."
    - "Java helpers serving a port stay while idle less than an hour."
    - a folders sentence starting "Rebuildable folders untouched since yesterday can go: "
    - a "worktree:burn:projects" sentence starting "In project-"
  - Every operator rule id appears in exactly one group.
  - The evidence for the java keep group is "From 1 answer".
  - `progress` on that memory, with no receipts and `now` just after the last answer, gives:
    - a first line "I guessed 9 of your last 10 answers right." The 14 replayed scores are right except the 7th, so the last 10 hold one miss;
    - a line "Replaying your 27 answers, I'd have asked 17 and handled the other 10 on my own the way you would have."
  - There are no "%" characters anywhere.
- [ ] **Step 2:** Run. Expect FAIL.
- [ ] **Step 3:** Implement. `snapshot()` calls both. `totalBurns` comes from the impact tally the engine already keeps (`AutopilotImpact`), when available.
- [ ] **Step 4:** Run. Expect PASS.
- [ ] **Step 5:** Commit: "Autopilot: lessons read as plain sentences, How I'm doing counts".

### Task 6: Act, then tell

**Files:**
- Modify `AutopilotModels.swift`:
  - `AutopilotTell { id: String; questionID: String; ruleID: String; kind: AutopilotKind; count: Int; bytes: UInt64; rows: [AutopilotQuestionRow]; why: String; date: Date; state: String /* "open" | "good" | "undone" | "expired" */; note: String? }`;
  - `AutopilotMemory` gains `tells: [AutopilotTell]` (default `[]`) and `actsOnItsOwn: Bool` (default true);
  - `AutopilotSnapshot.tells` holds the open ones;
  - new commands `tellGood(id: String)`, `tellUndo(id: String)`, `setActsOnItsOwn(Bool)` and `forgetLesson(ruleIDs: [String])`.
- Modify `AutopilotEngine.swift`.
- Test: engine-level, in `Proof/AutopilotLearningTests.swift`. Reuse the temp-root engine and fake-source helpers from `Proof/AutopilotSweepTests.swift`; make them internal or shared if needed.

**Behavior** (spec 3.2 and 3.4):
- `refreshQuestions`: for each newly proposed question:
  - set `guess = AutopilotPolicy.guess(q, memory)`;
  - when `memory.actsOnItsOwn && guess?.sure == true`, call `act(q)` instead of appending it.
- `act(q)` runs inside the same memory update:
  1. append `q` with `answer .yes`, `answered now`, `answeredBy "bz"`;
  2. `learn` its lesson;
  3. append an open tell, with `why = guess.why`.
- After the update, burn in the background like an answer.
- **`.answer` with yes/no** on a question with a `guess`: append a score (`subject`, `guess.answer`, `answer`, `right`, `date`) and trim to `maximumScores`.
- **`.tellGood`:** state "good"; append a right score for the tell's subject.
- **`.tellUndo`:**
  1. For each receipt with outcome `burned`, authority `"rule:" + tell.ruleID` (or a former id) and `date >= tell.date` that has a `restore`, run the existing restore path.
  2. Replace the lesson with a keep: `lessonMatch(q.kind, q.match, verdict: .keep)`, through `learn`.
  3. Set the question's answer to `.no` and `answeredBy` to nil.
  4. Append a wrong score.
  5. Set the state to "undone".
  6. Set `note` when some burns couldn't be restored: "Stopped programs and deleted folders can't come back; I'll ask next time." or the restore error text.
- **On each `refreshQuestions`:** open tells older than 7 days become "expired".
- **`.forgetLesson`:** `forgetRule` for each id.
- **`.setActsOnItsOwn`:** set the flag.

- [ ] **Step 1: Write the failing tests** in `tellProof()`.
  - Answering a question whose guess is yes with No appends one score with `right == false`.
  - Trusted acts:
    - Setup: memory with two owner yes answers on copies (risks `saved=local`, `changes=small`), 5 right scores on "worktree:", and a catalog with 3 unsure copies (`stale week`, `saved local`, 1.2 GB in total).
    - After a tick:
      - there is no open question about copies;
      - one open tell has count 3 and bytes 1.2 GB;
      - the question is stored as answered yes by "bz";
      - fake sources show 3 copy burns;
      - the tell's rule exists.
  - `actsOnItsOwn = false` with the same setup gives an open question with `guess.sure == true` and no tell.
  - `tellGood` gives state "good" and a right score.
  - `tellUndo`:
    - fake sources record 3 restores;
    - the rule is now a keep;
    - the question's answer is no;
    - `trusted("worktree:")` is false;
    - the state is "undone";
    - the next tick opens a question rather than acting.
  - The same `tellUndo` test with a program tell: 0 restores, state "undone", a note mentioning "can't come back".
  - A tell dated 8 days ago is "expired" after a tick.
- [ ] **Step 2:** Run. Expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `--autopilot-learning`, `--autopilot-sweep` and `--autopilot-worktrees`. Expect PASS.
- [ ] **Step 5:** Commit: "Autopilot: act on what it's sure of, then tell, with Undo".

### Task 7: The AI, MCP and CLI use lessons, guesses and the eval

**Files:**
- `Sources/BurnCore/AutopilotEngine.swift`: `catalogPage` and `ask`.
- `Sources/BurnCore/AutopilotSweep.swift`: the prompt.
- `Sources/BurnMCP/AutopilotTools.swift`: the `autopilot_ask` schema and the catalog output.
- `Sources/BurnCLI/main.swift`: `autopilot eval`.
- Tests in `Proof/AutopilotSweepTests.swift` and `Proof/AutopilotLearningTests.swift`.

**Interfaces:**
- `AutopilotCatalogPage` gains `lessons: [AutopilotCatalogLesson]`, one per lesson group:

  ```swift
  public struct AutopilotCatalogLesson: Codable, Sendable { public var ids: [String]; public var sentence: String; public var kind: AutopilotKind; public var verdict: AutopilotVerdict; public var matches: [[String: [String]]]; public var answers: Int; public var burned: Int; public var bytes: UInt64; public var undone: Int }
  ```

- `ask(_ question:, replacing:, guess: AutopilotAnswer? = nil)`. After the existing checks, which stay unchanged:
  - set `risks`, `rows`, `newest` and `line` from the matching items;
  - set `guess`: BZ's own guess, with `answer` replaced by the AI's guess and `source "ai"` when one is given, and `sure` only when BZ's is sure and the AI's guess is yes;
  - when sure and `actsOnItsOwn`, act exactly as in Task 6 and return the stored question;
  - the MCP reply then says: "I was sure you'd say yes, so I burned them and will tell the owner."
- MCP `guess`:
  - an optional string;
  - "yes" and "no" are accepted;
  - any other value is ignored, not refused.
- Prompt changes:
  - Add a paragraph before the procedure: "The owner's lessons (catalog `lessons`) are their intent and your brief: judge unsure items by why they burn or keep things, ask only where no lesson reaches, never contradict one."
  - Step 5 adds: "Include `guess` (yes or no): what you think the owner will answer."
- CLI:
  - `burnzombies autopilot eval [--json]` reads memory through the same path as `autopilot` and `catalog`;
  - it prints `AutopilotEval.report(replay)`, or the JSON-encoded `Replay`.

- [ ] **Step 1: Write the failing tests.**
  - `catalogPage` includes `lessons` whose `ids` cover every operator rule.
  - `ask` with `guess: .no` on an otherwise valid question stores `guess.source == "ai"` and `guess.answer == .no`.
  - `ask` with a pattern lacking recency is still refused, with the existing message.
  - The prompt string contains "lessons" and "guess".
  - `report` of the teach-history replay prints 27 step lines plus a summary.
  - The MCP schema for ask lists `guess`.
- [ ] **Step 2:** Run `--autopilot-sweep` and `--autopilot-learning`. Expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `--autopilot-sweep` and `--autopilot-learning`, and `scripts/test-mcp.py` if it covers tool schemas. Expect PASS.
- [ ] **Step 5:** Commit: "Autopilot: the AI works from lessons and guesses; autopilot eval".

### Task 8: The app (TeachView, Settings, demo, UI proof)

**Files:**
- `Sources/BurnApp/TeachView.swift`
- `Sources/BurnApp/AutopilotSettingsView.swift`
- `Sources/BurnCore/Demo.swift`: demo snapshot with rows, a tell, lessons and progress.
- The `--autopilot-proof` renderer in `Sources/BurnApp/main.swift`.

**Behavior:**
- **Question card:**
  - headline, then frees, then the `line` (secondary), then cautions;
  - rows: title bold, subtitle dim, `when` right-aligned;
  - "+ N more", then the note, then the existing buttons with the same ids;
  - follow the existing card styling and the spec's mockup order.
- **Tell card,** shown before questions:
  - the headline "Burned {count} {noun} on my own.";
  - the frees-style line "{roughly(bytes)}";
  - rows, then `why` with the prefix "You'd have said yes: ";
  - an optional `note`;
  - buttons "Good call" (id `teach-good`) and "Undo" (id `teach-undo`).
- **Confirmation after a Yes/No:** "Got it!" plus the sentence of the lesson group that now holds the new rule (find the group whose `ruleIDs` contains the rule for that question), plus the existing "I'll handle…" text.
- **Settings, What BZ has learned:**
  - lesson groups, each with its sentence, evidence (secondary) and a Forget button (`forgetLesson(group.ruleIDs)`);
  - starter rules listed as now.
- **Settings, How I'm doing:** a new section with the progress lines.
- **Toggle** "Act on its own when sure" → `setActsOnItsOwn`.

- [ ] **Step 1:** Extend the UI proof so it writes PNGs for a question card with rows, a tell card, and Settings with lessons and How I'm doing, using the demo snapshot.
- [ ] **Step 2:** `swift build` and run the UI proof (`.build/debug/BurnZombiesApp --autopilot-proof <tmp dir>`, or the name the build gives). Open the PNGs and check the text matches the copy above, with nothing clipped at the default window size.
- [ ] **Step 3:** Run `--autopilot-learning` and `--autopilot-policy`. Expect PASS.
- [ ] **Step 4:** Commit: "Autopilot app: cards with rows, tells, lessons and How I'm doing".

### Task 9: Simulated owners, docs, build number, full suite

**Files:**
- `Proof/AutopilotLearningTests.swift`: `simulatedOwnersProof()`.
- `docs/AUTOPILOT.md`.
- `Sources/BurnCore/BuildIdentity.swift` and `scripts/build-app.sh`: bump the build number the way PR #39 did (`git show d44ba79 -- Sources/BurnCore/BuildIdentity.swift scripts/build-app.sh`).

**Simulated owners:**
- A deterministic synthetic catalog per round, driven through the engine with fake sources as in Task 6.
- Each round adds new items of three kinds:
  - copies with varied `saved`, `changes`, `stale`, `repo` and `place`;
  - Node and Java programs with varied `idle` and `listening`;
  - node_modules and package-cache folders with varied `stale`.
- Run 8 rounds. Each round: tick, then answer every open question by the persona's policy, applied to every member: yes only when the persona would burn all of them, otherwise no.
- Personas:
  - **liberal:** burns copies that are pushed or merged, or that have stale ≥ day; burns programs idle ≥ 10m; burns folders with stale ≥ day.
  - **cautious:** like liberal, but keeps any copy whose `changes` aren't none.
  - **server keeper:** like liberal, but keeps programs with listening yes.
- For each persona, assert:
  - no burn receipt, tells included, is for an item the persona would keep;
  - the number of questions in rounds 5–8 is less than in rounds 1–4;
  - tells exist by round 8 for the liberal persona;
  - after a scripted Undo in round 6 (liberal), round 7 asks rather than acts on that subject.

- [ ] **Step 1:** Write `simulatedOwnersProof()` and run it. It should pass on the implementation from Tasks 1–8. If it fails, fix the implementation, not the persona.
- [ ] **Step 2:** Update `docs/AUTOPILOT.md`:
  - Training: cards with rows; lessons; guess, trust, and act then tell; the toggle.
  - New "How I'm doing" section, and `autopilot eval` in Command line.
  - Undo: tells.
  - Keep the plain voice and no percentages.
- [ ] **Step 3:** Bump the build number.
- [ ] **Step 4:** Run `caffeinate -i -m scripts/test.sh --integration`. Expect `EXIT 0` and "All proof groups completed; 0 failures".
- [ ] **Step 5:** Commit: "Autopilot: simulated-owner proof, docs, build N".
