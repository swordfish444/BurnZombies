# BurnZombies Autopilot — design

Status: approved for build (operator asked for plan → build → test → merge end to end, 2026-11-02).

## Why

BurnZombies observes a lot and burns almost nothing. On the operator's Mac (2026-11-02):

- 1,670 processes, 1,000 linked worktrees using 233 GB (400 untouched for 30+ days), 64 large disk branches.
- 0 zombies burned, 0 worktrees retired by automation, 0 bytes reclaimed. Lifetime review spend ≈ $1.16 for nothing.

Root causes, in order of impact:

1. **Hunts are dead.** Full Disk Access is bound to the app's executable digest, so every rebuild silently sets `canScan=false` and every hunt (even a manual one) returns without doing anything (`MachineReview.swift:273`). One 180-second reviewer timeout paused reviews permanently (Oct 30) until a human presses Resume. Default cadence is 4 hours.
2. **Autonomy is forbidden by construction.** A process can only be signalled with a *released owner claim*, *passive completion evidence* or a *cleanup lease* (`Monitor.swift:1506-1521`). Real orphans never have any of these, so they never even reach the reviewer queue (`ReviewEconomy.swift:20-65`). Any open socket, any binary inside an `.app` bundle, any live child, or a missing per-revision human "Approve once" also refuses the burn. The reviewer prompt forbids inferring abandonment from orphaning, idleness or age. Worktrees need a human "Adopt, archive and retire once" per exact revision, and ~30% are refused outright (submodules, shallow history, LFS) because the encrypted recovery format cannot hold them. Disk needs an exact user regeneration rule and is in "recommend" mode.
3. **Nothing generalizes.** Decisions bind to one exact revision. Rules are hyper-specific (one Gradle home), shadow-only by default, capped and canary-gated. Process proposals have no workflow key at all, so a Keep or Approve never teaches anything.
4. **The UI is technical and does not scale.** 915 findings in one flat list, each needing an individual decision phrased in safety jargon ("one-item canary pending", "Reconcile saved recovery feedback").
5. **The AI is starved.** 8 turns, 180 s, one or two items per run, no way to look at what a process actually is.

## Goal

BurnZombies runs on autopilot every 15 minutes. An AI (headless Claude Code by default) catalogs processes, worktrees, agent threads and junk folders, decides what is safe, burns it, and verifies the result. When it is genuinely unsure it asks the operator a tiny yes/no question about a *pattern*, not an item. Each answer becomes a rule. After about a dozen answers, BurnZombies handles nearly everything on its own.

## Non-goals and anti-goals

- No rewrite of the native observers (process sampler, worktree discovery, disk discovery). Autopilot reads them.
- No SIGKILL, process-group kill, reboot, `sudo`, credential changes, or `git gc`/branch deletion.
- **Anti-goal:** losing work. A burned worktree must always be restorable. An active agent session's helpers must never be touched.
- **Anti-goal:** nagging. At most three open questions at a time; one notification per batch of new questions.
- **Anti-goal:** a second hard-coded classifier pretending to be intelligence. Native code supplies facts, a small set of explicit starter rules, and hard rails. Judgment, labels, explanations, investigation and question-writing are the AI's job.

## The loop

Every 15 minutes (configurable 5 min–4 h):

1. **Catalog (native, no tokens).** Snapshot every candidate with a small fact vector (below). Agent threads (Claude Code and Codex sessions) are indexed so processes and worktrees know whether the chat that made them is alive.
2. **Policy (native, deterministic).** Each item resolves to `protected`, `burn`, `keep` or `unsure` (contract below).
3. **Burn what is authorized (native).** Items authorized by an operator rule or a starter rule are burned right away through the executors. This also runs when the AI is unavailable.
4. **AI sweep (only when something new needs judgment).** Headless Claude Code receives the catalog through MCP tools, investigates unsure items with read-only inspection tools, records verdicts with confidence and plain-English explanations, burns what it is confident about (natively re-checked), and turns the most valuable unsure clusters into at most three training questions. It runs when there are new unsure items, new answers, or 4 hours have passed; otherwise the tick costs no tokens.
5. **Verify and account.** Process exits are verified; worktree removals are verified (directory gone, safety ref present); disk bytes are measured before removal. Receipts feed the existing Impact counters.

Failures never pause the loop permanently. Timeouts and errors back off (15 → 30 → 60 → 120 min cap). Login/usage errors back off for an hour and show a quiet banner; native rule-based burning keeps running.

## Facts

Each item carries `facts: [String: String]` with small categorical values so rules can match exactly. Values are the same strings in rules, questions and UI.

Processes:

| fact | values |
| --- | --- |
| `kind` | `process` |
| `program` | executable basename, lowercased (`node`, `python3.12`, `chromium`) |
| `family` | `node`, `python`, `ruby`, `java`, `browser`, `build`, `shell`, `other` |
| `orphaned` | `yes` (parent is launchd and its process-group leader is gone, or reparenting was observed) / `no` |
| `thread` | `live` (descendant of, or cwd under, a live agent session) / `ended` / `none` |
| `agent` | `claude`, `codex`, `cursor`, `none` (which harness launched it, when known) |
| `idle` | `active`, `10m`, `1h`, `6h`, `1d` (CPU-idle duration bucket from samples) |
| `listening` | `yes` / `no` (owns a listening socket) |
| `memory` | `small` (<100 MB), `medium` (<1 GB), `large` |
| `repo` | repository name of its working directory, or `none` |

Worktrees:

| fact | values |
| --- | --- |
| `kind` | `worktree` |
| `place` | `patrol6`, `codex`, `claude`, `conductor`, `sibling`, `other` (where it lives / which tool made it) |
| `repo` | repository name |
| `saved` | `merged` (HEAD reachable from the default branch), `pushed` (reachable from any remote ref), `local` (commits exist only here), `unknown` |
| `changes` | `none`, `small` (≤20 files), `large` |
| `stale` | `today`, `week`, `month`, `older` (last file change or agent activity, whichever is newer) |
| `thread` | `live` / `ended` / `none` |
| `inUse` | `yes` / `no` / `unknown` (a process has its cwd or open files inside) |
| `size` | `small` (<100 MB), `medium` (<1 GB), `large` |

Junk folders:

| fact | values |
| --- | --- |
| `kind` | `disk` |
| `folder` | `node_modules`, `build-output`, `xcode-derived`, `package-cache`, `python-env`, `other` |
| `home` | `stale-worktree`, `repo`, `global-cache` |
| `stale` | as above |
| `size` | `medium` (<1 GB), `large` (<10 GB), `huge` |

## Autonomy contract

`authority(item)` is evaluated natively, in this order, every time an item is about to be burned:

1. **Hard rails fail → `protected`.** Never burned, never asked about.
2. **An operator `keep` rule matches → `keep`.** Keep always wins.
3. **An operator `burn` rule matches → `burn`.**
4. **A starter rule matches → `burn`** (the operator can switch each starter rule off).
5. **The AI recorded `burn` with confidence ≥ 0.85 for this exact item revision, and the item is AI-eligible → `burn`.** AI-eligible means:
   - a process that is `orphaned=yes` or `thread=ended`, and `listening=no`;
   - a worktree with `place` not `codex`/`claude`/`conductor` (owner-managed ones need an operator rule), and `inUse=no`, `thread≠live`;
   - a junk folder with `folder≠other`.
6. **Otherwise → `unsure`**, which feeds training questions.

A rule matches when every fact in its pattern equals the item's fact. More specific rules are not needed for correctness because `keep` always wins.

### Starter rules (on by default, shown in Settings)

- **S1 leftover programs:** `kind=process, orphaned=yes, thread≠live, idle∈{6h,1d}, listening=no`.
- **S2 finished copies:** `kind=worktree, saved=merged, changes=none, stale∈{month,older}, inUse=no, thread≠live`, place not owner-managed.
- **S3 rebuildable junk in old copies:** `kind=disk, home=stale-worktree, folder∈{node_modules,build-output,xcode-derived}`.

## Training questions

- Unsure items are clustered natively by every 2–3 fact subset; a cluster's value is `count + bytes/1 GB`. The best non-overlapping clusters become question candidates. The AI may rewrite the wording and choose a better pattern with `autopilot_ask`.
- At most three questions are open. The UI shows one big card at a time.
- Wording is for a ten-year-old: "Can I burn old copies of your projects that are already saved on GitHub?" with "I found 212 of these, using 48 GB" and up to three example names.
- **Yes** creates a `burn` rule; **No** creates a `keep` rule; **Skip** hides the question for a day. Answering re-evaluates the catalog immediately and burns newly authorized items.
- **Training progress** = `min(1, answers / 12)`. **Autopilot coverage** = share of current non-protected items decided without asking. The UI shows both.

## Execution rails

### Processes (SIGTERM only)

Kept from today: same user, pid > 1, not BurnZombies or the caller's ancestry, not user-protected or snoozed, not an OS zombie, not `/System`, `/usr/libexec`, `/usr/sbin`, not a named harness/system process, exact identity (boot, pid, start time, path) re-checked immediately before `kill`.

Changed for autopilot:

- Binaries inside `.app` bundles are protected only when the bundle lives in `/Applications`, `~/Applications`, `/System` or `/Library`. Automation browsers (Playwright/Puppeteer caches, `node_modules`, temporary folders) become ordinary candidates.
- Open sockets are a fact (`listening`), not a refusal.
- Live children are burned with their parent (deepest first) when each child passes the same rails; otherwise the burn is refused.
- Helpers of a **live** agent session are protected (`thread=live`).
- No Full Disk Access requirement for processes.

### Worktrees (always restorable)

1. Re-inspect: linked worktree (not main, not bare), not locked, no rebase/merge in progress, `bz_path_in_use` reports no consumer, no live agent session with its cwd inside.
2. Submodules: refuse if any submodule is dirty or its checked-out commit is not reachable from the submodule's remotes.
3. Snapshot: write a commit containing HEAD's tree plus all tracked changes, all untracked files and small (≤5 MB each, ≤100 MB total) ignored files outside rebuildable folders, using a temporary index; store it at `refs/burnzombies/retired/<id>` in the repository. When the worktree is clean, the ref points at HEAD. Verify the ref resolves before removal.
4. `git worktree remove --force <path>`; verify the directory and registration are gone.
5. Receipt: bytes freed, ref, original branch and HEAD. **Restore** recreates the worktree at its original path from the ref and turns the snapshot back into uncommitted changes.

This handles shallow clones and LFS (content is stored in the snapshot) and does not need the Keychain.

### Junk folders

- Only folders whose `folder` fact is a known rebuildable kind are removed autonomously; anything else needs an operator `burn` rule and goes to the Trash instead of being deleted.
- Never inside iCloud Drive, Mail, Messages, Photos libraries, `.ssh`, `.gnupg`, Keychains, or outside the home folder.
- `bz_path_in_use` must report no consumer. Bytes are measured before removal.

## AI sweep

- Harness: headless Claude Code (`claude -p`), default model `sonnet`, 10-minute timeout, MCP server `burnzombies` in autopilot mode, built-in tools limited to `Read,Glob,Grep`, hooks disabled, no session persistence. Codex remains selectable.
- MCP tools (autopilot mode):
  - `autopilot_catalog` — policy summary, rules, open questions, items grouped by status (unsure first), paginated.
  - `autopilot_inspect` — live detail for one item: process command line (live only, never stored), cwd, parent chain, children, listening ports, owning thread; worktree status, delivery state, recent commits, last activity; folder contents summary.
  - `autopilot_decide` — record `{id, verdict: burn|keep|unsure, confidence, label, why}` for items.
  - `autopilot_burn` — burn items; every item is re-authorized and re-checked natively.
  - `autopilot_ask` — open a training question for a fact pattern with kid-simple wording.
  - `autopilot_report` — a two-sentence summary for the activity log.
- The prompt states the goal (burn as much as is safely possible), the procedure, the contract above, and the writing style. Refusals are final for the sweep.

## Full Disk Access

Autopilot no longer waits for it. Leftover programs need no special access. The worktree inventory and protected folders still follow the existing explicit setup (macOS ties the grant to the app's code signature, so an ad-hoc rebuild must be re-allowed). Without access, Autopilot keeps working from the last inventory and the UI shows a quiet coverage note with the existing Allow button.

## UI

Vocabulary: **zombies** (leftover programs), **old copies** (worktrees), **junk folders** (disk); actions **Burn** and **Keep**; statuses **Will burn**, **Needs you**, **Keeping**, **Burned**, **Protected**.

- **Menu:** autopilot status line ("Autopilot on · next sweep in 12 min"), the existing counters, and an orange "BZ has 3 quick questions" button when questions are open.
- **Teach BZ window:** one big question card, three example chips, giant **Yes, burn them** / **No, keep them** buttons, a small Skip link, and a progress ring ("BZ is 64% trained"). After an answer: "Got it! I'll burn these on my own from now on."
- **Findings window:** one summary sentence ("I found 1,014 things. I'll burn 812 on my own, I'm keeping 199, and I need your help with 3."), status tabs, three friendly sections, and a clean detail card: **What is it?**, **Why I think so**, **If I burn it**, Burn now / Keep / Restore, and a collapsed **Technical details** disclosure for paths, PIDs and branches.
- **Settings:** autopilot on/off, sweep frequency, the AI model, "What BZ has learned" (rules in plain English with Forget), starter rules with switches, and "Start training over". The previous Worktrees and Findings windows stay reachable under Advanced.

## Storage

JSON documents under `~/Library/Application Support/BurnZombies/autopilot/` through the existing bounded `Store` (0600 files, atomic writes, size limits): `catalog.json` (rewritten each tick), `memory.json` (rules, questions, AI decisions), `receipts.json` (last 500), `sweep.json` (schedule and backoff).

## Testing

- Pure logic: rule matching, keep-wins, starter rules, AI eligibility, clustering, question ranking, progress and coverage.
- Executors against sacrificial fixtures only: orphaned `sleep` trees, a protected-path refusal, listening servers; temporary repositories with clean/merged, dirty, untracked, ignored, submodule, locked and in-use worktrees, plus restore round-trips; rebuildable folders with and without an open file.
- Sweep orchestration with a mock harness: native rule burns without AI, backoff instead of pause, AI skipped when nothing changed.
- Real headless Claude Code sweep in an isolated home whose catalog is scoped to fixtures only.
- Offscreen renders of the menu, Teach BZ and Findings windows, with text checks.
