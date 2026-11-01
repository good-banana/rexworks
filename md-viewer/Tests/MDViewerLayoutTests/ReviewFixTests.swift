import CoreGraphics
import Foundation
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class ReviewFixTests: XCTestCase {
  private func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
  }

  func testHugeUnbreakableWordIsLinear() throws {
    let word = String(repeating: "abcdefghij", count: 12_000)
    let prepared = prepare("Start \(word) end\n\n```\n\(word)\n```")
    XCTAssertTrue(prepared.segments.allSatisfy { $0.range.count <= 256 })
    var page: PageLayout?
    let layoutTime = milliseconds { page = prepared.layout(width: 900) }
    let result = try XCTUnwrap(page)
    let range = try XCTUnwrap(result.range(of: word))
    XCTAssertEqual(result.plainText(range), word)
    var rects: [HighlightRect] = []
    let rectTime = milliseconds { rects = result.rects(for: range) }
    XCTAssertGreaterThan(rects.count, 100)
    let probe = try XCTUnwrap(rects.dropFirst(rects.count / 2).first).rect
    var position: TextPosition?
    let hitTime = milliseconds { position = result.textPosition(at: CGPoint(x: probe.midX, y: probe.midY)) }
    XCTAssertTrue(range.contains(try XCTUnwrap(position).offset))
    let region = try XCTUnwrap(result.regions.first)
    XCTAssertGreaterThan(region.contentWidth, 100_000)
    print(
      String(
        format: "120K-char word: layout %.2f ms, rects %.2f ms, hit test %.3f ms", layoutTime, rectTime, hitTime))
    XCTAssertLessThan(layoutTime, 2000)
    XCTAssertLessThan(rectTime, 500)
    XCTAssertLessThan(hitTime, 500)
    for fragment in result.fragments(in: range) where fragment.region == nil {
      XCTAssertLessThanOrEqual(fragment.maxX, result.contentLeft + result.contentWidth + 0.5)
    }
  }

  func testMarkdownCopyWithCRLFAndCRLineEndings() throws {
    for ending in ["\r\n", "\r"] {
      let markdown = ["# Title", "", "Para one", "line two", "", "| a | b |", "| - | - |", "| 1 | 2 |", ""]
        .joined(separator: ending)
      let page = layout(markdown)
      let cell = try XCTUnwrap(page.range(of: "1"))
      XCTAssertEqual(page.markdown(cell), "| a | b |\n| - | - |\n| 1 | 2 |", ending.debugDescription)
      let para = try XCTUnwrap(page.range(of: "Para one"))
      XCTAssertEqual(page.markdown(para), "Para one\nline two", ending.debugDescription)
    }
    XCTAssertEqual(PreparedDocument.lines("a\r\nb\rc\n\nd"), ["a", "b", "c", "", "d"])
  }

  private func minX(_ page: PageLayout, _ word: String) throws -> CGFloat {
    let rect = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: word))).first, word).rect
    XCTAssertGreaterThan(rect.width, 0, word)
    return rect.minX
  }

  func testRightToLeftParagraphOrderAlignmentAndHighlights() throws {
    let page = layout("שלום עולם")
    XCTAssertGreaterThan(try minX(page, "שלום"), try minX(page, "עולם"))
    let first = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: "שלום"))).first).rect
    XCTAssertEqual(first.maxX, page.contentLeft + page.contentWidth, accuracy: 1)
    let arabic = layout("مرحبا بالعالم")
    XCTAssertGreaterThan(try minX(arabic, "مرحبا"), try minX(arabic, "بالعالم"))
    let whole = arabic.rects(for: 0..<arabic.prepared.text.length)
    XCTAssertFalse(whole.isEmpty)
    XCTAssertTrue(whole.allSatisfy { $0.rect.width > 0 })
    let point = try XCTUnwrap(arabic.center(of: "مرحبا"))
    let position = try XCTUnwrap(arabic.textPosition(at: point))
    XCTAssertTrue(try XCTUnwrap(arabic.range(of: "مرحبا")).contains(position.offset))
  }

  func testMixedDirectionLines() throws {
    let ltr = layout("Hello שלום עולם world")
    let ltrOrder = try ["Hello", "עולם", "שלום", "world"].map { try minX(ltr, $0) }
    XCTAssertEqual(ltrOrder, ltrOrder.sorted())
    XCTAssertEqual(try minX(ltr, "Hello"), ltr.contentLeft, accuracy: 1)
    let rtl = layout("שלום hello world עולם")
    let rtlOrder = try ["עולם", "hello", "world", "שלום"].map { try minX(rtl, $0) }
    XCTAssertEqual(rtlOrder, rtlOrder.sorted())
    XCTAssertEqual(rtl.plainText(0..<rtl.prepared.text.length), "שלום hello world עולם")
  }

  func testWrappedRightToLeftLinesStayInBounds() throws {
    let page = layout(Array(repeating: "שלום עולם", count: 40).joined(separator: " "), width: 600)
    XCTAssertGreaterThan(Set(page.fragments.map(\.lineTop)).count, 3)
    for rect in page.rects(for: 0..<page.prepared.text.length) {
      XCTAssertGreaterThanOrEqual(rect.rect.minX, page.contentLeft - 1)
      XCTAssertLessThanOrEqual(rect.rect.maxX, page.contentLeft + page.contentWidth + 1)
    }
  }

  func testCodeBlockInfoIsExposed() throws {
    let long = String(repeating: "x", count: 400)
    let prepared = prepare("```swift\nlet a = 1\n\(long)\n```\n\n```mermaid\ngraph TD\n```")
    let page = prepared.layout(width: 800)
    let region = try XCTUnwrap(page.regions.first)
    let info = try XCTUnwrap(prepared.codeBlocks[region.id])
    XCTAssertEqual(info.language, "swift")
    XCTAssertEqual(info.code, "let a = 1\n\(long)\n")
    XCTAssertEqual(info.lineRanges.map { page.plainText($0) }, ["let a = 1", long])
    XCTAssertEqual(region.kind, .codeBlock(language: "swift"))
    XCTAssertTrue(page.targets.contains { $0.target == .copyCode(region.id, language: "swift") })
    XCTAssertTrue(prepared.codeBlocks.values.contains { $0.isDiagram && $0.code == "graph TD\n" })
  }

  func testAlignedDivisionsOffsetTables() throws {
    let table = "| A | B |\n| - | - |\n| 1 | 2 |"
    for (align, expected) in [("center", 0.5), ("right", 1.0)] {
      let page = layout("<div align=\"\(align)\">\n\n\(table)\n\n</div>")
      let fill = try XCTUnwrap(page.decorations { $0 == .tableHeaderFill }.first).rect
      XCTAssertLessThan(fill.width, page.contentWidth / 2)
      let slack = page.contentWidth - fill.width
      XCTAssertEqual(fill.minX - page.contentLeft, slack * expected, accuracy: 1, align)
      let cell = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: "1"))).first).rect
      XCTAssertTrue(fill.minX < cell.minX && cell.maxX < fill.maxX)
    }
    let plain = layout(table)
    XCTAssertEqual(try XCTUnwrap(plain.decorations { $0 == .tableHeaderFill }.first).rect.minX, plain.contentLeft)
  }

  func testHeaderCellsWithoutAlignmentCenter() throws {
    let page = layout("| H | Left |\n| --- | :--- |\n| a much longer value | x |")
    let borders = page.decorations { $0 == .tableCellBorder }
    let header = try XCTUnwrap(page.center(of: "H"))
    let headerCell = try XCTUnwrap(borders.first { $0.rect.contains(header) }).rect
    XCTAssertEqual(header.x, headerCell.midX, accuracy: 1)
    let left = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: "Left"))).first).rect
    let leftCell = try XCTUnwrap(borders.first { $0.rect.contains(CGPoint(x: left.midX, y: left.midY)) }).rect
    let padding = page.prepared.typography.pixels(em: page.prepared.typography.tableCellPadding.width)
    XCTAssertEqual(left.minX, leftCell.minX + padding, accuracy: 1)
    let body = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: "a much"))).first).rect
    XCTAssertEqual(body.minX, headerCell.minX + padding, accuracy: 1)
  }

  func testTypographyClamps() {
    XCTAssertEqual(Typography(zoom: 100).zoom, 5)
    XCTAssertEqual(Typography(zoom: 0).zoom, 0.25)
    XCTAssertEqual(Typography(zoom: .nan).zoom, 1)
    XCTAssertEqual(Typography(bodySize: 1000).bodySize, 72)
    XCTAssertEqual(Typography(backingScale: -2).backingScale, 1)
    var typography = Typography()
    typography.zoom = 50
    XCTAssertEqual(typography.scale, 10)
    XCTAssertEqual(Typography.backingScale(cellPixelHeight: 30, screenScale: 9), 4)
    XCTAssertGreaterThan(PreparedDocument(markdown: "text", typography: typography).layout(width: 4000).height, 0)
  }

  func testWordRangeUsesWordBoundaries() throws {
    let page = layout("hi 👍🏽 there 日本語のテキストです beta_gamma.")
    let emoji = try XCTUnwrap(page.range(of: "👍🏽"))
    XCTAssertEqual(page.wordRange(at: emoji.lowerBound + 1), emoji)
    let katakana = try XCTUnwrap(page.range(of: "テキスト"))
    XCTAssertEqual(page.wordRange(at: katakana.lowerBound + 2), katakana)
    let snake = try XCTUnwrap(page.range(of: "gamma"))
    XCTAssertEqual(page.plainText(page.wordRange(at: snake.lowerBound)), "beta_gamma")
    let end = page.prepared.text.length
    XCTAssertEqual(page.plainText(page.wordRange(at: end)), ".")
  }

  func testLinksInsideSummaryWinOverTheToggle() throws {
    let page = layout(
      "<details>\n<summary>See <a href=\"https://x.test\">docs</a> here</summary>\n\nBody.\n\n</details>")
    XCTAssertEqual(page.target(at: try XCTUnwrap(page.center(of: "docs"))), .link("https://x.test"))
    guard case .detailsToggle = page.target(at: try XCTUnwrap(page.center(of: "here"))) else {
      return XCTFail("summary text is not a toggle")
    }
  }

  func testSendableConformances() {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(PreparedDocument.self)
    requireSendable(PageLayout.self)
    requireSendable(LayoutInput.self)
    let page = layout("text")
    let done = expectation(description: "background read")
    DispatchQueue.global().async {
      XCTAssertEqual(page.plainText(0..<4), "text")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }

  func testHitTestingLandsOnGraphemeBoundaries() throws {
    let line = "e\u{301}\u{301}x 👨‍👩‍👧 y 🇯🇵 a\u{308}b"
    let page = layout(line)
    let text = page.prepared.text
    let rect = try XCTUnwrap(page.rects(for: 0..<text.length).first).rect
    var x = rect.minX - 2
    while x < rect.maxX + 2 {
      let offset = try XCTUnwrap(page.textPosition(at: CGPoint(x: x, y: rect.midY))).offset
      if offset < text.length {
        XCTAssertEqual(text.rangeOfComposedCharacterSequence(at: offset).location, offset, "x \(x)")
      }
      x += 0.5
    }
    let family = try XCTUnwrap(page.range(of: "👨‍👩‍👧"))
    XCTAssertEqual(page.wordRange(at: family.lowerBound + 2), family)
  }
}
