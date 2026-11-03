import XCTest

@testable import MDViewerCore

final class ConfigCLITests: XCTestCase {
  private let installed: Set<String> = ["/login/bin/nvim", "/login/bin/hx", "/abs/custom-editor"]
  private var paths: SupportPaths!

  override func setUpWithError() throws {
    paths = SupportPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: paths.home)
  }

  private func runner(own: [String: String] = [:]) -> ConfigRunner {
    ConfigRunner(paths: paths) { [installed] settings in
      EditorResolver(
        settings: settings, ownEnvironment: own,
        loginEnvironment: { LoginEnvironment(variables: ["PATH": "/login/bin"]) },
        isExecutable: { installed.contains($0) })
    }
  }

  private func parsed(_ arguments: [String]) throws -> ConfigAction {
    try XCTUnwrap(try? ConfigCommandLine.parse(arguments).get())
  }

  func testParsesEveryForm() throws {
    XCTAssertEqual(try parsed([]), .show)
    XCTAssertEqual(try parsed(["get", "edit-mode"]), .get(.editMode))
    XCTAssertEqual(try parsed(["set", "editor", "nvim -u NONE"]), .set(.editor, "nvim -u NONE"))
    XCTAssertEqual(try parsed(["unset", "editor-kind"]), .unset(.editorKind))
    XCTAssertEqual(try parsed(["set", "previews", "single"]), .set(.previews, "single"))
  }

  func testRejectsMalformedCommandsAsUsageErrors() {
    for arguments in [
      ["bogus"], ["get"], ["get", "editor", "x"], ["set", "editor"], ["set", "editor", "a", "b"], ["unset"],
      ["get", "editMode"],
    ] {
      XCTAssertThrowsError(try ConfigCommandLine.parse(arguments).get(), "\(arguments)")
    }
  }

  func testSetWritesEnumValuesAndKeepsUnknownKeys() throws {
    try Data(#"{"rexPath":"/r","custom":1}"#.utf8).write(to: paths.configFile)
    let output = runner().run(.set(.editMode, "here"))
    XCTAssertEqual(output.status, 0)
    XCTAssertEqual(output.stdout, "edit-mode = here\n")
    XCTAssertEqual(SettingsStore.load(paths).editMode, .here)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as? [String: Any])
    XCTAssertEqual(object["custom"] as? Int, 1)
    XCTAssertEqual(object["rexPath"] as? String, "/r")
  }

  func testInvalidEnumValueIsAUsageErrorAndWritesNothing() {
    let output = runner().run(.set(.editMode, "sideways"))
    XCTAssertEqual(output.status, 64)
    XCTAssertEqual(output.stderr, "invalid value for edit-mode: sideways (expected split, here)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
  }

  func testSetEditorWithUnresolvableFirstWordExitsOneAndWritesNothing() {
    let output = runner().run(.set(.editor, "nonexistent --flag"))
    XCTAssertEqual(output.status, 1)
    XCTAssertEqual(output.stderr, "not found: nonexistent")
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
  }

  func testSetEditorWithRelativePathIsNotFound() {
    let output = runner().run(.set(.editor, "./bin/nvim"))
    XCTAssertEqual(output.status, 1)
    XCTAssertEqual(output.stderr, "not found: ./bin/nvim")
  }

  func testSetOnABrokenConfigExitsOneAndLeavesItUntouched() throws {
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: paths.configFile)
    let output = runner().run(.set(.editMode, "here"))
    XCTAssertEqual(output.status, 1)
    XCTAssertTrue(output.stderr.hasPrefix("config set failed: "), output.stderr)
    XCTAssertEqual(try Data(contentsOf: paths.configFile), Data("{broken".utf8))
  }

  func testSetEditorAcceptsCommandsOnPathAndAbsolutePaths() {
    XCTAssertEqual(runner().run(.set(.editor, "nvim -u NONE")).status, 0)
    XCTAssertEqual(SettingsStore.load(paths).editor, "nvim -u NONE")
    XCTAssertEqual(runner().run(.set(.editor, "/abs/custom-editor")).status, 0)
    XCTAssertEqual(SettingsStore.load(paths).editor, "/abs/custom-editor")
  }

  func testSetEditorRejectsUnbalancedQuotesAsUsageError() {
    XCTAssertEqual(runner().run(.set(.editor, "nvim 'x")).status, 64)
  }

  func testUnsetRemovesOnlyThatKey() throws {
    XCTAssertEqual(runner().run(.set(.editMode, "here")).status, 0)
    XCTAssertEqual(runner().run(.set(.previews, "single")).status, 0)
    let output = runner().run(.unset(.editMode))
    XCTAssertEqual(output.status, 0)
    XCTAssertEqual(output.stdout, "edit-mode unset\n")
    XCTAssertEqual(SettingsStore.load(paths).editMode, .split)
    XCTAssertEqual(SettingsStore.load(paths).previews, .single)
  }

  func testGetPrintsTheEffectiveValue() {
    XCTAssertEqual(runner().run(.get(.editMode)).stdout, "split\n")
    XCTAssertEqual(runner().run(.get(.previews)).stdout, "perFile\n")
    XCTAssertEqual(runner().run(.set(.editor, "hx")).status, 0)
    XCTAssertEqual(runner().run(.get(.editor)).stdout, "hx\n")
    XCTAssertEqual(runner().run(.get(.editorKind)).stdout, "helix\n")
  }

  func testGetWithNothingToReportExitsOneQuietly() {
    let output = runner().run(.get(.editor))
    XCTAssertEqual(output, ConfigOutput(status: 1, stdout: "", stderr: ""))
  }

  func testGetEditorFallsBackToTheEnvironment() {
    let output = runner(own: ["EDITOR": "nvim"]).run(.get(.editor))
    XCTAssertEqual(output.stdout, "/login/bin/nvim\n")
  }

  func testShowListsSettingsSourcesResolutionAndDetectedEditors() {
    XCTAssertEqual(runner().run(.set(.previews, "single")).status, 0)
    let output = runner(own: ["VISUAL": "nvim"]).run(.show)
    XCTAssertEqual(output.status, 0)
    XCTAssertEqual(
      output.stdout,
      """
      previews    single  (setting)
      edit-mode   split  (default)
      editor      /login/bin/nvim  ($VISUAL)
      editor-kind neovim  (detected)

      Editor resolution: /login/bin/nvim ($VISUAL), neovim, live sync
      Detected editors: nvim (/login/bin/nvim), hx (/login/bin/hx)

      """)
  }

  func testShowWithNothingResolvedSaysSo() {
    let output = runner().run(.show)
    XCTAssertTrue(output.stdout.contains("editor      -  (unset)"))
    XCTAssertTrue(output.stdout.contains("Editor resolution: no editor set; previews will ask on first e"))
  }

  func testShowReportsAStaleEditorSetting() throws {
    try Data(#"{"editor":"gone --x"}"#.utf8).write(to: paths.configFile)
    XCTAssertTrue(runner().run(.show).stdout.contains("Editor resolution: editor setting: gone not found"))
  }
}
