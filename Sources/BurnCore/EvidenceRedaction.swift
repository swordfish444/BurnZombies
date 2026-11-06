import Foundation

/// The shared model-facing boundary for source, README and manifest excerpts.
enum EvidenceRedaction {
  private static let terms = [
    "password", "secret", "token", "api_key", "apikey", "credential", "authorization",
    "private key", "private_key", "sk-", "ghp_", "github_pat_", "akia", "-----begin",
  ]
  private static let assignment = try! NSRegularExpression(
    pattern:
      #"^\s*(?:-\s+)?(?:(?:export|const|let|var|val)\s+)?["']?[\w.-]*(?:password|secret|token|api[_-]?key|credentials?|authorization|private[_-]?key)(?:[_-][\w.-]+)?["']?\s*[:=]\s*(.*)$"#,
    options: [.caseInsensitive])
  private static let hereDocument = try! NSRegularExpression(
    pattern: #"<<(-?)\s*(["']?)([A-Za-z_][A-Za-z_0-9]*)\2"#)

  private static func sensitive(_ value: String) -> Bool {
    let lower = value.lowercased()
    return terms.contains(where: lower.contains)
      || lower.range(of: "://[^/ ]+@", options: .regularExpression) != nil
  }

  /// Inspect decoded JSON strings and fields before serializing. One private script/value
  /// must not discard a neighboring project name or useful build command.
  static func json(_ value: Any) -> Any? {
    if let object = value as? [String: Any] {
      let safe = object.reduce(into: [String: Any]()) { result, field in
        if sensitive(field.key) {
          result["[redacted]"] = true
        } else if let clean = json(field.value) {
          result[field.key] = clean
        }
      }
      return safe
    }
    if let array = value as? [Any] { return array.compactMap { json($0) } }
    if let string = value as? String {
      let clean = text(string)
      return !string.isEmpty && clean.isEmpty ? "[redacted]" : clean
    }
    return value
  }

  static func text(_ value: String) -> String {
    var lines: [String] = []
    var closing: String?
    var indentedAfter: Int?
    var hereEnd: String?
    var stripTabs = false
    var continued = false
    var containers: [Character] = []
    var containerQuote: Character?
    for part in value.split(separator: "\n") {
      let line = String(part.last == "\r" ? part.dropLast() : part[...])
      if let delimiter = hereEnd {
        let candidate = stripTabs ? String(line.drop { $0 == "\t" }) : line
        if candidate == delimiter { hereEnd = nil }
        continue
      }
      if let delimiter = closing {
        if ends(line, with: delimiter) { closing = nil }
        continue
      }
      if !containers.isEmpty {
        consumeContainers(line, stack: &containers, quote: &containerQuote)
        continue
      }
      if continued {
        continued = continues(line)
        continue
      }
      let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
      if let level = indentedAfter {
        if line.trimmingCharacters(in: .whitespaces).isEmpty || indentation > level { continue }
        indentedAfter = nil
      }
      if let marker = line.range(
        of: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#,
        options: [.regularExpression, .caseInsensitive])
      {
        let end = String(line[marker]).uppercased().replacingOccurrences(of: "BEGIN", with: "END")
        if !line[marker.upperBound...].uppercased().contains(end) { closing = end }
        continue
      }
      let range = NSRange(line.startIndex..., in: line)
      if let match = assignment.firstMatch(in: line, range: range),
        let tail = Range(match.range(at: 1), in: line)
      {
        let rhs = String(line[tail]).trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: #"^[\w.\[\], |]+\s*=\s*"#, with: "", options: .regularExpression)
          .replacingOccurrences(of: #"^(?:[!&][\w:!.-]+\s+)+"#, with: "", options: .regularExpression)
        let quoted = rhs.replacingOccurrences(
          of: #"^[rRuUbBfF]{1,2}(?=[\"'])"#, with: "", options: .regularExpression)
        let code = shellCode(rhs)
        if rhs.isEmpty || rhs.first == "|" || rhs.first == ">" {
          let listItem = line.dropFirst(indentation).hasPrefix("- ")
          indentedAfter = indentation + (listItem ? 2 : 0)
        } else if let delimiter = ["\"\"\"", "'''", "\"", "'", "`"].first(where: quoted.hasPrefix) {
          if !ends(String(quoted.dropFirst(delimiter.count)), with: delimiter) { closing = delimiter }
        } else if let here = hereDocument.firstMatch(
          in: code, range: NSRange(code.startIndex..., in: code)),
          let marker = Range(here.range(at: 3), in: code)
        {
          hereEnd = String(code[marker])
          stripTabs = here.range(at: 1).length == 1
        } else if rhs.first == "[" || rhs.first == "{" || rhs.hasPrefix("$(") {
          consumeContainers(rhs.hasPrefix("$(") ? String(rhs.dropFirst()) : rhs,
                            stack: &containers, quote: &containerQuote)
        } else {
          continued = continues(rhs)
        }
        continue
      }
      if !sensitive(line) { lines.append(line) }
    }
    return String(lines.joined(separator: "\n").prefix(1600))
  }

  /// Ignore shell comments and quoted examples when looking for heredoc operators.
  private static func shellCode(_ line: String) -> String {
    var result = ""
    var quote: Character?
    var escaped = false
    for character in line {
      if escaped {
        result.append(character == "<" || character == "#" ? " " : character)
        escaped = false
        continue
      }
      if character == "\\" && quote != "'" { escaped = true; result.append(character); continue }
      if let delimiter = quote {
        if character == delimiter { quote = nil }
        // Preserve a quoted heredoc marker, but hide operators inside ordinary quotes.
        result.append(character == "<" || character == "#" ? " " : character)
      } else if character == "#" && (result.isEmpty || result.last?.isWhitespace == true) {
        break
      } else {
        if character == "\"" || character == "'" || character == "`" { quote = character }
        result.append(character)
      }
    }
    return result
  }

  private static func continues(_ line: String) -> Bool {
    let code = shellCode(line).trimmingCharacters(in: .whitespaces)
    return code.reversed().prefix { $0 == "\\" }.count % 2 == 1
  }

  private static func consumeContainers(
    _ line: String, stack: inout [Character], quote: inout Character?
  ) {
    var escaped = false
    for character in line {
      if escaped { escaped = false; continue }
      if character == "\\" { escaped = true; continue }
      if let delimiter = quote {
        if character == delimiter { quote = nil }
      } else if character == "\"" || character == "'" || character == "`" {
        quote = character
      } else if character == "#" {
        break
      } else if character == "[" || character == "{" || character == "(" {
        stack.append(character == "[" ? "]" : character == "{" ? "}" : ")")
      } else if character == stack.last {
        stack.removeLast()
        if stack.isEmpty { return }
      }
    }
  }

  private static func ends(_ line: String, with delimiter: String) -> Bool {
    var search = line.startIndex..<line.endIndex
    while let match = line.range(of: delimiter, options: .caseInsensitive, range: search) {
      var before = match.lowerBound
      var escapes = 0
      while before > line.startIndex {
        let previous = line.index(before: before)
        guard line[previous] == "\\" else { break }
        escapes += 1
        before = previous
      }
      if escapes.isMultiple(of: 2) { return true }
      search = match.upperBound..<line.endIndex
    }
    return false
  }
}
