import XCTest

@testable import MDViewerCore

final class EditorResolutionTests: XCTestCase {
  private struct StubRunner: ProcessRunning {
    var result: Result<(status: Int32, stdout: Data, stderr: Data), Error>
    var onRun: (@Sendable (String, [String], TimeInterval?) -> Void)?

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval?) throws -> (
      status: Int32, stdout: Data, stderr: Data
    ) {
      onRun?(executable, arguments, timeout)
      return try result.get()
    }
  }

  private let installed: Set<String> = [
    "/login/bin/nvim", "/login/bin/hx", "/usr/bin/vim", "/own/bin/nano", "/login/bin/code", "/login/bin/subl",
    "/abs/custom-editor",
  ]

  private func resolver(
    settings: Settings = Settings(), own: [String: String] = [:], login: [String: String] = [:],
    loginNotice: String? = nil
  ) -> EditorResolver {
    EditorResolver(
      settings: settings, ownEnvironment: own,
      loginEnvironment: { LoginEnvironment(variables: login, notice: loginNotice) },
      isExecutable: { [installed] in installed.contains($0) })
  }

  private func settings(editor: String?, kind: EditorKind? = nil) -> Settings {
    var settings = Settings()
    settings.editor = editor
    settings.editorKind = kind
    return settings
  }

  private func resolved(_ resolution: EditorResolution) -> ResolvedEditor? {
    if case .resolved(let editor) = resolution.outcome { return editor }
    return nil
  }

  func testShellWordSplitting() {
    XCTAssertEqual(ShellWords.split("nvim -u 'my config.lua'"), ["nvim", "-u", "my config.lua"])
    XCTAssertEqual(ShellWords.split("code --folder \"a b\" -w"), ["code", "--folder", "a b", "-w"])
    XCTAssertEqual(ShellWords.split("my\\ editor x"), ["my editor", "x"])
    XCTAssertEqual(ShellWords.split("a '' b"), ["a", "", "b"])
    XCTAssertEqual(ShellWords.split("echo $HOME \"$X\""), ["echo", "$HOME", "$X"])
    XCTAssertEqual(ShellWords.split("  "), [])
    XCTAssertNil(ShellWords.split("nvim 'oops"))
    XCTAssertNil(ShellWords.split("nvim \\"))
  }

  func testEnvParsingDropsStartupNoiseFromFirstRecord() {
    let output = "Last login: today\nwelcome\nEDITOR=nvim\0PATH=/a:/b\0"
    XCTAssertEqual(
      LoginEnvironment.parse(Data(output.utf8)), ["EDITOR": "nvim", "PATH": "/a:/b"])
  }

  func testEnvParsingKeepsValuesWithNewlines() {
    let output = "B=x\0A=one\ntwo\nthree\0"
    XCTAssertEqual(LoginEnvironment.parse(Data(output.utf8)), ["A": "one\ntwo\nthree", "B": "x"])
  }

  func testEnvParsingIgnoresInvalidRecords() {
    let output = "A=1\0garbage\01BAD=x\0bad-name=y\0=nope\0_OK9=z\0EMPTY=\0"
    XCTAssertEqual(LoginEnvironment.parse(Data(output.utf8)), ["A": "1", "_OK9": "z", "EMPTY": ""])
  }

  func testProbeRunsLoginShellWithDeadline() {
    final class Box: @unchecked Sendable { var call: (String, [String], TimeInterval?)? }
    let box = Box()
    let runner = StubRunner(
      result: .success((0, Data("EDITOR=hx\0".utf8), Data())),
      onRun: { box.call = ($0, $1, $2) })
    let login = LoginEnvironment.probe(
      runner: runner, ownEnvironment: ["SHELL": "/bin/fish"], isExecutable: { $0 == "/bin/fish" })
    XCTAssertEqual(login.variables, ["EDITOR": "hx"])
    XCTAssertNil(login.notice)
    XCTAssertEqual(box.call?.0, "/bin/fish")
    XCTAssertEqual(box.call?.1, ["-l", "-c", "/usr/bin/env -0"])
    XCTAssertEqual(box.call?.2, 3)
  }

  func testProbeFallsBackToZshWhenShellMissing() {
    final class Box: @unchecked Sendable { var executable: String? }
    let box = Box()
    let runner = StubRunner(
      result: .success((0, Data("A=1\0".utf8), Data())), onRun: { executable, _, _ in box.executable = executable })
    _ = LoginEnvironment.probe(runner: runner, ownEnvironment: ["SHELL": "/nope"], isExecutable: { _ in false })
    XCTAssertEqual(box.executable, "/bin/zsh")
  }

  func testProbeFailureFallsBackToOwnEnvironment() {
    let own = ["EDITOR": "vim"]
    let failures: [Result<(status: Int32, stdout: Data, stderr: Data), Error>] = [
      .failure(ProcessRunnerError(message: "timed out")),
      .success((1, Data("A=1\0".utf8), Data())),
      .success((0, Data(), Data())),
      .success((0, Data("noise only".utf8), Data())),
    ]
    for result in failures {
      let login = LoginEnvironment.probe(
        runner: StubRunner(result: result), ownEnvironment: own, isExecutable: { _ in true })
      XCTAssertEqual(login.variables, own)
      XCTAssertEqual(login.notice, "Could not read your login environment; using md-viewer's own")
    }
  }

  func testSettingWinsOverEnvironment() throws {
    let result = resolver(
      settings: settings(editor: "hx --x"), own: ["VISUAL": "nvim"], login: ["PATH": "/login/bin"]
    ).resolve()
    let editor = try XCTUnwrap(resolved(result))
    XCTAssertEqual(editor.executable, "/login/bin/hx")
    XCTAssertEqual(editor.words, ["--x"])
    XCTAssertEqual(editor.kind, .helix)
    XCTAssertEqual(editor.source, .setting)
  }

  func testSettingKindOverridesDetection() throws {
    let result = resolver(
      settings: settings(editor: "/abs/custom-editor", kind: .neovim), login: [:]
    ).resolve()
    XCTAssertEqual(try XCTUnwrap(resolved(result)).kind, .neovim)
    let detected = resolver(settings: settings(editor: "/abs/custom-editor")).resolve()
    XCTAssertEqual(try XCTUnwrap(resolved(detected)).kind, .terminal)
  }

  func testUnresolvableSettingStopsResolution() {
    let result = resolver(
      settings: settings(editor: "missing --flag"), own: ["VISUAL": "/login/bin/nvim"],
      login: ["PATH": "/login/bin"]
    ).resolve()
    XCTAssertEqual(result.outcome, .stopped("editor setting: missing not found; , to choose"))
  }

  func testRelativePathWithASlashDoesNotResolve() {
    let relative = EditorResolver(
      settings: settings(editor: "./bin/nvim"), ownEnvironment: [:],
      loginEnvironment: { LoginEnvironment(variables: [:]) }, isExecutable: { _ in true })
    XCTAssertEqual(relative.resolve().outcome, .stopped("editor setting: ./bin/nvim not found; , to choose"))
  }

  func testVisualBeforeEditorInOwnEnvironment() throws {
    let result = resolver(
      own: ["EDITOR": "vim", "VISUAL": "nvim"], login: ["PATH": "/login/bin:/usr/bin"]
    ).resolve()
    let editor = try XCTUnwrap(resolved(result))
    XCTAssertEqual(editor.executable, "/login/bin/nvim")
    XCTAssertEqual(editor.source, .ownEnvironment("VISUAL"))
  }

  func testOwnEnvironmentBeatsLoginEnvironment() throws {
    let result = resolver(
      own: ["EDITOR": "vim"], login: ["VISUAL": "nvim", "PATH": "/login/bin:/usr/bin"]
    ).resolve()
    XCTAssertEqual(try XCTUnwrap(resolved(result)).source, .ownEnvironment("EDITOR"))
  }

  func testLoginEnvironmentUsedWhenOwnHasNone() throws {
    let result = resolver(
      own: [:], login: ["EDITOR": "hx", "VISUAL": "nvim", "PATH": "/login/bin"]
    ).resolve()
    let editor = try XCTUnwrap(resolved(result))
    XCTAssertEqual(editor.executable, "/login/bin/nvim")
    XCTAssertEqual(editor.source, .loginEnvironment("VISUAL"))
  }

  func testLoginPathBeforeOwnPath() throws {
    let result = resolver(
      own: ["EDITOR": "nano", "PATH": "/own/bin"], login: ["PATH": "/login/bin:/own/bin"]
    ).resolve()
    XCTAssertEqual(try XCTUnwrap(resolved(result)).executable, "/own/bin/nano")
    let both = resolver(
      own: ["EDITOR": "nvim", "PATH": "/own/bin"], login: ["PATH": "/login/bin"]
    ).resolve()
    XCTAssertEqual(try XCTUnwrap(resolved(both)).executable, "/login/bin/nvim")
  }

  func testUnresolvableEnvironmentValueIsSkippedWithNotice() throws {
    let result = resolver(
      own: ["EDITOR": "vi2"], login: ["EDITOR": "hx", "PATH": "/login/bin"]
    ).resolve()
    XCTAssertEqual(try XCTUnwrap(resolved(result)).source, .loginEnvironment("EDITOR"))
    XCTAssertEqual(result.notices, ["$EDITOR names vi2, which is not installed"])
  }

  func testNoMatchNeedsPickerAndNeverGuesses() {
    let result = resolver(own: [:], login: ["PATH": "/login/bin"]).resolve()
    XCTAssertEqual(result.outcome, .needsPicker)
    XCTAssertEqual(result.notices, [])
  }

  func testLoginNoticeIsReported() {
    let result = resolver(
      own: [:], login: [:], loginNotice: "Could not read your login environment; using md-viewer's own"
    )
    .resolve()
    XCTAssertEqual(result.notices, ["Could not read your login environment; using md-viewer's own"])
  }

  func testCandidatesFollowFixedOrderOnLoginPath() {
    let candidates = resolver(login: ["PATH": "/login/bin:/usr/bin:/own/bin"]).candidates()
    XCTAssertEqual(candidates.map(\.name), ["nvim", "hx", "vim", "nano", "code", "subl"])
    XCTAssertEqual(candidates.map(\.executable).first, "/login/bin/nvim")
    XCTAssertEqual(candidates.map(\.kind), [.neovim, .helix, .vim, .nano, .vscode, .sublime])
  }

  func testCandidateNamesOrder() {
    XCTAssertEqual(
      EditorResolver.candidateNames,
      ["nvim", "hx", "vim", "emacs", "nano", "micro", "kak", "code", "cursor", "zed", "subl"])
  }
}
