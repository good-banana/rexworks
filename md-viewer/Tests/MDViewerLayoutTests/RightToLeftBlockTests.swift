import CoreGraphics
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class RightToLeftBlockTests: XCTestCase {
  private func rect(_ page: PageLayout, _ needle: String) throws -> CGRect {
    try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: needle), needle)).first, needle).rect
  }

  func testCodeLinesKeepLeftToRightBase() throws {
    let page = layout("```\n// مرحبا x = 1\n```")
    let slash = try rect(page, "//")
    let assignment = try rect(page, "x = 1")
    let padding = page.prepared.typography.pixels(em: page.prepared.typography.codePadding)
    XCTAssertEqual(slash.minX, page.contentLeft + padding, accuracy: 1)
    XCTAssertLessThan(slash.maxX, try rect(page, "مرحبا").minX)
    XCTAssertLessThan(try rect(page, "مرحبا").maxX, assignment.minX)
    XCTAssertTrue(page.prepared.segments.allSatisfy { $0.drawOffset == 0 })
  }

  func testBulletAndNumberedListsMirror() throws {
    let page = layout("- عنصر أول\n- عنصر ثان\n\n1. خطوة واحدة\n2. خطوة ثانية\n\n- English item")
    let right = page.contentLeft + page.contentWidth
    let indent = page.prepared.typography.pixels(em: page.prepared.typography.listIndent)
    let first = try rect(page, "عنصر أول")
    XCTAssertEqual(first.maxX, right - indent, accuracy: 1)
    let markers = page.labels.map { (page.prepared.labels[$0.label].text, $0.origin.x) }
    XCTAssertEqual(markers.map(\.0), ["\u{2022}", "\u{2022}", "1.", "2.", "\u{2022}"])
    for (_, x) in markers.prefix(4) {
      XCTAssertGreaterThan(x, first.maxX)
      XCTAssertLessThan(x, right)
    }
    let english = try rect(page, "English item")
    XCTAssertEqual(english.minX, page.contentLeft + indent, accuracy: 1)
    XCTAssertLessThan(try XCTUnwrap(markers.last).1, english.minX)
  }

  func testTaskListMirrors() throws {
    let page = layout("- [x] مهمة منجزة\n- [ ] مهمة مفتوحة")
    let text = try rect(page, "مهمة منجزة")
    let boxes = page.decorations {
      if case .taskBox = $0 { return true }
      return false
    }
    XCTAssertEqual(boxes.count, 2)
    for box in boxes {
      XCTAssertGreaterThan(box.rect.minX, text.maxX)
      XCTAssertLessThan(box.rect.maxX, page.contentLeft + page.contentWidth)
    }
    let target = try XCTUnwrap(page.targets.first { if case .task = $0.target { return true } else { return false } })
    XCTAssertEqual(target.rect, boxes[0].rect)
  }

  func testBlockquoteAndAlertBarsMirror() throws {
    let page = layout("> اقتباس باللغة العربية\n\n> [!NOTE]\n> ملاحظة مهمة\n\n> English quote")
    let right = page.contentLeft + page.contentWidth
    let bars = page.decorations { $0 == .blockquoteBar }
    XCTAssertEqual(bars.count, 2)
    XCTAssertEqual(bars[0].rect.maxX, right, accuracy: 0.5)
    XCTAssertEqual(bars[1].rect.minX, page.contentLeft, accuracy: 0.5)
    let quote = try rect(page, "اقتباس")
    XCTAssertLessThan(quote.maxX, bars[0].rect.minX)
    let alertBar = try XCTUnwrap(page.decorations { $0 == .alertBar(.note) }.first)
    XCTAssertEqual(alertBar.rect.maxX, right, accuracy: 0.5)
    let icon = try XCTUnwrap(page.decorations { $0 == .alertIcon(.note) }.first)
    XCTAssertLessThan(icon.rect.maxX, alertBar.rect.minX)
    let title = try XCTUnwrap(page.labels.first { page.prepared.labels[$0.label].role == .alertTitle(.note) })
    XCTAssertLessThan(title.origin.x, icon.rect.minX)
    XCTAssertLessThan(try rect(page, "ملاحظة").maxX, alertBar.rect.minX)
  }
}
