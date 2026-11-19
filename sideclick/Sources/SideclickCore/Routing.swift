import Foundation

public let rexBundleID = "com.superlogical.rex"
public let safariBundleID = "com.apple.Safari"
public let routerBundleID = "com.goodbanana.rexworks.sideclick"
public let webSchemes = ["http", "https"]

public enum Route: Equatable, Sendable {
  case pane
  case forward(bundleID: String)
}

public func route(
  url: URL, senderBundleID: String?, optionHeld: Bool, previousHandlers: [String: String],
  isInstalled: (String) -> Bool
) -> Route {
  let scheme = url.scheme?.lowercased() ?? ""
  if senderBundleID == rexBundleID, !optionHeld, webSchemes.contains(scheme) {
    return .pane
  }
  return .forward(bundleID: forwardTarget(scheme: scheme, previousHandlers: previousHandlers, isInstalled: isInstalled))
}

public func forwardTarget(scheme: String, previousHandlers: [String: String], isInstalled: (String) -> Bool)
  -> String
{
  let candidates = [previousHandlers[scheme.lowercased()]] + webSchemes.map { previousHandlers[$0] }
  for case let bundleID? in candidates where bundleID != routerBundleID && isInstalled(bundleID) {
    return bundleID
  }
  return safariBundleID
}

public func shouldReactivate(frontmostPID: Int32?, ownPID: Int32, senderRunning: Bool) -> Bool {
  guard senderRunning else { return false }
  guard let frontmostPID else { return true }
  return frontmostPID == ownPID
}
