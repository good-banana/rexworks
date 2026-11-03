import Foundation
import MDViewerCore

enum ConfigCommand {
  static func run(_ arguments: [String]) -> Never {
    switch ConfigCommandLine.parse(arguments) {
    case .failure(let error):
      fail(error.description, status: 64)
    case .success(let action):
      let output = ConfigRunner(paths: currentPaths(), makeResolver: systemEditorResolver).run(action)
      print(output.stdout, terminator: "")
      if !output.stderr.isEmpty { FileHandle.standardError.write(Data((output.stderr + "\n").utf8)) }
      exit(output.status)
    }
  }
}

func systemEditorResolver(settings: Settings) -> EditorResolver {
  let environment = ProcessInfo.processInfo.environment
  let runner = ProcessRunner()
  let login = LoginProbe()
  return EditorResolver(
    settings: settings, ownEnvironment: environment,
    loginEnvironment: { login.value(runner: runner, environment: environment) },
    isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
}

private final class LoginProbe {
  private var cached: LoginEnvironment?

  func value(runner: ProcessRunning, environment: [String: String]) -> LoginEnvironment {
    if let cached { return cached }
    let probed = LoginEnvironment.probe(
      runner: runner, ownEnvironment: environment,
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    cached = probed
    return probed
  }
}
