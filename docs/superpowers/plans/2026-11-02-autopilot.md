# BurnZombies Autopilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** BurnZombies burns zombies, retires old worktrees and clears junk folders on its own every 15 minutes, learns from a dozen yes/no answers, and explains itself in kid-simple language.

**Architecture:** A native `Autopilot` actor builds a fact-tagged catalog from the existing observers, applies operator/starter rules and AI judgments (`AutopilotPolicy`), and burns authorized items through three hard-railed executors. A headless Claude Code sweep (MCP autopilot tools) judges unsure items and writes training questions. SwiftUI windows show Teach BZ and a simplified Findings view.

**Tech Stack:** Swift 6.2 package (language mode 5), macOS 14+, SwiftUI/AppKit, system SQLite/JSON via `Store`, `/usr/bin/git`, official MCP Swift SDK 0.12.1, headless `claude -p`.

**Spec:** `docs/superpowers/specs/2026-11-02-autopilot-design.md`

## Global Constraints

- Build: `swift build`; tests: `.build/debug/BurnProof --<flag>`; full suite `scripts/test.sh`. No XCTest.
- State lives under `Store.defaultRoot/autopilot/` (tests pass a temporary root). Files 0600, written with `Store.write(_:to:limit:)`.
- Git subprocesses go through `WorktreeGit.run(path, args, seconds:)` (hooks, fsmonitor, network and global config disabled).
- Consumer checks use `bz_path_in_use(path)`: `0` none, `1` in use, anything else unknown (treat as in use).
- Processes: SIGTERM only, through `Native.terminate(_:)`; never SIGKILL, never a process group.
- Never touch real user work in tests: fixtures live in temporary directories and processes the test spawns.
- Fact values are exactly the strings in the spec's Facts tables.
- `AutopilotPolicy.trainingTarget = 12`, `AutopilotPolicy.aiConfidenceFloor = 0.85`, at most 3 open questions, default sweep interval 15 minutes, AI timeout 600 s, AI re-judgment at most every 4 hours when nothing changed.
- UI copy uses: zombies, old copies, junk folders, Burn, Keep, Will burn, Needs you, Keeping, Burned, Protected.

## Review Focus

- A worktree whose branch was force-pushed or rebased after "merged" was computed: `saved` must be recomputed from the current HEAD at retire time, and a `local` result refuses the starter-rule burn.
- A process whose PID is reused between catalog and burn: identity (boot/start/path) mismatch must refuse, never signal.
- A question answered while a sweep is running: the new rule must apply on the next evaluation without being overwritten by the sweep's save.
- Restore after the original path was re-used by a new directory: restore must refuse instead of overwriting.
- A machine with thousands of items: catalog, snapshot and MCP pages must stay bounded (≤ 200 entries per MCP page, `Store` limits honored).

---

### Task 1: Core models, policy and memory store

**Files:**
- Create: `Sources/BurnCore/AutopilotModels.swift`, `Sources/BurnCore/AutopilotPolicy.swift`, `Sources/BurnCore/AutopilotStore.swift`
- Create (stubs other tasks fill): `Sources/BurnCore/AutopilotWorktrees.swift`, `Sources/BurnCore/AutopilotDisk.swift`, `Sources/BurnCore/AgentThreads.swift`
- Test: `Proof/AutopilotPolicyTests.swift`; wire `--autopilot-policy`, `--autopilot-worktrees`, `--autopilot-disk`, `--autopilot-process`, `--autopilot-sweep` and the default suite in `Proof/Runner.swift`

**Interfaces (Produces):**
- `enum AutopilotKind: String { process, worktree, disk }`
- `enum AutopilotStatus: String { protected, burn, keep, unsure, burned, failed }`
- `enum AutopilotVerdict: String { burn, keep, unsure }`, `enum AutopilotAnswer: String { yes, no, skip }`
- `struct AutopilotItem { id, kind, name, detail, path?, bytes, facts: [String:String], revision, protectedReason?, observedAt, pid?, processKey? }` — ids are `process:<ProcessIdentity.key>`, `worktree:<WorktreeRecord.id>`, `disk:<sha256(path)>`
- `struct AutopilotRule { id, kind, match: [String:[String]], verdict, source: operator|starter, title, enabled, created, questionID? }`
- `struct AutopilotJudgment { itemID, revision, verdict, confidence, label, why, date }`
- `struct AutopilotQuestion { id, kind, match, question, why, examples, count, bytes, asked, source, answer?, answered?, snoozedUntil? }`
- `struct AutopilotRestore { repository, path, ref, head, branch?, snapshot }`, `struct AutopilotReceipt { id: UUID, itemID, kind, name, authority, outcome, detail, bytes, date, restore?, eventID? }`
- `struct AutopilotMemory { rules, starterDisabled, keptItems, questions, judgments }`, `struct AutopilotSweepState { enabled, intervalMinutes, lastTick, lastAISweep, lastAIDigest, failures, retryAfter, lastError, log }`
- `struct AutopilotEntry { item, status, authority?, label, why, consequence, receipt? }`, `struct AutopilotSnapshot { entries, questions, rules, trainingProgress, answers, coverage, counts: [String:Int], bytes: [String:UInt64], sweep, receipts, coverageNotes }`
- `enum AutopilotPolicy { starterRules, trainingTarget, aiConfidenceFloor, matches(_:_:), decide(_ item:, memory:, now:) -> (AutopilotStatus, String?), aiEligible(_:), proposeQuestions(_ unsure:, memory:, limit:, now:) -> [AutopilotQuestion], consequence(_:) -> String, coverage(_ entries:) -> Double }`
- `final class AutopilotStore { init(root: URL) throws; memory()/save(memory:); catalog()/save(catalog:); receipts()/append(_:); sweep()/save(sweep:) }`

- [ ] **Step 1: Write failing tests** in `autopilotPolicyProof()`: keep rule beats burn rule on the same item; starter S1/S2/S3 match their spec patterns and stop matching when disabled; `aiEligible` is false for `listening=yes`, for `place=codex`, for `folder=other`; an AI `burn` judgment at 0.84 stays `unsure`, at 0.9 for the current revision becomes `burn`, at 0.9 for an older revision stays `unsure`; protected items are never `burn`; kept items are `keep`; `proposeQuestions` returns ≤3 questions covering the largest clusters, never one already answered or snoozed; training progress after 6 yes/no answers is 0.5; store round-trips memory and caps receipts at 500.
- [ ] **Step 2: Run** `swift build && .build/debug/BurnProof --autopilot-policy` → compile failure.
- [ ] **Step 3: Implement** models, policy and store. Clustering: for each unsure item, candidate patterns are every subset of size 2–3 of its facts excluding `repo` and `size`; score = `count + bytes / 1e9`; greedily pick best patterns whose item sets overlap < 50% with already-picked ones.
- [ ] **Step 4: Run** `.build/debug/BurnProof --autopilot-policy` → `PASS`.
- [ ] **Step 5: Commit** `feat: autopilot models, learning policy and memory store`.

### Task 2: Worktree facts, safe retire and restore

**Files:** Modify `Sources/BurnCore/AutopilotWorktrees.swift`; Test `Proof/AutopilotWorktreeTests.swift`

**Interfaces:**
- Consumes: `AutopilotItem`, `AutopilotReceipt`, `AutopilotRestore`, `AgentThread` (Task 3), `WorktreeRecord`, `WorktreeGit.run`, `bz_path_in_use`.
- Produces: `enum AutopilotWorktrees { static func items(_ records: [WorktreeRecord], threads: [AgentThread], delivery: inout [String: AutopilotDelivery], now: Date, budget: Int) -> [AutopilotItem]; static func delivery(path: String) throws -> AutopilotDelivery; static func retire(_ item: AutopilotItem, authority: String, root: URL, inUse: (String) -> Int32 = { bz_path_in_use($0) }) -> AutopilotReceipt; static func restore(_ receipt: AutopilotReceipt) throws }`
- `struct AutopilotDelivery: Codable { head: String; saved: String; checked: Date }`

- [ ] **Step 1: Failing tests** in `autopilotWorktreeProof()` using temporary repos with a bare `origin`: merged clean worktree → `saved=merged`, `changes=none`; pushed-not-merged → `pushed`; local commit → `local`; retire of a clean merged worktree removes the directory and registration and leaves `refs/burnzombies/retired/<id>` at HEAD; retire of a dirty worktree with an untracked file and a small ignored `.env` stores them in a snapshot commit and restore brings back the file, the change as uncommitted, and the `.env`; `node_modules` in the worktree is not in the snapshot; locked worktree, main checkout, `inUse` returning 1 or −1, and a dirty submodule each refuse with the worktree untouched; restore refuses when the original path exists.
- [ ] **Step 2–4:** implement until `.build/debug/BurnProof --autopilot-worktrees` passes. Snapshot = temporary `GIT_INDEX_FILE` copy of the index, `add -A`, `add -f` for ≤5 MB ignored files (≤100 MB total) outside `node_modules, .build, build, dist, target, .next, .turbo, .gradle, DerivedData, .venv, venv, __pycache__, Pods, .cache`, then `write-tree` + `commit-tree -p HEAD`; `update-ref`; `worktree remove --force`.
- [ ] **Step 5: Commit** `feat: restorable autopilot worktree retirement`.

### Task 3: Agent threads and junk folders

**Files:** Modify `Sources/BurnCore/AgentThreads.swift`, `Sources/BurnCore/AutopilotDisk.swift`; Test `Proof/AutopilotDiskTests.swift`

**Interfaces:**
- Produces: `struct AgentThread: Codable { id, agent: String, cwd: String, live: Bool, pid: Int32?, title: String?, lastActive: Date }`; `enum AgentThreads { static func index(home: String = NSHomeDirectory(), now: Date) -> [AgentThread]; static func state(for path: String, threads: [AgentThread]) -> (thread: String, lastActive: Date?) }` — Claude Code from `~/.claude/sessions/*.json` (live when `pid` is alive) and `~/.claude/projects/<slug>` (newest `.jsonl` mtime); Codex from the first line (`session_meta.payload.cwd`) of rollouts under `~/.codex/sessions` modified in the last 30 days.
- Produces: `enum AutopilotDisk { static let rebuildable: [String: String] /* folder name → folder fact */; static func items(worktrees: [WorktreeRecord], home: String, now: Date, sizer: (String) -> UInt64?) -> [AutopilotItem]; static func reclaim(_ item: AutopilotItem, authority: String, inUse: (String) -> Int32 = { bz_path_in_use($0) }) -> AutopilotReceipt }`

- [ ] **Step 1: Failing tests** in `autopilotDiskProof()` with a fake home: live and ended Claude sessions and a Codex rollout produce threads with the right cwd/live; `state(for:)` picks the deepest matching cwd; `node_modules` and `.build` under a stale fixture worktree become `folder=node_modules|build-output, home=stale-worktree`; `~/Library/Developer/Xcode/DerivedData/X` becomes `xcode-derived, global-cache`; folders under `.ssh`, `Library/Mobile Documents` or outside home never appear; `reclaim` deletes a rebuildable folder and reports its bytes; it refuses `folder=other`, refuses when `inUse` returns 1 or −1, and refuses a symlink.
- [ ] **Step 2–4:** implement until `.build/debug/BurnProof --autopilot-disk` passes.
- [ ] **Step 5: Commit** `feat: agent thread index and rebuildable junk folders`.

### Task 4: Kid-simple UI

**Files:** Create `Sources/BurnApp/TeachView.swift`, `Sources/BurnApp/AutopilotFindingsView.swift`, `Sources/BurnApp/AutopilotSettingsView.swift`, `Sources/BurnApp/AutopilotProof.swift`; Modify `Sources/BurnApp/main.swift` (menu section, window openers, `--autopilot-proof`), `Sources/BurnCore/Demo.swift` (demo `AutopilotSnapshot`)

**Interfaces:**
- Consumes: `AutopilotSnapshot`, `AutopilotEntry`, `AutopilotQuestion`, `AutopilotRule`, `AutopilotReceipt` (Task 1).
- Produces on `AppModel`: `@Published var autopilot: AutopilotSnapshot`; `func answer(_ q: AutopilotQuestion, _ a: AutopilotAnswer)`, `func burnNow(_ e: AutopilotEntry)`, `func keepForever(_ e: AutopilotEntry)`, `func restore(_ r: AutopilotReceipt)`, `func forgetRule(_ r: AutopilotRule)`, `func setStarter(_ id: String, enabled: Bool)`, `func setAutopilot(enabled: Bool)`, `func setSweepInterval(minutes: Int)`, `func resetTraining()`; `var openTeach: (() -> Void)?`.

- [ ] **Step 1: Failing proof** `--autopilot-proof <dir>` renders offscreen (no window shown or focused) and OCR-checks: menu shows "Autopilot" and "quick question"; Teach BZ shows the question text, "Yes, burn them", "No, keep them", "trained"; Findings shows the summary sentence, "Needs you", "What is it?", "Why I think so", "If I burn it", "Technical details"; Settings shows "What BZ has learned" and "Start training over"; empty states render ("Nothing needs you right now").
- [ ] **Step 2–4:** implement until the proof passes; dark appearance matches existing windows; layout bounded at 360 pt menu width and 1000×700 windows.
- [ ] **Step 5: Commit** `feat: Teach BZ, simple Findings and autopilot settings`.

### Task 5: Process lane, engine, MCP tools and the sweep

**Files:** Create `Sources/BurnCore/AutopilotProcesses.swift`, `Sources/BurnCore/AutopilotEngine.swift`, `Sources/BurnCore/AutopilotSweep.swift`; Modify `Sources/BurnCore/Models.swift` (`Observation.pgid`), `Sources/BurnCore/Native.swift`, `Sources/BurnCore/Monitor.swift` (`autopilotRecords()`, `autopilotBurn(...)`), `Sources/BurnCore/AgentBridge.swift` (`autopilot` operation + `payload`), `Sources/BurnMCP/BurnMCP.swift` (autopilot tools when `BURNZOMBIES_AUTOPILOT=1`), `Sources/BurnCore/MachineReview.swift` (claude/codex autopilot arguments, backoff instead of pause, 15-minute default), `Sources/BurnCore/FullDiskAccess.swift` (auto-verify), `Sources/BurnCLI/main.swift` (`autopilot` subcommands), `Sources/BurnApp/main.swift` (wiring); Test `Proof/AutopilotProcessTests.swift`, `Proof/AutopilotSweepTests.swift`

**Interfaces:**
- Produces: `enum AutopilotProcesses { static func items(_ records: [String: Record], threads: [AgentThread], protectedPIDs: Set<Int32>, now: Date) -> [AutopilotItem] }`; `Monitor.autopilotBurn(_ keys: [String], authority: String, label: String) throws -> UUID` (CleanupEvent id); `actor Autopilot { init(root:, monitor:, worktrees:, threads:, executors:); tick(now:) async -> AutopilotSnapshot; snapshot() -> AutopilotSnapshot; answer(_:_:) async throws; burnNow(_:) async throws -> AutopilotReceipt; keep(_:) throws; restore(_:) async throws; forget(_:) throws; setStarter(_:enabled:) throws; reset() throws; catalogPage(status:offset:limit:) -> AutopilotCatalogPage; inspect(_:) async -> [String:String]; decide(_:) throws -> Int; burn(ids:) async -> [AutopilotReceipt]; ask(_:) throws -> AutopilotQuestion; report(_:) throws }`; `AutopilotSweeper.due(state:, digest:, now:) -> SweepPlan`.

- [ ] **Step 1: Failing tests**: an orphaned `sleep` tree spawned by the test (parent exits) yields `orphaned=yes, thread=none`; `autopilotBurn` signals it and its child, verifies exit, and refuses a PID whose start time changed; a process under `/System` or the caller's ancestry is refused; a listening socket no longer refuses but sets `listening=yes`; sweep: native rule burns happen with no harness configured; a failing harness sets `retryAfter` with backoff and never `paused`; the AI is skipped when the unsure digest is unchanged and < 4 h old; MCP `autopilot_burn` of an unauthorized item is refused with "ask the operator".
- [ ] **Step 2–4:** implement until `--autopilot-process` and `--autopilot-sweep` pass, then `scripts/test.sh --integration` passes with existing proofs updated where autopilot intentionally changed behavior.
- [ ] **Step 5: Commit** `feat: autopilot engine, process lane, MCP tools and 15-minute sweep`.

### Task 6: End-to-end proof, docs and release

**Files:** Create `scripts/test-autopilot-e2e.py`; Modify `README.md`, `docs/SAFETY.md`, `docs/ARCHITECTURE.md`, `docs/USER_GUIDE.md`, `.github/workflows/ci.yml`

- [ ] **Step 1:** E2E script builds the app bundle, creates an isolated `BURNZOMBIES_HOME`, a fixture scope (orphaned sleep tree, a clean merged worktree, a dirty worktree, a `node_modules` in a stale worktree), runs one real headless Claude Code sweep against it, and asserts: orphan burned, merged worktree retired with ref, dirty one retired-with-snapshot or asked, junk folder reclaimed, ≤3 questions, nothing outside the fixture scope touched.
- [ ] **Step 2:** Run it locally with the operator's Claude Code login; record results in `docs/VALIDATION.md`.
- [ ] **Step 3:** Update docs (autonomy contract, rails, Teach BZ), CI steps (`--autopilot-*` proofs, `--autopilot-proof`), screenshots.
- [ ] **Step 4:** Full suite + CI green; PR; merge.
