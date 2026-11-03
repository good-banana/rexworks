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

public struct SplitPlacement: Equatable, Sendable {
  public var anchor: PaneTarget
  public var direction: String
  public var ratio: Int

  public init(anchor: PaneTarget, direction: String, ratio: Int) {
    self.anchor = anchor
    self.direction = direction
    self.ratio = ratio
  }

  public static func beside(_ target: PaneTarget) -> SplitPlacement {
    SplitPlacement(anchor: target, direction: "right", ratio: 45)
  }

  public static func below(_ preview: PaneTarget) -> SplitPlacement {
    SplitPlacement(anchor: preview, direction: "below", ratio: 50)
  }
}

public enum OpenOutcome: Equatable, Sendable {
  case reused(block: String, message: String)
  case split(SplitPlacement)
  case newTab(session: String)
}

public enum OpenPolicy: Equatable, Sendable {
  case perFile
  case new
  case replace
}

public struct PreviewPane: Equatable, Sendable {
  public var block: String
  public var state: ViewerState?

  public init(block: String, state: ViewerState?) {
    self.block = block
    self.state = state
  }
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

private struct BlockInspect: Decodable {
  struct Block: Decodable {
    let blockID: String
    let windowID: String?

    enum CodingKeys: String, CodingKey {
      case blockID = "block_id"
      case windowID = "window_id"
    }
  }

  let sessionID: String
  let block: Block

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case block
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

public let callerBlockVariable = "REX_BLOCK"

public func callerTarget(blockInspectJSON: Data) -> PaneTarget? {
  guard let inspect = try? JSONDecoder().decode(BlockInspect.self, from: blockInspectJSON),
    let window = inspect.block.windowID
  else { return nil }
  return PaneTarget(session: inspect.sessionID, window: window, block: inspect.block.blockID)
}

public func openTarget(
  environment: [String: String],
  inspectBlock: (String) -> Data?,
  focusedTarget: () throws -> PaneTarget
) rethrows -> PaneTarget {
  if let block = environment[callerBlockVariable], !block.isEmpty,
    let target = inspectBlock(block).flatMap(callerTarget(blockInspectJSON:))
  {
    return target
  }
  return try focusedTarget()
}

public func environmentWithoutCallerBlock(_ environment: [String: String]) -> [String: String] {
  environment.filter { $0.key != callerBlockVariable }
}

public func previewBlocks(blockListJSON: Data, window: String) -> [String] {
  guard let list = try? JSONDecoder().decode(BlockList.self, from: blockListJSON) else { return [] }
  return list.blocks.filter { $0.windowID == window && $0.label == previewBlockLabel }.map(\.blockID)
}

public let previewStartupWindow: TimeInterval = 1
public let previewProbeInterval: TimeInterval = 0.05

public func reachablePreviews(
  _ blocks: [String], startupWindow: TimeInterval = previewStartupWindow, now: () -> Date = Date.init,
  sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, probe: (String) -> PreviewProbe
) -> [PreviewPane] {
  let deadline = now().addingTimeInterval(startupWindow)
  var probes: [String: PreviewProbe] = [:]
  var pending = blocks
  while true {
    for block in pending { probes[block] = probe(block) }
    pending = pending.filter { probes[$0] == .unreachable }
    let remaining = deadline.timeIntervalSince(now())
    guard !pending.isEmpty, remaining > 0 else { break }
    sleep(min(previewProbeInterval, remaining))
  }
  return blocks.map { block in
    guard case .answered(let state) = probes[block] else { return PreviewPane(block: block, state: nil) }
    return PreviewPane(block: block, state: state)
  }
}

public let themeSourceBlockOption = "--theme-source-block"
public let openerBlockOption = "--opener-block"

public struct ViewerOrigin: Equatable, Sendable {
  public var themeSourceBlock: String?
  public var opener: String?

  public init(themeSourceBlock: String? = nil, opener: String? = nil) {
    self.themeSourceBlock = themeSourceBlock
    self.opener = opener
  }
}

private func viewerCommand(file: URL, mdViewer: String, origin: ViewerOrigin) -> [String] {
  var command = [
    "--focus=false", "--shell=none", "--label", previewBlockLabel,
    "--cwd", file.deletingLastPathComponent().path,
    "--", mdViewer, "view",
  ]
  if let block = origin.themeSourceBlock { command += [themeSourceBlockOption, block] }
  if let block = origin.opener { command += [openerBlockOption, block] }
  return command + [file.path]
}

public func splitArguments(
  placement: SplitPlacement, file: URL, mdViewer: String, origin: ViewerOrigin = ViewerOrigin()
) -> [String] {
  var arguments = ["run", "--session", placement.anchor.session]
  if let block = placement.anchor.block { arguments += ["--block", block] }
  arguments += ["--split", placement.direction, "--ratio", String(placement.ratio)]
  return arguments + viewerCommand(file: file, mdViewer: mdViewer, origin: origin)
}

public func canonicalPath(_ path: String) -> String {
  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

public func isSameExecutable(_ first: String, _ second: String) -> Bool {
  canonicalPath(first) == canonicalPath(second)
}

public func tabArguments(session: String, file: URL, mdViewer: String, origin: ViewerOrigin = ViewerOrigin())
  -> [String]
{
  ["run", "--session", session] + viewerCommand(file: file, mdViewer: mdViewer, origin: origin)
}

public struct ViewArguments: Equatable, Sendable {
  public var file: String
  public var origin = ViewerOrigin()

  public init?(_ arguments: [String]) {
    guard let last = arguments.last, arguments.count % 2 == 1 else { return nil }
    file = last
    for index in stride(from: 0, to: arguments.count - 1, by: 2) {
      let value = arguments[index + 1]
      guard !value.isEmpty else { return nil }
      switch arguments[index] {
      case themeSourceBlockOption where origin.themeSourceBlock == nil: origin.themeSourceBlock = value
      case openerBlockOption where origin.opener == nil: origin.opener = value
      default: return nil
      }
    }
  }
}

private func newest(_ previews: [PreviewPane]) -> PreviewPane? {
  previews.enumerated().max { first, second in
    let firstKey = first.element.state?.openedAt ?? -.infinity
    let secondKey = second.element.state?.openedAt ?? -.infinity
    return firstKey == secondKey ? first.offset < second.offset : firstKey < secondKey
  }?.element
}

public func planOpen(
  target: PaneTarget, file: URL, previews: [PreviewPane], policy: OpenPolicy, undeliverable: Set<String> = []
) -> OpenOutcome {
  switch policy {
  case .perFile:
    let wanted = canonicalPath(file.path)
    let showing = previews.filter { $0.state?.file.map(canonicalPath) == wanted }
    if let match = newest(showing), let shown = match.state?.file {
      return .reused(block: match.block, message: shown)
    }
  case .replace:
    let reusable = previews.filter { !undeliverable.contains($0.block) }
    let opened = reusable.filter { target.block != nil && $0.state?.opener == target.block }
    if let preview = newest(opened) ?? newest(reusable) {
      return .reused(block: preview.block, message: file.path)
    }
  case .new:
    break
  }
  if let preview = newest(previews) {
    return .split(.below(PaneTarget(session: target.session, window: target.window, block: preview.block)))
  }
  if target.window != nil, target.block != nil { return .split(.beside(target)) }
  return .newTab(session: target.session)
}

public func resolveOpen(
  target: PaneTarget, file: URL, previews: [PreviewPane], policy: OpenPolicy,
  deliver: (_ block: String, _ message: String) -> Bool
) -> OpenOutcome {
  var previews = previews
  var undeliverable: Set<String> = []
  while true {
    let outcome = planOpen(
      target: target, file: file, previews: previews, policy: policy, undeliverable: undeliverable)
    guard case .reused(let block, let message) = outcome, !deliver(block, message) else { return outcome }
    if previews.contains(where: { $0.block == block && $0.state == nil }) {
      undeliverable.insert(block)
    } else {
      previews.removeAll { $0.block == block }
    }
  }
}

public enum OpenChoice: Equatable, Sendable {
  case configured
  case new
  case replace
}

public let openUsage = "usage: md-viewer open [--new | --replace] <file>"

public struct OpenArgumentsError: Error, Equatable, CustomStringConvertible {
  public let description: String
}

public struct OpenArguments: Equatable, Sendable {
  public var file: String
  public var choice: OpenChoice

  public init(file: String, choice: OpenChoice = .configured) {
    self.file = file
    self.choice = choice
  }

  public static func parse(_ arguments: [String]) -> Result<OpenArguments, OpenArgumentsError> {
    var file: String?
    var choice = OpenChoice.configured
    var acceptsOptions = true
    for argument in arguments {
      if acceptsOptions, argument == "--" {
        acceptsOptions = false
      } else if acceptsOptions, argument.hasPrefix("-"), argument != "-" {
        let requested: OpenChoice
        switch argument {
        case "--new": requested = .new
        case "--replace": requested = .replace
        default: return .failure(OpenArgumentsError(description: "unknown option: \(argument)\n\(openUsage)"))
        }
        guard choice == .configured || choice == requested else {
          return .failure(OpenArgumentsError(description: "--new and --replace cannot be used together\n\(openUsage)"))
        }
        choice = requested
      } else if file == nil {
        file = argument
      } else {
        return .failure(OpenArgumentsError(description: openUsage))
      }
    }
    guard let file else { return .failure(OpenArgumentsError(description: openUsage)) }
    return .success(OpenArguments(file: file, choice: choice))
  }

  public func policy(_ mode: PreviewMode) -> OpenPolicy {
    switch choice {
    case .new: .new
    case .replace: .replace
    case .configured: mode == .single ? .replace : .perFile
    }
  }
}
