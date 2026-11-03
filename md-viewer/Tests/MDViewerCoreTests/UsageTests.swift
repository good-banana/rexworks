import XCTest

@testable import MDViewerCore

final class UsageTests: XCTestCase {
  func testViewIsDescribedAsAFullPreviewInThisPane() {
    XCTAssertTrue(commandUsage.contains("view <file>   Render a Markdown preview in this pane"))
    XCTAssertFalse(commandUsage.contains("in the terminal"))
  }

  func testOpenDescribesBothFlags() {
    XCTAssertTrue(commandUsage.contains("open [--new | --replace] <file>"))
    XCTAssertTrue(commandUsage.contains("--new always opens a\n"))
    XCTAssertTrue(commandUsage.contains("--replace updates the preview this pane opened last."))
  }
}
