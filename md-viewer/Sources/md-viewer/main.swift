import Foundation

let usage = """
  Usage: md-viewer <command> [arguments]

  Commands:
    view <file>   Render a Markdown file in the terminal
    open <file>   Open a Markdown file in a preview pane
    setup         Install the handler app and register it
    uninstall     Remove the handler app and restore previous handlers
    doctor        Diagnose the installation
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
case "open":
  guard arguments.count == 2 else { fail("usage: md-viewer open <file>", status: 64) }
  OpenCommand.run(file: arguments[1])
case "view", "setup", "uninstall", "doctor":
  fail("not implemented", status: 2)
case let command?:
  fail("unknown command: \(command)\n\n\(usage)", status: 64)
}
