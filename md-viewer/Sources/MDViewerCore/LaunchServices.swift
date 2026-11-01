import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

public protocol HandlerRegistry: Sendable {
  func defaultHandler(for contentType: String) -> String?
  func isInstalled(_ bundleID: String) -> Bool
  func setDefaultHandler(_ bundleID: String, for contentType: String) async throws
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

  public func isInstalled(_ bundleID: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
  }

  public func setDefaultHandler(_ bundleID: String, for contentType: String) async throws {
    guard let type = UTType(contentType) else {
      throw HandlerRegistryError(description: "unknown content type \(contentType)")
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      throw HandlerRegistryError(description: "no installed application with id \(bundleID)")
    }
    do {
      try await NSWorkspace.shared.setDefaultApplication(at: url, toOpen: type)
    } catch {
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

public struct RestoreStep: Equatable, Sendable {
  public let type: String
  public let bundleID: String
  public let missingPrevious: String?
}

public func restorePlan(
  previous: [String: String], types: [String], isInstalled: (String) -> Bool
) -> [RestoreStep] {
  types.map { type in
    guard let recorded = previous[type] else {
      return RestoreStep(type: type, bundleID: textEditBundleID, missingPrevious: nil)
    }
    if isInstalled(recorded) {
      return RestoreStep(type: type, bundleID: recorded, missingPrevious: nil)
    }
    return RestoreStep(type: type, bundleID: textEditBundleID, missingPrevious: recorded)
  }
}
