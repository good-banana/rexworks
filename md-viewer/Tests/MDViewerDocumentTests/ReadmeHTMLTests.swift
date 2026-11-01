import MDViewerDocument
import XCTest

final class ReadmeHTMLTests: XCTestCase {
  var document: Document!

  override func setUpWithError() throws {
    document = Document.parse(try fixture("readme"))
  }

  func testCenteredLogoWithLightAndDarkSources() throws {
    XCTAssertEqual(
      shape(document.blocks[0]),
      "div(center)[p(img(docs/logo-light.png width=240 sources=[dark:docs/logo-dark.png light:docs/logo-light.png]:"
        + " \"Project logo\"))]")
    let image = try XCTUnwrap(document.blocks[0].division?.blocks.first?.paragraph?.first)
    guard case .image(let picture) = image.kind else { return XCTFail("expected an image") }
    XCTAssertEqual(picture.sources.map(\.media), ["(prefers-color-scheme: dark)", "(prefers-color-scheme: light)"])
    XCTAssertEqual(picture.sources.map(\.colorScheme), [.dark, .light])
  }

  func testCenteredBadges() {
    XCTAssertEqual(
      shape(document.blocks[1]),
      "div(center)[p(link(https://ci.example/build: img(https://img.shields.io/badge/build-passing-green: \"Build\"))"
        + " \" \" link(LICENSE: img(https://img.shields.io/badge/license-MIT-blue: \"License\")))]")
  }

  func testDivWrappingMarkdown() throws {
    XCTAssertEqual(
      shape(document.blocks[2]),
      "div(center)[h1(\"Project Title\"), p(strong(\"A tagline with \" em(\"emphasis\") \".\")),"
        + " p(link(https://docs.example: \"Docs\") \" · \" link(#install: \"Install\"))]")
    XCTAssertEqual(document.blocks[2].division?.blocks.first?.heading?.slug, "project-title")
    XCTAssertEqual(document.blocks[2].range.start.line, 14)
    XCTAssertEqual(document.blocks[2].range.end.line, 22)
    XCTAssertEqual(shape(document.blocks[3]), "h2(\"Install\")")
  }

  func testHTMLTable() throws {
    XCTAssertEqual(
      shape(document.blocks[4]),
      "table(head: th(left)[plain(\"Platform\")] th[plain(\"Command\")]; td[plain(\"macOS\")]"
        + " td(center)[plain(code(\"brew install tool\"))]; td(span=2)[plain(\"More platforms \" strong(\"soon\"))])")
    XCTAssertEqual(document.blocks[4].table?.alignments, [.left, .none])
  }

  func testNestedDetails() {
    XCTAssertEqual(
      shape(document.blocks[5]),
      "details(\"Advanced \" code(\"options\"))[p(\"Intro \" strong(\"text\") \".\"),"
        + " details(open \"Inner\")[ul[li[p(\"a\")], li[p(\"b\")]]]]")
    XCTAssertEqual(document.blocks.count, 6)
  }

  func testBlankLineInsideAlignedParagraph() {
    let images = Document.parse("<p align=\"center\">\n<img src=\"a.png\">\n\n<img src=\"b.png\">\n</p>\n")
    XCTAssertEqual(shape(images.blocks), "div(center)[p(img(a.png: \"\") \" \" img(b.png: \"\"))]")
    let markdown = Document.parse("<p align=\"center\">\n<img src=\"a.png\">\n\n**Bold**\n</p>\n")
    XCTAssertEqual(shape(markdown.blocks), "div(center)[p(img(a.png: \"\"))], p(strong(\"Bold\"))")
  }

  func testMarkdownInsideHTMLTableCell() {
    let table = Document.parse("<table>\n<tr>\n<td>\n\n**Bold cell**\n\n</td>\n<td>Plain</td>\n</tr>\n</table>\n")
    XCTAssertEqual(shape(table.blocks), "table(td[p(strong(\"Bold cell\"))] td[plain(\"Plain\")])")
    XCTAssertNil(table.blocks.first?.table?.header)
  }

  func testPictureWithoutImageUsesFirstSource() {
    XCTAssertEqual(
      shape(Document.parse("<picture><source srcset=\"a.png\"></picture>\n").blocks),
      "p(img(a.png sources=[any:a.png]: \"\"))")
  }

  func testHostileHTML() throws {
    let hostile = Document.parse(try fixture("hostile-html"))
    XCTAssertEqual(
      shape(hostile.blocks),
      [
        "div(center)[p(\"Safe \" strong(\"text\"))]",
        "p(\"tab trick \" link(https://ok.example: \"ok\"))",
        "p(\"md link \")",
        "p(\"svg\")",
        "p(\"After.\")",
      ].joined(separator: ", "))
  }

  func testOriginalHostileFixture() throws {
    XCTAssertEqual(
      shape(Document.parse(try fixture("hostile")).blocks),
      "h1(\"Hostile\"), plain(img(x: \"\")), p(\"x\")")
  }

  func testUnsafeURLSchemes() {
    XCTAssertEqual(
      paragraphShape("[a](JAVASCRIPT:x) [b](data:text/html,x) [c](/path:with/colon)"),
      "\"a b \" link(/path:with/colon: \"c\")")
    XCTAssertEqual(paragraphShape("x <a href=\" javascript:x\">y</a>"), "\"x y\"")
  }
}
