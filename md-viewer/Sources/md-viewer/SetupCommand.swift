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

func systemInstaller() -> Installer {
  Installer(
    paths: currentPaths(), registry: SystemHandlerRegistry(), types: markdownContentTypes(),
    notify: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
}

enum SetupCommand {
  static func setup() async -> Never {
    guard let rex = locateExecutable("rex") else { fail("rex not found in PATH", status: 1) }
    guard
      let bundled = bundledAppCandidates(executable: ownExecutable()).first(where: {
        FileManager.default.fileExists(atPath: $0.path)
      })
    else { fail("MD Viewer.app not found next to md-viewer", status: 1) }
    do {
      try await systemInstaller().install(
        bundledApp: bundled, rexPath: rex, mdViewerPath: ownExecutable().path)
    } catch let error as HandlerTimeoutError {
      fail("setup failed: \(error). Approve the macOS prompt, then rerun md-viewer setup.", status: 1)
    } catch {
      fail("setup failed: \(error)", status: 1)
    }
    print("md-viewer is now the default Markdown handler. Run md-viewer doctor to verify.")
    updateFindBinding(rex: rex, install: true)
    AgentsCommand.offerInstall()
    exit(0)
  }

  static func uninstall() async -> Never {
    AgentsCommand.removeQuietly()
    updateFindBinding(rex: (try? ConfigStore.load(currentPaths()))?.rexPath ?? locateExecutable("rex"), install: false)
    do {
      let failures = try await systemInstaller().uninstall()
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

  static func updateFindBinding(rex: String?, install: Bool) {
    let config = RexFindBinding.configFile(
      environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    do {
      let changed = install ? try RexFindBinding.install(at: config) : try RexFindBinding.remove(at: config)
      guard changed else { return }
      if let rex { _ = try? ProcessRunner().run(rex, ["config", "reload"]) }
      print(
        install
          ? "Cmd-F in md-viewer panes now opens md-viewer's find (\(config.path))."
          : "Removed the md-viewer Cmd-F binding from \(config.path).")
    } catch {
      FileHandle.standardError.write(Data("could not update \(config.path): \(error.localizedDescription)\n".utf8))
    }
  }
}
