import Foundation
import MDViewerCore

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

    let resources = webResourcesLocation()
    report(resources != nil, "web resources \(resources?.path ?? "not found")")

    exit(allPassed ? 0 : 1)
  }

  private static func webResourcesLocation() -> URL? {
    let name = "md-viewer_MDViewerWeb.bundle"
    let directory = ownExecutable().deletingLastPathComponent()
    return [directory, directory.appendingPathComponent("../libexec")]
      .map { $0.appendingPathComponent(name).standardizedFileURL }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }
}
