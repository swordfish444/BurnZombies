import BurnCore
import Foundation

// Big unsaved files: an old copy with more unsaved files than a restore point holds was skipped and
// tried again every 6 hours, for good, while nothing asked about it. Now retire names the big files,
// the copy carries a risk for each kind of them (`bigCode=yes`, `bigMedia=yes`, …), and only a Yes to
// a card that showed that kind lets them go: deleted for good, which Undo can't bring back.

/// The folders and files retire leaves out of a backup that can't hold them all.
private func bigFilesChoiceProof() {
  let now = Date()
  func file(_ path: String, _ megabytes: Double, daysAgo: Double = 3) -> AutopilotUnsavedFile {
    AutopilotUnsavedFile(
      path: path, bytes: UInt64(megabytes * 1_000_000),
      changed: now.addingTimeInterval(-daysAgo * 86_400))
  }
  // 21 checkouts of about 43 MB each, a 44 MB one beside them, a small result and four new scripts.
  var files: [AutopilotUnsavedFile] = []
  for checkout in 0..<21 {
    for part in 0..<10 { files.append(file("tmp/checkouts/c\(checkout)/src/f\(part).ts", 4.35)) }
  }
  files.append(file("tmp/base/src/main.ts", 44))
  files.append(file("tmp/ab-results.json", 0.002, daysAgo: 1))
  for script in 0..<4 { files.append(file("scripts/balance/s\(script).ts", 0.005, daysAgo: 1)) }
  let chosen = AutopilotWorktrees.bigFiles(files, entries: ["tmp/", "scripts/balance/"])
  equal(chosen.map(\.path), ["tmp/checkouts"], "the folder of checkouts, nothing small beside it")
  equal(chosen.first?.files, 210)
  equal(chosen.first?.bytes, 210 * 4_350_000)
  equal(chosen.first?.kind, "TypeScript files")
  equal(chosen.first?.risk, "bigCode", "TypeScript is code")
  equal(chosen.first?.changed, now.addingTimeInterval(-3 * 86_400), "when it last changed")

  let fits: [AutopilotBigFiles] = AutopilotWorktrees.bigFiles(
    [file("clip.mov", 400)], entries: ["clip.mov"])
  equal(fits, [], "what fits in a backup isn't big")
  // A big file in a folder Git tracks things in goes alone; the file beside it is backed up.
  let dump: [AutopilotBigFiles] = AutopilotWorktrees.bigFiles(
    [file("data/dump.sql", 600), file("data/notes.md", 0.001)],
    entries: ["data/dump.sql", "data/notes.md"])
  equal(dump.map(\.path), ["data/dump.sql"])
  equal(dump.first?.files, 1)
  equal(dump.first?.risk, "bigData", "a database dump is data")
  // Biggest first, and only as many as it takes: the smaller folder still fits in the backup.
  var two: [AutopilotUnsavedFile] = []
  for n in 0..<10 { two.append(file("renders/r\(n)/frame.png", 45)) }
  for n in 0..<4 { two.append(file("recordings/take\(n).mp4", 50)) }
  let biggest = AutopilotWorktrees.bigFiles(two, entries: ["renders/", "recordings/"])
  equal(biggest.map(\.path), ["renders"], "the biggest is enough")
  equal(biggest.first?.kind, "images")
  equal(biggest.first?.risk, "bigMedia")
  // Nothing big enough on its own: the biggest loose files go, until the rest fits.
  var loose: [AutopilotUnsavedFile] = []
  for n in 0..<7 { loose.append(file("src/gen/part\(n).bin", 90 - Double(n))) }
  let spread = AutopilotWorktrees.bigFiles(loose, entries: loose.map(\.path))
  equal(spread.map(\.path), ["src/gen/part0.bin"], "the biggest of many small ones")
  equal(spread.first?.risk, "bigOther", "a kind with no name is other files")
}

/// A copy untouched for a week whose work is merged, with lots of unsaved changes, 1.4 GB, and big
/// unsaved files of the kinds in `big` ("bigCode", …).
private func gameCopy(
  _ name: String, big: [String] = [], changes: String = "large", stale: String = "week", now: Date
) -> AutopilotItem {
  var facts: [String: String] = [
    "repo": "game", "place": "other", "saved": "merged", "changes": changes, "stale": stale,
    "inUse": "no", "thread": "none",
  ]
  for risk in big { facts[risk] = "yes" }
  return AutopilotItem(
    id: "worktree:" + name, kind: .worktree, name: name, bytes: 1_400_000_000, facts: facts,
    lastUsed: now.addingTimeInterval(-8 * 86_400), title: name)
}

/// The folder of checkouts a game copy holds: big unsaved code.
private func checkoutsFolder(_ now: Date) -> AutopilotBigFiles {
  AutopilotBigFiles(
    path: "tmp/checkouts", bytes: 914_000_000, files: 31_000, kind: "TypeScript files",
    changed: now.addingTimeInterval(-26 * 86_400))
}

/// Recordings a test run left: big unsaved media.
private func recordingsFolder(_ now: Date) -> AutopilotBigFiles {
  AutopilotBigFiles(
    path: "qa/recordings", bytes: 2_100_000_000, files: 40, kind: "videos",
    changed: now.addingTimeInterval(-20 * 86_400))
}

/// An answer the owner gave before cards named their risks: copies nobody touched since yesterday
/// are done.
private func doneSinceYesterday(_ now: Date) -> AutopilotQuestion {
  var question = AutopilotQuestion(
    kind: .worktree, match: ["stale": ["day"]], question: "Can I burn old project copies?",
    why: "", examples: [], count: 4, bytes: 3_000_000_000,
    asked: now.addingTimeInterval(-20 * 86_400))
  question.answer = .yes
  question.answered = now.addingTimeInterval(-20 * 86_400)
  return question
}

/// Memory holding the owner's answers, each learned as its lesson.
private func taught(_ answers: [AutopilotQuestion], now: Date) -> AutopilotMemory {
  var memory = AutopilotMemory()
  for question in answers {
    memory.questions.append(question)
    let verdict: AutopilotVerdict = question.answer == .yes ? .burn : .keep
    let lessons: [AutopilotRule] = AutopilotPolicy.lessons(
      for: question, verdict: verdict, created: question.answered ?? now,
      earlier: memory.questions)
    for lesson in lessons { AutopilotPolicy.learn(lesson, into: &memory.rules) }
  }
  return memory
}

/// `question` answered at `now`.
private func answered(
  _ question: AutopilotQuestion, _ answer: AutopilotAnswer, now: Date
) -> AutopilotQuestion {
  var result = question
  result.answer = answer
  result.answered = now
  return result
}

/// The last 5 guesses about copies were right.
private func trustedOnCopies(_ memory: AutopilotMemory, now: Date) -> AutopilotMemory {
  var trusted = memory
  trusted.scores = (0..<AutopilotPolicy.trustStreak).map { i in
    AutopilotScore(
      questionID: "right-\(i)", subject: "worktree:", guess: .yes, answer: .yes, right: true,
      date: now.addingTimeInterval(Double(i - 10)))
  }
  return trusted
}

/// Big unsaved files as the policy reads them (spec 3–7).
func bigFilesPolicyProof() throws {
  bigFilesChoiceProof()
  let now = Date()
  let checkouts = gameCopy("checkouts", big: ["bigCode"], now: now)
  let clean = gameCopy("clean", now: now)
  let owner = taught([doneSinceYesterday(now)], now: now)

  // No lesson that never named big files burns them: not the owner's, not a starter rule, not the AI.
  equal(AutopilotPolicy.decide(clean, memory: owner).status, .burn, "the lesson burns a clean copy")
  equal(
    AutopilotPolicy.decide(checkouts, memory: owner).status, .unsure,
    "but not one with big unsaved files: no card ever showed them")
  let finished = AutopilotItem(
    id: "worktree:finished", kind: .worktree, name: "finished", bytes: 1_400_000_000,
    facts: [
      "place": "patrol6", "saved": "merged", "changes": "none", "stale": "older", "inUse": "no",
      "thread": "none", "bigArchives": "yes",
    ])
  equal(
    AutopilotPolicy.decide(finished, memory: AutopilotMemory()).status, .unsure,
    "nor a starter rule")
  var judged = owner
  judged.judgments[checkouts.id] = AutopilotJudgment(
    itemID: checkouts.id, revision: checkouts.revision, verdict: .burn, confidence: 0.95,
    label: "Old game copy", why: "Its work is merged.")
  checkFalse(AutopilotPolicy.aiEligible(checkouts), "the AI may not burn it")
  check(AutopilotPolicy.aiEligible(clean), "as it may a clean copy")
  equal(AutopilotPolicy.decide(checkouts, memory: judged).status, .unsure, "however sure the AI is")

  // A question about copies untouched for a week covers it, and its card names the files and says
  // what a Yes costs before anything is pressed.
  let week: [String: [String]] = ["stale": ["week"]]
  check(
    AutopilotPolicy.matches(AutopilotPolicy.coverage(.worktree, week), checkouts),
    "a question's coverage includes it")
  var carried = checkouts
  carried.bigFiles = [checkoutsFolder(now)]
  guard let question = AutopilotPolicy.proposeQuestions([carried], memory: owner, now: now).first
  else { return failTest("a copy with big unsaved files is asked about") }
  equal(question.match, week)
  equal(question.risks, ["bigCode=yes", "changes=large"])
  equal(question.bigBytes, 914_000_000)
  let card = AutopilotPolicy.card(question, now: now)
  check(card.cautions.contains("1 has big unsaved code files"), "the card names the kind: \(card.cautions)")
  let cost = "A Yes deletes its 914 MB of big unsaved files for good. Undo won't bring these back; everything else in it is backed up first."
  equal(card.cost, cost)
  equal(card.note, cost, "it is never \"so you can undo it\"")
  let changed: String = AutopilotPolicy.clock(
    now.addingTimeInterval(-26 * 86_400), now: now, calendar: .current)
  equal(card.rows.first?.details, ["tmp/checkouts · 914 MB of TypeScript files · " + changed])
  equal(AutopilotPolicy.card(answered(AutopilotQuestion(
    kind: .worktree, match: week, question: "q", why: "", examples: [], count: 1,
    bytes: 1_000_000_000), .skip, now: now)).cost, nil, "a card without big files has no cost line")

  // A card about several copies puts the ones with big files first and says what they cost together.
  var bigger = gameCopy("bigger", now: now)
  bigger.bytes = 3_000_000_000
  let both = AutopilotPolicy.proposeQuestions([bigger, carried], memory: AutopilotMemory(), now: now)
  if let two = both.first {
    let shown = AutopilotPolicy.card(two, now: now)
    equal(shown.rows.map(\.title), ["checkouts", "bigger"], "big files first, though it's smaller")
    equal(shown.rows.last?.details, [], "a copy without big files names none")
    equal(
      shown.cost,
      "A Yes deletes their 914 MB of big unsaved files for good. Undo won't bring these back; everything else is backed up first."
    )
  } else {
    failTest("a card about both copies")
  }

  // An answer from before cards named their risks never covered big files, so even with one about
  // that exact pattern they're asked about; the clean copies it answered stay answered.
  let oldWeek = answered(
    AutopilotQuestion(
      kind: .worktree, match: week, question: "Can I burn copies untouched for a week?", why: "",
      examples: [], count: 2, bytes: 2_000_000_000, asked: now), .yes, now: now)
  let older = taught([doneSinceYesterday(now), oldWeek], now: now)
  equal(
    AutopilotPolicy.proposeQuestions([carried], memory: older, now: now).count, 1,
    "big files under a pattern answered before cards named risks are still asked about")
  var unchecked = gameCopy("unchecked", now: now)
  unchecked.facts["saved"] = "unknown"
  equal(
    AutopilotPolicy.proposeQuestions([unchecked], memory: older, now: now).count, 0,
    "as before, that answer covers the rest")

  // Yes: the lesson names the kind, stands beside the older lesson, and burns the next copy like it.
  let yes = answered(question, .yes, now: now)
  let lesson = AutopilotPolicy.lesson(for: yes, verdict: .burn, created: now)
  equal(lesson.match["bigCode"], ["yes", "no"], "a Yes to a card that showed big code lets it go")
  equal(lesson.match["bigMedia"], nil, "and no other kind: a lesson without it covers none")
  let afterYes = taught([doneSinceYesterday(now), yes], now: now)
  check(
    afterYes.rules.contains { $0.id == lesson.id },
    "a lesson that never named big files doesn't take it in")
  equal(AutopilotPolicy.decide(checkouts, memory: afterYes).status, .burn, "so it burns")
  equal(
    AutopilotPolicy.decide(gameCopy("next", big: ["bigCode"], now: now), memory: afterYes).status,
    .burn, "and so does the next copy like it")
  equal(
    AutopilotPolicy.decide(gameCopy("films", big: ["bigMedia"], now: now), memory: afterYes).status,
    .unsure, "but not one with another kind of big files")
  equal(
    AutopilotPolicy.decide(
      gameCopy("few", big: ["bigCode"], changes: "small", now: now), memory: afterYes
    ).status, .unsure, "nor one with a risk the card didn't show")
  var plain = question
  plain.risks = ["changes=large"]
  equal(
    AutopilotPolicy.lesson(for: answered(plain, .yes, now: now), verdict: .burn, created: now)
      .match["bigCode"], nil, "a card that didn't show them doesn't let them go")
  let sentence: String? = AutopilotPolicy.lessonGroups(afterYes).first {
    $0.id == "worktree:burn:week"
  }?.sentence
  equal(
    sentence,
    "Copies nobody touched for a week are done once their work is on GitHub, even with unsaved work or big unsaved code files."
  )

  // No: it keeps the copies with that kind of big files at that age and newer, and nothing else.
  let no = answered(question, .no, now: now)
  let keeps: [AutopilotRule] = AutopilotPolicy.lessons(
    for: no, verdict: .keep, created: now, earlier: owner.questions)
  equal(
    keeps.map(\.match), [["stale": ["today", "day", "week"], "bigCode": ["yes"]]],
    "a No keeps only copies with big unsaved code")
  let afterNo = taught([doneSinceYesterday(now), no], now: now)
  equal(AutopilotPolicy.decide(checkouts, memory: afterNo).status, .keep, "it keeps them")
  equal(AutopilotPolicy.decide(clean, memory: afterNo).status, .burn, "clean copies still go")
  let kept: String? = AutopilotPolicy.lessonGroups(afterNo).first { $0.verdict == .keep }?.sentence
  equal(kept, "Copies used in the last month stay: Has big unsaved code files.")

  // BZ's own call reaches only kinds the owner said yes to.
  let trusted = trustedOnCopies(afterYes, now: now)
  var again = question
  again.id = "again"
  let sure = AutopilotPolicy.guess(again, memory: trusted)
  equal(sure?.sure, true, "sure of big code, which the owner said yes to")
  check(
    sure?.why.contains("big unsaved code files") == true,
    "and says so: \(sure?.why ?? "")")
  var films = again
  films.risks = ["bigMedia=yes", "changes=large"]
  equal(AutopilotPolicy.guess(films, memory: trusted)?.sure, false, "never of a kind they didn't")

  // The replay knows the card was about big files: the older lesson didn't settle it.
  let replay = AutopilotEval.replay([doneSinceYesterday(now), yes])
  equal(replay.steps.map(\.outcome), ["asked", "asked"], "big files are asked about in the replay too")

  // What retire found reaches the copy while it is as the refusal saw it.
  var refusal = AutopilotReceipt.refused(
    gameCopy("checkouts", now: now), authority: "rule:x", AutopilotWorktrees.bigFilesRefusal)
  refusal.bigFiles = [checkoutsFolder(now), recordingsFolder(now)]
  let plainItems: [AutopilotItem] = [gameCopy("checkouts", now: now), clean]
  let marked = AutopilotPolicy.withBigFiles(plainItems, receipts: [refusal])
  equal(marked.first?.facts["bigCode"], "yes", "the copy carries each kind as a risk")
  equal(marked.first?.facts["bigMedia"], "yes")
  equal(marked.first?.facts["bigData"], nil)
  equal(marked.first?.bigFiles?.map(\.path), ["tmp/checkouts", "qa/recordings"], "and the files")
  equal(
    marked.first?.revision,
    AutopilotItem.revision(id: checkouts.id, facts: marked.first?.facts ?? [:]),
    "its revision follows its facts")
  equal(marked.last, clean, "a copy no refusal named is as it was")
  let changedCopy = gameCopy("checkouts", changes: "small", now: now)
  equal(
    AutopilotPolicy.withBigFiles([changedCopy], receipts: [refusal]).first?.facts["bigCode"], nil,
    "a copy that changed since is looked at again")

  // Retire drops them only for every kind the copy was known to hold, under a lesson.
  let both2 = [checkoutsFolder(now), recordingsFolder(now)]
  check(
    AutopilotWorktrees.dropsBigFiles(marked[0], authority: "rule:x", files: both2),
    "a lesson that covered every kind")
  checkFalse(
    AutopilotWorktrees.dropsBigFiles(checkouts, authority: "rule:x", files: both2),
    "not a kind that turned up since")
  checkFalse(
    AutopilotWorktrees.dropsBigFiles(marked[0], authority: "operator", files: both2),
    "nor the owner's Burn now")
}

// MARK: The engine

/// A Mac whose copies may hold big unsaved files. Retire refuses a copy with them unless the policy
/// lets them go (`AutopilotWorktrees.dropsBigFiles`), naming them as real retire does; copies come
/// back on restore.
private final class BigFilesWorld: @unchecked Sendable {
  let tries = Calls()
  let burns = Calls()
  let dropped = Calls()
  let restores = Calls()
  private let lock = NSLock()
  private var items: [AutopilotItem]
  private var big: [String: [AutopilotBigFiles]]
  init(_ items: [AutopilotItem], big: [String: [AutopilotBigFiles]]) {
    self.items = items
    self.big = big
  }
  func add(_ item: AutopilotItem, big files: [AutopilotBigFiles] = []) {
    lock.withLock {
      items.append(item)
      if !files.isEmpty { big[item.id] = files }
    }
  }
  func tried(_ id: String) -> Int { tries.all.filter { $0 == id }.count }
  var present: [AutopilotItem] {
    let burned = Set(burns.all)
    let back = Set(restores.all)
    return lock.withLock { items.filter { !burned.contains($0.id) || back.contains($0.id) } }
  }
  var sources: AutopilotSources {
    AutopilotSources(
      worktrees: { _, _, delivery in (self.present, delivery) },
      retireWorktree: { item, authority in
        self.tries.add(item.id)
        let found: [AutopilotBigFiles] = self.lock.withLock { self.big[item.id] ?? [] }
        let drops: Bool = AutopilotWorktrees.dropsBigFiles(item, authority: authority, files: found)
        if !found.isEmpty && !drops {
          var refused = AutopilotReceipt.refused(
            item, authority: authority, AutopilotWorktrees.bigFilesRefusal)
          refused.bigFiles = found
          return refused
        }
        self.burns.add(item.id)
        if !found.isEmpty { self.dropped.add(item.id) }
        let backup = AutopilotRestore(
          repository: "/fixture/.git", path: "/fixture/" + item.name,
          ref: "refs/fixture/" + item.name, head: String(repeating: "0", count: 40), branch: nil,
          snapshot: true)
        var receipt = AutopilotReceipt(
          itemID: item.id, kind: .worktree, name: item.name, authority: authority,
          outcome: "burned", detail: "Removed.", bytes: item.bytes, restore: backup)
        receipt.bigFiles = found.isEmpty ? nil : found
        return receipt
      },
      restoreWorktree: { receipt in self.restores.add(receipt.itemID) })
  }
}

private func bigFilesEngine(_ name: String, _ world: BigFilesWorld, _ memory: AutopilotMemory)
  throws -> (Autopilot, AutopilotStore, URL)
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bz-autopilot-bigfiles-" + name + "-" + UUID().uuidString)
  let store = try AutopilotStore(root: root)
  try store.save(memory: memory)
  return (try Autopilot(root: root, sources: world.sources), store, root)
}

private func entry(_ snapshot: AutopilotSnapshot, _ name: String) -> AutopilotEntry? {
  snapshot.entries.first { $0.item.id == "worktree:" + name }
}

/// The owner's lesson covers a game copy and a clean one. The clean one burns; the game copy's big
/// unsaved files get it refused once, naming them. From then on it waits unsure, tried again by
/// nothing, and the owner is asked about it on a card that names the files and their cost.
private func askedNotRetried(_ name: String) async throws -> (
  engine: Autopilot, store: AutopilotStore, root: URL, world: BigFilesWorld,
  question: AutopilotQuestion, now: Date
) {
  let now = Date()
  let world = BigFilesWorld(
    [gameCopy("checkouts", now: now), gameCopy("clean", now: now)],
    big: ["worktree:checkouts": [checkoutsFolder(now)]])
  let (engine, store, root) = try bigFilesEngine(
    name, world, taught([doneSinceYesterday(now)], now: now))
  _ = await engine.tick(now: now)
  equal(world.burns.all, ["worktree:clean"], "\(name): the clean copy burns")
  equal(world.tried("worktree:checkouts"), 1, "\(name): the game copy is tried once")
  let named: AutopilotReceipt? = try store.receipts().last { $0.itemID == "worktree:checkouts" }
  equal(named?.outcome, "refused")
  equal(named?.bigFiles?.map(\.path), ["tmp/checkouts"], "\(name): the refusal names the files")

  let look = await engine.tick(now: now.addingTimeInterval(15 * 60))
  let waiting = entry(look, "checkouts")
  equal(waiting?.status, .unsure, "\(name): the copy waits unsure")
  equal(waiting?.item.facts["bigCode"], "yes")
  equal(
    waiting?.why, "It has big files that aren't saved anywhere else, so I won't burn it without your OK.",
    "\(name): and says why, promising no question")
  guard let question = look.questions.first(where: { $0.kind == .worktree }) else {
    failTest("\(name): the owner is asked about it")
    throw StoreError.message("no question")
  }
  equal(question.risks, ["bigCode=yes", "changes=large"])
  equal(question.rows?.first?.bigFiles?.map(\.path), ["tmp/checkouts"], "\(name): its card names them")
  // Six hours on, nothing has tried it again.
  _ = await engine.tick(now: now.addingTimeInterval(7 * 3600))
  equal(world.tried("worktree:checkouts"), 1, "\(name): nothing tries it again")
  return (engine, store, root, world, question, now)
}

/// A Yes burns the copy without its big files, and the next copy like it burns without a question;
/// a copy with another kind of big files gets a card of its own.
private func bigFilesYesProof() async throws {
  let run = try await askedNotRetried("yes")
  defer { try? FileManager.default.removeItem(at: run.root) }
  _ = try await run.engine.apply(
    .answer(questionID: run.question.id, answer: .yes, risks: run.question.risks), now: run.now)
  await eventually { run.world.burns.all.contains("worktree:checkouts") }
  check(run.world.dropped.all.contains("worktree:checkouts"), "the Yes lets its big files go")
  let lesson: AutopilotRule? = try run.store.memory().rules.first {
    $0.questionID == run.question.id
  }
  equal(lesson?.match["bigCode"], ["yes", "no"])

  run.world.add(gameCopy("checkouts-2", now: run.now), big: [checkoutsFolder(run.now)])
  _ = await run.engine.tick(now: run.now.addingTimeInterval(8 * 3600))
  _ = await run.engine.tick(now: run.now.addingTimeInterval(8 * 3600 + 900))
  await eventually { run.world.burns.all.contains("worktree:checkouts-2") }
  check(
    run.world.dropped.all.contains("worktree:checkouts-2"), "the next copy like it burns on its own")
  let after = await run.engine.tick(now: run.now.addingTimeInterval(9 * 3600))
  checkFalse(after.questions.contains { $0.kind == .worktree }, "and nobody is asked about it")

  run.world.add(gameCopy("films", now: run.now), big: [recordingsFolder(run.now)])
  _ = await run.engine.tick(now: run.now.addingTimeInterval(10 * 3600))
  let films = await run.engine.tick(now: run.now.addingTimeInterval(10 * 3600 + 900))
  checkFalse(run.world.burns.all.contains("worktree:films"), "big videos aren't big code")
  let asked: AutopilotQuestion? = films.questions.first { $0.kind == .worktree }
  equal(asked?.risks, ["bigMedia=yes", "changes=large"], "they get a card of their own")
}

/// A No keeps the copy, and only copies with big files: clean ones the owner's lesson burns still go.
private func bigFilesNoProof() async throws {
  let run = try await askedNotRetried("no")
  defer { try? FileManager.default.removeItem(at: run.root) }
  let refused = try await run.engine.apply(
    .answer(questionID: run.question.id, answer: .no, risks: run.question.risks), now: run.now)
  equal(entry(refused, "checkouts")?.status, .keep, "the No keeps it")
  run.world.add(gameCopy("clean-2", now: run.now))
  _ = await run.engine.tick(now: run.now.addingTimeInterval(8 * 3600))
  await eventually { run.world.burns.all.contains("worktree:clean-2") }
  check(run.world.burns.all.contains("worktree:clean-2"), "a clean copy still burns")
  equal(run.world.tried("worktree:checkouts"), 1, "and nothing tries the kept one again")
}

/// A refusal from before refusals named the files doesn't stand: the copy is tried again at once.
private func unnamedRefusalProof() async throws {
  let now = Date()
  let copy = gameCopy("checkouts", now: now)
  let world = BigFilesWorld([copy], big: ["worktree:checkouts": [checkoutsFolder(now)]])
  let memory = taught([doneSinceYesterday(now)], now: now)
  let (engine, store, root) = try bigFilesEngine("unnamed", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  guard let lesson = memory.rules.first else { return failTest("the owner's lesson") }
  var old = AutopilotReceipt.refused(
    copy, authority: "rule:" + lesson.id,
    "It has big files that aren't saved anywhere else, so I'll ask you before touching it.")
  old.date = now.addingTimeInterval(-3600)
  try store.append(old)
  _ = await engine.tick(now: now)
  equal(world.tried("worktree:checkouts"), 1, "an older build's refusal is tried again at once")
  let named: AutopilotReceipt? = try store.receipts().last { $0.itemID == "worktree:checkouts" }
  equal(named?.bigFiles?.map(\.path), ["tmp/checkouts"], "and this time the files are named")
}

/// BZ's own call deletes only kinds of big files the owner said yes to, and tells the owner what it
/// deleted for good before Undo is pressed. Trusted on copies, with the owner's Yes to big code on
/// record, BZ acts on a card with big code and tells what went; Undo brings the copy back without
/// them and says so. A copy with big videos is asked about.
private func ownCallProof() async throws {
  let now = Date()
  let codeYes = answered(
    { () -> AutopilotQuestion in
      var question = AutopilotQuestion(
        kind: .worktree, match: ["stale": ["month"]], question: "Burn 1 copy?", why: "",
        examples: [], count: 1, bytes: 1_400_000_000, asked: now)
      question.risks = ["bigCode=yes", "changes=large"]
      return question
    }(), .yes, now: now.addingTimeInterval(-86_400))
  let memory = trustedOnCopies(taught([codeYes], now: now), now: now)
  var copy = gameCopy("checkouts", big: ["bigCode"], now: now)
  copy.bigFiles = [checkoutsFolder(now)]
  let world = BigFilesWorld(
    [copy, gameCopy("wip", now: now)], big: ["worktree:checkouts": [checkoutsFolder(now)]])
  let (engine, store, root) = try bigFilesEngine("own-call", world, memory)
  defer { try? FileManager.default.removeItem(at: root) }
  _ = await engine.tick(now: now)
  await eventually { world.burns.all.count == 2 }
  let acted = await engine.tick(now: now.addingTimeInterval(60))
  guard let tell = acted.tells.first else { return failTest("BZ acts on big code it is sure of") }
  let act: AutopilotRule? = try store.memory().rules.first { $0.id == tell.ruleID }
  equal(act?.match["bigCode"], ["yes", "no"], "its lesson lets the approved kind go")
  equal(act?.match["bigMedia"], nil, "and no other")
  check(world.dropped.all.contains("worktree:checkouts"), "the big code went with the copy")
  equal(tell.bigBytes, 914_000_000, "the tell knows what went for good")
  equal(
    AutopilotPolicy.bigFilesTold(tell),
    "Their 914 MB of big unsaved files were deleted for good. Undo brings the copies back without them."
  )
  let row: AutopilotQuestionRow? = tell.rows.first { $0.title == "checkouts" }
  equal(row?.bigFiles?.map(\.path), ["tmp/checkouts"], "and its card names them")

  world.add(gameCopy("films", now: now), big: [recordingsFolder(now)])
  _ = await engine.tick(now: now.addingTimeInterval(120))
  let look = await engine.tick(now: now.addingTimeInterval(180))
  equal(entry(look, "films")?.status, .unsure, "big videos are no kind the owner said yes to")
  let asked: AutopilotQuestion? = look.questions.first { $0.kind == .worktree }
  equal(asked?.risks?.contains("bigMedia=yes"), true, "they are asked about")
  equal(asked?.guess?.sure, false)
  checkFalse(world.burns.all.contains("worktree:films"), "and not burned")

  _ = try await engine.apply(.tellUndo(id: tell.id), now: now.addingTimeInterval(240))
  let undone: AutopilotTell? = try store.memory().tells.first { $0.id == tell.id }
  equal(undone?.state, "undone")
  equal(
    undone?.note, "1 copy came back without its big unsaved files, which were deleted for good.",
    "Undo says what it couldn't bring back")
  equal(undone?.seen, false, "and waits for the owner's OK")
}

/// Big unsaved files through the engine (spec 1–8).
func bigFilesProof() async throws {
  try await bigFilesYesProof()
  try await bigFilesNoProof()
  try await unnamedRefusalProof()
  try await ownCallProof()
}
