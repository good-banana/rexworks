import Foundation
import MDViewerDocument
import XCTest

final class RobustnessTests: XCTestCase {
  func parseOnSmallStack(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) -> Document? {
    let box = ResultBox()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
      box.document = Document.parse(markdown)
      done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    XCTAssertEqual(done.wait(timeout: .now() + 60), .success, file: file, line: line)
    return box.document
  }

  func assertFast(_ limit: TimeInterval, _ markdown: String, file: StaticString = #filePath, line: UInt = #line) {
    let start = Date()
    _ = Document.parse(markdown)
    XCTAssertLessThan(Date().timeIntervalSince(start), limit, file: file, line: line)
  }

  func testDeepBlockQuotesOnSmallStack() throws {
    let document = try XCTUnwrap(parseOnSmallStack(String(repeating: ">", count: 20_000) + " deep\n"))
    XCTAssertEqual(document.blocks.count, 1)
    XCTAssertTrue(document.blocks[0].plainTextForTest.contains("deep"))
  }

  func testDeepHTMLAndEmphasisOnSmallStack() throws {
    let divs = String(repeating: "<div>", count: 30_000) + "inner" + String(repeating: "</div>", count: 30_000)
    let document = try XCTUnwrap(parseOnSmallStack(divs + "\n\nAfter.\n"))
    XCTAssertTrue(document.blocks.contains { $0.plainTextForTest.contains("inner") })
    XCTAssertEqual(document.blocks.last?.paragraph.map(shape), "\"After.\"")
    let emphasis = try XCTUnwrap(parseOnSmallStack(String(repeating: "*a", count: 50_000) + "\n"))
    XCTAssertEqual(emphasis.blocks.count, 1)
    let lists = try XCTUnwrap(parseOnSmallStack(String(repeating: "- ", count: 5_000) + "item\n"))
    XCTAssertTrue(lists.blocks[0].plainTextForTest.contains("item"))
  }

  func testUnclosedCommentsAreLinear() {
    assertFast(2, String(repeating: "<!--", count: 20_000))
    assertFast(2, "<div>\n" + String(repeating: "<!-- ", count: 20_000))
    assertFast(2, "<div>\n" + String(repeating: "<a x=\"y\" ", count: 20_000))
    assertFast(2, "<div>\n" + String(repeating: "<script>", count: 20_000))
    XCTAssertEqual(Document.parse("<div>\n<!-- never closed\n\n# Heading\n").blocks.map(shape), ["h1(\"Heading\")"])
  }

  func testNestedHTMLIsNotQuadratic() {
    assertFast(2, String(repeating: "<div>", count: 10_000) + "x\n")
    assertFast(2, "<div>\n" + String(repeating: "<b><p>", count: 10_000) + "x\n")
  }
}

private final class ResultBox: @unchecked Sendable {
  var document: Document?
}

extension Block {
  var plainTextForTest: String {
    switch kind {
    case .paragraph(let inlines), .plain(let inlines): inlines.plainText
    case .heading(let heading): heading.content.plainText
    case .blockQuote(let blocks): blocks.map(\.plainTextForTest).joined(separator: "\n")
    case .division(let division): division.blocks.map(\.plainTextForTest).joined(separator: "\n")
    case .list(let list): list.items.flatMap(\.blocks).map(\.plainTextForTest).joined(separator: "\n")
    default: ""
    }
  }
}
