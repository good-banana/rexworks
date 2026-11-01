import XCTest

@testable import MDViewerCore

final class FakeRegistry: HandlerRegistry {
  var defaults: [String: String] = [:]
  var registered: [URL] = []
  var unregistered: [URL] = []

  func defaultHandler(for contentType: String) -> String? { defaults[contentType] }
  func setDefaultHandler(_ bundleID: String, for contentType: String) throws {
    defaults[contentType] = bundleID
  }
  func register(app: URL) throws { registered.append(app) }
  func unregister(app: URL) throws { unregistered.append(app) }
}

final class SetupTests: XCTestCase {
  let selfID = "com.goodbanana.rexworks.md-viewer"
  let markdown = "net.daringfireball.markdown"

  func testRecordsCurrentHandlersFirstTime() {
    XCTAssertEqual(
      recordPreviousHandlers(
        existing: [:], current: [markdown: "com.microsoft.VSCode"], selfID: selfID),
      [markdown: "com.microsoft.VSCode"])
  }

  func testRerunDoesNotRecordSelf() {
    XCTAssertEqual(
      recordPreviousHandlers(
        existing: [markdown: "com.microsoft.VSCode"], current: [markdown: selfID], selfID: selfID),
      [markdown: "com.microsoft.VSCode"])
  }

  func testUserChangedDefaultAfterSetupIsRecorded() {
    XCTAssertEqual(
      recordPreviousHandlers(
        existing: [markdown: "com.a"], current: [markdown: "com.b"], selfID: selfID),
      [markdown: "com.b"])
  }

  func testRestorePlanFallsBackToTextEdit() {
    let plan = restorePlan(previous: [markdown: "com.a"], types: [markdown, "dyn.x"])
    XCTAssertEqual(plan.map(\.bundleID), ["com.a", "com.apple.TextEdit"])
  }

  func testMarkdownContentTypesAreUniqueAndIncludeMarkdown() {
    let types = markdownContentTypes()
    XCTAssertEqual(types.first, markdown)
    XCTAssertEqual(Set(types).count, types.count)
  }

  private func makeEnvironment() throws -> (
    home: URL, bundle: URL, installer: Installer, registry: FakeRegistry
  ) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundle = home.appendingPathComponent("src/MD Viewer.app")
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: bundle.appendingPathComponent("Contents/marker"))
    let registry = FakeRegistry()
    registry.defaults = [markdown: "com.microsoft.VSCode"]
    let installer = Installer(
      paths: SupportPaths(home: home), registry: registry, types: [markdown, "dyn.x"])
    return (home, bundle, installer, registry)
  }

  func testInstallRecordsPreviousSetsDefaultsAndWritesConfig() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    let config = try env.installer.install(
      bundledApp: env.bundle, rexPath: "/bin/rex", mdViewerPath: "/bin/md-viewer")

    XCTAssertEqual(config.previousHandlers, [markdown: "com.microsoft.VSCode"])
    XCTAssertEqual(env.registry.defaults[markdown], selfID)
    XCTAssertEqual(env.registry.defaults["dyn.x"], selfID)
    let paths = SupportPaths(home: env.home)
    XCTAssertEqual(env.registry.registered, [paths.installedApp])
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: paths.installedApp.appendingPathComponent("Contents/marker").path))
    XCTAssertEqual(try ConfigStore.load(paths), config)
  }

  func testSecondInstallKeepsOriginalPreviousHandler() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    let second = try env.installer.install(
      bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    XCTAssertEqual(second.previousHandlers, [markdown: "com.microsoft.VSCode"])
  }

  func testUninstallRestoresDefaultsAndRemovesFiles() throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    let failures = try env.installer.uninstall()

    XCTAssertEqual(failures, [])
    XCTAssertEqual(env.registry.defaults[markdown], "com.microsoft.VSCode")
    XCTAssertEqual(env.registry.defaults["dyn.x"], "com.apple.TextEdit")
    let paths = SupportPaths(home: env.home)
    XCTAssertEqual(env.registry.unregistered, [paths.installedApp])
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.installedApp.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
  }
}
