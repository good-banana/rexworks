import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

public protocol HandlerRegistry {
  func defaultHandler(for contentType: String) -> String?
  func setDefaultHandler(_ bundleID: String, for contentType: String) throws
  func register(app: URL) throws
  func unregister(app: URL) throws
}

public struct HandlerRegistryError: Error, CustomStringConvertible {
  public let description: String
}

public let textEditBundleID = "com.apple.TextEdit"
private let lsregisterPath =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

public struct SystemHandlerRegistry: HandlerRegistry {
  public init() {}

  public func defaultHandler(for contentType: String) -> String? {
    guard let type = UTType(contentType),
      let url = NSWorkspace.shared.urlForApplication(toOpen: type)
    else { return nil }
    return Bundle(url: url)?.bundleIdentifier
  }

  public func setDefaultHandler(_ bundleID: String, for contentType: String) throws {
    guard let type = UTType(contentType) else {
      throw HandlerRegistryError(description: "unknown content type \(contentType)")
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      throw HandlerRegistryError(description: "no installed application with id \(bundleID)")
    }
    let completion = CompletionBox()
    NSWorkspace.shared.setDefaultApplication(at: url, toOpen: type) { error in
      completion.finish(error)
    }
    if let error = completion.wait() {
      throw HandlerRegistryError(
        description:
          "cannot set \(bundleID) as handler for \(contentType): \(error.localizedDescription)")
    }
  }

  public func register(app: URL) throws {
    try runLSRegister(["-f", app.path])
  }

  public func unregister(app: URL) throws {
    try runLSRegister(["-u", app.path])
  }

  private func runLSRegister(_ arguments: [String]) throws {
    let result = try ProcessRunner().run(lsregisterPath, arguments)
    guard result.status == 0 else {
      throw HandlerRegistryError(description: "lsregister exited with \(result.status)")
    }
  }
}

public func applicationURLs(forBundleID bundleID: String) -> [URL] {
  (LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?
    .takeRetainedValue() as? [URL]) ?? []
}

public func markdownContentTypes() -> [String] {
  let candidates = [
    "net.daringfireball.markdown",
    UTType(filenameExtension: "md")?.identifier,
    UTType(filenameExtension: "markdown")?.identifier,
  ]
  var seen = Set<String>()
  return candidates.compactMap { $0 }.filter { seen.insert($0).inserted }
}

public func recordPreviousHandlers(
  existing: [String: String], current: [String: String?], selfID: String
) -> [String: String] {
  var result = existing
  for (type, handler) in current {
    if let handler, handler != selfID { result[type] = handler }
  }
  return result
}

public func restorePlan(previous: [String: String], types: [String]) -> [(
  type: String, bundleID: String
)] {
  types.map { (type: $0, bundleID: previous[$0] ?? textEditBundleID) }
}

private final class CompletionBox: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var error: Error?

  func finish(_ error: Error?) {
    lock.withLock { self.error = error }
    semaphore.signal()
  }

  func wait() -> Error? {
    semaphore.wait()
    return lock.withLock { error }
  }
}
