import BurnCore
import Foundation

/// 30 answers from one real Mac, in the order given (3 are skips), with project names replaced.
/// The spec's reference replay (docs/superpowers/specs/2026-11-04-teach-intent-design.md, 4.1) gives:
/// 27 answers; 3 settled and 7 acted, all matching the owner (126.6 GB); 17 asked; 13 of 14
/// guesses right; 17 lessons.
let teachHistoryJSON = #"""
  [
  {"answer":"yes","answered":815344408.101968,"asked":815339153.575284,"bytes":0,"count":1,"examples":[],"id":"q01","kind":"worktree","match":{"saved":["merged"],"stale":["week"]},"question":"Question 1?","source":"native","why":""},
  {"answer":"yes","answered":815344416.293365,"asked":815339153.575284,"bytes":88305664,"count":2,"examples":[],"id":"q02","kind":"worktree","match":{"place":["agent"],"saved":["pushed"],"stale":["month"]},"question":"Question 2?","source":"native","why":""},
  {"answer":"yes","answered":815344423.814197,"asked":815339784.236719,"bytes":2278522880,"count":1,"examples":[],"id":"q03","kind":"process","match":{"family":["java"],"idle":["1h"],"listening":["yes"]},"question":"Question 3?","source":"native","why":""},
  {"answer":"yes","answered":815344434.984615,"asked":815344408.101968,"bytes":20944437248,"count":43,"examples":[],"id":"q04","kind":"worktree","match":{"saved":["merged"],"stale":["day"]},"question":"Question 4?","source":"native","why":""},
  {"answer":"yes","answered":815344450.806078,"asked":815344416.293365,"bytes":18116608,"count":11,"examples":[],"id":"q05","kind":"worktree","match":{"place":["agent"],"saved":["pushed"],"stale":["week"]},"question":"Question 5?","source":"native","why":""},
  {"answer":"skip","answered":815344466.537545,"asked":815344423.814197,"bytes":3113058304,"count":2,"examples":[],"id":"q06","kind":"process","match":{"agent":["codex"],"family":["java"],"idle":["10m"]},"question":"Question 6?","source":"native","why":""},
  {"answer":"yes","answered":815344475.615509,"asked":815344434.984615,"bytes":307904512,"count":7,"examples":[],"id":"q07","kind":"worktree","match":{"place":["agent"],"saved":["pushed"],"stale":["day"]},"question":"Question 7?","source":"native","why":""},
  {"answer":"yes","answered":815344490.564608,"asked":815344450.806078,"bytes":500924416,"count":3,"examples":[],"id":"q08","kind":"process","match":{"family":["node"],"idle":["1d"],"listening":["yes"]},"question":"Question 8?","source":"native","why":""},
  {"answer":"skip","answered":815344505.193602,"asked":815344466.537545,"bytes":3113058304,"count":2,"examples":[],"id":"q09","kind":"process","match":{"family":["java"],"idle":["10m"],"listening":["yes"]},"question":"Question 9?","source":"native","why":""},
  {"answer":"yes","answered":815344528.009682,"asked":815344475.615509,"bytes":58548224,"count":3,"examples":[],"id":"q10","kind":"worktree","match":{"saved":["local"],"stale":["week"]},"question":"Question 10?","source":"native","why":""},
  {"answer":"skip","answered":815344544.574809,"asked":815344505.193602,"bytes":3113058304,"count":2,"examples":[],"id":"q11","kind":"process","match":{"agent":["codex"],"family":["java"],"idle":["10m"],"thread":["none"]},"question":"Question 11?","source":"native","why":""},
  {"answer":"no","answered":815344552.995677,"asked":815344544.574809,"bytes":3113058304,"count":2,"examples":[],"id":"q12","kind":"process","match":{"agent":["codex"],"family":["java"],"idle":["10m"],"listening":["yes"]},"question":"Question 12?","source":"native","why":""},
  {"answer":"yes","answered":815345510.77211,"asked":815345042.570276,"bytes":55012274176,"count":81,"examples":[],"id":"q13","kind":"worktree","match":{"changes":["small"],"inUse":["no"],"place":["other"],"repo":["project-1"],"saved":["unknown"],"stale":["day"],"thread":["none"]},"question":"Question 13?","source":"ai","why":""},
  {"answer":"yes","answered":815345525.662173,"asked":815345044.011777,"bytes":16129810432,"count":97,"examples":[],"id":"q14","kind":"worktree","match":{"changes":["none"],"inUse":["no"],"place":["agent"],"saved":["unknown"],"stale":["day"],"thread":["none"]},"question":"Question 14?","source":"ai","why":""},
  {"answer":"yes","answered":815345536.704973,"asked":815345510.77211,"bytes":20286631936,"count":5,"examples":[],"id":"q15","kind":"disk","match":{"folder":["package-cache"],"stale":["day"]},"question":"Question 15?","source":"native","why":""},
  {"answer":"yes","answered":815345577.375569,"asked":815345525.662173,"bytes":10039296,"count":2,"examples":[],"id":"q16","kind":"worktree","match":{"place":["agent"],"saved":["local"],"stale":["day"]},"question":"Question 16?","source":"native","why":""},
  {"answer":"yes","answered":815345585.034325,"asked":815345525.662173,"bytes":10228899840,"count":6,"examples":[],"id":"q17","kind":"disk","match":{"folder":["node_modules"],"home":["repo"],"stale":["day"]},"question":"Question 17?","source":"native","why":""},
  {"answer":"yes","answered":815345592.808369,"asked":815345536.704973,"bytes":3352133632,"count":9,"examples":[],"id":"q18","kind":"disk","match":{"folder":["build-output"],"home":["repo"],"stale":["day"]},"question":"Question 18?","source":"native","why":""},
  {"answer":"yes","answered":815350034.453929,"asked":815349593.588538,"bytes":3159154688,"count":2,"examples":[],"id":"q19","kind":"worktree","match":{"changes":["small","large"],"inUse":["no"],"place":["other"],"repo":["project-1"],"saved":["unknown"],"stale":["day","week"],"thread":["none"]},"question":"Question 19?","source":"ai","why":""},
  {"answer":"yes","answered":815350040.353278,"asked":815349665.232129,"bytes":99499159552,"count":17,"examples":[],"id":"q20","kind":"worktree","match":{"changes":["unknown"],"inUse":["unknown"],"place":["codex","other"],"repo":["project-1"],"saved":["merged"],"size":["large"],"stale":["unknown"],"thread":["none"]},"question":"Question 20?","source":"ai","why":""},
  {"answer":"yes","answered":815350047.308454,"asked":815349689.206595,"bytes":17047687168,"count":12,"examples":[],"id":"q21","kind":"worktree","match":{"changes":["unknown","none"],"inUse":["unknown","no"],"place":["agent"],"saved":["pushed","merged"],"stale":["unknown"],"thread":["none"]},"question":"Question 21?","source":"ai","why":""},
  {"answer":"yes","answered":815357698.395036,"asked":815357553.805703,"bytes":10765819904,"count":4,"examples":[],"id":"q22","kind":"worktree","match":{"place":["other"],"repo":["project-2"],"saved":["merged"],"size":["large"],"thread":["none"]},"question":"Question 22?","source":"ai","why":""},
  {"answer":"yes","answered":815357707.673395,"asked":815357592.107032,"bytes":5449826304,"cautions":["1 is still running a server"],"count":1,"examples":[],"id":"q23","kind":"process","match":{"family":["node"],"idle":["10m"]},"question":"Question 23?","source":"native","why":""},
  {"answer":"yes","answered":815357715.374428,"asked":815357687.615116,"bytes":1744482304,"count":2,"examples":[],"id":"q24","kind":"worktree","match":{"place":["other"],"repo":["project-1"],"saved":["merged"],"size":["medium"],"thread":["none"]},"question":"Question 24?","source":"ai","why":""},
  {"answer":"yes","answered":815365571.717189,"asked":815364276.228116,"bytes":11703246848,"count":4,"examples":[],"id":"q25","kind":"worktree","match":{"changes":["none"],"inUse":["no"],"place":["agent"],"saved":["merged","pushed"],"size":["large"],"stale":["today"],"thread":["none"]},"question":"Question 25?","source":"ai","why":""},
  {"answer":"yes","answered":815406630.906904,"asked":815371634.804161,"bytes":1365024768,"count":4,"examples":[],"id":"q26","kind":"worktree","match":{"place":["other"],"repo":["project-3","project-4","project-5"],"saved":["merged"],"size":["medium"],"thread":["none"]},"question":"Question 26?","source":"ai","why":""},
  {"answer":"yes","answered":815411182.219906,"asked":815408114.730534,"bytes":7666868224,"cautions":["3 have work only on this Mac","4 have unsaved changes"],"count":4,"examples":[],"id":"q27","kind":"worktree","match":{"changes":["small","large"],"inUse":["no"],"place":["codex"],"repo":["project-1"],"saved":["local","pushed"],"stale":["day","week"],"thread":["none"]},"question":"Question 27?","source":"ai","why":""},
  {"answer":"yes","answered":815411188.109151,"asked":815410502.879395,"bytes":5884166144,"count":3,"examples":[],"id":"q28","kind":"worktree","match":{"changes":["none"],"place":["claude","codex"],"repo":["project-1","project-2"],"saved":["merged"],"size":["large"],"thread":["ended"]},"question":"Question 28?","source":"ai","why":""},
  {"answer":"yes","answered":815411193.900898,"asked":815410685.023674,"bytes":63224664064,"cautions":["3 have unsaved changes"],"count":3,"examples":[],"id":"q29","kind":"worktree","match":{"changes":["none","small"],"place":["codex"],"repo":["project-1"],"saved":["merged"],"size":["large"],"thread":["none"]},"question":"Question 29?","source":"ai","why":""},
  {"answer":"yes","answered":815416762.87842,"asked":815413134.940346,"bytes":2753368064,"count":5,"examples":[],"id":"q30","kind":"worktree","match":{"changes":["none"],"inUse":["no"],"place":["agent"],"saved":["merged","pushed"],"size":["medium"],"stale":["today"],"thread":["none"]},"question":"Question 30?","source":"ai","why":""}
  ]
  """#

/// The owner's anonymized answers (`teachHistoryJSON`), 30 questions with 3 skips.
func teachHistory() throws -> [AutopilotQuestion] {
  try JSONDecoder().decode([AutopilotQuestion].self, from: Data(teachHistoryJSON.utf8))
}

/// Version-1 memory made from the teach history the way it was before lessons: one rule per Yes or
/// No, widened, keeping the project and maker it was asked about.
func teachHistoryVersion1(_ history: [AutopilotQuestion]) -> AutopilotMemory {
  var memory = AutopilotMemory()
  memory.version = 1
  memory.questions = history
  for q in history {
    guard let answer = q.answer, answer != .skip else { continue }
    let verdict: AutopilotVerdict = answer == .yes ? .burn : .keep
    memory.rules.append(
      AutopilotRule(
        kind: q.kind, match: AutopilotPolicy.widen(q.match, verdict: verdict), verdict: verdict,
        source: .operator, title: AutopilotPolicy.ruleTitle(q, answer: answer),
        created: q.answered ?? q.asked, questionID: q.id))
  }
  return memory
}

/// The lessons the teach history leaves, by match, worked out by hand from the fixture.
enum TeachLessons {
  static let ages = ["day", "week", "month", "older"]
  /// q16 with q01, q02, q04, q05, q07, q10 and q27 in it.
  static let copiesDay: [String: [String]] = [
    "saved": ["local", "pushed", "merged"], "stale": ages,
  ]
  /// q13 with q14.
  static let unchecked: [String: [String]] = [
    "changes": ["small", "none"], "inUse": ["no"], "saved": ["unknown"], "stale": ages,
    "thread": ["none", "ended"],
  ]
  /// q19.
  static let unsavedUnchecked: [String: [String]] = [
    "changes": ["small", "large"], "inUse": ["no"], "saved": ["unknown"], "stale": ["day", "week"],
    "thread": ["none", "ended"],
  ]
  /// q25 with q30.
  static let sameDay: [String: [String]] = [
    "changes": ["none"], "inUse": ["no"], "saved": ["merged", "pushed"],
    "stale": ["today"] + ages, "thread": ["none", "ended"],
  ]
  static let javaBurn: [String: [String]] = [
    "family": ["java"], "idle": ["1h", "6h", "1d"], "listening": ["yes", "no"],
  ]
  /// q23 with q08.
  static let nodeBurn: [String: [String]] = [
    "family": ["node"], "idle": ["10m", "1h", "6h", "1d"],
  ]
  static let javaKeep: [String: [String]] = [
    "family": ["java"], "idle": ["active", "10m"], "listening": ["yes"],
  ]
  static let caches: [String: [String]] = ["folder": ["package-cache"], "stale": ages]
  static let modules: [String: [String]] = [
    "folder": ["node_modules"], "home": ["repo"], "stale": ages,
  ]
  static let builds: [String: [String]] = [
    "folder": ["build-output"], "home": ["repo"], "stale": ages,
  ]
  /// Answers whose rules don't pin recency, so they stay exactly as they were.
  static let anyAge = ["q20", "q21", "q22", "q24", "q26", "q28", "q29"]

  static func id(_ kind: AutopilotKind, _ match: [String: [String]], _ verdict: AutopilotVerdict)
    -> String
  {
    AutopilotRule.key(kind: kind, match: match) + ":" + verdict.rawValue
  }
  static var copiesDayID: String { id(.worktree, copiesDay, .burn) }
  static var javaKeepID: String { id(.process, javaKeep, .keep) }
  /// The rule q04 taught before lessons: no project in it, so the lesson keeps its id.
  static var q04ID: String {
    id(.worktree, ["saved": ["merged"], "stale": ages], .burn)
  }
  /// The rule q07 taught before lessons, naming who made the copies.
  static var q07ID: String {
    id(.worktree, ["place": ["agent"], "saved": ["pushed", "merged"], "stale": ages], .burn)
  }
}

/// Burns, a restore and receipts no lesson made, by the rule q04 taught before lessons.
func teachHistoryReceipts() -> [AutopilotReceipt] {
  let old = "rule:" + TeachLessons.q04ID
  func receipt(_ authority: String, _ outcome: String, _ gigabytes: UInt64) -> AutopilotReceipt {
    AutopilotReceipt(
      itemID: "worktree:" + UUID().uuidString, kind: .worktree, name: "copy",
      authority: authority, outcome: outcome, detail: "", bytes: gigabytes * 1_000_000_000,
      date: Date(timeIntervalSinceReferenceDate: 815_420_000))
  }
  return [
    receipt(old, "burned", 1), receipt(old, "burned", 2), receipt(old, "restored", 4),
    receipt(old, "refused", 8), receipt(old, "verifying", 16), receipt(old, "failed", 32),
    receipt("starter:starter-finished-copies", "burned", 64), receipt("ai:0.90", "burned", 128),
    receipt("operator", "burned", 256),
  ]
}
