import Foundation

/// A browser a program drives: Playwright, Puppeteer, chromedriver, an MCP server and their kind.
/// Recognized only from the browser's own command line, read live and never kept. The browser the
/// owner uses carries none of these flags.
public struct RobotBrowser: Equatable, Sendable {
  public enum Control: String, Sendable {
    /// Over a pipe its launcher opened. Once the launcher is gone, nothing can drive it again.
    case pipe
    /// Over a debugging port, which anything on this Mac could connect to again.
    case port
  }
  public var control: Control
  /// Its profile is a temporary folder its driver made and removes when it closes the browser.
  public var throwawayProfile: Bool
  public var headless: Bool

  /// Browser executables by name, lowercased: Chrome, Chromium, Chrome for Testing, Edge, Brave,
  /// Firefox and Playwright's WebKit, wherever they are installed. Their helpers have other names.
  static let names: Set<String> = [
    "google chrome", "google chrome beta", "google chrome dev", "google chrome canary",
    "google chrome for testing", "chromium", "chrome", "chrome-headless-shell", "headless_shell",
    "microsoft edge", "microsoft edge beta", "microsoft edge dev", "microsoft edge canary",
    "msedge", "brave browser", "brave browser beta", "brave browser nightly", "firefox",
    "firefox-bin", "playwright",
  ]

  /// How the throwaway profiles of Playwright, Puppeteer and chromedriver are named.
  public static let throwawayPrefixes = [
    "playwright_chromiumdev_profile-", "playwright_firefoxdev_profile-",
    "playwright_webkitdev_profile-", "puppeteer_dev_chrome_profile-",
    "puppeteer_dev_firefox_profile-", "puppeteer_dev_profile-", ".org.chromium.Chromium.",
  ]

  public static func isBrowser(_ executable: String) -> Bool {
    names.contains((executable as NSString).lastPathComponent.lowercased())
  }

  /// The robot browser `arguments` (argv, the program first) describe, or nil for anything else:
  /// another program, a browser's helper, or a browser opened by a person. A control pipe is
  /// never opened by hand; a debugging port is, so a port counts only with a sign of automation.
  public static func fingerprint(executable: String, arguments: [String]) -> RobotBrowser? {
    guard isBrowser(executable) else { return nil }
    var pipe = false
    var port = false
    var automated = false
    var headless = false
    var profile: String?
    var index = 1
    while index < arguments.count {
      let argument = arguments[index]
      let flag = argument.lowercased()
      index += 1
      if flag.hasPrefix("--type=") { return nil }
      switch flag {
      case "--remote-debugging-pipe", "--inspector-pipe", "-juggler-pipe", "--juggler-pipe":
        pipe = true
      case "-marionette", "--marionette":
        port = true
        automated = true
      case "--enable-automation", "--use-mock-keychain", "--test-type=webdriver":
        automated = true
      case "-headless", "--headless":
        headless = true
      case "-profile", "--profile":
        if index < arguments.count {
          profile = arguments[index]
          index += 1
        }
      default:
        if flag.hasPrefix("--remote-debugging-pipe=") {
          pipe = true
        } else if flag.hasPrefix("--remote-debugging-port") {
          port = true
        } else if flag.hasPrefix("--headless=") {
          headless = true
        } else if flag.hasPrefix("--user-data-dir=") {
          profile = String(argument.dropFirst("--user-data-dir=".count))
        }
      }
    }
    let throwaway = profile.map(isThrowaway) ?? false
    if pipe {
      return RobotBrowser(control: .pipe, throwawayProfile: throwaway, headless: headless)
    }
    guard port, automated || headless || throwaway else { return nil }
    return RobotBrowser(control: .port, throwawayProfile: throwaway, headless: headless)
  }

  /// Whether a profile folder is one its tool made for a single run.
  public static func isThrowaway(_ profile: String) -> Bool {
    let name = (profile as NSString).lastPathComponent
    return throwawayPrefixes.contains(where: name.hasPrefix)
  }

  /// The outermost app bundle an executable is in ("/Applications/Google Chrome.app/"), or nil.
  public static func bundle(_ executable: String) -> String? {
    executable.range(of: ".app/").map { String(executable[..<$0.upperBound]) }
  }
}
