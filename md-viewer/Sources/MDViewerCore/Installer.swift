import Foundation

public struct Installer {
  public let paths: SupportPaths
  public let registry: HandlerRegistry
  public let types: [String]
  public let selfID: String

  public init(
    paths: SupportPaths, registry: HandlerRegistry, types: [String],
    selfID: String = HandlerIdentity.bundleID
  ) {
    self.paths = paths
    self.registry = registry
    self.types = types
    self.selfID = selfID
  }

  @discardableResult
  public func install(bundledApp: URL, rexPath: String, mdViewerPath: String) throws -> Config {
    let fileManager = FileManager.default
    let destination = paths.installedApp
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let staged = directory.appendingPathComponent(".md-viewer-\(UUID().uuidString).app")
    try fileManager.copyItem(at: bundledApp, to: staged)
    do {
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
      } else {
        try fileManager.moveItem(at: staged, to: destination)
      }
    } catch {
      try? fileManager.removeItem(at: staged)
      throw error
    }
    try registry.register(app: destination)

    let existing = try ConfigStore.load(paths)?.previousHandlers ?? [:]
    var current: [String: String?] = [:]
    for type in types { current[type] = registry.defaultHandler(for: type) }
    let config = Config(
      rexPath: rexPath, mdViewerPath: mdViewerPath,
      previousHandlers: recordPreviousHandlers(existing: existing, current: current, selfID: selfID))
    try ConfigStore.save(config, paths)

    for type in types { try registry.setDefaultHandler(selfID, for: type) }
    return config
  }

  public func uninstall() throws -> [String] {
    let fileManager = FileManager.default
    let previous = try ConfigStore.load(paths)?.previousHandlers ?? [:]
    let owned = types.filter { registry.defaultHandler(for: $0) == selfID }
    var failures: [String] = []
    for step in restorePlan(previous: previous, types: owned) {
      do {
        try registry.setDefaultHandler(step.bundleID, for: step.type)
      } catch {
        failures.append("\(error)")
      }
    }
    guard failures.isEmpty else { return failures }
    if fileManager.fileExists(atPath: paths.installedApp.path) {
      try registry.unregister(app: paths.installedApp)
      try fileManager.removeItem(at: paths.installedApp)
    }
    if fileManager.fileExists(atPath: paths.root.path) {
      try fileManager.removeItem(at: paths.root)
    }
    return []
  }
}

public func bundledAppCandidates(executable: URL) -> [URL] {
  let absolute = URL(fileURLWithPath: executable.path)
  let directories = [absolute, absolute.resolvingSymlinksInPath()].map {
    $0.deletingLastPathComponent()
  }
  var seen = Set<String>()
  return directories.flatMap { directory in
    ["../libexec/MD Viewer.app", "../app/MD Viewer.app", "../../app/MD Viewer.app"].map {
      directory.appendingPathComponent($0).standardizedFileURL
    }
  }.filter { seen.insert($0.path).inserted }
}
