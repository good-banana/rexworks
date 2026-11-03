import XCTest

@testable import MDViewerCore

final class RexTargetTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  func testLastFocusedSessionParsesPreference() {
    let data = Data(#"{"sessionID":"session:01a1"}"#.utf8)
    XCTAssertEqual(lastFocusedSession(preferencesData: data), "session:01a1")
    XCTAssertNil(lastFocusedSession(preferencesData: nil))
    XCTAssertNil(lastFocusedSession(preferencesData: Data("garbage".utf8)))
  }

  func testResolvesActiveWindowFocusedBlock() throws {
    let json = Data(
      """
      {"active_window_id":"window:2","windows":[
        {"window_id":"window:1","focused_block_id":"block:a"},
        {"window_id":"window:2","focused_block_id":"block:b"}]}
      """.utf8)
    XCTAssertEqual(
      resolveTarget(sessionInspectJSON: json, session: "session:1"),
      PaneTarget(session: "session:1", window: "window:2", block: "block:b"))
  }

  func testResolvesRealSessionInspectFixture() throws {
    let target = resolveTarget(
      sessionInspectJSON: try fixture("session-inspect"), session: "session:x")
    XCTAssertEqual(target.window, "window:01a193ad-f8f8-7ee0-ad1e-277b4d213ab6")
    XCTAssertEqual(target.block, "block:01a193b6-fe81-72ee-bab7-569aa3a4f5ca")
  }

  func testMissingFocusYieldsSessionOnlyTarget() {
    let json = Data(#"{"active_window_id":"window:9","windows":[]}"#.utf8)
    XCTAssertEqual(
      resolveTarget(sessionInspectJSON: json, session: "session:1"),
      PaneTarget(session: "session:1", window: nil, block: nil))
    XCTAssertEqual(
      resolveTarget(sessionInspectJSON: Data("nope".utf8), session: "session:1"),
      PaneTarget(session: "session:1", window: nil, block: nil))
  }

  private let callerInspect = Data(
    """
    {"session_id":"session:caller","block":{"block_id":"block:caller","label":"shell",
      "placement":"placed","window_id":"window:caller"}}
    """.utf8)
  private let focused = PaneTarget(session: "session:focused", window: "window:focused", block: "block:focused")

  func testCallerTargetReadsBlockInspect() {
    XCTAssertEqual(
      callerTarget(blockInspectJSON: callerInspect),
      PaneTarget(session: "session:caller", window: "window:caller", block: "block:caller"))
    let unplaced = Data(#"{"session_id":"session:1","block":{"block_id":"block:1","placement":"unplaced"}}"#.utf8)
    XCTAssertNil(callerTarget(blockInspectJSON: unplaced))
    XCTAssertNil(callerTarget(blockInspectJSON: Data("nope".utf8)))
  }

  func testOpenTargetPrefersCallingBlock() {
    var inspected: [String] = []
    var focusedCalls = 0
    let target = openTarget(
      environment: ["REX_BLOCK": "block:caller"],
      inspectBlock: {
        inspected.append($0)
        return self.callerInspect
      },
      focusedTarget: {
        focusedCalls += 1
        return self.focused
      })
    XCTAssertEqual(target, PaneTarget(session: "session:caller", window: "window:caller", block: "block:caller"))
    XCTAssertEqual(inspected, ["block:caller"])
    XCTAssertEqual(focusedCalls, 0)
  }

  func testOpenTargetFallsBackToFocusedPaneWithoutCallingBlock() {
    for environment in [[:], ["REX_BLOCK": ""]] as [[String: String]] {
      var inspected = false
      let target = openTarget(
        environment: environment,
        inspectBlock: { _ in
          inspected = true
          return self.callerInspect
        },
        focusedTarget: { self.focused })
      XCTAssertEqual(target, focused)
      XCTAssertFalse(inspected)
    }
  }

  func testOpenTargetFallsBackToFocusedPaneForUnknownBlock() {
    XCTAssertEqual(
      openTarget(
        environment: ["REX_BLOCK": "block:gone"], inspectBlock: { _ in nil }, focusedTarget: { self.focused }),
      focused)
    XCTAssertEqual(
      openTarget(
        environment: ["REX_BLOCK": "block:gone"], inspectBlock: { _ in Data("{}".utf8) },
        focusedTarget: { self.focused }),
      focused)
  }

  func testHandlerEnvironmentDropsCallerBlockSoClicksTargetFocusedPane() {
    let inherited = ["REX_BLOCK": "block:stale", "REX_SESSION": "session:1", "PATH": "/usr/bin"]
    let environment = environmentWithoutCallerBlock(inherited)
    XCTAssertEqual(environment, ["REX_SESSION": "session:1", "PATH": "/usr/bin"])
    XCTAssertEqual(
      openTarget(environment: environment, inspectBlock: { _ in self.callerInspect }, focusedTarget: { self.focused }),
      focused)
  }

  func testPreviewBlocksListsEveryPreviewInTheWindowOnly() throws {
    let json = try fixture("block-ls")
    XCTAssertEqual(
      previewBlocks(blockListJSON: json, window: "window:01a193ad-f8f8-7ee0-ad1e-277b4d213ab6"),
      ["block:01a193b9-0508-79fa-bbba-bae305053d7a"])
    XCTAssertEqual(
      previewBlocks(blockListJSON: json, window: "window:01a18e8c-86a4-7320-99d8-5c0e0a7dcf04"),
      ["block:01a18e8c-ffff-7134-90c4-3b3fc97dac00"])
    XCTAssertEqual(previewBlocks(blockListJSON: json, window: "window:none"), [])
    XCTAssertEqual(previewBlocks(blockListJSON: Data("nope".utf8), window: "w"), [])
  }

  func testSessionSelectionPrefersFocusedThenClientThenList() throws {
    let clients = try fixture("client-ls")
    let list = try fixture("ls")
    XCTAssertEqual(
      selectSession(
        lastFocused: "session:01a1941c-33b6-701f-90d5-556f31539a8c", clientListJSON: clients,
        sessionListJSON: list),
      "session:01a1941c-33b6-701f-90d5-556f31539a8c")
    XCTAssertEqual(
      selectSession(lastFocused: "session:gone", clientListJSON: clients, sessionListJSON: list),
      "session:01a18e8c-860a-7d94-b653-588b0358ac75")
    XCTAssertEqual(
      selectSession(lastFocused: nil, clientListJSON: Data("{}".utf8), sessionListJSON: list),
      "session:01a18e8c-860a-7d94-b653-588b0358ac75")
    XCTAssertNil(
      selectSession(
        lastFocused: nil, clientListJSON: Data("{}".utf8), sessionListJSON: Data("{}".utf8)))
  }

  func testSplitArgumentsAreLiteralAndShellFree() {
    let file = URL(fileURLWithPath: "/tmp/$(touch pwned); a (b) \u{1F415}.md")
    let args = splitArguments(
      placement: .beside(PaneTarget(session: "session:1", window: "window:2", block: "block:b")),
      file: file, mdViewer: "/opt/homebrew/bin/md-viewer",
      origin: ViewerOrigin(themeSourceBlock: "block:b", opener: "block:b"))
    XCTAssertEqual(
      args,
      [
        "run", "--session", "session:1", "--block", "block:b", "--split", "right",
        "--ratio", "45", "--focus=false", "--shell=none", "--label", "md-viewer",
        "--cwd", "/tmp", "--", "/opt/homebrew/bin/md-viewer", "view", "--theme-source-block", "block:b",
        "--opener-block", "block:b", file.path,
      ])
  }

  func testLaterPreviewsSplitBelowTheNewestPreview() {
    let args = splitArguments(
      placement: .below(PaneTarget(session: "s", window: "w", block: "block:preview")),
      file: URL(fileURLWithPath: "/tmp/a.md"), mdViewer: "/bin/md-viewer")
    XCTAssertEqual(
      Array(args.prefix(9)), ["run", "--session", "s", "--block", "block:preview", "--split", "below", "--ratio", "50"])
  }

  func testTabArgumentsOpenNewWindowWithoutFocus() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    XCTAssertEqual(
      tabArguments(session: "session:1", file: file, mdViewer: "/bin/md-viewer"),
      [
        "run", "--session", "session:1", "--focus=false", "--shell=none", "--label",
        "md-viewer", "--cwd", "/tmp", "--", "/bin/md-viewer", "view", "/tmp/a.md",
      ])
    XCTAssertEqual(
      tabArguments(
        session: "session:1", file: file, mdViewer: "/bin/md-viewer", origin: ViewerOrigin(themeSourceBlock: "block:s")
      )
      .suffix(4),
      ["view", "--theme-source-block", "block:s", "/tmp/a.md"])
  }

  func testSplitWithoutOriginOmitsTheFlags() {
    let args = splitArguments(
      placement: .beside(PaneTarget(session: "s", window: "w", block: "b")), file: URL(fileURLWithPath: "/tmp/a.md"),
      mdViewer: "/old/md-viewer")
    XCTAssertFalse(args.contains("--theme-source-block"))
    XCTAssertFalse(args.contains("--opener-block"))
    XCTAssertEqual(args.suffix(2), ["view", "/tmp/a.md"])
  }

  func testSameExecutableComparesRealPaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let real = directory.appendingPathComponent("md-viewer")
    let link = directory.appendingPathComponent("linked")
    let other = directory.appendingPathComponent("other")
    FileManager.default.createFile(atPath: real.path, contents: Data())
    FileManager.default.createFile(atPath: other.path, contents: Data())
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    XCTAssertTrue(isSameExecutable(link.path, real.path))
    XCTAssertTrue(isSameExecutable(directory.path + "/./md-viewer", real.path))
    XCTAssertFalse(isSameExecutable(other.path, real.path))
  }

  func testViewArgumentsAcceptOptionalThemeSourceAndOpenerBlocks() {
    XCTAssertEqual(ViewArguments(["/tmp/a.md"])?.file, "/tmp/a.md")
    XCTAssertEqual(ViewArguments(["/tmp/a.md"])?.origin, ViewerOrigin())
    let withBlock = ViewArguments(["--theme-source-block", "block:7", "/tmp/a.md"])
    XCTAssertEqual(withBlock?.origin, ViewerOrigin(themeSourceBlock: "block:7"))
    XCTAssertEqual(withBlock?.file, "/tmp/a.md")
    let both = ViewArguments(["--opener-block", "block:o", "--theme-source-block", "block:t", "/tmp/a.md"])
    XCTAssertEqual(both?.origin, ViewerOrigin(themeSourceBlock: "block:t", opener: "block:o"))
    XCTAssertEqual(both?.file, "/tmp/a.md")
    XCTAssertNil(ViewArguments([]))
    XCTAssertNil(ViewArguments(["--theme-source-block", "", "/tmp/a.md"]))
    XCTAssertNil(ViewArguments(["--opener-block", "", "/tmp/a.md"]))
    XCTAssertNil(ViewArguments(["--opener-block", "a", "--opener-block", "b", "/tmp/a.md"]))
    XCTAssertNil(ViewArguments(["--other", "x", "/tmp/a.md"]))
    XCTAssertNil(ViewArguments(["a.md", "b.md"]))
  }
}
