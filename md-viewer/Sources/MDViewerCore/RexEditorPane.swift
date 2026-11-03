import Foundation

public let editorPaneLabel = "md-viewer-editor"

public enum BlockState: Equatable, Sendable {
  case found
  case notFound
  case unknown
}

public enum PaneWaitResult: Equatable, Sendable {
  case ended
  case noPayload
}

private struct RunResult: Decodable {
  let blockIDs: [String]

  enum CodingKeys: String, CodingKey {
    case blockIDs = "block_ids"
  }
}

public enum RexEditorPane {
  public static func runArguments(
    session: String, anchorBlock: String, directory: String, command: [String]
  ) -> [String] {
    [
      "run", "--json", "--session", session, "--block", anchorBlock, "--split", "left", "--ratio", "50",
      "--label", editorPaneLabel, "--cwd", directory, "--",
    ] + command
  }

  public static func focusArguments(block: String) -> [String] {
    ["focus", block]
  }

  public static func waitArguments(block: String, session: String) -> [String] {
    ["wait", block, "-s", session, "--json"]
  }

  public static func inspectArguments(block: String, session: String) -> [String] {
    ["block", "inspect", "-s", session, block]
  }

  public static func blockListArguments(session: String) -> [String] {
    ["block", "ls", "-s", session, "--json"]
  }

  public static func blockID(runJSON: Data) -> String? {
    guard let result = try? JSONDecoder().decode(RunResult.self, from: runJSON),
      result.blockIDs.count == 1
    else { return nil }
    return result.blockIDs.first
  }

  public static func fallbackBlockID(blockListJSON: Data, excluding known: Set<String>) -> String? {
    guard let list = try? JSONDecoder().decode(BlockList.self, from: blockListJSON) else { return nil }
    let candidates = list.blocks.filter { $0.label == editorPaneLabel && !known.contains($0.blockID) }
    return candidates.count == 1 ? candidates.first?.blockID : nil
  }

  public static func classifyWait(stdout: Data) -> PaneWaitResult {
    guard let payload = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
      !payload.isEmpty
    else { return .noPayload }
    return .ended
  }

  public static func classifyInspect(status: Int32, stderr: Data) -> BlockState {
    if status == 0 { return .found }
    let message = String(decoding: stderr, as: UTF8.self)
    return status == 3 && message.contains("not found") ? .notFound : .unknown
  }
}
