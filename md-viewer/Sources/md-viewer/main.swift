import Foundation
import MDViewerCore
import MDViewerHost

func fail(_ message: String, status: Int32) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "--help", "-h":
  print(commandUsage)
case "-v", "--version":
  print("md-viewer \(mdViewerVersion)")
case "open":
  switch OpenArguments.parse(Array(arguments.dropFirst())) {
  case .success(let open): OpenCommand.run(open)
  case .failure(let error): fail(error.description, status: 64)
  }
case "setup":
  await SetupCommand.setup()
case "uninstall":
  await SetupCommand.uninstall()
case "agents":
  AgentsCommand.run(arguments.count == 2 ? arguments[1] : nil)
case "agent-guide":
  print(agentGuide, terminator: "")
case "doctor":
  DoctorCommand.run()
case "view":
  guard let view = ViewArguments(Array(arguments.dropFirst())) else {
    fail("usage: md-viewer view [--theme-source-block <block>] [--opener-block <block>] <file>", status: 64)
  }
  await ViewCommand.run(view)
case SVGRenderProcess.command:
  exit(SVGRenderProcess.serve(arguments: Array(arguments.dropFirst())))
case let command?:
  fail("unknown command: \(command)\n\n\(commandUsage)", status: 64)
}
