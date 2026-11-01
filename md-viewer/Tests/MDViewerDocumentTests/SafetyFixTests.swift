import MDViewerDocument
import XCTest

final class SafetyFixTests: XCTestCase {
  func blocks(_ markdown: String) -> String {
    shape(Document.parse(markdown).blocks)
  }

  func testUnclosedDroppedElementsDoNotHideTheDocument() {
    XCTAssertEqual(blocks("<form>\n\n# Heading\n"), "h1(\"Heading\")")
    XCTAssertEqual(blocks("<button>\n\n# Heading\n"), "h1(\"Heading\")")
    XCTAssertEqual(blocks("<style> elements are great\n\n# Section\n"), "plain(\"elements are great # Section\")")
    XCTAssertEqual(paragraphShape("Use the <script> tag to load things"), "\"Use the  tag to load things\"")
    XCTAssertEqual(paragraphShape("Set the <title> of the page."), "\"Set the  of the page.\"")
    XCTAssertEqual(blocks("<div>\n<iframe src=\"x\">\n\nText after.\n"), "p(\"Text after.\")")
  }

  func testClosedDroppedElementsStillHideTheirContent() {
    XCTAssertEqual(blocks("<form>\n\n**hidden**\n\n</form>\n\nShown.\n"), "p(\"Shown.\")")
    XCTAssertEqual(paragraphShape("a <script>alert(1)</script> b"), "\"a  b\"")
    XCTAssertEqual(blocks("<style>\np { }\n</style>\n\nShown.\n"), "p(\"Shown.\")")
  }

  func testBogusCommentsAreHidden() {
    XCTAssertEqual(blocks("<!DOCTYPE html>\n\nText.\n"), "p(\"Text.\")")
    XCTAssertEqual(blocks("<?php echo 1; ?>\n\nText.\n"), "p(\"Text.\")")
    XCTAssertEqual(blocks("<![CDATA[ hidden ]]>\n\nText.\n"), "p(\"Text.\")")
    XCTAssertEqual(blocks("<p>a <!-- unclosed\nb</p>\n"), "p(\"a\")")
    XCTAssertEqual(paragraphShape("a <?pi?> b"), "\"a  b\"")
  }

  func testEntities() {
    XCTAssertEqual(
      blocks("<p>&copy; &mdash; &rarr; &NotEqualTilde; &#x1F600 &#65&#66; &bogus;</p>\n"),
      "p(\"\u{A9} \u{2014} \u{2192} \u{2242}\u{338} \u{1F600} AB &bogus;\")")
    XCTAssertEqual(blocks("<p>&#0; &#x110000; &#99999999999999;</p>\n"), "p(\"\u{FFFD} \u{FFFD} \u{FFFD}\")")
  }

  func testUnsafeURLSchemeBypasses() {
    for href in [
      "javascript&colon;alert(1)", "java&Tab;script:alert(1)", "java&NewLine;script:alert(1)", "java&#115cript:x",
      "&#0000106avascript:x", "&#x6A;avascript:x", "JAVASCRIPT:x", " javascript:x", "vbscript:x", "data:text/html,x",
    ] {
      XCTAssertEqual(paragraphShape("x <a href=\"\(href)\">y</a>"), "\"x y\"", href)
      XCTAssertEqual(paragraphShape("x <img src=\"\(href)\">"), "\"x \"", href)
    }
    XCTAssertEqual(paragraphShape("[a](javascript&colon;x) [b](java&#115cript:x)"), "\"a b\"")
    XCTAssertEqual(
      paragraphShape("x <a href=\"https://ok.example/a:b\">ok</a>"), "\"x \" link(https://ok.example/a:b: \"ok\")")
  }

  func testRawHTMLAnchors() throws {
    let document = Document.parse(
      """
      <a name="top"></a>

      # Title

      <h2 id="custom">Custom</h2>

      Jump with <a id="inline-id" href="#top">link</a>, then [go](#top).
      """)
    XCTAssertEqual(shape(document.blocks[0]), "p(anchor(top))")
    XCTAssertEqual(document.blocks[2].division == nil ? document.blocks[2].heading?.slug : nil, "custom")
    XCTAssertEqual(document.anchorNames, ["top", "title", "custom", "inline-id"])
    XCTAssertEqual(document.resolveAnchor("#top"), "top")
    XCTAssertEqual(document.resolveAnchor("#user-content-top"), "top")
    XCTAssertEqual(document.resolveAnchor("user-content-custom"), "custom")
    XCTAssertEqual(document.resolveAnchor("#title"), "title")
    XCTAssertNil(document.resolveAnchor("#missing"))
    XCTAssertEqual(
      shape(document.blocks[3].paragraph ?? []),
      "\"Jump with \" anchor(inline-id) link(#top: \"link\") \", then \" link(#top: \"go\") \".\"")
  }

  func testInlineRangesForExtensionAutolinks() throws {
    let document = Document.parse("# T\n\nx\n\ny\n\nSee https://example.com and www.x.com now, mail a@b.co.\n")
    let inlines = try XCTUnwrap(document.blocks.last?.paragraph)
    let ranges = inlines.map {
      "\($0.range.start.line):\($0.range.start.column)-\($0.range.end.line):\($0.range.end.column)"
    }
    XCTAssertEqual(shape(inlines).components(separatedBy: " autolink").count, 4)
    XCTAssertEqual(ranges, ["7:1-7:4", "7:5-7:23", "7:24-7:28", "7:29-7:37", "7:38-7:48", "7:49-7:54", "7:55-7:55"])
    for inline in inlines { XCTAssertLessThanOrEqual(inline.range.end.column, 55) }
    let angle = try XCTUnwrap(Document.parse("a <https://x.example> b\n").blocks.first?.paragraph)
    XCTAssertEqual(angle[1].range.start.column, 3)
    XCTAssertEqual(angle[1].range.end.column, 21)
  }
}
