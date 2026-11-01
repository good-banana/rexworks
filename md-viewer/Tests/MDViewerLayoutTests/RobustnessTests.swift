import CoreGraphics
import Foundation
import XCTest

@testable import MDViewerLayout

final class RobustnessTests: XCTestCase {
  func testEmptyDocument() {
    let page = layout("")
    XCTAssertTrue(page.fragments.isEmpty)
    XCTAssertGreaterThan(page.height, 0)
    XCTAssertNil(page.textPosition(at: CGPoint(x: 10, y: 10)))
    XCTAssertEqual(page.plainText(0..<10), "")
    XCTAssertEqual(page.markdown(0..<0), "")
    XCTAssertTrue(page.find("x").isEmpty)
    XCTAssertNil(page.sourceRange(for: 0..<0))
  }

  func testTinyWidthsDoNotTrap() throws {
    let prepared = prepare(try fixture("sample"))
    for width in [0, 1, 20, 80] {
      let page = prepared.layout(width: CGFloat(width))
      XCTAssertGreaterThan(page.height, 0)
      XCTAssertEqual(
        page.plainText(0..<prepared.text.length), prepared.layout(width: 1000).plainText(0..<prepared.text.length))
    }
  }

  func testDeepNestingOnASmallStack() {
    let markdown = [
      String(repeating: ">", count: 5000) + " deep quote",
      (0..<300).map { String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n"),
      String(repeating: "<div>", count: 3000) + "\n\ninside\n\n" + String(repeating: "</div>", count: 3000),
      String(repeating: "<table><tr><td>", count: 30) + "cell",
    ].joined(separator: "\n\n")
    let box = LayoutBox()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
      box.page = prepare(markdown).layout(width: 900)
      done.signal()
    }
    #if DEBUG
      thread.stackSize = 4 * 1024 * 1024
    #else
      thread.stackSize = 512 * 1024
    #endif
    thread.start()
    XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
    let page = box.page
    XCTAssertNotNil(page?.range(of: "deep quote"))
    XCTAssertNotNil(page?.range(of: "cell"))
  }

  func testOddTableSpans() {
    let markdown = """
      <table>
      <tr><td rowspan="5">tall</td><td colspan="3">wide</td></tr>
      <tr><td>a</td></tr>
      <tr></tr>
      <tr><td colspan="0">zero</td><td rowspan="-2">negative</td></tr>
      </table>
      """
    let page = layout(markdown, width: 600)
    for word in ["tall", "wide", "a", "zero", "negative"] { XCTAssertNotNil(page.center(of: word), word) }
  }
}

private final class LayoutBox: @unchecked Sendable {
  var page: PageLayout?
}
