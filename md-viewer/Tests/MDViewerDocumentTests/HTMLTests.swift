import MDViewerDocument
import XCTest

final class HTMLTests: XCTestCase {
  func blocks(_ markdown: String) -> String {
    shape(Document.parse(markdown).blocks)
  }

  func testSupportedInlineTags() {
    XCTAssertEqual(
      paragraphShape("Press <kbd>Ctrl</kbd>+<kbd>C</kbd>"), "\"Press \" kbd(\"Ctrl\") \"+\" kbd(\"C\")")
    XCTAssertEqual(paragraphShape("x H<sub>2</sub>O x<sup>2</sup>"), "\"x H\" sub(\"2\") \"O x\" sup(\"2\")")
    XCTAssertEqual(
      paragraphShape("x <b>b</b> <strong>s</strong> <i>i</i> <em>e</em>"),
      "\"x \" strong(\"b\") \" \" strong(\"s\") \" \" em(\"i\") \" \" em(\"e\")")
    XCTAssertEqual(paragraphShape("x <code>a <b>b</b></code> <tt>t</tt>"), "\"x \" code(\"a b\") \" \" code(\"t\")")
    XCTAssertEqual(
      paragraphShape("x <s>s</s> <del>d</del> <strike>k</strike> <ins>i</ins> <mark>m</mark> <small>sm</small>"),
      "\"x \" del(\"s\") \" \" del(\"d\") \" \" del(\"k\") \" \" ins(\"i\") \" \" mark(\"m\") \" \" small(\"sm\")")
    XCTAssertEqual(
      paragraphShape("x <abbr title=\"HyperText Markup Language\">HTML</abbr> <span>sp</span>"),
      "\"x \" abbr(HyperText Markup Language: \"HTML\") \" sp\"")
    XCTAssertEqual(
      paragraphShape("x <a href=\"https://a.example\" title='T'>go *now*</a>"),
      "\"x \" link(https://a.example title=T: \"go \" em(\"now\"))")
    XCTAssertEqual(paragraphShape("x <a name=\"anchor\">named</a>"), "\"x \" anchor(anchor) \"named\"")
    XCTAssertEqual(
      paragraphShape("line<br>next<br/>last<BR />end"), "\"line\" hard \"next\" hard \"last\" hard \"end\"")
    XCTAssertEqual(
      paragraphShape("x <img src=\"a.png\" alt=\"An &amp; image\" width=\"100\" height=50px>"),
      "\"x \" img(a.png width=100 height=50: \"An & image\")")
    XCTAssertEqual(paragraphShape("x <img src=\"a.png\" width=\"50%\">"), "\"x \" img(a.png width=50.0%: \"\")")
    XCTAssertEqual(
      paragraphShape("x <img src=\"a.png\" width=\" 49.5 %\" height=\"250%\">"),
      "\"x \" img(a.png width=49.5% height=100.0%: \"\")", "percentages are trimmed and capped at 100")
    XCTAssertEqual(paragraphShape("x <img src=\"a.png\" width=\"-5%\">"), "\"x \" img(a.png: \"\")")
    XCTAssertEqual(paragraphShape("x <KBD>Up</KBD>"), "\"x \" kbd(\"Up\")")
  }

  func testNestedAndMismatchedTags() {
    XCTAssertEqual(paragraphShape("x <b>bold <i>both</i></b>"), "\"x \" strong(\"bold \" em(\"both\"))")
    XCTAssertEqual(paragraphShape("x <b>open to end"), "\"x \" strong(\"open to end\")")
    XCTAssertEqual(paragraphShape("x </b> stray"), "\"x  stray\"")
    XCTAssertEqual(paragraphShape("x <b>a <i>b</b> c"), "\"x \" strong(\"a \" em(\"b\")) \" c\"")
    XCTAssertEqual(paragraphShape("x <strong>a</b> c</strong>"), "\"x \" strong(\"a c\")")
    XCTAssertEqual(paragraphShape("*x <b>y* z</b>"), "em(\"x \" strong(\"y\")) \" z\"")
  }

  func testUnknownTagsKeepOnlyTheirText() {
    XCTAssertEqual(paragraphShape("a <foo class=\"x\">b</foo> c"), "\"a b c\"")
    XCTAssertEqual(
      paragraphShape("a <u>under</u> <font color=\"red\">red</font> <video src=\"v.mp4\">fallback</video>"),
      "\"a under red \" img( video=v.mp4: \"Video\")")
    XCTAssertEqual(paragraphShape("x <unknown-element/> y </stray> z"), "\"x  y  z\"")
    let document = Document.parse("<custom-tag>\nhello <b>bold</b>\n</custom-tag>\n\nAfter.\n")
    XCTAssertEqual(shape(document.blocks), "plain(\"hello \" strong(\"bold\")), p(\"After.\")")
    XCTAssertEqual(
      document.blocks[0].range, SourceRange(start: .init(line: 1, column: 1), end: .init(line: 3, column: 13)))
    XCTAssertEqual(blocks("<div align=\"center\"><u>kept</u> text</div>\n"), "div(center)[plain(\"kept text\")]")
  }

  func testCommentsAreDropped() {
    XCTAssertEqual(paragraphShape("a <!-- hidden --> c"), "\"a  c\"")
    XCTAssertEqual(Document.parse("<!-- only a comment -->\n").blocks, [])
    XCTAssertEqual(blocks("<p>\nvisible <!-- hidden -->\n</p>\n"), "p(\"visible\")")
  }

  func testHTMLTextDecodesEntitiesAndCollapsesWhitespace() {
    XCTAssertEqual(
      blocks("<p>Fish &amp; chips &lt;3 &#x41;&#66; <kbd>K</kbd><br>\n   next &unknown;</p>\n"),
      "p(\"Fish & chips <3 AB \" kbd(\"K\") hard \"next &unknown;\")")
  }

  func testDroppedElementsCannotInjectMarkup() {
    XCTAssertEqual(
      blocks("<div align=\"center\">\n<script>var s = \"</div><b>\";</script>\nInside <STYLE>p { }</STYLE>\n</div>\n"),
      "div(center)[plain(\"Inside\")]")
    XCTAssertEqual(paragraphShape("a <textarea>**x** <b>y</b></textarea> b"), "\"a  b\"")
    XCTAssertEqual(paragraphShape("a <button onclick=\"x()\">Go</button> b"), "\"a  b\"")
  }

  func testMarkdownInsideHTMLWithoutBlankLineStaysLiteral() {
    XCTAssertEqual(blocks("<div>\n**not bold**\n</div>\n"), "plain(\"**not bold**\")")
  }

  func testBlockElements() {
    let markdown = """
      <ol start="3">
        <li>Three</li>
        <li>Four <b>bold</b>
        <li>Five
      </ol>
      <ul><li>Bullet</li></ul>
      <hr>
      <blockquote>Quoted <em>text</em></blockquote>
      <pre>
      line 1
        indented &lt;tag&gt;
      </pre>
      <h2 align="right">Right heading</h2>
      <center>Centered</center>
      <dl><dt>Term</dt><dd>Definition</dd></dl>
      """
    XCTAssertEqual(
      blocks(markdown),
      [
        "ol(3)[li[plain(\"Three\")], li[plain(\"Four \" strong(\"bold\"))], li[plain(\"Five\")]]",
        "ul[li[plain(\"Bullet\")]]", "hr", "quote[plain(\"Quoted \" em(\"text\"))]",
        "code(: \"line 1\n  indented <tag>\n\")", "div(right)[h2(\"Right heading\")]",
        "div(center)[plain(\"Centered\")]",
        "plain(\"Term\")", "plain(\"Definition\")",
      ].joined(separator: ", "))
    XCTAssertNil(Document.parse("<h3>No anchor</h3>\n").blocks.first?.heading?.slug)
  }

  func testDetailsWithMarkdownBody() throws {
    let document = Document.parse(try fixture("all-nodes"))
    let block = try XCTUnwrap(document.blocks.first { $0.details != nil })
    XCTAssertEqual(
      shape(block), "details(open \"More \" strong(\"info\"))[p(\"Hidden \" strong(\"markdown\") \" body.\")]")
    XCTAssertEqual(block.range, SourceRange(start: .init(line: 52, column: 1), end: .init(line: 57, column: 10)))
  }

  func testFixtureInlineTags() throws {
    let document = Document.parse(try fixture("all-nodes"))
    XCTAssertEqual(
      shape(document.blocks[15].paragraph ?? []),
      "kbd(\"Ctrl\") \"+\" kbd(\"C\") \" and H\" sub(\"2\") \"O and x\" sup(\"2\") \".\"")
  }

  func testDetailsVariants() throws {
    XCTAssertEqual(
      blocks("<details><summary>One line</summary>Body text</details>\n"),
      "details(\"One line\")[plain(\"Body text\")]")
    XCTAssertEqual(blocks("<details>\n\nBody\n\n</details>\n"), "details()[p(\"Body\")]")
    let unclosed = Document.parse("<details>\n<summary>S</summary>\n\nBody\n")
    XCTAssertEqual(shape(unclosed.blocks), "details(\"S\")[p(\"Body\")]")
    XCTAssertEqual(unclosed.blocks[0].range.end.line, 4)
    XCTAssertEqual(Document.parse("</details>\n").blocks, [])
  }

  func testDetailsDoNotEscapeTheirContainer() {
    XCTAssertEqual(
      blocks("> <details>\n> <summary>Q</summary>\n\nOutside.\n"), "quote[details(\"Q\")[]], p(\"Outside.\")")
  }
}
