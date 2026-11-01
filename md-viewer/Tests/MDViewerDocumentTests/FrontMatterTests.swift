import MDViewerDocument
import XCTest

final class FrontMatterTests: XCTestCase {
  func keys(_ markdown: String) -> [String] {
    FrontMatter.split(markdown).entries.map(\.key)
  }

  func testFixtureBecomesEntries() throws {
    let document = Document.parse(try fixture("frontmatter"))
    XCTAssertEqual(document.frontMatter.map(\.key), ["title", "status", "tags", "author"])
    XCTAssertEqual(document.frontMatter[0].value, "Release plan")
    XCTAssertEqual(document.frontMatter[2].value, "- rex\n- md-viewer")
    XCTAssertEqual(document.frontMatter[3].value, "\"<script>window.__pwned=1</script>\"")
    XCTAssertFalse(document.blocks.contains { $0.isThematicBreak })
    let headings = document.headings()
    XCTAssertEqual(headings.map(\.level), [1])
    XCTAssertEqual(headings.map { shape($0.content) }, ["\"Body heading\""])
  }

  func testBodyPositionsCountFrontMatterLines() throws {
    let document = Document.parse(try fixture("frontmatter"))
    XCTAssertEqual(
      document.blocks[0].range, SourceRange(start: .init(line: 11, column: 1), end: .init(line: 11, column: 14)))
  }

  func testLeadingRuleWithoutClosingIsNotFrontMatter() throws {
    let document = Document.parse(try fixture("leading-rule"))
    XCTAssertTrue(document.frontMatter.isEmpty)
    XCTAssertEqual(document.blocks.filter(\.isThematicBreak).count, 1)
  }

  func testRulesAroundProseAreNotFrontMatter() {
    let document = Document.parse("---\n\nIntro paragraph.\n\n---\n\n# Heading\n")
    XCTAssertTrue(document.frontMatter.isEmpty)
    XCTAssertEqual(document.blocks.compactMap(\.paragraph).map(shape), ["\"Intro paragraph.\""])
    XCTAssertEqual(document.blocks.filter(\.isThematicBreak).count, 2)
  }

  func testRuleBeforeSetextHeadingIsNotFrontMatter() {
    let document = Document.parse("---\n\nTitle\n---\nbody\n")
    XCTAssertTrue(document.frontMatter.isEmpty)
    XCTAssertEqual(document.headings().map(\.level), [2])
    XCTAssertEqual(document.headings().map { shape($0.content) }, ["\"Title\""])
  }

  func testEmptyFrontMatterOnlyStripsDelimiters() {
    let markdown = "---\n---\n# Heading\n\ntext\n\n---\n\nmore\n"
    let split = FrontMatter.split(markdown)
    XCTAssertTrue(split.entries.isEmpty)
    XCTAssertEqual(split.body, "# Heading\n\ntext\n\n---\n\nmore\n")
    XCTAssertEqual(split.bodyLineOffset, 2)
    let document = Document.parse(markdown)
    XCTAssertEqual(document.blocks.filter(\.isThematicBreak).count, 1)
    XCTAssertEqual(document.headings().map { shape($0.content) }, ["\"Heading\""])
    XCTAssertEqual(document.blocks.compactMap(\.paragraph).map(shape), ["\"text\"", "\"more\""])
    XCTAssertEqual(document.blocks[0].range.start, SourcePosition(line: 3, column: 1))
  }

  func testVariants() {
    for markdown in [
      "---\r\ntitle: CRLF\r\n---\r\n# Heading\r\n",
      "\u{FEFF}---\ntitle: BOM\n---\n# Heading\n",
      "---\ntitle: Dots\n...\n# Heading\n",
      "--- \t\ntitle: Spaces\n---  \n# Heading\n",
    ] {
      let document = Document.parse(markdown)
      XCTAssertEqual(document.frontMatter.map(\.key), ["title"], markdown)
      XCTAssertEqual(document.headings().map { shape($0.content) }, ["\"Heading\""], markdown)
      XCTAssertEqual(document.blocks[0].range.start.line, 4, markdown)
    }
    XCTAssertEqual(FrontMatter.split("---\r\ntitle: CRLF\r\n---\r\n").entries.map(\.value), ["CRLF"])
  }

  func testClosingAtEndOfInput() {
    let split = FrontMatter.split("---\ntitle: End\n---")
    XCTAssertEqual(split.entries, [FrontMatterEntry(key: "title", value: "End")])
    XCTAssertEqual(split.body, "")
  }

  func testUnterminatedIsNotFrontMatter() {
    let markdown = "---\ntitle: Open\n# Heading\n"
    let split = FrontMatter.split(markdown)
    XCTAssertTrue(split.entries.isEmpty)
    XCTAssertEqual(split.body, markdown)
    XCTAssertEqual(split.bodyLineOffset, 0)
  }

  func testDelimiterVariantsThatDoNotOpenOrClose() {
    XCTAssertEqual(keys("----\ntitle: x\n---\n"), [])
    XCTAssertEqual(keys("---\ntitle: x\n----\n"), [])
    XCTAssertEqual(keys("---\ntitle: x\n--- trailing\n"), [])
    XCTAssertEqual(keys(" ---\ntitle: x\n---\n"), [])
    XCTAssertEqual(keys("---\ntitle: x\n---\r"), [])
  }

  func testCommentsAndBlankLinesAreSkipped() {
    let split = FrontMatter.split("---\n# comment\n\n  # indented comment\ntitle: x\n\n---\nbody\n")
    XCTAssertEqual(split.entries, [FrontMatterEntry(key: "title", value: "x")])
    XCTAssertEqual(split.body, "body\n")
  }

  func testCommentOnlyFrontMatterIsNotFrontMatter() {
    let markdown = "---\n# only a comment\n---\nbody\n"
    XCTAssertTrue(FrontMatter.split(markdown).entries.isEmpty)
    XCTAssertEqual(FrontMatter.split(markdown).body, markdown)
  }

  func testNonFieldLineMakesItNotFrontMatter() {
    XCTAssertEqual(keys("---\ntitle: x\nplain line\n---\n"), [])
    XCTAssertEqual(keys("---\n- item\n---\n"), [])
    XCTAssertEqual(keys("---\n  indented first\n---\n"), [])
    XCTAssertEqual(keys("---\n:colon first\n---\n"), [])
    XCTAssertEqual(keys("---\n#hash: first\n---\n"), [])
    XCTAssertEqual(keys("---\nkey:value\n---\n"), [])
  }

  func testFieldForms() {
    let split = FrontMatter.split("---\nempty:\nspaced:   \nurl: http://a.b:8080/x\n key with space : v \n---\n")
    XCTAssertEqual(
      split.entries,
      [
        FrontMatterEntry(key: "empty", value: ""),
        FrontMatterEntry(key: "spaced", value: ""),
        FrontMatterEntry(key: "url", value: "http://a.b:8080/x\nkey with space : v "),
      ])
    XCTAssertEqual(keys("---\nkey with space : v \n---\n"), ["key with space"])
    XCTAssertEqual(FrontMatter.split("---\nkey with space : v \n---\n").entries.map(\.value), ["v"])
  }

  func testNestedLinesStripCommonIndent() {
    let split = FrontMatter.split("---\nlist:\n    - a\n      - b\n    - c\ntext: first\n  more\n---\n")
    XCTAssertEqual(
      split.entries,
      [
        FrontMatterEntry(key: "list", value: "- a\n  - b\n- c"),
        FrontMatterEntry(key: "text", value: "first\nmore"),
      ])
  }

  func testByteOrderMarkWithoutFrontMatterIsKept() {
    let markdown = "\u{FEFF}# Heading\n"
    XCTAssertEqual(FrontMatter.split(markdown).body, markdown)
    XCTAssertEqual(Document.parse(markdown).headings().map { shape($0.content) }, ["\"Heading\""])
  }
}
