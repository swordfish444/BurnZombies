import AppKit
import BurnCore
import Darwin
import Foundation

enum BlazerMapCommand {
  static func run(_ arguments: [String]) throws {
    let flags = Set(arguments)
    guard flags.count == arguments.count, flags.isSubset(of: ["--demo", "--json", "--open"]),
      !(flags.contains("--json") && flags.contains("--open"))
    else { throw StoreError.message("Use map [--demo] [--json | --open].") }

    let snapshot = flags.contains("--demo") ? BlazerMap.demoSnapshot() : BlazerMap.scan()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if flags.contains("--json") {
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
      return
    }
    let payload = try encoder.encode(snapshot).base64EncodedString()
    let html = BlazerMapPage.html.replacingOccurrences(of: "__BLAZER_MAP_PAYLOAD__", with: payload)
    var template = Array(
      FileManager.default.temporaryDirectory.appendingPathComponent("burnzombies-map.XXXXXX").path.utf8CString)
    let directory = try template.withUnsafeMutableBufferPointer { buffer -> URL in
      guard let path = mkdtemp(buffer.baseAddress) else {
        throw StoreError.message("Could not create a private map directory.")
      }
      return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    let file = directory.appendingPathComponent("zombie-map.html")
    try Data(html.utf8).write(to: file, options: .withoutOverwriting)
    guard chmod(file.path, 0o600) == 0 else {
      throw StoreError.message("Could not secure the local map.")
    }
    print(file.path)
    if flags.contains("--open"), !NSWorkspace.shared.open(file) {
      throw StoreError.message("Could not open the browser. Open the printed file manually.")
    }
  }
}
