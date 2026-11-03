import XCTest

@testable import MDViewerCore

final class RexEditorPaneTests: XCTestCase {
  private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  func testRunArgumentsMatchTheSplitContract() {
    let arguments = RexEditorPane.runArguments(
      session: "session:1", anchorBlock: "block:p", directory: "/tmp/notes", command: ["/usr/bin/nvim", "+3", "a.md"])
    XCTAssertEqual(
      arguments,
      [
        "run", "--json", "--session", "session:1", "--block", "block:p", "--split", "left", "--ratio", "50",
        "--label", "md-viewer-editor", "--cwd", "/tmp/notes", "--", "/usr/bin/nvim", "+3", "a.md",
      ])
  }

  func testQueryArgumentsAskForJSONWhereTheyParseIt() {
    XCTAssertEqual(RexEditorPane.waitArguments(block: "block:e", session: "session:1").last, "--json")
    XCTAssertEqual(RexEditorPane.blockListArguments(session: "session:1").last, "--json")
    XCTAssertEqual(RexEditorPane.focusArguments(block: "block:e"), ["focus", "block:e"])
    XCTAssertEqual(
      RexEditorPane.inspectArguments(block: "block:e", session: "session:1"),
      ["block", "inspect", "-s", "session:1", "block:e"])
  }

  func testParsesTheNewBlockFromRealRunOutput() throws {
    XCTAssertEqual(
      RexEditorPane.blockID(runJSON: try fixture("rex-run")), "block:01a1a2b7-d61a-74b3-9771-06d6aa61e8f6")
  }

  func testRunOutputWithoutExactlyOneBlockHasNoID() {
    XCTAssertNil(RexEditorPane.blockID(runJSON: Data(#"{"block_ids":[]}"#.utf8)))
    XCTAssertNil(RexEditorPane.blockID(runJSON: Data(#"{"block_ids":["block:a","block:b"]}"#.utf8)))
    XCTAssertNil(RexEditorPane.blockID(runJSON: Data(#"{"block_id":"block:a"}"#.utf8)))
    XCTAssertNil(RexEditorPane.blockID(runJSON: Data("not json".utf8)))
  }

  func testFallbackFindsTheOneNewEditorBlock() {
    let list = Data(
      """
      {"blocks":[
        {"block_id":"block:old","label":"md-viewer-editor"},
        {"block_id":"block:new","label":"md-viewer-editor"},
        {"block_id":"block:shell","label":"shell"}]}
      """.utf8)
    XCTAssertEqual(RexEditorPane.fallbackBlockID(blockListJSON: list, excluding: ["block:old"]), "block:new")
  }

  func testFallbackRefusesAmbiguityAndAbsence() {
    let two = Data(
      #"{"blocks":[{"block_id":"block:a","label":"md-viewer-editor"},{"block_id":"block:b","label":"md-viewer-editor"}]}"#
        .utf8)
    XCTAssertNil(RexEditorPane.fallbackBlockID(blockListJSON: two, excluding: []))
    XCTAssertNil(RexEditorPane.fallbackBlockID(blockListJSON: two, excluding: ["block:a", "block:b"]))
    XCTAssertNil(RexEditorPane.fallbackBlockID(blockListJSON: Data("garbage".utf8), excluding: []))
  }

  func testFallbackOnRealBlockListFindsNothingWithoutEditors() throws {
    XCTAssertNil(RexEditorPane.fallbackBlockID(blockListJSON: try fixture("rex-block-ls"), excluding: []))
  }

  func testWaitPayloadsEndThePane() throws {
    XCTAssertEqual(RexEditorPane.classifyWait(stdout: try fixture("rex-wait-exited")), .ended)
    XCTAssertEqual(RexEditorPane.classifyWait(stdout: try fixture("rex-wait-closed")), .ended)
  }

  func testWaitWithoutPayloadNeedsAnInspect() {
    XCTAssertEqual(RexEditorPane.classifyWait(stdout: Data()), .noPayload)
    XCTAssertEqual(RexEditorPane.classifyWait(stdout: Data("{}".utf8)), .noPayload)
    XCTAssertEqual(RexEditorPane.classifyWait(stdout: Data("Error: nope".utf8)), .noPayload)
  }

  func testInspectOfAnExistingBlockIsFound() {
    XCTAssertEqual(RexEditorPane.classifyInspect(block: missingBlock, status: 0, stderr: Data()), .found)
  }

  private let missingBlock = "block:01a1a2b8-248d-7733-a80b-e2c571e5779e"

  func testInspectOfAMissingBlockIsNotFoundOnlyForTheRealFailure() throws {
    let stderr = try fixture("rex-block-inspect-missing", "stderr")
    let status = try XCTUnwrap(
      Int32(
        String(decoding: try fixture("rex-block-inspect-missing", "exit"), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(RexEditorPane.classifyInspect(block: missingBlock, status: status, stderr: stderr), .notFound)
  }

  func testInspectWithABadSessionOrMalformedIDIsNotAMissingBlock() throws {
    let badSession = try fixture("rex-block-inspect-bad-session", "stderr")
    let badID = try fixture("rex-block-inspect-bad-id", "stderr")
    XCTAssertEqual(RexEditorPane.classifyInspect(block: missingBlock, status: 3, stderr: badSession), .unknown)
    XCTAssertEqual(RexEditorPane.classifyInspect(block: "block:nope", status: 3, stderr: badID), .unknown)
  }

  func testNotFoundMustNameTheQueriedBlock() throws {
    let stderr = try fixture("rex-block-inspect-missing", "stderr")
    XCTAssertEqual(RexEditorPane.classifyInspect(block: "block:other", status: 3, stderr: stderr), .unknown)
  }

  func testOtherInspectFailuresAreUnknown() throws {
    let notFound = try fixture("rex-block-inspect-missing", "stderr")
    XCTAssertEqual(RexEditorPane.classifyInspect(block: missingBlock, status: 1, stderr: notFound), .unknown)
    XCTAssertEqual(
      RexEditorPane.classifyInspect(block: missingBlock, status: 3, stderr: Data("Error: timeout".utf8)), .unknown)
    XCTAssertEqual(RexEditorPane.classifyInspect(block: missingBlock, status: 3, stderr: Data()), .unknown)
  }

  func testInspectFixtureDecodesAsABlock() throws {
    let target = callerTarget(blockInspectJSON: try fixture("rex-block-inspect"))
    XCTAssertEqual(target?.block, "block:01a1a2b8-248d-7733-a80b-e2c571e5779e")
  }
}
