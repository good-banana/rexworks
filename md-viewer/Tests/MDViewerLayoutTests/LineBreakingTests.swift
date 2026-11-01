import CoreGraphics
import MDViewerDocument
import XCTest

@testable import MDViewerLayout

final class LineBreakingTests: XCTestCase {
  private let paragraph =
    "The quick brown fox jumps over the lazy dog while the indexer keeps writing change events to the stream, "
    + "and the reviewers read every line twice before approving the rollout plan for production."

  func testLineCountShrinksAsWidthGrows() {
    let prepared = prepare(paragraph)
    let counts = [500, 900, 1600, 3200].map { width in
      Set(prepared.layout(width: CGFloat(width)).fragments.map(\.lineTop)).count
    }
    XCTAssertGreaterThan(counts[0], counts[1])
    XCTAssertGreaterThan(counts[1], counts[2])
    XCTAssertGreaterThanOrEqual(counts[2], counts[3])
    XCTAssertEqual(counts[3], 1)
  }

  func testLinesStayInsideTheContentWidth() {
    let prepared = prepare(paragraph)
    for width in stride(from: 300, through: 2000, by: 170) {
      let page = prepared.layout(width: CGFloat(width))
      let right = page.contentLeft + page.contentWidth
      for fragment in page.fragments {
        let segment = prepared.segments[fragment.segment]
        let visibleRight = fragment.isClipped ? fragment.maxX : fragment.maxX - segment.trailingWhitespace
        XCTAssertLessThanOrEqual(visibleRight, right + 0.5, "width \(width)")
        XCTAssertGreaterThanOrEqual(fragment.minX, page.contentLeft - 0.5)
      }
    }
  }

  func testFragmentsFollowTextOrderAndCoverTheText() {
    let page = layout(paragraph, width: 700)
    let covered = page.fragments.map(\.range)
    XCTAssertEqual(covered.first?.lowerBound, 0)
    XCTAssertEqual(covered.last?.upperBound, page.prepared.text.length)
    for (previous, next) in zip(covered, covered.dropFirst()) {
      XCTAssertEqual(previous.upperBound, next.lowerBound)
    }
    var lastTop = -CGFloat.infinity
    for fragment in page.fragments {
      XCTAssertGreaterThanOrEqual(fragment.lineTop, lastTop)
      lastTop = fragment.lineTop
    }
  }

  func testNoBreakBetweenStyleRunsWithoutSpace() {
    let prepared = prepare("Start " + String(repeating: "filler ", count: 30) + "foo**bar**baz end")
    for width in stride(from: 300, through: 1500, by: 37) {
      let page = prepared.layout(width: CGFloat(width))
      XCTAssertEqual(page.lineTops(for: "foobarbaz").count, 1, "width \(width)")
    }
  }

  func testOverlongWordBreaksInsideTheWord() throws {
    let url = String(repeating: "abcdefghij", count: 30)
    let page = layout("See \(url) now", width: 400)
    let range = try XCTUnwrap(page.range(of: url))
    let pieces = page.fragments(in: range)
    XCTAssertGreaterThan(Set(pieces.map(\.lineTop)).count, 2)
    XCTAssertTrue(pieces.contains(where: \.isClipped))
    for piece in pieces { XCTAssertLessThanOrEqual(piece.maxX, page.contentLeft + page.contentWidth + 0.5) }
    XCTAssertEqual(page.plainText(range), url)
  }

  func testHardBreakForcesNewLine() {
    let page = layout("first line  \nsecond line\\\nthird line")
    let tops = ["first", "second", "third"].map { page.lineTops(for: $0).first ?? -1 }
    XCTAssertLessThan(tops[0], tops[1])
    XCTAssertLessThan(tops[1], tops[2])
    XCTAssertEqual(page.plainText(0..<page.prepared.text.length), "first line\nsecond line\nthird line")
  }

  func testCenteredAndRightAlignedLines() throws {
    let page = layout("<p align=\"center\">Centered words</p>\n\n<p align=\"right\">Right words</p>", width: 1200)
    let center = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: "Centered words"))).first?.rect)
    XCTAssertEqual(center.midX, page.contentLeft + page.contentWidth / 2, accuracy: 2)
    let right = try XCTUnwrap(page.rects(for: XCTUnwrap(page.range(of: "Right words"))).first?.rect)
    XCTAssertEqual(right.maxX, page.contentLeft + page.contentWidth, accuracy: 2)
  }

  func testCJKTextBreaksBetweenCharacters() {
    let page = layout(String(repeating: "日本語のテキスト", count: 20), width: 400)
    XCTAssertGreaterThan(Set(page.fragments.map(\.lineTop)).count, 2)
    XCTAssertFalse(page.fragments.contains(where: \.isClipped))
  }
}
