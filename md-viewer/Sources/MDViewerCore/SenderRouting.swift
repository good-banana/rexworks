import Foundation

public enum OpenRoute: Equatable, Sendable {
  case rexPreview
  case forward(bundleID: String)
  case textEditFallback
}

public enum HandlerIdentity {
  public static let bundleID = "com.goodbanana.rexworks.md-viewer"
  public static let rexBundlePrefix = "com.superlogical.rex"
}

public func route(
  senderBundleID: String?,
  previousHandler: String?,
  handlerExists: (String) -> Bool
) -> OpenRoute {
  if let senderBundleID, senderBundleID.hasPrefix(HandlerIdentity.rexBundlePrefix) {
    return .rexPreview
  }
  if let previousHandler, previousHandler != HandlerIdentity.bundleID, handlerExists(previousHandler) {
    return .forward(bundleID: previousHandler)
  }
  return .textEditFallback
}

public func forwardRoute(previousHandler: String?, handlerExists: (String) -> Bool) -> OpenRoute {
  route(senderBundleID: nil, previousHandler: previousHandler, handlerExists: handlerExists)
}
