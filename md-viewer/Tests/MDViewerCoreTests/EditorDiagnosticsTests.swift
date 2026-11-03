import XCTest

@testable import MDViewerCore

final class EditorDiagnosticsTests: XCTestCase {
  private var paths: SupportPaths!
  private let installed: Set<String> = ["/bin/nvim", "/bin/hx", "/bin/code"]

  override func setUpWithError() throws {
    paths = SupportPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: paths.home)
  }

  private func setup(_ environment: [String: String]) -> String {
    EditorSetup.apply(
      paths: paths, ownEnvironment: environment.merging(["PATH": "/bin"]) { a, _ in a },
      isExecutable: { [installed] in installed.contains($0) })
  }

  func testExistingSettingIsKept() throws {
    try SettingsStore.update(paths, set: [.editor: "hx"])
    XCTAssertEqual(
      setup(["EDITOR": "nvim"]),
      "Editor for previews: hx (change it with md-viewer config set editor <command>)")
    XCTAssertEqual(SettingsStore.load(paths).editor, "hx")
  }

  func testEditorVariableIsSavedWhenNoSetting() {
    XCTAssertEqual(
      setup(["EDITOR": "nvim"]),
      "Saved nvim from $EDITOR as the editor for previews; change it with md-viewer config set editor <command>")
    XCTAssertEqual(SettingsStore.load(paths).editor, "nvim")
  }

  func testVisualWinsAndKeepsArguments() {
    XCTAssertEqual(
      setup(["VISUAL": "code -w", "EDITOR": "nvim"]),
      "Saved code -w from $VISUAL as the editor for previews; change it with md-viewer config set editor <command>")
    XCTAssertEqual(SettingsStore.load(paths).editor, "code -w")
  }

  func testUnresolvableVisualFallsBackToEditor() {
    XCTAssertTrue(setup(["VISUAL": "ghost", "EDITOR": "hx"]).hasPrefix("Saved hx from $EDITOR"))
  }

  func testNothingResolvesSavesNothing() {
    XCTAssertEqual(
      setup(["EDITOR": "ghost"]),
      "No editor set; previews will ask on first e, or run md-viewer config set editor <command>")
    XCTAssertEqual(
      setup([:]), "No editor set; previews will ask on first e, or run md-viewer config set editor <command>")
    XCTAssertNil(SettingsStore.load(paths).editor)
  }

  private func resolution(_ settings: Settings, environment: [String: String] = [:]) -> EditorResolution {
    EditorResolver(
      settings: settings, ownEnvironment: environment,
      loginEnvironment: { LoginEnvironment(variables: ["PATH": "/bin"]) },
      isExecutable: { [installed] in installed.contains($0) }
    ).resolve()
  }

  func testDoctorReportsNeovimWithSupportedVersion() {
    var settings = Settings()
    settings.editor = "nvim"
    let lines = EditorDoctor.lines(
      settings: settings, resolution: resolution(settings),
      neovimVersion: { _ in NeovimVersion(major: 0, minor: 10, patch: 1) })
    XCTAssertEqual(
      lines,
      [
        DiagnosticLine(level: .ok, text: "editor nvim at /bin/nvim (setting), Neovim, live sync"),
        DiagnosticLine(level: .ok, text: "Neovim 0.10.1 supports live sync (0.9 or later)"),
        DiagnosticLine(level: .info, text: "edit-mode split"),
      ])
  }

  func testDoctorFailsOldNeovimAndUnreadableVersion() {
    var settings = Settings()
    settings.editor = "nvim"
    let old = EditorDoctor.lines(
      settings: settings, resolution: resolution(settings),
      neovimVersion: { _ in NeovimVersion(major: 0, minor: 8, patch: 3) })
    XCTAssertEqual(
      old[1], DiagnosticLine(level: .fail, text: "Neovim 0.8.3 supports live sync (0.9 or later)"))
    let unreadable = EditorDoctor.lines(
      settings: settings, resolution: resolution(settings), neovimVersion: { _ in nil })
    XCTAssertEqual(unreadable[1].level, .fail)
  }

  func testDoctorDescribesOtherEditors() {
    var settings = Settings()
    settings.editor = "hx"
    var versionAsked = false
    let helix = EditorDoctor.lines(
      settings: settings, resolution: resolution(settings),
      neovimVersion: { _ in
        versionAsked = true
        return nil
      })
    XCTAssertEqual(
      helix[0], DiagnosticLine(level: .ok, text: "editor hx at /bin/hx (setting), Helix, refresh on save"))
    XCTAssertFalse(versionAsked)
    settings.editor = "code -w"
    let code = EditorDoctor.lines(settings: settings, resolution: resolution(settings), neovimVersion: { _ in nil })
    XCTAssertEqual(
      code[0], DiagnosticLine(level: .ok, text: "editor code -w at /bin/code (setting), VS Code, opens outside Rex"))
  }

  func testDoctorFailsUnresolvedSettingAndInformsWhenNothingResolves() {
    var settings = Settings()
    settings.editor = "ghost --flag"
    let failed = EditorDoctor.lines(settings: settings, resolution: resolution(settings), neovimVersion: { _ in nil })
    XCTAssertEqual(
      failed[0],
      DiagnosticLine(level: .fail, text: "editor setting: ghost not found (md-viewer config set editor <command>)"))
    var here = Settings()
    here.editMode = .here
    let none = EditorDoctor.lines(settings: here, resolution: resolution(here), neovimVersion: { _ in nil })
    XCTAssertEqual(
      none,
      [
        DiagnosticLine(level: .info, text: "editor not set; previews will ask on first e"),
        DiagnosticLine(level: .info, text: "edit-mode here"),
      ])
  }

  func testNeovimVersionParsing() {
    XCTAssertEqual(
      NeovimVersion.parse("NVIM v0.10.0-dev-1234+gabc\nBuild type: Release\n"),
      NeovimVersion(major: 0, minor: 10, patch: 0))
    XCTAssertEqual(NeovimVersion.parse("NVIM v0.9.5\n"), NeovimVersion(major: 0, minor: 9, patch: 5))
    XCTAssertNil(NeovimVersion.parse("VIM - Vi IMproved 9.0"))
    XCTAssertTrue(NeovimVersion(major: 1, minor: 0, patch: 0).supportsLiveSync)
    XCTAssertFalse(NeovimVersion(major: 0, minor: 8, patch: 0).supportsLiveSync)
  }

  private struct StubRunner: ProcessRunning {
    let status: Int32
    let output: String
    let recorder: Recorder

    final class Recorder: @unchecked Sendable {
      var calls: [(String, [String], TimeInterval?)] = []
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> (
      status: Int32, stdout: Data, stderr: Data
    ) {
      recorder.calls.append((executable, arguments, timeout))
      return (status, Data(output.utf8), Data())
    }
  }

  func testProbeRunsVersionWithDeadline() {
    let recorder = StubRunner.Recorder()
    let version = NeovimVersion.probe(
      executable: "/bin/nvim", runner: StubRunner(status: 0, output: "NVIM v0.9.0\n", recorder: recorder))
    XCTAssertEqual(version, NeovimVersion(major: 0, minor: 9, patch: 0))
    XCTAssertEqual(recorder.calls.count, 1)
    XCTAssertEqual(recorder.calls[0].0, "/bin/nvim")
    XCTAssertEqual(recorder.calls[0].1, ["--version"])
    XCTAssertEqual(recorder.calls[0].2, NeovimVersion.timeout)
    XCTAssertNil(
      NeovimVersion.probe(
        executable: "/bin/nvim", runner: StubRunner(status: 1, output: "NVIM v0.9.0", recorder: recorder)))
  }
}
