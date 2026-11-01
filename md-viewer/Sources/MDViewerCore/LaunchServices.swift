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
    LSCopyDefaultRoleHandlerForContentType(contentType as CFString, .viewer)?
      .takeRetainedValue() as String?
  }

  public func setDefaultHandler(_ bundleID: String, for contentType: String) throws {
    let status = LSSetDefaultRoleHandlerForContentType(
      contentType as CFString, .viewer, bundleID as CFString)
    guard status == noErr else {
      throw HandlerRegistryError(
        description: "cannot set \(bundleID) as handler for \(contentType) (status \(status))")
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
