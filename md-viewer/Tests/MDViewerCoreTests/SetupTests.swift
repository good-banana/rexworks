import XCTest

@testable import MDViewerCore

final class FakeRegistry: HandlerRegistry, @unchecked Sendable {
  var defaults: [String: String] = [:]
  var registered: [URL] = []
  var unregistered: [URL] = []
  var failingSets: Set<String> = []
  var hangingSets: Set<String> = []
  var missingApps: Set<String> = []

  func defaultHandler(for contentType: String) -> String? { defaults[contentType] }
  func isInstalled(_ bundleID: String) -> Bool { !missingApps.contains(bundleID) }
  func setDefaultHandler(_ bundleID: String, for contentType: String) async throws {
    if hangingSets.contains(bundleID) { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
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

final class MessageLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func append(_ message: String) {
    lock.lock()
    stored.append(message)
    lock.unlock()
  }
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
    let plan = restorePlan(previous: [markdown: "com.a"], types: [markdown, "dyn.x"], isInstalled: { _ in true })
    XCTAssertEqual(plan.map(\.bundleID), ["com.a", "com.apple.TextEdit"])
    XCTAssertEqual(plan.map(\.missingPrevious), [nil, nil])
  }

  func testRestorePlanReplacesDeletedPreviousAppWithTextEdit() {
    let plan = restorePlan(previous: [markdown: "com.gone"], types: [markdown], isInstalled: { $0 != "com.gone" })
    XCTAssertEqual(
      plan, [RestoreStep(type: markdown, bundleID: "com.apple.TextEdit", missingPrevious: "com.gone")])
  }

  func testMarkdownContentTypesAreUniqueAndIncludeMarkdown() {
    let types = markdownContentTypes()
    XCTAssertEqual(types.first, markdown)
    XCTAssertEqual(Set(types).count, types.count)
  }

  private func makeEnvironment(setTimeout: Duration = .seconds(60)) throws -> (
    home: URL, bundle: URL, installer: Installer, registry: FakeRegistry, log: MessageLog
  ) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundle = home.appendingPathComponent("src/MD Viewer.app")
    try FileManager.default.createDirectory(
      at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: bundle.appendingPathComponent("Contents/marker"))
    let registry = FakeRegistry()
    registry.defaults = [markdown: "com.microsoft.VSCode"]
    let log = MessageLog()
    let installer = Installer(
      paths: SupportPaths(home: home), registry: registry, types: [markdown, "dyn.x"],
      setTimeout: setTimeout, notify: log.append)
    return (home, bundle, installer, registry, log)
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

  func testUninstallRemovesEditorSupportDirectories() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    let paths = SupportPaths(home: env.home)
    try NeovimPlugin.install(paths)
    let directories = [paths.neovimSocketsDirectory, paths.buffersDirectory, paths.editorsDirectory]
    for directory in directories {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("x".utf8).write(to: directory.appendingPathComponent("entry"))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.neovimPlugin.path))

    let failures = try await env.installer.uninstall()

    XCTAssertEqual(failures, [])
    for url in directories + [paths.neovimPlugin.deletingLastPathComponent()] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path)
    }
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

  func testInstallAfterASettingWasWrittenKeepsTheSetting() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    let paths = SupportPaths(home: env.home)
    try SettingsStore.update(paths, set: [.editMode: "here", .editor: "hx"])
    let config = try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    XCTAssertEqual(try ConfigStore.load(paths), config)
    let settings = SettingsStore.load(paths)
    XCTAssertEqual(settings.editMode, .here)
    XCTAssertEqual(settings.editor, "hx")
  }

  func testUninstallAfterASettingWasWrittenSucceeds() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try SettingsStore.update(SupportPaths(home: env.home), set: [.editMode: "here"])
    let failures = try await env.installer.uninstall()
    XCTAssertEqual(failures, [])
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

  func testInstallAndUninstallWarnAboutMacOSPromptBeforeChangingDefaults() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    XCTAssertEqual(env.log.messages, [changingDefaultsNotice])
    _ = try await env.installer.uninstall()
    XCTAssertEqual(env.log.messages, [changingDefaultsNotice, changingDefaultsNotice])
  }

  func testInstallTimesOutWhenMacOSNeverAnswers() async throws {
    let env = try makeEnvironment(setTimeout: .milliseconds(100))
    defer { try? FileManager.default.removeItem(at: env.home) }
    env.registry.hangingSets = [selfID]
    do {
      try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
      XCTFail("expected timeout")
    } catch let error as HandlerTimeoutError {
      XCTAssertEqual(error.bundleID, selfID)
      XCTAssertEqual(error.contentType, markdown)
    }
    let saved = try ConfigStore.load(SupportPaths(home: env.home))
    XCTAssertEqual(saved?.previousHandlers, [markdown: "com.microsoft.VSCode"])
  }

  func testUninstallTimeoutReportsFailureAndKeepsAppAndConfig() async throws {
    let env = try makeEnvironment(setTimeout: .milliseconds(100))
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    env.registry.hangingSets = ["com.microsoft.VSCode"]
    let failures = try await env.installer.uninstall()

    XCTAssertEqual(failures, ["timed out setting com.microsoft.VSCode as handler for \(markdown)"])
    let paths = SupportPaths(home: env.home)
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.installedApp.path))
    XCTAssertEqual(
      try ConfigStore.load(paths)?.previousHandlers, [markdown: "com.microsoft.VSCode"])
    XCTAssertEqual(env.registry.unregistered, [])
  }

  func testUninstallRestoresTextEditWhenPreviousAppWasDeleted() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.home) }
    try await env.installer.install(bundledApp: env.bundle, rexPath: "/r", mdViewerPath: "/m")
    env.registry.missingApps = ["com.microsoft.VSCode"]
    let failures = try await env.installer.uninstall()

    XCTAssertEqual(failures, [])
    XCTAssertEqual(env.registry.defaults[markdown], "com.apple.TextEdit")
    XCTAssertTrue(
      env.log.messages.contains(
        "com.microsoft.VSCode is no longer installed; restoring \(markdown) to com.apple.TextEdit."))
    XCTAssertFalse(FileManager.default.fileExists(atPath: SupportPaths(home: env.home).root.path))
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
