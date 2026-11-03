import Foundation
import MDViewerCore

struct OpenFailure: Error, CustomStringConvertible {
  let description: String
}

enum OpenCommand {
  static func run(_ arguments: OpenArguments) -> Never {
    do {
      _ = try open(arguments, requiresBlock: false)
      exit(0)
    } catch {
      fail("\(error)", status: 1)
    }
  }

  static func open(_ arguments: OpenArguments, requiresBlock: Bool) throws -> String? {
    guard let file = validatedMarkdownFile(arguments.file) else {
      throw OpenFailure(description: "not a Markdown file: \(arguments.file)")
    }
    let runner = ProcessRunner()
    let paths = currentPaths()
    let config = try? ConfigStore.load(paths)
    guard let rex = config?.rexPath ?? locateExecutable("rex") else { throw OpenFailure(description: "rex not found") }
    let mdViewer = config?.mdViewerPath ?? ownExecutable().path
    let viewerIsCurrent = isSameExecutable(mdViewer, ownExecutable().path)

    let target = try openTarget(
      environment: ProcessInfo.processInfo.environment,
      inspectBlock: { try? rexJSON(runner, rex, ["block", "inspect", $0, "--json"]) },
      focusedTarget: { try focusedTarget(runner, rex) })

    let lock = OpenLock.acquire(paths.openLock)
    defer { lock?.release() }
    var previews: [PreviewPane] = []
    if let window = target.window {
      let blocks = try rexJSON(runner, rex, ["block", "ls", "-s", target.session, "--json"])
      previews = reachablePreviews(previewBlocks(blockListJSON: blocks, window: window)) {
        ViewerSocketClient.query(paths.viewerSocket(block: $0))
      }
    }
    let knownPreviews =
      requiresBlock
      ? previewBlockIDs(
        blockListJSON: (try? rexJSON(runner, rex, ["block", "ls", "-s", target.session, "--json"])) ?? Data())
      : []

    let origin = viewerIsCurrent ? ViewerOrigin(themeSourceBlock: target.block, opener: target.block) : ViewerOrigin()
    let outcome = resolveOpen(
      target: target, file: file, previews: previews, policy: arguments.policy(config?.previewMode ?? .perFile)
    ) { ViewerSocketClient.send(path: $1, to: paths.viewerSocket(block: $0)) }
    var runJSON: Data?
    switch outcome {
    case .reused:
      break
    case .split(let placement):
      runJSON = try rexJSON(
        runner, rex, splitArguments(placement: placement, file: file, mdViewer: mdViewer, origin: origin))
    case .newTab(let session):
      runJSON = try rexJSON(
        runner, rex, tabArguments(session: session, file: file, mdViewer: mdViewer, origin: origin))
    }
    guard requiresBlock else { return nil }
    return openedPreviewBlock(outcome: outcome, runJSON: runJSON, knownPreviews: knownPreviews) {
      try? rexJSON(runner, rex, ["block", "ls", "-s", target.session, "--json"])
    }
  }

  private static func focusedTarget(_ runner: ProcessRunning, _ rex: String) throws -> PaneTarget {
    let clients = try rexJSON(runner, rex, ["client", "ls", "--json"])
    let sessions = try rexJSON(runner, rex, ["ls", "--json"])
    guard
      let session = selectSession(
        lastFocused: readLastFocusedSession(), clientListJSON: clients, sessionListJSON: sessions)
    else { fail("no Rex session found", status: 1) }
    let inspect = try rexJSON(runner, rex, ["session", "inspect", session, "--json"])
    return resolveTarget(sessionInspectJSON: inspect, session: session)
  }

  private static func validatedMarkdownFile(_ argument: String) -> URL? {
    let url = URL(fileURLWithPath: argument).standardizedFileURL
    guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    return url
  }

  private struct RexFailure: Error, CustomStringConvertible {
    let description: String
  }

  private static func rexJSON(_ runner: ProcessRunning, _ rex: String, _ arguments: [String]) throws
    -> Data
  {
    let result = try runner.run(rex, arguments)
    guard result.status == 0 else {
      let message = String(decoding: result.stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw RexFailure(description: message.isEmpty ? "rex exited with \(result.status)" : message)
    }
    return result.stdout
  }
}
