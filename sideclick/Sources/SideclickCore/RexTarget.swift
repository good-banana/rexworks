import Foundation

public struct PaneTarget: Equatable, Sendable {
  public var session: String
  public var window: String
  public var block: String

  public init(session: String, window: String, block: String) {
    self.session = session
    self.window = window
    self.block = block
  }
}

private struct FocusPreference: Decodable {
  let sessionID: String
}

public func lastFocusedSession(preferencesData: Data?) -> String? {
  guard let preferencesData else { return nil }
  return (try? JSONDecoder().decode(FocusPreference.self, from: preferencesData))?.sessionID
}

public func readLastFocusedSession() -> String? {
  lastFocusedSession(
    preferencesData: UserDefaults(suiteName: rexBundleID)?.data(forKey: "Workspace.lastFocusedSession"))
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

public func selectSession(lastFocused: String?, clientListJSON: Data) -> String? {
  let appSessions =
    (try? JSONDecoder().decode(ClientList.self, from: clientListJSON))?
    .clients.first { $0.info?.kind == "app" }?.sessionIDs ?? []
  if let lastFocused, appSessions.contains(lastFocused) { return lastFocused }
  return appSessions.first
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

public func focusedPane(sessionInspectJSON: Data, session: String) -> PaneTarget? {
  guard let inspect = try? JSONDecoder().decode(SessionInspect.self, from: sessionInspectJSON),
    let active = inspect.activeWindowID,
    let window = inspect.windows.first(where: { $0.windowID == active }),
    let block = window.focusedBlockID
  else { return nil }
  return PaneTarget(session: session, window: active, block: block)
}

private struct BlockList: Decodable {
  struct Block: Decodable {
    let blockID: String
    let windowID: String?

    enum CodingKeys: String, CodingKey {
      case blockID = "block_id"
      case windowID = "window_id"
    }
  }

  let blocks: [Block]
}

public func windowBlocks(blockListJSON: Data, target: PaneTarget) -> [String] {
  let inWindow =
    (try? JSONDecoder().decode(BlockList.self, from: blockListJSON))?
    .blocks.filter { $0.windowID == target.window }.map(\.blockID) ?? []
  return [target.block] + inWindow.filter { $0 != target.block }
}

private struct BlockProcess: Decodable {
  struct Child: Decodable {
    let pid: Int32
  }

  let child: Child?
}

public func childPID(processJSON: Data) -> Int32? {
  (try? JSONDecoder().decode(BlockProcess.self, from: processJSON))?.child?.pid
}
