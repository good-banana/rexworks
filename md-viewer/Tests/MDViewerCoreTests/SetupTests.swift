import XCTest

@testable import MDViewerCore

final class FakeRegistry: HandlerRegistry {
  var defaults: [String: String] = [:]
  var registered: [URL] = []
  var unregistered: [URL] = []
  var failingSets: Set<String> = []

  func defaultHandler(for contentType: String) -> String? { defaults[contentType] }
  func setDefaultHandler(_ bundleID: String, for contentType: String) async throws {
    if failingSets.contains(bundleID) { throw HandlerRegistryError(description: "denied") }
    defaults[contentType] = bundleID
  }
  func register(app: URL) throws { registered.append(app) }
  func unregister(app: URL) throws { unregistered.append(app) }
}

func assertThrowsAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
  do {
    try await body()
    XCTFail("expected throw", file: file, line: line)
  } catch {}
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

  func testInstallRecordsPreviousSetsDefaultsAndWritesConfig() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    let config = try await env.installer.install(
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

  func testSecondInstallKeepsOriginalPreviousHandler() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    let second = try await env.installer.install(
      bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    XCTAssertEqual(second.previousHandlers, [markdown: "com.microsoft.VSCode"])
  }

  func testUninstallRestoresDefaultsAndRemovesFiles() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    let failures = try await env.installer.uninstall()

    XCTAssertEqual(failures, [])
    XCTAssertEqual(env.registry.defaults[markdown], "com.microsoft.VSCode")
    XCTAssertEqual(env.registry.defaults["dyn.x"], "com.apple.TextEdit")
    let paths = SupportPaths(home: env.home)
    XCTAssertEqual(env.registry.unregistered, [paths.installedApp])
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.installedApp.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
  }

  func testUninstallWithFailedRestoreKeepsConfigAndApp() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    env.registry.failingSets = ["com.microsoft.VSCode"]
    let failures = try await env.installer.uninstall()

    XCTAssertEqual(failures.count, 1)
    let paths = SupportPaths(home: env.home)
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.installedApp.path))
    XCTAssertEqual(
      try ConfigStore.load(paths)?.previousHandlers, [markdown: "com.microsoft.VSCode"])
    XCTAssertEqual(env.registry.unregistered, [])
  }

  func testUninstallWithoutSetupLeavesDefaultsAlone() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    let failures = try await env.installer.uninstall()

    XCTAssertEqual(failures, [])
    XCTAssertEqual(env.registry.defaults, [markdown: "com.microsoft.VSCode"])
  }

  func testInstallReplacesExistingAppAndLeavesNoStagedCopy() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    try Data("y".utf8).write(to: env.bundle.appendingPathComponent("Contents/marker"))
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")

    let paths = SupportPaths(home: env.home)
    let marker = paths.installedApp.appendingPathComponent("Contents/marker")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "y")
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: paths.installedApp.deletingLastPathComponent().path)
    XCTAssertEqual(siblings, ["MD Viewer.app"])
  }

  func testFailedDefaultSetKeepsConfigForRestore() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    env.registry.failingSets = [selfID]
    await assertThrowsAsync {
      try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    }
    let saved = try ConfigStore.load(SupportPaths(home: env.home))
    XCTAssertEqual(saved?.previousHandlers, [markdown: "com.microsoft.VSCode"])
  }

  func testBundledAppCandidatesCoverHomebrewAndDevLayouts() {
    let candidates = bundledAppCandidates(
      executable: URL(fileURLWithPath: "/work/md-viewer/.build/debug/md-viewer")
    ).map(\.path)
    XCTAssertTrue(candidates.contains("/work/md-viewer/.build/app/MD Viewer.app"))
    XCTAssertTrue(candidates.contains("/work/md-viewer/.build/libexec/MD Viewer.app"))
    XCTAssertEqual(Set(candidates).count, candidates.count)
  }
}
