import XCTest

@testable import MDViewerCore

final class EditorProfileTests: XCTestCase {
  private let launch = NeovimLaunch(
    socket: "/s/v.sock", token: "tok", controlSocket: "/n/c.sock", filesSidecar: "/n/c.files",
    buffersDirectory: "/b", plugin: "/p/md-viewer.lua")

  func testKindDetectionFromBasename() {
    let expected: [String: EditorKind] = [
      "/opt/bin/nvim": .neovim, "vim": .vim, "vi": .vim, "view": .vim, "hx": .helix, "helix": .helix,
      "emacs": .emacs, "emacsclient": .emacs, "nano": .nano, "micro": .micro, "kak": .kakoune,
      "code": .vscode, "code-insiders": .vscode, "cursor": .cursor, "zed": .zed, "subl": .sublime,
      "ed": .terminal, "my-wrapper": .terminal,
    ]
    for (executable, kind) in expected {
      XCTAssertEqual(EditorProfile.detectKind(executable: executable), kind, executable)
    }
  }

  func testLineArgumentsForEachKind() {
    let expected: [EditorKind: [String]] = [
      .neovim: ["+7", "f.md"], .vim: ["+7", "f.md"], .helix: ["f.md:7"], .emacs: ["+7", "f.md"],
      .nano: ["+7", "f.md"], .micro: ["+7", "f.md"], .kakoune: ["+7", "f.md"],
      .vscode: ["-g", "f.md:7"], .cursor: ["-g", "f.md:7"], .zed: ["f.md:7"], .sublime: ["f.md:7"],
      .terminal: ["f.md"],
    ]
    XCTAssertEqual(Set(expected.keys), Set(EditorKind.allCases))
    for (kind, arguments) in expected {
      XCTAssertEqual(EditorProfile(kind: kind).lineArguments(file: "f.md", line: 7), arguments, "\(kind)")
    }
  }

  func testNoLineMeansFileOnly() {
    for kind in EditorKind.allCases {
      XCTAssertEqual(EditorProfile(kind: kind).lineArguments(file: "f.md", line: nil), ["f.md"], "\(kind)")
    }
  }

  func testAbsolutePathComesFirstThenWordsThenProfileArguments() {
    let command = EditorProfile(kind: .helix).commandLine(
      executable: "/opt/bin/hx", words: ["--config", "x.toml"], file: "f.md", line: 3)
    XCTAssertEqual(command, ["/opt/bin/hx", "--config", "x.toml", "f.md:3"])
  }

  func testEmacsFlagsAddedOnlyWhenMissing() {
    let profile = EditorProfile(kind: .emacs)
    XCTAssertEqual(
      profile.commandLine(executable: "/bin/emacs", words: [], file: "f.md", line: 2),
      ["/bin/emacs", "-nw", "+2", "f.md"])
    XCTAssertEqual(
      profile.commandLine(executable: "/bin/emacsclient", words: [], file: "f.md", line: 2),
      ["/bin/emacsclient", "-t", "+2", "f.md"])
    for flag in ["-nw", "--no-window-system", "-t", "--tty"] {
      XCTAssertEqual(
        profile.commandLine(executable: "/bin/emacs", words: [flag], file: "f.md", line: 2),
        ["/bin/emacs", flag, "+2", "f.md"], flag)
    }
  }

  func testNeovimCommand() throws {
    let command = try XCTUnwrap(
      EditorProfile(kind: .neovim).neovimCommand(
        executable: "/opt/bin/nvim", words: ["-u", "x.lua"], file: "f.md", line: 9, launch: launch))
    XCTAssertEqual(
      command,
      [
        "/usr/bin/env", "MD_VIEWER_SOCKET=/s/v.sock", "MD_VIEWER_TOKEN=tok", "MD_VIEWER_CONTROL=/n/c.sock",
        "MD_VIEWER_FILES=/n/c.files", "MD_VIEWER_BUFFERS=/b", "MD_VIEWER_PLUGIN=/p/md-viewer.lua",
        "/opt/bin/nvim", "-u", "x.lua", "--cmd", "lua dofile(os.getenv('MD_VIEWER_PLUGIN'))",
        "-c", "lua MdViewer.ensure()", "+9", "f.md",
      ])
    XCTAssertFalse(command.contains { $0.contains("--listen") })
  }

  func testOnlyNeovimHasLiveSyncAndLaunch() {
    for kind in EditorKind.allCases where kind != .neovim {
      let profile = EditorProfile(kind: kind)
      XCTAssertFalse(profile.syncsLive, "\(kind)")
      XCTAssertNil(
        profile.neovimCommand(executable: "/bin/x", words: [], file: "f.md", line: 1, launch: launch))
    }
    XCTAssertTrue(EditorProfile(kind: .neovim).syncsLive)
  }

  func testGUIKindsDoNotRunInTerminal() {
    for kind in [EditorKind.vscode, .cursor, .zed, .sublime] {
      let profile = EditorProfile(kind: kind)
      XCTAssertFalse(profile.runsInTerminal, "\(kind)")
      XCTAssertNil(
        profile.neovimCommand(executable: "/bin/x", words: [], file: "f.md", line: 1, launch: launch))
    }
    for kind in EditorKind.allCases where ![EditorKind.vscode, .cursor, .zed, .sublime].contains(kind) {
      XCTAssertTrue(EditorProfile(kind: kind).runsInTerminal, "\(kind)")
    }
  }
}
