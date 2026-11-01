import Foundation
import MDViewerCore

let usage = """
  Usage: md-viewer <command> [arguments]

  Commands:
    view <file>   Render a Markdown file in the terminal
    open <file>   Open a Markdown file in a preview pane
    setup         Install the handler app and register it
    uninstall     Remove the handler app and restore previous handlers
    doctor        Diagnose the installation
    agents <install|status|remove>
                  Manage the coding-agent skill that opens previews
    agent-guide   Print guidance for coding agents
    -v, --version Print the version
    --help        Show this help
  """

func fail(_ message: String, status: Int32) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil, "--help", "-h":
  print(usage)
case "-v", "--version":
  print("md-viewer \(mdViewerVersion)")
case "open":
  guard arguments.count == 2 else { fail("usage: md-viewer open <file>", status: 64) }
  OpenCommand.run(file: arguments[1])
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
    fail("usage: md-viewer view [--theme-source-block <block>] <file>", status: 64)
  }
  await ViewCommand.run(file: view.file)
case let command?:
  fail("unknown command: \(command)\n\n\(usage)", status: 64)
}
