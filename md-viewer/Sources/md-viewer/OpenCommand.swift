import Foundation
import MDViewerCore

enum OpenCommand {
  static func run(file argument: String) -> Never {
    guard let file = validatedMarkdownFile(argument) else {
      fail("not a Markdown file: \(argument)", status: 1)
    }
    let runner = ProcessRunner()
    let paths = SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    let config = try? ConfigStore.load(paths)
    guard let rex = config?.rexPath ?? locateExecutable("rex") else { fail("rex not found", status: 1) }
    let mdViewer = config?.mdViewerPath ?? ownExecutable().path

    do {
      let clients = try rexJSON(runner, rex, ["client", "ls", "--json"])
      let sessions = try rexJSON(runner, rex, ["ls", "--json"])
      guard
        let session = selectSession(
          lastFocused: readLastFocusedSession(), clientListJSON: clients, sessionListJSON: sessions)
      else { fail("no Rex session found", status: 1) }

      let inspect = try rexJSON(runner, rex, ["session", "inspect", session, "--json"])
      let target = resolveTarget(sessionInspectJSON: inspect, session: session)

      var existing: String?
      if let window = target.window {
        let blocks = try rexJSON(runner, rex, ["block", "ls", "-s", session, "--json"])
        existing = previewBlock(blockListJSON: blocks, window: window)
      }

      switch planOpen(target: target, existingPreview: existing, previewAlive: false) {
      case .reused:
        exit(0)
      case .split(let target):
        _ = try rexJSON(runner, rex, splitArguments(target: target, file: file, mdViewer: mdViewer))
      case .newTab(let session):
        _ = try rexJSON(runner, rex, tabArguments(session: session, file: file, mdViewer: mdViewer))
      }
      exit(0)
    } catch {
      fail("\(error)", status: 1)
    }
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
