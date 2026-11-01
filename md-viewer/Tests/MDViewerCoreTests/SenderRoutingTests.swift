import XCTest

@testable import MDViewerCore

final class SenderRoutingTests: XCTestCase {
  func testRexSenderPreviews() {
    for sender in ["com.superlogical.rex", "com.superlogical.rex.beta"] {
      XCTAssertEqual(
        route(senderBundleID: sender, previousHandler: "com.x", handlerExists: { _ in true }),
        .rexPreview)
    }
    XCTAssertEqual(
      route(senderBundleID: "com.superlogical.rex", previousHandler: nil, handlerExists: { _ in true }),
      .rexPreview)
  }

  func testOtherSendersForward() {
    for sender in ["com.apple.finder", nil] {
      XCTAssertEqual(
        route(
          senderBundleID: sender, previousHandler: "com.microsoft.VSCode", handlerExists: { _ in true }),
        .forward(bundleID: "com.microsoft.VSCode"))
    }
  }

  func testMissingOrSelfPreviousFallsBackToTextEdit() {
    XCTAssertEqual(
      route(senderBundleID: "com.apple.finder", previousHandler: nil, handlerExists: { _ in true }),
      .textEditFallback)
    XCTAssertEqual(
      route(senderBundleID: "com.apple.finder", previousHandler: "com.gone", handlerExists: { _ in false }),
      .textEditFallback)
    XCTAssertEqual(
      route(
        senderBundleID: "com.apple.finder", previousHandler: "com.goodbanana.rexworks.md-viewer",
        handlerExists: { _ in true }),
      .textEditFallback)
  }

  func testForwardRouteAfterFailedPreviewNeverPreviews() {
    XCTAssertEqual(
      forwardRoute(previousHandler: "com.microsoft.VSCode", handlerExists: { _ in true }),
      .forward(bundleID: "com.microsoft.VSCode"))
    XCTAssertEqual(forwardRoute(previousHandler: "com.gone", handlerExists: { _ in false }), .textEditFallback)
    XCTAssertEqual(forwardRoute(previousHandler: nil, handlerExists: { _ in true }), .textEditFallback)
    XCTAssertEqual(
      forwardRoute(previousHandler: HandlerIdentity.bundleID, handlerExists: { _ in true }), .textEditFallback)
  }
}
