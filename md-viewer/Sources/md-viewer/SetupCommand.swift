import Foundation
import MDViewerCore

func locateExecutable(_ name: String) -> String? {
  let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
  return directories.map { "\($0)/\(name)" }.first {
    FileManager.default.isExecutableFile(atPath: $0)
  }
}

func ownExecutable() -> URL {
  URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
}

func currentPaths() -> SupportPaths {
  SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
}

enum SetupCommand {
  static func setup() -> Never {
    guard let rex = locateExecutable("rex") else { fail("rex not found in PATH", status: 1) }
    guard
      let bundled = bundledAppCandidates(executable: URL(fileURLWithPath: CommandLine.arguments[0])).first(where: {
        FileManager.default.fileExists(atPath: $0.path)
      })
    else { fail("MD Viewer.app not found next to md-viewer", status: 1) }
    let installer = Installer(
      paths: currentPaths(), registry: SystemHandlerRegistry(), types: markdownContentTypes())
    do {
      try installer.install(
        bundledApp: bundled, rexPath: rex, mdViewerPath: ownExecutable().path)
    } catch {
      fail("setup failed: \(error)", status: 1)
    }
    print("md-viewer is now the default Markdown handler. Run md-viewer doctor to verify.")
    exit(0)
  }

  static func uninstall() -> Never {
    let installer = Installer(
      paths: currentPaths(), registry: SystemHandlerRegistry(), types: markdownContentTypes())
    do {
      let failures = try installer.uninstall()
      for failure in failures { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
      print("md-viewer removed and previous handlers restored.")
      exit(failures.isEmpty ? 0 : 1)
    } catch {
      fail("uninstall failed: \(error)", status: 1)
    }
  }
}
