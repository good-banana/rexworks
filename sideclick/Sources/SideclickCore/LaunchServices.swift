import AppKit
import Foundation

public protocol HandlerRegistry: Sendable {
  func defaultHandler(forScheme scheme: String) -> String?
  func isInstalled(_ bundleID: String) -> Bool
  func applicationURL(for bundleID: String) -> URL?
  func setDefaultHandler(_ app: URL, forScheme scheme: String) async throws
  func register(app: URL) throws
  func unregister(app: URL) throws
}

private let lsregisterPath =
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

public struct SystemHandlerRegistry: HandlerRegistry {
  public init() {}

  public func defaultHandler(forScheme scheme: String) -> String? {
    guard let probe = URL(string: "\(scheme)://example.com"),
      let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
    else { return nil }
    return Bundle(url: app)?.bundleIdentifier
  }

  public func isInstalled(_ bundleID: String) -> Bool {
    applicationURL(for: bundleID) != nil
  }

  public func applicationURL(for bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
  }

  public func setDefaultHandler(_ app: URL, forScheme scheme: String) async throws {
    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
  }

  public func register(app: URL) throws {
    try lsregister(["-f", app.path])
  }

  public func unregister(app: URL) throws {
    try lsregister(["-u", app.path])
  }

  private func lsregister(_ arguments: [String]) throws {
    let result = try ProcessRunner().run(lsregisterPath, arguments)
    guard result.status == 0 else { throw OpenError("lsregister exited with \(result.status)") }
  }
}

public func recordPreviousHandlers(existing: [String: String], current: [String: String?]) -> [String: String] {
  var result = existing
  for (scheme, handler) in current {
    if let handler, handler != routerBundleID { result[scheme] = handler }
  }
  return result
}

public struct RestoreStep: Equatable, Sendable {
  public let scheme: String
  public let bundleID: String
  public let missingPrevious: String?

  public init(scheme: String, bundleID: String, missingPrevious: String?) {
    self.scheme = scheme
    self.bundleID = bundleID
    self.missingPrevious = missingPrevious
  }
}

public func restorePlan(previous: [String: String], isInstalled: (String) -> Bool) -> [RestoreStep] {
  webSchemes.map { scheme in
    guard let recorded = previous[scheme] else {
      return RestoreStep(scheme: scheme, bundleID: safariBundleID, missingPrevious: nil)
    }
    if isInstalled(recorded) { return RestoreStep(scheme: scheme, bundleID: recorded, missingPrevious: nil) }
    return RestoreStep(scheme: scheme, bundleID: safariBundleID, missingPrevious: recorded)
  }
}
