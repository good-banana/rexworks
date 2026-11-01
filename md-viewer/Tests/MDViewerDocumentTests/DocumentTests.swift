import MDViewerDocument
import XCTest

final class DocumentTests: XCTestCase {
  var document: Document!

  override func setUpWithError() throws {
    document = Document.parse(try fixture("all-nodes"))
  }

  func testFixtureBlockSequence() {
    let names = document.blocks.map { block -> String in
      switch block.kind {
      case .heading(let heading): "h\(heading.level)"
      case .paragraph: "p"
      case .blockQuote: "quote"
      case .alert(let alert): "alert-\(alert.kind.rawValue)"
      case .list(let list): list.items.first?.task == nil ? "list" : "tasks"
      case .codeBlock(let code): code.isFenced ? "fence" : "indented"
      case .table: "table"
      case .footnoteDefinition: "footnote"
      case .details: "details"
      case .division: "division"
      case .plain: "plain"
      case .thematicBreak: "hr"
      }
    }
    XCTAssertEqual(
      names,
      [
        "h1", "h2", "h3", "p", "p", "list", "list", "tasks", "quote", "alert-warning", "fence", "indented",
        "table", "p", "hr", "p", "details", "footnote",
      ])
  }

  func testHeadings() {
    let headings = document.headings()
    XCTAssertEqual(headings.map(\.level), [1, 2, 3])
    XCTAssertEqual(headings.map(\.slug), ["heading-one", "setext-two", "heading-three-with-code"])
    XCTAssertEqual(shape(headings[2].content), "\"Heading \" em(\"Three\") \" with \" code(\"code\")")
    let levels = Document.parse((1...6).map { String(repeating: "#", count: $0) + " h\($0)\n" }.joined())
    XCTAssertEqual(levels.headings().map(\.level), [1, 2, 3, 4, 5, 6])
  }

  func testInlineFormatting() {
    XCTAssertEqual(
      shape(document.blocks[3].paragraph ?? []),
      [
        "\"A paragraph with \" em(\"emphasis\") \", \" strong(\"strong\") \", \" del(\"struck\") \", \"",
        "code(\"inline code\") \",\" soft \"a \" link(https://example.com title=Title: \"link\") \", an \"",
        "img(img.png title=Pic: \"image\") \" and a soft break.\" soft \"Hard break one\" hard",
        "\"and with a backslash\" hard \"done.\"",
      ].joined(separator: " "))
  }

  func testHardBreakFromTrailingSpaces() {
    XCTAssertEqual(paragraphShape("two\u{20}\u{20}\nlines"), "\"two\" hard \"lines\"")
  }

  func testAutolinks() {
    XCTAssertEqual(
      shape(document.blocks[4].paragraph ?? []),
      [
        "\"Autolinks: \" autolink(https://angle.example: \"https://angle.example\") \", \"",
        "autolink(https://bare.example: \"https://bare.example\") \", \"",
        "autolink(http://www.web.example: \"www.web.example\") \" and \"",
        "autolink(mailto:mail@example.com: \"mail@example.com\") \".\"",
      ].joined(separator: " "))
    XCTAssertEqual(
      paragraphShape("[https://a.example](https://a.example)"), "link(https://a.example: \"https://a.example\")")
  }

  func testLists() throws {
    let bullet = try XCTUnwrap(document.blocks[5].list)
    XCTAssertEqual(bullet.kind, .bullet)
    XCTAssertTrue(bullet.isTight)
    XCTAssertEqual(bullet.items.map { shape($0.blocks[0].paragraph ?? []) }, ["\"one\"", "\"two\""])
    XCTAssertEqual(bullet.items.map(\.task), [nil, nil])

    let ordered = try XCTUnwrap(document.blocks[6].list)
    XCTAssertEqual(ordered.kind, .ordered(start: 3))
    XCTAssertFalse(ordered.isTight)
    XCTAssertEqual(ordered.items.count, 3)
    XCTAssertEqual(ordered.items[2].range.start, SourcePosition(line: 22, column: 1))
  }

  func testTaskItems() throws {
    let tasks = try XCTUnwrap(document.blocks[7].list)
    XCTAssertEqual(tasks.items.map(\.task), [.unchecked, .checked])
    XCTAssertEqual(tasks.items.map { shape($0.blocks[0].paragraph ?? []) }, ["\"open task\"", "\"done task\""])
    let upper = try XCTUnwrap(Document.parse("- [X] upper\n- plain\n").blocks.first?.list)
    XCTAssertEqual(upper.items.map(\.task), [.checked, nil])
  }

  func testBlockQuotes() throws {
    let quote = try XCTUnwrap(document.blocks[8].quote)
    XCTAssertEqual(shape(quote[0].paragraph ?? []), "\"Quote line\"")
    let nested = try XCTUnwrap(quote[1].quote)
    XCTAssertEqual(shape(nested[0].paragraph ?? []), "\"Nested quote\"")
  }

  func testCodeBlocks() throws {
    let fenced = try XCTUnwrap(document.blocks[10].codeBlock)
    XCTAssertEqual(fenced, CodeBlock(info: "swift title=\"demo.swift\"", code: "let x = 1\n", isFenced: true))
    XCTAssertEqual(fenced.language, "swift")
    let indented = try XCTUnwrap(document.blocks[11].codeBlock)
    XCTAssertEqual(indented, CodeBlock(info: "", code: "indented code\n", isFenced: false))
    XCTAssertNil(indented.language)
    let tilde = try XCTUnwrap(Document.parse("~~~mermaid\ngraph\n~~~\n").blocks.first?.codeBlock)
    XCTAssertEqual(tilde.language, "mermaid")
    XCTAssertEqual(tilde.code, "graph\n")
  }

  func testTables() throws {
    let table = try XCTUnwrap(document.blocks[12].table)
    XCTAssertEqual(table.alignments, [.left, .center, .right, .none])
    let header = try XCTUnwrap(table.header)
    XCTAssertEqual(header.cells.map(cellText), ["\"Left\"", "\"Center\"", "\"Right\"", "\"None\""])
    XCTAssertEqual(header.cells.map(\.isHeader), [true, true, true, true])
    XCTAssertEqual(table.rows.map { $0.cells.map(cellText) }, [["\"a\"", "\"b\"", "\"c\"", "\"d\""]])
    XCTAssertEqual(table.rows[0].cells.map(\.alignment), [.left, .center, .right, .none])
    XCTAssertEqual(table.rows[0].cells.map(\.isHeader), [false, false, false, false])
    XCTAssertEqual(table.rows[0].range.start.line, header.range.start.line + 2)
  }

  func testTableFormattingAndShortRows() throws {
    let table = try XCTUnwrap(Document.parse("| a | b |\n|---|---|\n| **x** |\n").blocks.first?.table)
    XCTAssertEqual(table.rows[0].cells.map(cellText), ["strong(\"x\")", ""])
  }

  func testFootnotes() throws {
    XCTAssertEqual(shape(document.blocks[13].paragraph ?? []), "\"Footnote reference.\" fn(note 1)")
    let footnote = try XCTUnwrap(document.blocks.last?.footnote)
    XCTAssertEqual(footnote.label, "note")
    XCTAssertEqual(footnote.number, 1)
    XCTAssertEqual(shape(footnote.blocks[0].paragraph ?? []), "\"The footnote text.\"")
    XCTAssertEqual(document.blocks.last?.range.start.line, 46)
  }

  func testFootnoteNumberingFollowsReferenceOrder() {
    let parsed = Document.parse("B[^b] A[^a] B again[^b] missing[^x]\n\n[^a]: A.\n[^b]: B.\n[^unused]: U.\n")
    XCTAssertEqual(
      shape(parsed.blocks[0].paragraph ?? []),
      "\"B\" fn(b 1) \" A\" fn(a 2) \" B again\" fn(b 1) \" missing[^x]\"")
    XCTAssertEqual(parsed.blocks.compactMap(\.footnote).map(\.label), ["b", "a"])
    XCTAssertEqual(parsed.blocks.compactMap(\.footnote).map(\.number), [1, 2])
  }

  func testThematicBreak() {
    XCTAssertTrue(document.blocks[14].isThematicBreak)
    XCTAssertEqual(Document.parse("***\n___\n").blocks.filter(\.isThematicBreak).count, 2)
  }

  func testSourceRanges() {
    XCTAssertEqual(
      document.blocks[0].range, SourceRange(start: .init(line: 1, column: 1), end: .init(line: 1, column: 13)))
    XCTAssertEqual(
      document.blocks[1].range, SourceRange(start: .init(line: 3, column: 1), end: .init(line: 4, column: 10)))
    let paragraph = document.blocks[3]
    XCTAssertEqual(paragraph.range.start.line, 8)
    XCTAssertEqual(paragraph.range.end.line, 12)
    let first = try? XCTUnwrap(paragraph.paragraph?.first)
    XCTAssertEqual(first?.range.start, SourcePosition(line: 8, column: 1))
  }

  func testRangesNormalizeCmarkQuirks() throws {
    func range(_ block: Block) -> String {
      "\(block.range.start.line):\(block.range.start.column)-\(block.range.end.line):\(block.range.end.column)"
    }
    XCTAssertEqual(range(document.blocks[5]), "16:1-17:5")
    XCTAssertEqual(range(document.blocks[11]), "38:5-38:17")
    XCTAssertEqual(range(document.blocks[14]), "48:1-48:3")
    XCTAssertEqual(range(try XCTUnwrap(document.blocks.last)), "46:1-46:27")
    let quoted = try XCTUnwrap(Document.parse("> <pre>\r\n> x\r\n> </pre>\r\n\r\nafter\r\n").blocks.first?.quote)
    XCTAssertEqual(range(quoted[0]), "1:3-3:8")
    let breaks = (document.blocks[3].paragraph ?? []).filter { $0.kind == .softBreak || $0.kind == .hardBreak }
    XCTAssertEqual(
      breaks.map(\.range.start),
      [
        .init(line: 8, column: 68), .init(line: 9, column: 84), .init(line: 10, column: 15),
        .init(line: 11, column: 21),
      ])
  }

  func testEmptyDocument() {
    XCTAssertEqual(Document.parse(""), Document(frontMatter: [], blocks: []))
  }

  func testPlainText() {
    let inlines = Document.parse("a *b* `c` [d](e) ![f](g)\nh\\\ni").blocks[0].paragraph ?? []
    XCTAssertEqual(inlines.plainText, "a b c d f h\ni")
  }
}
