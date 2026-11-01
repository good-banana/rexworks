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
    let existing = try ConfigStore.load(paths)?.previousHandlers ?? [:]
    var current: [String: String?] = [:]
    for type in types { current[type] = registry.defaultHandler(for: type) }
    let config = Config(
      rexPath: rexPath, mdViewerPath: mdViewerPath,
      previousHandlers: recordPreviousHandlers(existing: existing, current: current, selfID: selfID))
    try ConfigStore.save(config, paths)

    let destination = paths.installedApp
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: bundledApp, to: destination)
    try registry.register(app: destination)
    for type in types { try registry.setDefaultHandler(selfID, for: type) }
    return config
  }

  public func uninstall() throws -> [String] {
    let fileManager = FileManager.default
    let previous = try ConfigStore.load(paths)?.previousHandlers ?? [:]
    var failures: [String] = []
    for step in restorePlan(previous: previous, types: types) {
      do {
        try registry.setDefaultHandler(step.bundleID, for: step.type)
      } catch {
        failures.append("\(error)")
      }
    }
    if fileManager.fileExists(atPath: paths.installedApp.path) {
      do { try registry.unregister(app: paths.installedApp) } catch { failures.append("\(error)") }
      try fileManager.removeItem(at: paths.installedApp)
    }
    if fileManager.fileExists(atPath: paths.root.path) {
      try fileManager.removeItem(at: paths.root)
    }
    return failures
  }
}
