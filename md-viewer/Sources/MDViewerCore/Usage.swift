import Foundation

public let commandUsage = """
  Usage: md-viewer <command> [arguments]

  Commands:
    view <file>   Render a Markdown preview in this pane
    open [--new | --replace] <file>
                  Open a Markdown file in a preview pane. --new always opens a
                  new pane. --replace updates the preview this pane opened last.
    setup         Install the handler app and register it
    uninstall     Remove the handler app and restore previous handlers
    doctor        Diagnose the installation
    agents <install|status|remove>
                  Manage the coding-agent skill that opens previews
    agent-guide   Print guidance for coding agents
    -v, --version Print the version
    --help        Show this help
  """
