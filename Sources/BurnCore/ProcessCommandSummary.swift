import Foundation

/// Only arguments occupying a known task-identification position are exposed. Unknown flags
/// close the grammar: their values cannot become script names, options or positional secrets.
public enum ProcessCommandSummary {
  public static func describe(_ arguments: [String], executable: String) -> String {
    let program = URL(fileURLWithPath: executable).lastPathComponent
    let interpreter =
      ["node", "nodejs", "bun", "deno", "python", "python3", "ruby", "sh", "bash", "zsh"].contains(
        program)
      || program.range(of: "^python3\\.[0-9]+$", options: .regularExpression) != nil
    let tools: Set<String> = [
      "npm", "npx", "pnpm", "yarn", "bun", "deno", "vite", "vitest", "pytest", "jest", "next",
      "webpack", "esbuild", "playwright",
    ]
    let words: Set<String> = [
      "run", "test", "build", "dev", "start", "serve", "watch", "install", "vite", "vitest",
      "pytest", "jest", "tsc", "next", "webpack", "esbuild", "playwright",
    ]
    let counts: Set<String> = ["--port", "--workers", "--concurrency", "--max-old-space-size"]
    let switches: Set<String> = ["--watch", "--run", "--headless", "--no-sandbox"]
    var result = [program]
    var index = 1
    while index < arguments.count {
      let value = arguments[index]
      if index == 1, interpreter, !value.hasPrefix("-"), !value.contains("://"),
        !value.contains("="), !value.contains("?"), !value.contains("\n"),
        ["js", "mjs", "cjs", "ts", "py", "sh", "rb"].contains(
          URL(fileURLWithPath: value).pathExtension),
        URL(fileURLWithPath: value).lastPathComponent.utf8.count <= 120
      {
        result.append(URL(fileURLWithPath: value).lastPathComponent)
      } else if tools.contains(program), index <= 2, words.contains(value) {
        result.append(value)
      } else if interpreter || tools.contains(program), switches.contains(value) {
        result.append(value)
      } else if interpreter || tools.contains(program), counts.contains(value),
        index + 1 < arguments.count, let number = UInt32(arguments[index + 1]), number <= 65535
      {
        result += [value, String(number)]
        index += 1
      } else if program == "sleep", index == 1, let seconds = UInt32(value), seconds <= 86400 {
        result.append(String(seconds))
      } else {
        result.append("[redacted]")
        break
      }
      index += 1
    }
    return result.joined(separator: " ")
  }
}
