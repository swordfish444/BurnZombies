import Darwin
import Foundation

public struct AppVersion: Codable, Sendable, Equatable, Comparable, CustomStringConvertible {
  public let major: UInt64
  public let minor: UInt64
  public let patch: UInt64
  public init(_ value: String) throws {
    let fields = value.split(separator: ".", omittingEmptySubsequences: false)
    guard value.count <= 64, fields.count == 3,
      fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
      let major = UInt64(fields[0]), let minor = UInt64(fields[1]), let patch = UInt64(fields[2])
    else { throw StoreError.message("The release has an invalid version.") }
    self.major = major
    self.minor = minor
    self.patch = patch
  }
  public var description: String { "\(major).\(minor).\(patch)" }
  public static func < (a: Self, b: Self) -> Bool {
    if a.major != b.major { return a.major < b.major }
    if a.minor != b.minor { return a.minor < b.minor }
    return a.patch < b.patch
  }
}

public struct AppUpdateRelease: Sendable, Equatable {
  public static let repository = "https://github.com/swordfish444/BurnZombies"
  public static let endpoint = URL(
    string: "https://api.github.com/repos/swordfish444/BurnZombies/releases/latest")!
  public static let assetName = "BurnZombies-macOS-universal.tar.gz"
  public let version: AppVersion
  public let archive: URL
  public let checksums: URL
  public let notes: URL
  public let bytes: Int64
  public let digest: String?

  public static func decode(_ data: Data) throws -> Self {
    struct Release: Decodable {
      struct Asset: Decodable {
        var name: String
        var browser_download_url: URL
        var size: Int64
        var digest: String?
      }
      var tag_name: String
      var draft: Bool
      var prerelease: Bool
      var html_url: URL
      var assets: [Asset]
    }
    guard data.count <= 1_048_576 else {
      throw StoreError.message("The update response is too large.")
    }
    let release = try JSONDecoder().decode(Release.self, from: data)
    guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v") else {
      throw StoreError.message("Only published stable BurnZombies releases can be installed.")
    }
    let version = try AppVersion(String(release.tag_name.dropFirst()))
    let base = repository + "/releases/download/v" + version.description + "/"
    let archives = release.assets.filter { $0.name == assetName }
    let sums = release.assets.filter { $0.name == "SHA256SUMS" }
    guard archives.count == 1, sums.count == 1, let archive = archives.first, let sum = sums.first,
      archive.browser_download_url.absoluteString == base + assetName,
      sum.browser_download_url.absoluteString == base + "SHA256SUMS",
      release.html_url.absoluteString == repository + "/releases/tag/v" + version.description,
      archive.size > 0, archive.size <= 268_435_456, sum.size > 0, sum.size <= 65_536
    else { throw StoreError.message("This release is missing its official app or checksums.") }
    if let digest = archive.digest {
      guard digest.hasPrefix("sha256:"), isDigest(String(digest.dropFirst(7))) else {
        throw StoreError.message("The release has an invalid download fingerprint.")
      }
    }
    return .init(
      version: version, archive: archive.browser_download_url, checksums: sum.browser_download_url,
      notes: release.html_url, bytes: archive.size, digest: archive.digest)
  }
  public static func isDigest(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isASCII && ("0123456789abcdef".contains($0)) }
  }
  public static func checksum(_ data: Data) throws -> String {
    guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
      throw StoreError.message("The release checksums could not be read.")
    }
    let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 2, fields[1] == assetName else { return nil }
      return String(fields[0])
    }
    guard matches.count == 1, let digest = matches.first, isDigest(digest) else {
      throw StoreError.message("The app's release checksum is missing or ambiguous.")
    }
    return digest
  }
}

/// One bounded, cookie-free HTTPS download. A check never sends app state or credentials.
public final class AppUpdateDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var file: FileHandle?
  private var cancelled = false
  private var received: Int64 = 0
  private var expected: Int64 = -1
  private var lastProgress: TimeInterval = 0
  private let maximum: Int64
  private let progress: @Sendable (Double?) -> Void

  public init(maximum: Int64, progress: @escaping @Sendable (Double?) -> Void = { _ in }) {
    self.maximum = maximum
    self.progress = progress
  }
  public func download(_ url: URL, to destination: URL) async throws {
    guard Self.allowed(url) else {
      throw StoreError.message("The update URL is not an official HTTPS download.")
    }
    let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StoreError.message("Could not create the private update download.") }
    file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var complete = false
    defer {
      lock.lock()
      try? file?.close()
      file = nil
      lock.unlock()
      if !complete { try? FileManager.default.removeItem(at: destination) }
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
        lock.lock()
        if cancelled {
          lock.unlock()
          next.resume(throwing: CancellationError())
          return
        }
        continuation = next
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("BurnZombies-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      self.lock.lock()
      self.cancelled = true
      let task = self.task
      self.lock.unlock()
      task?.cancel()
    }
    try Task.checkCancellation()
    complete = true
  }
  public static func allowed(_ url: URL) -> Bool {
    url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
      && [
        "api.github.com", "github.com", "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
      ].contains(url.host ?? "")
  }
  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, Self.allowed(url) else {
      completionHandler(nil)
      finish(StoreError.message("The update redirected outside GitHub's HTTPS download service."))
      return
    }
    completionHandler(request)
  }
  public func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      completionHandler(.cancel)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      finish(
        StoreError.message(
          [403, 429].contains(status)
            ? "GitHub is limiting update checks. Please try again later."
            : "GitHub could not provide this update (HTTP \(status)). Please try again."))
      return
    }
    expected = response.expectedContentLength
    guard expected <= maximum else {
      completionHandler(.cancel)
      finish(StoreError.message("The update download exceeds its size limit."))
      return
    }
    completionHandler(.allow)
  }
  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
  {
    lock.lock()
    guard continuation != nil else {
      lock.unlock()
      return
    }
    guard Int64(data.count) <= maximum - received else {
      lock.unlock()
      finish(StoreError.message("The update download exceeds its size limit."))
      return
    }
    do {
      try file?.write(contentsOf: data)
      received += Int64(data.count)
      let fraction = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
      let now = ProcessInfo.processInfo.systemUptime
      let publish = now - lastProgress >= 0.1 || fraction == 1
      if publish { lastProgress = now }
      lock.unlock()
      if publish { progress(fraction) }
    } catch {
      lock.unlock()
      finish(error)
    }
  }
  public func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    finish(error)
  }
  private func finish(_ error: Error?) {
    lock.lock()
    let next = continuation
    continuation = nil
    let session = self.session
    self.session = nil
    lock.unlock()
    guard let next else { return }
    session?.invalidateAndCancel()
    if let error { next.resume(throwing: error) } else { next.resume() }
  }
}

public enum AppUpdateClient {
  public static func check() async throws -> AppUpdateRelease {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bz-update-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("release.json")
    try await AppUpdateDownload(maximum: 1_048_576).download(AppUpdateRelease.endpoint, to: file)
    return try AppUpdateRelease.decode(Data(contentsOf: file))
  }
}
