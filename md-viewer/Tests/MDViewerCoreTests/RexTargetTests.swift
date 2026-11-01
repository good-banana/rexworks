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

  func testPreviewBlockFindsLabeledBlockInWindow() throws {
    let json = try fixture("block-ls")
    XCTAssertEqual(
      previewBlock(blockListJSON: json, window: "window:01a193ad-f8f8-7ee0-ad1e-277b4d213ab6"),
      "block:01a193b9-0508-79fa-bbba-bae305053d7a")
    XCTAssertNil(previewBlock(blockListJSON: json, window: "window:none"))
    XCTAssertNil(previewBlock(blockListJSON: Data("nope".utf8), window: "w"))
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
      target: PaneTarget(session: "session:1", window: "window:2", block: "block:b"),
      file: file, mdViewer: "/opt/homebrew/bin/md-viewer")
    XCTAssertEqual(
      args,
      [
        "run", "--session", "session:1", "--block", "block:b", "--split", "right",
        "--ratio", "45", "--focus=false", "--shell=none", "--label", "md-viewer",
        "--cwd", "/tmp", "--", "/opt/homebrew/bin/md-viewer", "view", file.path,
      ])
  }

  func testTabArgumentsOpenNewWindowWithoutFocus() {
    let file = URL(fileURLWithPath: "/tmp/a.md")
    XCTAssertEqual(
      tabArguments(session: "session:1", file: file, mdViewer: "/bin/md-viewer"),
      [
        "run", "--session", "session:1", "--focus=false", "--shell=none", "--label",
        "md-viewer", "--cwd", "/tmp", "--", "/bin/md-viewer", "view", "/tmp/a.md",
      ])
  }

  func testPlanPrefersReuseThenSplitThenTab() {
    let target = PaneTarget(session: "s", window: "w", block: "b")
    XCTAssertEqual(
      planOpen(target: target, existingPreview: "block:p", previewAlive: true),
      .reused(block: "block:p"))
    XCTAssertEqual(
      planOpen(target: target, existingPreview: "block:p", previewAlive: false), .split(target))
    XCTAssertEqual(
      planOpen(target: target, existingPreview: nil, previewAlive: false), .split(target))
    XCTAssertEqual(
      planOpen(
        target: PaneTarget(session: "s", window: nil, block: nil), existingPreview: nil,
        previewAlive: false),
      .newTab(session: "s"))
    XCTAssertEqual(
      planOpen(
        target: PaneTarget(session: "s", window: "w", block: nil), existingPreview: nil,
        previewAlive: false),
      .newTab(session: "s"))
  }
}
