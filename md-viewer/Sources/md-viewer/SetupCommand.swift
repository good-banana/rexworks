import Foundation
import MDViewerCore

func locateExecutable(_ name: String) -> String? {
  let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
  return directories.map { "\($0)/\(name)" }.first {
    FileManager.default.isExecutableFile(atPath: $0)
  }
}

func ownExecutable() -> URL {
  Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
}

func currentPaths() -> SupportPaths {
  SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
}

enum SetupCommand {
  static func setup() async -> Never {
    guard let rex = locateExecutable("rex") else { fail("rex not found in PATH", status: 1) }
    guard
      let bundled = bundledAppCandidates(executable: ownExecutable()).first(where: {
        FileManager.default.fileExists(atPath: $0.path)
      })
    else { fail("MD Viewer.app not found next to md-viewer", status: 1) }
    let installer = Installer(
      paths: currentPaths(), registry: SystemHandlerRegistry(), types: markdownContentTypes())
    do {
      try await installer.install(
        bundledApp: bundled, rexPath: rex, mdViewerPath: ownExecutable().path)
    } catch {
      fail("setup failed: \(error)", status: 1)
    }
    print("md-viewer is now the default Markdown handler. Run md-viewer doctor to verify.")
    exit(0)
  }

  static func uninstall() async -> Never {
    let installer = Installer(
      paths: currentPaths(), registry: SystemHandlerRegistry(), types: markdownContentTypes())
    do {
      let failures = try await installer.uninstall()
      for failure in failures { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
      if failures.isEmpty {
        print("md-viewer removed and previous handlers restored.")
        exit(0)
      }
      FileHandle.standardError.write(
        Data("uninstall incomplete; the app and config were kept so you can retry.\n".utf8))
      exit(1)
    } catch {
      fail("uninstall failed: \(error)", status: 1)
    }
  }
}
