import Foundation

/// Unsaved files too big to back up: a folder Git tracks nothing in, or a single untracked file, in
/// an old copy. Retire names them when it can't back the copy up; a Yes to a card that showed them
/// deletes them.
public struct AutopilotBigFiles: Codable, Sendable, Equatable {
  /// Where it is in the copy: "tmp/checkouts".
  public var path: String
  public var bytes: UInt64
  public var files: Int
  /// What most of its bytes are: "TypeScript files", "videos", or just "files".
  public var kind: String
  /// When a file in it last changed.
  public var changed: Date?
  public init(path: String, bytes: UInt64, files: Int, kind: String, changed: Date?) {
    self.path = path
    self.bytes = bytes
    self.files = files
    self.kind = kind
    self.changed = changed
  }
}

/// One unsaved file in a copy, as retire finds it.
public struct AutopilotUnsavedFile: Sendable, Equatable {
  public var path: String
  public var bytes: UInt64
  public var changed: Date
  public init(path: String, bytes: UInt64, changed: Date) {
    self.path = path
    self.bytes = bytes
    self.changed = changed
  }
}

extension AutopilotWorktrees {
  /// Why retire leaves a copy with big unsaved files alone. It promises nothing more: whether the
  /// owner is asked depends on the rules every question follows.
  public static let bigFilesRefusal =
    "It has big files that aren't saved anywhere else, so I left it alone."
  /// Refusals for big files that named none, as builds before they were named wrote them. Such a
  /// refusal doesn't stand: trying again names them, so the owner can be asked.
  static let unnamedBigFiles: Set<String> = [
    "It has big files that aren't saved anywhere else, so I'll ask you before touching it.",
    bigFilesRefusal,
  ]

  /// Whether retire deletes a copy's big unsaved files instead of leaving the copy alone: only for
  /// a copy the catalog knew holds them (`bigFiles=yes`) that burns under an owner's lesson. The
  /// policy lets no lesson burn such a copy unless it names them, and never a starter rule, the AI
  /// or BZ's own call; the owner's Burn now still leaves it alone, since no card showed the files.
  public static func dropsBigFiles(_ item: AutopilotItem, authority: String) -> Bool {
    item.facts["bigFiles"] == "yes" && authority.hasPrefix("rule:")
  }

  /// The unsaved files to leave out of a backup that can't hold them all (`limit`), biggest first
  /// and only as many as it takes:
  /// 1. inside each folder Git tracks nothing in (an `entries` path ending in "/", as `git ls-files
  ///    --others --directory` lists it), the deepest folder holding `worth` or more when none of
  ///    its own folders does: a folder of checkouts is one, not each checkout; and each single
  ///    untracked file of `worth` or more elsewhere;
  /// 2. if that isn't enough, whole entries, biggest first.
  /// A folder that holds a file Git tracks is never taken whole, so new work beside generated
  /// output stays in the backup. Empty when everything fits.
  public static func bigFiles(
    _ files: [AutopilotUnsavedFile], entries: [String], limit: UInt64 = maximumUnsavedBytes,
    worth: UInt64 = AutopilotPolicy.worthBytes
  ) -> [AutopilotBigFiles] {
    var left: UInt64 = files.reduce(0) { $0 + $1.bytes }
    guard left > limit else { return [] }
    let roots = Set(entries.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) })
    // What each folder inside a folder Git tracks nothing in holds, and what each entry holds.
    var folders: [String: Pile] = [:]
    var tops: [String: Pile] = [:]
    for file in files {
      var prefix = ""
      var root: String?
      for part in file.path.split(separator: "/").dropLast() {
        prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
        if root == nil && roots.contains(prefix) { root = prefix }
        if root != nil { folders[prefix, default: Pile()].add(file) }
      }
      tops[root ?? file.path, default: Pile()].add(file)
    }
    var holdsBig = Set<String>()
    for (path, pile) in folders where pile.bytes >= worth {
      if let slash = path.lastIndex(of: "/") { holdsBig.insert(String(path[..<slash])) }
    }
    var candidates: [(path: String, pile: Pile)] = []
    for (path, pile) in folders where pile.bytes >= worth && !holdsBig.contains(path) {
      candidates.append((path, pile))
    }
    for (path, pile) in tops where !roots.contains(path) && pile.bytes >= worth {
      candidates.append((path, pile))
    }
    var chosen: [(path: String, pile: Pile)] = []
    for candidate in candidates.sorted(by: Pile.biggest) where left > limit {
      chosen.append(candidate)
      left -= candidate.pile.bytes
    }
    // Not enough: whole entries, biggest first, each taking in what was chosen inside it.
    let entriesFirst: [(path: String, pile: Pile)] = tops.map { ($0.key, $0.value) }
    for entry in entriesFirst.sorted(by: Pile.biggest) where left > limit {
      guard !chosen.contains(where: { $0.path == entry.path }) else { continue }
      let inside: (String) -> Bool = { $0.hasPrefix(entry.path + "/") }
      let already: UInt64 = chosen.filter { inside($0.path) }.reduce(0) { $0 + $1.pile.bytes }
      chosen.removeAll { inside($0.path) }
      chosen.append(entry)
      left -= entry.pile.bytes - already
    }
    return chosen.sorted(by: Pile.biggest).map { path, pile in
      AutopilotBigFiles(
        path: path, bytes: pile.bytes, files: pile.files, kind: pile.kind, changed: pile.newest)
    }
  }

  /// What a file's name says it is, in the words a card uses for many of them.
  static func kind(of path: String) -> String {
    let name: Substring = path.split(separator: "/").last ?? ""
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "files" }
    let suffix: String = name[name.index(after: dot)...].lowercased()
    return kinds[suffix] ?? "files"
  }

  static let kinds: [String: String] = {
    let groups: [(String, [String])] = [
      ("TypeScript files", ["ts", "tsx", "mts", "cts"]),
      ("JavaScript files", ["js", "jsx", "mjs", "cjs"]),
      ("JSON files", ["json", "jsonl", "ndjson"]),
      ("Python files", ["py", "pyc"]),
      ("images", ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "psd"]),
      ("videos", ["mp4", "mov", "webm", "mkv", "avi", "m4v"]),
      ("audio files", ["mp3", "wav", "aac", "m4a", "flac", "ogg"]),
      ("archives", ["zip", "tar", "gz", "tgz", "xz", "bz2", "7z", "rar", "zst"]),
      ("disk images", ["dmg", "iso", "img"]),
      ("databases", ["sqlite", "sqlite3", "db", "sql"]),
      ("logs", ["log"]),
      ("data files", ["csv", "tsv", "parquet", "arrow", "npy"]),
    ]
    var byExtension: [String: String] = [:]
    for (words, suffixes) in groups {
      for suffix in suffixes { byExtension[suffix] = words }
    }
    return byExtension
  }()
}

/// Unsaved files added up: how many, how big, when one last changed and what kinds they are.
private struct Pile {
  var bytes: UInt64 = 0
  var files = 0
  var newest: Date?
  var kinds: [String: UInt64] = [:]

  mutating func add(_ file: AutopilotUnsavedFile) {
    bytes += file.bytes
    files += 1
    newest = max(newest ?? file.changed, file.changed)
    kinds[AutopilotWorktrees.kind(of: file.path), default: 0] += file.bytes
  }

  /// The kind most of its bytes are, or "files" when no kind is half of them.
  var kind: String {
    let top = kinds.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
    guard let top, top.value * 2 >= bytes else { return "files" }
    return top.key
  }

  static func biggest(_ a: (path: String, pile: Pile), _ b: (path: String, pile: Pile)) -> Bool {
    a.pile.bytes != b.pile.bytes ? a.pile.bytes > b.pile.bytes : a.path < b.path
  }
}

extension AutopilotPolicy {
  /// Risks a burn lesson covers only by naming them, by kind: the risky value, and the value of a
  /// thing without the fact. A copy's unsaved files too big to back up are deleted when it burns, so
  /// a lesson learned before a card ever showed them never burns them, nor does a starter rule, the
  /// AI or BZ's own call.
  static let namedRisks: [AutopilotKind: [(fact: String, risky: String, clear: String)]] = [
    .worktree: [(fact: "bigFiles", risky: "yes", clear: "no")]
  ]

  /// The named risks of a kind as a card lists them: "bigFiles=yes".
  static func namedRisks(_ kind: AutopilotKind) -> Set<String> {
    Set((namedRisks[kind] ?? []).map { $0.fact + "=" + $0.risky })
  }

  /// A thing's value for `fact`: its own, or for a named risk it doesn't carry, the clear one.
  static func value(_ item: AutopilotItem, _ fact: String) -> String? {
    if let own = item.facts[fact] { return own }
    return namedRisks[item.kind]?.first { $0.fact == fact }?.clear
  }

  /// A lesson's match as it covers things: a burn that leaves out a named risk covers only things
  /// clear of it. Keeps are as they are.
  static func effective(_ rule: AutopilotRule) -> [String: [String]] {
    guard rule.verdict == .burn else { return rule.match }
    var match = rule.match
    for named in namedRisks[rule.kind] ?? [] where match[named.fact] == nil {
      match[named.fact] = [named.clear]
    }
    return match
  }

  /// What a question is about, to check lessons against: its general pattern, and each named risk
  /// as its card showed it, things that carry it and things that don't, or only things that don't.
  static func askedPattern(_ question: AutopilotQuestion) -> [String: [String]] {
    var pattern = generalize(question.kind, question.match)
    let shown: Set<String> = risks(of: question)
    for named in namedRisks[question.kind] ?? [] where pattern[named.fact] == nil {
      let carried: Bool = shown.contains(named.fact + "=" + named.risky)
      pattern[named.fact] = carried ? [named.risky, named.clear] : [named.clear]
    }
    return pattern
  }

  /// Why a copy with big unsaved files waits: no question is promised, since one may not come, as
  /// when it is too small to ask about on its own.
  public static let bigFilesWait =
    "It has big files that aren't saved anywhere else, so I won't burn it without your OK."

  /// Copies retire couldn't back up for big unsaved files carry the risk `bigFiles=yes`, with what
  /// those files are, while the copy is as the refusal that named them saw it (its revision without
  /// the risk, or with it, as after the owner's Burn now). The latest such refusal of each copy
  /// counts; one that rolled out of the receipts is found again by the next refusal.
  public static func withBigFiles(_ items: [AutopilotItem], receipts: [AutopilotReceipt])
    -> [AutopilotItem]
  {
    var named: [String: AutopilotReceipt] = [:]
    for receipt in receipts where receipt.outcome == "refused" && receipt.kind == .worktree {
      if let found = receipt.bigFiles, !found.isEmpty { named[receipt.itemID] = receipt }
    }
    guard !named.isEmpty else { return items }
    return items.map { item in
      guard item.kind == .worktree, let receipt = named[item.id], let found = receipt.bigFiles
      else { return item }
      var marked = item
      marked.facts["bigFiles"] = "yes"
      marked.revision = AutopilotItem.revision(id: item.id, facts: marked.facts)
      guard receipt.revision == item.revision || receipt.revision == marked.revision else {
        return item
      }
      marked.bigFiles = found
      return marked
    }
  }

  /// The dim lines under a copy's row: each big unsaved file or folder with its size, kind and
  /// last change ("tmp/checkouts · 914 MB of TypeScript files · Oct 10"), at most two, then how many
  /// more and how big.
  static func bigFilesLines(_ files: [AutopilotBigFiles], now: Date, calendar: Calendar)
    -> [String]
  {
    var lines: [String] = []
    for file in files.prefix(2) {
      let size: String = roughly(file.bytes)
      var parts: [String] = [file.path, file.files == 1 ? size : size + " of " + file.kind]
      if let changed = file.changed { parts.append(clock(changed, now: now, calendar: calendar)) }
      lines.append(parts.joined(separator: " · "))
    }
    let rest = files.dropFirst(2)
    guard !rest.isEmpty else { return lines }
    let bytes: UInt64 = rest.reduce(0) { $0 + $1.bytes }
    return lines + ["+ \(rest.count) more, " + roughly(bytes)]
  }

  /// What a Yes costs, before anything else: "A Yes deletes its 914 MB of big unsaved files for
  /// good. Everything else in it is backed up first."
  static func bigFilesNote(_ question: AutopilotQuestion, one: Bool) -> String {
    let bytes: UInt64 = question.bigBytes ?? 0
    let size: String = bytes > 0 ? roughly(bytes) + " of " : ""
    let whose: String = one ? "its " : "their "
    let rest: String =
      one ? "Everything else in it is backed up first." : "Everything else is backed up first."
    return "A Yes deletes " + whose + size + "big unsaved files for good. " + rest
  }

  /// What a burned copy's receipt says about the big files that went with it: "Its big unsaved
  /// files (914 MB in tmp/checkouts) were deleted for good."
  static func bigFilesGone(_ files: [AutopilotBigFiles]) -> String {
    let bytes: UInt64 = files.reduce(0) { $0 + $1.bytes }
    var place: String = files.first?.path ?? ""
    if files.count > 1 { place += " and \(files.count - 1) more" }
    return "Its big unsaved files (" + roughly(bytes) + " in " + place + ") were deleted for good."
  }
}
