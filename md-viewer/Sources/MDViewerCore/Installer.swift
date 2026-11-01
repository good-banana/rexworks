import Foundation

public let changingDefaultsNotice = "Changing the default app for Markdown files. macOS may ask you to confirm."

public struct HandlerTimeoutError: Error, CustomStringConvertible {
  public let bundleID: String
  public let contentType: String

  public var description: String {
    "timed out setting \(bundleID) as handler for \(contentType)"
  }
}

public struct Installer: Sendable {
  public let paths: SupportPaths
  public let registry: HandlerRegistry
  public let types: [String]
  public let selfID: String
  public let setTimeout: Duration
  public let notify: @Sendable (String) -> Void

  public init(
    paths: SupportPaths, registry: HandlerRegistry, types: [String],
    selfID: String = HandlerIdentity.bundleID, setTimeout: Duration = .seconds(60),
    notify: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.paths = paths
    self.registry = registry
    self.types = types
    self.selfID = selfID
    self.setTimeout = setTimeout
    self.notify = notify
  }

  @discardableResult
  public func install(bundledApp: URL, rexPath: String, mdViewerPath: String) async throws -> Config {
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

    if !types.isEmpty { notify(changingDefaultsNotice) }
    for type in types { try await setDefaultHandler(selfID, for: type) }
    return config
  }

  public func uninstall() async throws -> [String] {
    let fileManager = FileManager.default
    let previous = try ConfigStore.load(paths)?.previousHandlers ?? [:]
    let owned = types.filter { registry.defaultHandler(for: $0) == selfID }
    var failures: [String] = []
    let plan = restorePlan(previous: previous, types: owned, isInstalled: registry.isInstalled)
    if !plan.isEmpty { notify(changingDefaultsNotice) }
    for step in plan {
      if let missing = step.missingPrevious {
        notify("\(missing) is no longer installed; restoring \(step.type) to \(step.bundleID).")
      }
      do {
        try await setDefaultHandler(step.bundleID, for: step.type)
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

  private func setDefaultHandler(_ bundleID: String, for contentType: String) async throws {
    let registry = registry
    let timeout = setTimeout
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let outcome = SingleResume(continuation)
      let timer = Task {
        try await Task.sleep(for: timeout)
        outcome.resume(with: .failure(HandlerTimeoutError(bundleID: bundleID, contentType: contentType)))
      }
      Task {
        do {
          try await registry.setDefaultHandler(bundleID, for: contentType)
          outcome.resume(with: .success(()))
        } catch {
          outcome.resume(with: .failure(error))
        }
        timer.cancel()
      }
    }
  }
}

private final class SingleResume: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?

  init(_ continuation: CheckedContinuation<Void, Error>) {
    self.continuation = continuation
  }

  func resume(with result: Result<Void, Error>) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(with: result)
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
