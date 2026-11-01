import Foundation

public struct PaneTarget: Equatable, Sendable {
  public var session: String
  public var window: String?
  public var block: String?

  public init(session: String, window: String?, block: String?) {
    self.session = session
    self.window = window
    self.block = block
  }
}

public enum OpenOutcome: Equatable, Sendable {
  case reused(block: String)
  case split(PaneTarget)
  case newTab(session: String)
}

public let previewBlockLabel = "md-viewer"

private struct FocusPreference: Decodable {
  let sessionID: String
}

private struct SessionInspect: Decodable {
  struct Window: Decodable {
    let windowID: String
    let focusedBlockID: String?

    enum CodingKeys: String, CodingKey {
      case windowID = "window_id"
      case focusedBlockID = "focused_block_id"
    }
  }

  let activeWindowID: String?
  let windows: [Window]

  enum CodingKeys: String, CodingKey {
    case activeWindowID = "active_window_id"
    case windows
  }
}

private struct BlockList: Decodable {
  struct Block: Decodable {
    let blockID: String
    let label: String?
    let windowID: String?

    enum CodingKeys: String, CodingKey {
      case blockID = "block_id"
      case label
      case windowID = "window_id"
    }
  }

  let blocks: [Block]
}

private struct ClientList: Decodable {
  struct Client: Decodable {
    struct Info: Decodable {
      let kind: String?
    }

    let info: Info?
    let sessionIDs: [String]?

    enum CodingKeys: String, CodingKey {
      case info
      case sessionIDs = "session_ids"
    }
  }

  let clients: [Client]
}

private struct SessionList: Decodable {
  struct Session: Decodable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
      case sessionID = "session_id"
    }
  }

  let sessions: [Session]
}

public func lastFocusedSession(preferencesData: Data?) -> String? {
  guard let preferencesData,
    let preference = try? JSONDecoder().decode(FocusPreference.self, from: preferencesData)
  else { return nil }
  return preference.sessionID
}

public func readLastFocusedSession() -> String? {
  let data = UserDefaults(suiteName: "com.superlogical.rex")?.data(
    forKey: "Workspace.lastFocusedSession")
  return lastFocusedSession(preferencesData: data)
}

public func selectSession(
  lastFocused: String?, clientListJSON: Data, sessionListJSON: Data
) -> String? {
  let appSessions =
    (try? JSONDecoder().decode(ClientList.self, from: clientListJSON))?
    .clients.first { $0.info?.kind == "app" }?.sessionIDs ?? []
  if let lastFocused, appSessions.contains(lastFocused) { return lastFocused }
  if let first = appSessions.first { return first }
  return (try? JSONDecoder().decode(SessionList.self, from: sessionListJSON))?
    .sessions.first?.sessionID
}

public func resolveTarget(sessionInspectJSON: Data, session: String) -> PaneTarget {
  let sessionOnly = PaneTarget(session: session, window: nil, block: nil)
  guard let inspect = try? JSONDecoder().decode(SessionInspect.self, from: sessionInspectJSON),
    let active = inspect.activeWindowID,
    let window = inspect.windows.first(where: { $0.windowID == active }),
    let block = window.focusedBlockID
  else { return sessionOnly }
  return PaneTarget(session: session, window: active, block: block)
}

public func previewBlock(blockListJSON: Data, window: String) -> String? {
  guard let list = try? JSONDecoder().decode(BlockList.self, from: blockListJSON) else {
    return nil
  }
  return list.blocks.first { $0.windowID == window && $0.label == previewBlockLabel }?.blockID
}

public let themeSourceBlockOption = "--theme-source-block"

private func viewerCommand(file: URL, mdViewer: String, themeSourceBlock: String?) -> [String] {
  [
    "--focus=false", "--shell=none", "--label", previewBlockLabel,
    "--cwd", file.deletingLastPathComponent().path,
    "--", mdViewer, "view",
  ] + (themeSourceBlock.map { [themeSourceBlockOption, $0] } ?? []) + [file.path]
}

public func splitArguments(target: PaneTarget, file: URL, mdViewer: String) -> [String] {
  var arguments = ["run", "--session", target.session]
  if let block = target.block { arguments += ["--block", block] }
  arguments += ["--split", "right", "--ratio", "45"]
  return arguments + viewerCommand(file: file, mdViewer: mdViewer, themeSourceBlock: target.block)
}

public func tabArguments(session: String, file: URL, mdViewer: String, themeSourceBlock: String? = nil)
  -> [String]
{
  ["run", "--session", session] + viewerCommand(file: file, mdViewer: mdViewer, themeSourceBlock: themeSourceBlock)
}

public struct ViewArguments: Equatable, Sendable {
  public var file: String
  public var themeSourceBlock: String?

  public init?(_ arguments: [String]) {
    switch arguments.count {
    case 1:
      file = arguments[0]
    case 3 where arguments[0] == themeSourceBlockOption && !arguments[1].isEmpty:
      themeSourceBlock = arguments[1]
      file = arguments[2]
    default:
      return nil
    }
  }
}

public func planOpen(target: PaneTarget, existingPreview: String?, previewAlive: Bool)
  -> OpenOutcome
{
  if let existingPreview, previewAlive { return .reused(block: existingPreview) }
  if target.window != nil, target.block != nil { return .split(target) }
  return .newTab(session: target.session)
}
