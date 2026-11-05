import Foundation

/// A tip Teach BZ shows in the quiet corner above a question, one at a time.
public struct AutopilotTip: Equatable, Sendable, Identifiable {
  /// Where a tip makes sense. A question's tips hold in its details too, and the list's while one
  /// thing is open, so each place adds to the one before it.
  public enum Place: Int, Comparable, Sendable {
    case question, list, entry
    public static func < (a: Place, b: Place) -> Bool { a.rawValue < b.rawValue }
  }
  public var id: String
  public var text: String
  public var place: Place
  /// Comes before any other tip the first time: the card's own reassurance.
  public var opener = false
  /// What the owner does that retires it, once they know what it teaches: "details", "hover",
  /// "spare", "filter" or "flip".
  public var retiredBy: String?
}

/// Which tip comes next, the way games rotate loading-screen tips, with the rules of Valve's
/// instructor hints on top: one tip at a time, never the same one twice running, a shuffle with no
/// repeats until every tip had its turn, a limit on how often each tip shows, and a tip retires for
/// good once the owner does what it teaches. Tips for the place the owner is in come first.
public struct AutopilotTipDeck: Sendable, Equatable {
  /// How many times each tip shows before it retires.
  public static let showsEach = 3
  public var tips: [AutopilotTip]
  /// Times each tip has shown, by id; kept across launches by the app.
  public var shown: [String: Int]
  /// What the owner has done ("details", "spare"…); kept across launches too.
  public var done: Set<String>
  var bag: [String] = []
  var last: String?

  public init(tips: [AutopilotTip], shown: [String: Int] = [:], done: Set<String> = []) {
    self.tips = tips
    self.shown = shown
    self.done = done
  }

  /// Still worth showing: not retired by the owner, and not shown its limit yet.
  public func live(_ tip: AutopilotTip) -> Bool {
    if let action = tip.retiredBy, done.contains(action) { return false }
    return shown[tip.id, default: 0] < Self.showsEach
  }

  /// The next tip for `place`, counted as shown, or nil when every tip there is retired.
  public mutating func next(at place: AutopilotTip.Place, shuffle: Bool = true) -> AutopilotTip? {
    let pool = tips.filter { live($0) && $0.place <= place }
    let fresh = pool.filter { $0.id != last }
    let choices = fresh.isEmpty ? pool : fresh
    guard !choices.isEmpty else { return nil }
    var pick = choices.first { $0.opener && shown[$0.id, default: 0] == 0 }
    if pick == nil {
      // Unseen tips for where the owner is now, the most specific place first.
      let unseen = choices.filter { $0.place > .question && shown[$0.id, default: 0] == 0 }
      pick = unseen.max { $0.place < $1.place }
    }
    if pick == nil {
      bag.removeAll { id in !choices.contains { $0.id == id } }
      if bag.isEmpty {
        bag = choices.map(\.id)
        if shuffle { bag.shuffle() }
      }
      let id = bag.removeFirst()
      pick = choices.first { $0.id == id }
    }
    guard let tip = pick else { return nil }
    shown[tip.id, default: 0] += 1
    last = tip.id
    bag.removeAll { $0 == tip.id }
    return tip
  }

  /// The owner did `action`: tips it retires never show again. True when `showing` is one of them,
  /// so the corner lets it go at once.
  @discardableResult public mutating func did(_ action: String, showing: AutopilotTip? = nil) -> Bool {
    done.insert(action)
    return showing?.retiredBy == action
  }
}

extension AutopilotPolicy {
  /// The tips for a question about `kind`: the card's own reassurance first, then what the other
  /// words on the card mean, then how to use the details. `filters` says whether the details offer
  /// risk filters, so no tip points at something that isn't there.
  public static func tips(for kind: AutopilotKind, filters: Bool) -> [AutopilotTip] {
    let one: String
    let many: String
    var own: [AutopilotTip]
    switch kind {
    case .worktree:
      one = "copy"
      many = "copies"
      own = [
        AutopilotTip(
          id: "backup", text: "Every copy is backed up before it burns, so you can undo it.",
          place: .question, opener: true),
        AutopilotTip(
          id: "local",
          text: "“Work only on this Mac” means commits never pushed. The backup keeps them too.",
          place: .question),
        AutopilotTip(
          id: "unsaved", text: "Unsaved changes go into the backup too, before anything burns.",
          place: .question),
        AutopilotTip(
          id: "safe", text: "I never touch your main project folder, or a copy a chat is still using.",
          place: .question),
      ]
    case .process:
      one = "program"
      many = "programs"
      own = [
        AutopilotTip(
          id: "quit", text: "A burned program just stops. If something needs it, a fresh one starts.",
          place: .question, opener: true)
      ]
    case .disk:
      one = "folder"
      many = "folders"
      own = [
        AutopilotTip(
          id: "rebuild", text: "These folders come back on their own when your tools need them.",
          place: .question, opener: true)
      ]
    }
    var all = own + [
      AutopilotTip(
        id: "teach", text: "Each answer teaches me. Next time I’ll handle \(many) like these myself.",
        place: .question),
      AutopilotTip(id: "skip", text: "Not sure? Skip it, and I’ll ask again tomorrow.", place: .question),
      AutopilotTip(
        id: "details", text: "Want a closer look? View details lists every \(one).", place: .question,
        retiredBy: "details"),
      AutopilotTip(
        id: "hover", text: "Rest the pointer on a \(one) to see everything I know about it.",
        place: .list, retiredBy: "hover"),
      AutopilotTip(
        id: "spare", text: "Spare a \(one) to keep it out of the fire, now and later.",
        place: .list, retiredBy: "spare"),
      AutopilotTip(
        id: "flip", text: "Flip through them with ← and →. Esc takes you back to the list.",
        place: .entry, retiredBy: "flip"),
    ]
    if filters {
      all.append(
        AutopilotTip(
          id: "filters", text: "The filters show just the risky ones.", place: .list,
          retiredBy: "filter"))
    }
    return all
  }
}
