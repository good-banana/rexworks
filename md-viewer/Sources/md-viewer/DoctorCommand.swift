import Foundation
import MDViewerCore
import MDViewerMermaid
import MDViewerRender

enum DoctorCommand {
  static func run() -> Never {
    let paths = currentPaths()
    let registry = SystemHandlerRegistry()
    let config = try? ConfigStore.load(paths)
    var allPassed = true

    func report(_ passed: Bool, _ message: String) {
      if !passed { allPassed = false }
      print("\(passed ? "ok  " : "FAIL") \(message)")
    }

    let rex = config?.rexPath ?? locateExecutable("rex")
    if let rex, FileManager.default.isExecutableFile(atPath: rex) {
      let result = try? ProcessRunner().run(rex, ["whoami", "--json"])
      report(result?.status == 0, "rex at \(rex) responds to whoami")
    } else {
      report(false, "rex executable not found")
    }

    let installed = FileManager.default.fileExists(atPath: paths.installedApp.path)
    report(installed, "app installed at \(paths.installedApp.path)")
    let registered = applicationURLs(forBundleID: HandlerIdentity.bundleID)
    report(!registered.isEmpty, "app registered with Launch Services")

    for type in markdownContentTypes() {
      let handler = registry.defaultHandler(for: type)
      report(
        handler == HandlerIdentity.bundleID, "default handler for \(type) is \(handler ?? "none")")
    }

    let previous = config?.previousHandlers ?? [:]
    report(!previous.isEmpty, "previous handlers recorded")
    for (type, bundleID) in previous.sorted(by: { $0.key < $1.key }) {
      let resolvable = !applicationURLs(forBundleID: bundleID).isEmpty
      report(resolvable, "previous handler \(bundleID) for \(type) is installed")
    }

    let highlight = SyntaxHighlighter.locateScript()
    report(
      highlight != nil,
      "\(SyntaxHighlighter.bundleName) \(highlight.map { "at \($0.deletingLastPathComponent().path)" } ?? "not found")")
    let mermaid = MermaidRenderer.locatePage()
    report(
      mermaid != nil,
      "\(MermaidRenderer.bundleName) \(mermaid.map { "at \($0.deletingLastPathComponent().deletingLastPathComponent().path)" } ?? "not found")"
    )

    for line in SetupCommand.shellSetup().doctorLines(rexPath: rex) {
      switch line.level {
      case .ok: report(true, line.text)
      case .fail: report(false, line.text)
      case .info: print("info \(line.text)")
      }
    }

    let settings = SettingsStore.load(paths)
    let editorLines = EditorDoctor.lines(
      settings: settings, resolution: systemEditorResolver(settings: settings).resolve(),
      neovimVersion: { NeovimVersion.probe(executable: $0, runner: ProcessRunner()) })
    for line in editorLines {
      switch line.level {
      case .ok: report(true, line.text)
      case .fail: report(false, line.text)
      case .info: print("info \(line.text)")
      }
    }

    for line in agentStatusLines(AgentSkills(home: paths.home).status()) {
      print("info \(line)")
    }

    exit(allPassed ? 0 : 1)
  }
}
