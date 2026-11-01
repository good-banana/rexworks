import MDViewerDocument
import XCTest

final class HTMLTests: XCTestCase {
  func testSupportedInlineTags() {
    XCTAssertEqual(
      paragraphShape("Press <kbd>Ctrl</kbd>+<kbd>C</kbd>"), "\"Press \" kbd(\"Ctrl\") \"+\" kbd(\"C\")")
    XCTAssertEqual(paragraphShape("x H<sub>2</sub>O x<sup>2</sup>"), "\"x H\" sub(\"2\") \"O x\" sup(\"2\")")
    XCTAssertEqual(
      paragraphShape("x <b>b</b> <strong>s</strong> <i>i</i> <em>e</em>"),
      "\"x \" strong(\"b\") \" \" strong(\"s\") \" \" em(\"i\") \" \" em(\"e\")")
    XCTAssertEqual(paragraphShape("x <code>a <b>b</b></code>"), "\"x \" code(\"a b\")")
    XCTAssertEqual(
      paragraphShape("x <a href=\"https://a.example\" title='T'>go *now*</a>"),
      "\"x \" link(https://a.example title=T: \"go \" em(\"now\"))")
    XCTAssertEqual(paragraphShape("x <a name=\"anchor\">named</a>"), "\"x named\"")
    XCTAssertEqual(
      paragraphShape("line<br>next<br/>last<BR />end"), "\"line\" hard \"next\" hard \"last\" hard \"end\"")
    XCTAssertEqual(
      paragraphShape("x <img src=\"a.png\" alt=\"An &amp; image\" width=\"100\" height=50>"),
      "\"x \" img(a.png width=100 height=50: \"An & image\")")
    XCTAssertEqual(paragraphShape("x <KBD>Up</KBD>"), "\"x \" kbd(\"Up\")")
  }

  func testNestedAndMismatchedTags() {
    XCTAssertEqual(paragraphShape("x <b>bold <i>both</i></b>"), "\"x \" strong(\"bold \" em(\"both\"))")
    XCTAssertEqual(paragraphShape("x <b>open to end"), "\"x \" strong(\"open to end\")")
    XCTAssertEqual(paragraphShape("x </b> stray"), "\"x  stray\"")
    XCTAssertEqual(paragraphShape("x <b>a <i>b</b> c"), "\"x \" strong(\"a \" em(\"b\")) \" c\"")
    XCTAssertEqual(paragraphShape("x <strong>a</b> c</strong>"), "\"x \" strong(\"a c\")")
  }

  func testUnsupportedInlineHTMLIsLiteralText() {
    XCTAssertEqual(paragraphShape("a <span class=\"x\">b</span> c"), "\"a <span class=\"x\">b</span> c\"")
    XCTAssertEqual(paragraphShape("a <script>alert(1)</script> c"), "\"a <script>alert(1)</script> c\"")
    XCTAssertEqual(paragraphShape("a <!-- hidden --> c"), "\"a  c\"")
  }

  func testUnsupportedHTMLBlockIsLiteralText() {
    let document = Document.parse("<script>\nalert(1)\n</script>\n\nAfter.\n")
    XCTAssertEqual(document.blocks.count, 2)
    XCTAssertEqual(document.blocks[0].htmlBlock.map(shape), "\"<script> alert(1) </script>\"")
    XCTAssertEqual(
      document.blocks[0].range, SourceRange(start: .init(line: 1, column: 1), end: .init(line: 3, column: 9)))
    XCTAssertEqual(
      Document.parse("<div align=\"center\">\n  <img src=\"logo.png\" width=\"80\">\n</div>\n").blocks[0].htmlBlock.map(
        shape),
      "\"<div align=\"center\"> \" img(logo.png width=80: \"\") \" </div>\"")
    XCTAssertEqual(Document.parse("<!-- only a comment -->\n").blocks, [])
  }

  func testHTMLBlockTextDecodesEntitiesAndKeepsSupportedTags() {
    let document = Document.parse("<p>Fish &amp; chips &lt;3 &#x41;&#66; <kbd>K</kbd><br>next &unknown;</p>\n")
    XCTAssertEqual(
      document.blocks[0].htmlBlock.map(shape), "\"<p>Fish & chips <3 AB \" kbd(\"K\") hard \"next &unknown;</p>\"")
  }

  func testHostileFixture() throws {
    let document = Document.parse(try fixture("hostile"))
    XCTAssertEqual(
      document.blocks.map { shape($0.htmlBlock ?? $0.paragraph ?? []) },
      [
        "",
        "\"<script>window.__pwned=1</script>\"",
        "img(x: \"\")",
        "link(javascript:window.__pwned=1: \"x\")",
        "\"<audio autoplay src=\"x.mp3\"></audio>\"",
      ])
  }

  func testDetailsWithMarkdownBody() throws {
    let document = Document.parse(try fixture("all-nodes"))
    let block = try XCTUnwrap(document.blocks.first { $0.details != nil })
    let details = try XCTUnwrap(block.details)
    XCTAssertTrue(details.isOpen)
    XCTAssertEqual(shape(details.summary), "\"More \" strong(\"info\")")
    XCTAssertEqual(details.blocks.compactMap(\.paragraph).map(shape), ["\"Hidden \" strong(\"markdown\") \" body.\""])
    XCTAssertEqual(block.range, SourceRange(start: .init(line: 52, column: 1), end: .init(line: 57, column: 10)))
  }

  func testFixtureInlineTags() throws {
    let document = Document.parse(try fixture("all-nodes"))
    XCTAssertEqual(
      shape(document.blocks[15].paragraph ?? []),
      "kbd(\"Ctrl\") \"+\" kbd(\"C\") \" and H\" sub(\"2\") \"O and x\" sup(\"2\") \".\"")
  }

  func testDetailsVariants() throws {
    let closed = try XCTUnwrap(
      Document.parse("<details><summary>One line</summary>Body text</details>\n").blocks.first?.details)
    XCTAssertFalse(closed.isOpen)
    XCTAssertEqual(shape(closed.summary), "\"One line\"")
    XCTAssertEqual(closed.blocks.compactMap(\.htmlBlock).map(shape), ["\"Body text\""])

    let noSummary = try XCTUnwrap(Document.parse("<details>\n\nBody\n\n</details>\n").blocks.first?.details)
    XCTAssertEqual(noSummary.summary, [])
    XCTAssertEqual(noSummary.blocks.compactMap(\.paragraph).map(shape), ["\"Body\""])

    let unclosed = Document.parse("<details>\n<summary>S</summary>\n\nBody\n")
    XCTAssertEqual(unclosed.blocks.count, 1)
    XCTAssertEqual(unclosed.blocks[0].details?.blocks.compactMap(\.paragraph).map(shape), ["\"Body\""])
    XCTAssertEqual(unclosed.blocks[0].range.end.line, 4)

    XCTAssertEqual(Document.parse("</details>\n").blocks, [])
  }

  func testNestedDetails() throws {
    let markdown = """
      <details>
      <summary>Outer</summary>

      <details>
      <summary>Inner</summary>

      Deep.

      </details>

      After inner.

      </details>

      Outside.
      """
    let document = Document.parse(markdown)
    XCTAssertEqual(document.blocks.count, 2)
    let outer = try XCTUnwrap(document.blocks[0].details)
    XCTAssertEqual(shape(outer.summary), "\"Outer\"")
    XCTAssertEqual(outer.blocks.count, 2)
    let inner = try XCTUnwrap(outer.blocks[0].details)
    XCTAssertEqual(shape(inner.summary), "\"Inner\"")
    XCTAssertEqual(inner.blocks.compactMap(\.paragraph).map(shape), ["\"Deep.\""])
    XCTAssertEqual(outer.blocks[1].paragraph.map(shape), "\"After inner.\"")
    XCTAssertEqual(document.blocks[1].paragraph.map(shape), "\"Outside.\"")
  }

  func testDetailsDoNotEscapeTheirContainer() throws {
    let document = Document.parse("> <details>\n> <summary>Q</summary>\n\nOutside.\n")
    let quote = try XCTUnwrap(document.blocks[0].quote)
    XCTAssertEqual(quote[0].details.map { shape($0.summary) }, "\"Q\"")
    XCTAssertEqual(document.blocks[1].paragraph.map(shape), "\"Outside.\"")
  }
}
