import Foundation
import MDViewerDocument
import XCTest

final class FixRoundTwoTests: XCTestCase {
  func blocks(_ markdown: String) -> String {
    shape(Document.parse(markdown).blocks)
  }

  func testDataURIImageInAlignedParagraphLeavesNoTagText() {
    let payload = String(repeating: "iVBORw0KGgo", count: 400)
    let markdown = "<p align=\"center\"><img src=\"data:image/png;base64,\(payload)\" alt=\"logo\"></p>\n\nAfter.\n"
    XCTAssertEqual(blocks(markdown), "p(\"After.\")")
    XCTAssertEqual(blocks("<img src=\"data:image/png;base64,\(payload)\">\n"), "")
  }

  func testLongTagsTokenize() {
    let path = String(repeating: "L10 20 ", count: 450)
    XCTAssertEqual(paragraphShape("x <svg><path d=\"M0 0 \(path)\"/></svg> y"), "\"x  y\"")
    let query = String(repeating: "a", count: 2100)
    XCTAssertEqual(
      paragraphShape("x <a href=\"https://example.com/?q=\(query)\">link</a>"),
      "\"x \" link(https://example.com/?q=\(query): \"link\")")
    let image = "<p align=\"center\"><img src=\"https://cdn.example/\(query).png\" width=\"64\"></p>\n"
    XCTAssertEqual(blocks(image), "div(center)[p(img(https://cdn.example/\(query).png width=64: \"\"))]")
  }

  func testMalformedTagsAreDroppedNotShown() {
    XCTAssertEqual(blocks("<div>\n<a href=\"unclosed>text after\n</div>\n"), "plain(\"text after\")")
    XCTAssertEqual(blocks("<div>\nkeep <b class='open\n</div>\n"), "plain(\"keep\")")
    XCTAssertEqual(blocks("<div>\n1 < 2 and <3\n</div>\n"), "plain(\"1 < 2 and <3\")")
  }

  func testLongAndMalformedTagsStayLinear() {
    let longTags = String(
      repeating: "<img src=\"https://x.example/" + String(repeating: "a", count: 3000) + "\">", count: 200)
    for markdown in [
      "<div>\n" + longTags,
      "<div>\n" + String(repeating: "<a x=\"", count: 20_000) + ">",
      "<div>\n" + String(repeating: "<a x='y' z=\"", count: 20_000) + ">",
      "<div>\n" + String(repeating: "<b ", count: 20_000) + ">",
    ] {
      let start = Date()
      _ = Document.parse(markdown)
      XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
  }

  func testDroppedContentStaysHiddenPastTheDepthCap() {
    let opens = String(repeating: "<div>", count: 150)
    let document = Document.parse(opens + "<script>secret()</script><form>hidden<b>x</b></form>visible\n\n# After\n")
    let text = document.blocks.map(\.plainTextForTest).joined(separator: "|")
    XCTAssertTrue(text.contains("visible"), text)
    XCTAssertTrue(text.contains("After"), text)
    XCTAssertFalse(text.contains("secret"), text)
    XCTAssertFalse(text.contains("hidden"), text)
    let unclosed = Document.parse(opens + "<script>gone\n\n# After\n")
    XCTAssertTrue(unclosed.blocks.contains { $0.plainTextForTest.contains("After") })
  }

  func testBreakRangesAreZeroWidthAtLineEnd() throws {
    let inlines = try XCTUnwrap(Document.parse("x  \ny\nz\n").blocks.first?.paragraph)
    let ranges = inlines.map {
      "\($0.range.start.line):\($0.range.start.column)-\($0.range.end.line):\($0.range.end.column)"
    }
    XCTAssertEqual(shape(inlines), "\"x\" hard \"y\" soft \"z\"")
    XCTAssertEqual(ranges, ["1:1-1:1", "1:4-1:3", "2:1-2:1", "2:2-2:1", "3:1-3:1"])
  }

  func testLegacyEntitiesWithoutSemicolon() {
    XCTAssertEqual(
      blocks("<p>&copy 2026 &amp &notit; &notin; &frac12x &copyright</p>\n"),
      "p(\"\u{A9} 2026 & \u{AC}it; \u{2209} \u{BD}x \u{A9}right\")")
    XCTAssertEqual(paragraphShape("Markdown keeps &copy literal"), "\"Markdown keeps &copy literal\"")
    XCTAssertEqual(
      paragraphShape("x <a href=\"/?a=1&copy=2&amp=3&copy;&lt\">y</a>"), "\"x \" link(/?a=1&copy=2&amp=3\u{A9}<: \"y\")"
    )
    XCTAssertEqual(
      paragraphShape("x <img src=\"a.png\" alt=\"&copy 2026 &copyx\">"), "\"x \" img(a.png: \"\u{A9} 2026 &copyx\")")
  }
}
